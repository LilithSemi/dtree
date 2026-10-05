const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Self = @This();

pub const Node = union(enum) {
    begin: Begin,
    end: End,
    prop: Prop,

    pub const Begin = struct {
        depth: usize,
        name: []const u8,

        pub fn format(self: Begin, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(@typeName(Begin));
            try writer.print("{{ .depth = {d}, .name = \"{s}\" }}", .{
                self.depth,
                self.name,
            });
        }
    };

    pub const End = struct {
        depth: usize,
    };

    pub const Prop = struct {
        depth: usize,
        name: []const u8,
        value: []const u8,

        pub fn format(self: Prop, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(@typeName(Prop));
            try writer.print("{{ .depth = {d}, .name = \"{s}\", .value = {any} }}", .{
                self.depth,
                self.name,
                self.value,
            });
        }
    };

    pub fn name(self: Node) ?[]const u8 {
        return switch (self) {
            .begin => |b| b.name,
            .end => null,
            .prop => |p| p.name,
        };
    }

    pub fn depth(self: Node) usize {
        return switch (self) {
            .begin => |b| b.depth,
            .end => |e| e.depth,
            .prop => |p| p.depth,
        };
    }
};

pub const NodeIterator = struct {
    reader: *const Self,
    pos: usize = 0,
    depth: usize = 0,
    initPos: usize = 0,
    minDepth: usize = 0,

    pub fn realPos(self: *const NodeIterator) usize {
        return self.pos + self.reader.hdr.off_dt_struct;
    }

    pub fn offset(self: *const NodeIterator) usize {
        return (self.pos + self.reader.hdr.off_dt_struct) - @sizeOf(types.Header);
    }

    pub fn alignTo(self: *NodeIterator, comptime T: type) void {
        self.pos += @sizeOf(T) - 1;
        self.pos &= ~@as(usize, @sizeOf(T) - 1);
    }

    pub fn readBuffer(self: *NodeIterator, buf: []u8) void {
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            buf[i] = self.reader.buff[self.offset()];
            self.pos += 1;
        }
    }

    pub fn readBytes(self: *NodeIterator, len: usize) []const u8 {
        const pos = self.offset();
        const value = self.reader.buff[pos..][0..len];
        self.pos += len;
        return value;
    }

    pub fn readInt(self: *NodeIterator, comptime T: type) T {
        const len = @divExact(@typeInfo(T).int.bits, 8);
        const pos = self.offset();
        const value = self.reader.buff[pos..][0..len];
        self.pos += len;
        return std.mem.readInt(T, value, .big);
    }

    pub fn readStruct(self: *NodeIterator, comptime T: type) T {
        var res: [1]T = undefined;
        self.readBuffer(std.mem.sliceAsBytes(res[0..]));
        if (builtin.cpu.arch.endian() != std.builtin.Endian.big) {
            std.mem.byteSwapAllFields(T, &res[0]);
        }
        return res[0];
    }

    pub fn token(self: *NodeIterator) error{InvalidToken}!types.Token {
        return std.enums.fromInt(types.Token, self.readInt(u32)) orelse error.InvalidToken;
    }

    pub fn stringAt(self: *NodeIterator, off: usize) []const u8 {
        const pos = (self.reader.hdr.off_dt_strings + off) - @sizeOf(types.Header);
        const len = std.mem.len(@as([*c]const u8, @ptrCast(self.reader.buff[pos..])));
        return self.reader.buff[pos..(pos + len)];
    }

    pub fn string(self: *NodeIterator) []const u8 {
        const pos = self.offset();
        const len = std.mem.len(@as([*c]const u8, @ptrCast(self.reader.buff[pos..])));
        const str = self.reader.buff[pos..(pos + len)];
        self.pos += len + 1;
        return str;
    }

    pub fn next(self: *NodeIterator) !?Node {
        while (true) {
            if (self.depth == self.minDepth and self.pos > self.initPos) return null;

            switch (try self.token()) {
                .beginNode => {
                    self.depth += 1;
                    const str = self.string();
                    self.alignTo(u32);
                    return .{ .begin = .{
                        .name = str,
                        .depth = self.depth - 1,
                    } };
                },
                .endNode => {
                    self.depth -= 1;
                    return .{ .end = .{ .depth = self.depth } };
                },
                .prop => {
                    const prop = self.readStruct(types.Prop);
                    const name = self.stringAt(prop.name);
                    const value = self.readBytes(prop.len);
                    self.alignTo(u32);
                    return .{ .prop = .{
                        .depth = self.depth,
                        .name = name,
                        .value = value,
                    } };
                },
                // A tool that deletes a node or a property in place writes FDT_NOP over
                // it, so a NOP is a hole and not the end of the data. Step over it and
                // read the next token. To stop here would hide all that comes after.
                .nop => {},
                .end => return error.InvalidToken,
            }
        }
    }
};

allocator: ?Allocator,
hdr: types.Header,
buff: []const u8,

fn readHeader(bytes: *const [@sizeOf(types.Header)]u8) types.Header {
    var hdr: types.Header = std.mem.bytesToValue(types.Header, bytes);
    if (builtin.cpu.arch.endian() != std.builtin.Endian.big) {
        std.mem.byteSwapAllFields(types.Header, &hdr);
    }
    return hdr;
}

fn finish(allocator: ?Allocator, hdr: types.Header, buff: []const u8) error{ Truncated, OverRead, InvalidToken }!Self {
    const buffSize = hdr.totalsize - @sizeOf(types.Header);
    if (buff.len < buffSize) return error.Truncated;
    if (buff.len > buffSize) return error.OverRead;
    if (std.mem.readInt(u32, buff[(hdr.off_dt_struct - @sizeOf(types.Header))..][0..4], .big) != @intFromEnum(types.Token.beginNode)) return error.InvalidToken;

    return .{
        .allocator = allocator,
        .hdr = hdr,
        .buff = buff,
    };
}

pub fn initBuffer(buff: []const u8) !Self {
    if (buff.len < @sizeOf(types.Header)) return error.Truncated;
    const hdr = readHeader(buff[0..@sizeOf(types.Header)]);
    if (hdr.magic != types.magic) return error.InvalidMagic;
    if (buff.len < hdr.totalsize) return error.Truncated;
    return finish(null, hdr, buff[@sizeOf(types.Header)..hdr.totalsize]);
}

pub fn initReader(alloc: Allocator, reader: *std.Io.Reader) !Self {
    const hdr = readHeader(try reader.takeArray(@sizeOf(types.Header)));
    if (hdr.magic != types.magic) return error.InvalidMagic;

    const buff = try reader.readAlloc(alloc, hdr.totalsize - @sizeOf(types.Header));
    errdefer alloc.free(buff);
    return finish(alloc, hdr, buff);
}

pub fn initFile(alloc: Allocator, io: std.Io, file: std.Io.File) !Self {
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return initReader(alloc, &file_reader.interface);
}

pub fn deinit(self: *const Self) void {
    if (self.allocator) |alloc| alloc.free(self.buff);
}

pub fn nodeIterator(self: *const Self) NodeIterator {
    return .{ .reader = self };
}

pub fn writeDts(self: *const Self, writer: anytype) !void {
    var iter = self.nodeIterator();
    while (try iter.next()) |node| {
        for (0..(node.depth() * 2)) |_| try writer.writeByte(' ');

        switch (node) {
            .begin => |b| {
                try writer.writeAll(if (b.name.len == 0) "/" else b.name);
                try writer.writeAll(" {");
            },
            .end => {
                try writer.writeAll("}");
            },
            .prop => |p| {
                try writer.writeAll(p.name);
                try writer.writeAll(" = <");

                for (p.value, 0..) |c, i| {
                    try writer.print("0x{x}", .{c});
                    if (i + 1 < p.value.len) try writer.writeByte(' ');
                }

                try writer.writeByte('>');
            },
        }

        try writer.writeByte('\n');
    }
}

/// How a node name in the path is compared against a node name in the tree.
const NameMatch = enum {
    /// Every name must be equal.
    exact,
    /// The name of the node that holds the wanted property is a substring match, so that
    /// a caller can name `i2c@` and reach `i2c@04000000`. Every other name is equal.
    loose,
};

fn nodeNameMatches(
    name: []const u8,
    want: []const u8,
    mode: NameMatch,
    depth: usize,
    path_len: usize,
) bool {
    if (mode == .loose and depth + 2 == path_len) {
        return std.mem.containsAtLeast(u8, name, 1, want);
    }
    return std.mem.eql(u8, name, want);
}

/// Walks the tree and returns the value of the property that the path names.
///
/// A node counts only when every one of its parents counts. Without that rule a name at
/// the correct depth in an unrelated subtree answers the query, and the caller gets a
/// value from the wrong node with no error to show for it.
fn findPath(self: *const Self, path: []const []const u8, mode: NameMatch) ![]const u8 {
    if (path.len == 0) return error.NotFound;

    var iter = self.nodeIterator();
    // The count of leading path items that the current position matches. It grows only
    // by one at a time, so it can never skip a level.
    var matched: usize = 0;

    while (try iter.next()) |node| {
        switch (node) {
            .begin => |b| {
                if (b.depth != matched or b.depth >= path.len) continue;
                if (!nodeNameMatches(b.name, path[b.depth], mode, b.depth, path.len)) continue;
                // The last item of the path names a node and not a property, so there is
                // no value to give back.
                if (b.depth + 1 == path.len) return error.UnexpectedBeginOrEnd;
                matched = b.depth + 1;
            },
            .end => |e| {
                // The node at this depth is closed, so anything it matched stops here.
                if (matched > e.depth) matched = e.depth;
            },
            .prop => |p| {
                if (p.depth != matched or p.depth + 1 != path.len) continue;
                if (!std.mem.eql(u8, p.name, path[p.depth])) continue;
                return p.value;
            },
        }
    }
    return error.NotFound;
}

pub fn find(self: *const Self, path: []const []const u8) ![]const u8 {
    return self.findPath(path, .exact);
}

pub fn findLoose(self: *const Self, path: []const []const u8) ![]const u8 {
    return self.findPath(path, .loose);
}

pub fn findAs(self: *const Self, comptime T: type, path: []const []const u8) !T {
    if (T == bool) {
        _ = self.find(path) catch |err| {
            if (err == error.NotFound) return false;
            return err;
        };
        return true;
    }

    return decode(T, try self.find(path));
}

fn decode(comptime T: type, value: []const u8) error{WrongSize}!T {
    return switch (@typeInfo(T)) {
        .int => |info| blk: {
            if (info.signedness != .unsigned) @compileError("findAs only supports unsigned integers, got " ++ @typeName(T));
            const len = @divExact(info.bits, 8);
            if (value.len != len) return error.WrongSize;
            break :blk std.mem.readInt(T, value[0..len], .big);
        },
        .pointer => |info| blk: {
            if (info.size != .slice or info.child != u8) @compileError("findAs only supports []const u8 slices, got " ++ @typeName(T));
            const end = std.mem.indexOfScalar(u8, value, 0) orelse value.len;
            break :blk value[0..end];
        },
        else => @compileError("findAs does not support " ++ @typeName(T)),
    };
}

test "decode reads an unsigned cell big-endian" {
    try std.testing.expectEqual(@as(u32, 0x989680), try decode(u32, &.{ 0x00, 0x98, 0x96, 0x80 }));
    try std.testing.expectEqual(@as(u64, 0x1), try decode(u64, &.{ 0, 0, 0, 0, 0, 0, 0, 1 }));
}

test "decode rejects a mismatched width" {
    try std.testing.expectError(error.WrongSize, decode(u32, &.{ 0x00, 0x98 }));
}

test "decode strips a trailing NUL from a string" {
    try std.testing.expectEqualStrings("ok", try decode([]const u8, "ok\x00"));
    try std.testing.expectEqualStrings("nonul", try decode([]const u8, "nonul"));
}

/// Builds a small flattened device tree in memory, so that a test can describe an exact
/// token stream. It fills in only the parts that this reader looks at.
const TestBlob = struct {
    gpa: Allocator,
    structs: std.ArrayList(u8) = .empty,
    strings: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestBlob) void {
        self.structs.deinit(self.gpa);
        self.strings.deinit(self.gpa);
    }

    fn cell(self: *TestBlob, v: u32) Allocator.Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try self.structs.appendSlice(self.gpa, &b);
    }

    fn padStructs(self: *TestBlob) Allocator.Error!void {
        while (self.structs.items.len % 4 != 0) try self.structs.append(self.gpa, 0);
    }

    fn beginNode(self: *TestBlob, node_name: []const u8) Allocator.Error!void {
        try self.cell(@intFromEnum(types.Token.beginNode));
        try self.structs.appendSlice(self.gpa, node_name);
        try self.structs.append(self.gpa, 0);
        try self.padStructs();
    }

    fn endNode(self: *TestBlob) Allocator.Error!void {
        try self.cell(@intFromEnum(types.Token.endNode));
    }

    fn nop(self: *TestBlob) Allocator.Error!void {
        try self.cell(@intFromEnum(types.Token.nop));
    }

    fn prop(self: *TestBlob, prop_name: []const u8, value: []const u8) Allocator.Error!void {
        const off: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.gpa, prop_name);
        try self.strings.append(self.gpa, 0);

        try self.cell(@intFromEnum(types.Token.prop));
        try self.cell(@intCast(value.len));
        try self.cell(off);
        try self.structs.appendSlice(self.gpa, value);
        try self.padStructs();
    }

    /// Returns the whole blob. The caller frees it.
    fn finish(self: *TestBlob) Allocator.Error![]u8 {
        try self.cell(@intFromEnum(types.Token.end));

        const header_size: u32 = @sizeOf(types.Header);
        // One terminating reserve entry of two zero cells, which every blob carries.
        const rsvmap_size: u32 = @sizeOf(types.ReserveEntry);
        const struct_off = header_size + rsvmap_size;
        const struct_size: u32 = @intCast(self.structs.items.len);
        const strings_off = struct_off + struct_size;
        const strings_size: u32 = @intCast(self.strings.items.len);

        var header: types.Header = .{
            .magic = types.magic,
            .totalsize = strings_off + strings_size,
            .off_dt_struct = struct_off,
            .off_dt_strings = strings_off,
            .off_mem_rsvmap = header_size,
            .version = 17,
            .last_comp_version = 16,
            .boot_cpuid_phys = 0,
            .size_dt_strings = strings_size,
            .size_dt_struct = struct_size,
        };
        if (builtin.cpu.arch.endian() != std.builtin.Endian.big) {
            std.mem.byteSwapAllFields(types.Header, &header);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, std.mem.asBytes(&header));
        try out.appendNTimes(self.gpa, 0, rsvmap_size);
        try out.appendSlice(self.gpa, self.structs.items);
        try out.appendSlice(self.gpa, self.strings.items);
        return out.toOwnedSlice(self.gpa);
    }
};

test "find does not answer from a sibling that shares a name" {
    const gpa = std.testing.allocator;
    var b: TestBlob = .{ .gpa = gpa };
    defer b.deinit();

    // The wanted node comes first and holds nothing. A later sibling with a different
    // name holds a property of the wanted name. Only ancestry tells the two apart.
    try b.beginNode("");
    try b.beginNode("a");
    try b.endNode();
    try b.beginNode("b");
    try b.prop("x", &.{ 0xde, 0xad, 0xbe, 0xef });
    try b.endNode();
    try b.endNode();

    const blob = try b.finish();
    defer gpa.free(blob);

    const reader = try initBuffer(blob);
    try std.testing.expectError(error.NotFound, reader.find(&.{ "", "a", "x" }));
}

test "find reads a property out of the named node when a sibling holds the same name" {
    const gpa = std.testing.allocator;
    var b: TestBlob = .{ .gpa = gpa };
    defer b.deinit();

    try b.beginNode("");
    try b.beginNode("a");
    try b.prop("x", &.{ 0, 0, 0, 1 });
    try b.endNode();
    try b.beginNode("b");
    try b.prop("x", &.{ 0, 0, 0, 2 });
    try b.endNode();
    try b.endNode();

    const blob = try b.finish();
    defer gpa.free(blob);

    const reader = try initBuffer(blob);
    try std.testing.expectEqual(@as(u32, 1), try reader.findAs(u32, &.{ "", "a", "x" }));
    try std.testing.expectEqual(@as(u32, 2), try reader.findAs(u32, &.{ "", "b", "x" }));
}

test "find does not descend into a node whose parent does not match" {
    const gpa = std.testing.allocator;
    var b: TestBlob = .{ .gpa = gpa };
    defer b.deinit();

    // Both parents hold a child of the same name. Only the chain tells them apart.
    try b.beginNode("");
    try b.beginNode("p");
    try b.beginNode("c");
    try b.prop("v", &.{ 0, 0, 0, 7 });
    try b.endNode();
    try b.endNode();
    try b.beginNode("q");
    try b.beginNode("c");
    try b.prop("v", &.{ 0, 0, 0, 8 });
    try b.endNode();
    try b.endNode();
    try b.endNode();

    const blob = try b.finish();
    defer gpa.free(blob);

    const reader = try initBuffer(blob);
    try std.testing.expectEqual(@as(u32, 7), try reader.findAs(u32, &.{ "", "p", "c", "v" }));
    try std.testing.expectEqual(@as(u32, 8), try reader.findAs(u32, &.{ "", "q", "c", "v" }));
}

test "findLoose keeps its substring match but still obeys ancestry" {
    const gpa = std.testing.allocator;
    var b: TestBlob = .{ .gpa = gpa };
    defer b.deinit();

    try b.beginNode("");
    try b.beginNode("soc");
    try b.beginNode("i2c@04000000");
    try b.prop("status", "okay\x00");
    try b.endNode();
    try b.endNode();
    try b.beginNode("other");
    try b.beginNode("i2c@05000000");
    try b.prop("status", "disabled\x00");
    try b.endNode();
    try b.endNode();
    try b.endNode();

    const blob = try b.finish();
    defer gpa.free(blob);

    const reader = try initBuffer(blob);
    try std.testing.expectEqualStrings(
        "okay",
        try decode([]const u8, try reader.findLoose(&.{ "", "soc", "i2c@", "status" })),
    );
    try std.testing.expectEqualStrings(
        "disabled",
        try decode([]const u8, try reader.findLoose(&.{ "", "other", "i2c@", "status" })),
    );
}

test "a NOP token does not hide what comes after it" {
    const gpa = std.testing.allocator;
    var b: TestBlob = .{ .gpa = gpa };
    defer b.deinit();

    // A tool that deletes a property in place writes FDT_NOP over it. Everything after
    // the hole is still real.
    try b.beginNode("");
    try b.nop();
    try b.prop("model", "ok\x00");
    try b.nop();
    try b.beginNode("child");
    try b.nop();
    try b.prop("v", &.{ 0, 0, 0, 3 });
    try b.endNode();
    try b.endNode();

    const blob = try b.finish();
    defer gpa.free(blob);

    const reader = try initBuffer(blob);
    try std.testing.expectEqualStrings("ok", try reader.findAs([]const u8, &.{ "", "model" }));
    try std.testing.expectEqual(@as(u32, 3), try reader.findAs(u32, &.{ "", "child", "v" }));
}

test "a walk over a tree holding NOP tokens reports every node" {
    const gpa = std.testing.allocator;
    var b: TestBlob = .{ .gpa = gpa };
    defer b.deinit();

    try b.beginNode("");
    try b.nop();
    try b.beginNode("one");
    try b.endNode();
    try b.nop();
    try b.beginNode("two");
    try b.endNode();
    try b.endNode();

    const blob = try b.finish();
    defer gpa.free(blob);

    const reader = try initBuffer(blob);
    var iter = reader.nodeIterator();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    while (try iter.next()) |node| {
        if (node == .begin) try names.append(gpa, node.begin.name);
    }
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("", names.items[0]);
    try std.testing.expectEqualStrings("one", names.items[1]);
    try std.testing.expectEqualStrings("two", names.items[2]);
}
