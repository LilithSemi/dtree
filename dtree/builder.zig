//! Builds a flattened device tree blob.
//!
//! The reader beside this file takes a blob apart. A VMM has the opposite problem: it
//! describes the machine it invented and hands the result to a guest that has no
//! firmware to ask. So this writes the blob the reader reads.
//!
//! Everything in a device tree blob is big endian on disk, whatever the host is, so
//! every integer here is written a byte at a time rather than copied over a struct.
//! The layout is the header, then the memory reservation block, then the structure
//! block, then the strings block, with the alignment the specification requires
//! between each one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

const Builder = @This();

/// Version 17 of the specification, which can be read back to version 16.
const version = 17;
const last_comp_version = 16;

gpa: Allocator,
structure: std.ArrayList(u8) = .empty,
strings: std.ArrayList(u8) = .empty,
reservations: std.ArrayList(types.ReserveEntry) = .empty,
depth: usize = 0,

pub const Error = Allocator.Error || error{
    /// `finish` was called while a node was still open, or `endNode` was called with
    /// no node open. Either one produces a blob no reader will accept.
    Unbalanced,
};

pub fn init(gpa: Allocator) Builder {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Builder) void {
    self.structure.deinit(self.gpa);
    self.strings.deinit(self.gpa);
    self.reservations.deinit(self.gpa);
    self.* = undefined;
}

fn writeBig(list: *std.ArrayList(u8), gpa: Allocator, comptime T: type, value: T) Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try list.appendSlice(gpa, &bytes);
}

fn pad(list: *std.ArrayList(u8), gpa: Allocator) Error!void {
    while (list.items.len % 4 != 0) try list.append(gpa, 0);
}

/// Names repeat across a tree, so the strings block holds one copy of each.
fn intern(self: *Builder, name: []const u8) Error!u32 {
    var offset: usize = 0;
    while (offset < self.strings.items.len) {
        const end = std.mem.indexOfScalarPos(u8, self.strings.items, offset, 0) orelse break;
        if (std.mem.eql(u8, self.strings.items[offset..end], name)) return @intCast(offset);
        offset = end + 1;
    }

    const at: u32 = @intCast(self.strings.items.len);
    try self.strings.appendSlice(self.gpa, name);
    try self.strings.append(self.gpa, 0);
    return at;
}

/// The root node is named with an empty string.
pub fn beginNode(self: *Builder, name: []const u8) Error!void {
    try writeBig(&self.structure, self.gpa, u32, @intFromEnum(types.Token.beginNode));
    try self.structure.appendSlice(self.gpa, name);
    try self.structure.append(self.gpa, 0);
    try pad(&self.structure, self.gpa);
    self.depth += 1;
}

pub fn endNode(self: *Builder) Error!void {
    if (self.depth == 0) return Error.Unbalanced;
    try writeBig(&self.structure, self.gpa, u32, @intFromEnum(types.Token.endNode));
    self.depth -= 1;
}

pub fn prop(self: *Builder, name: []const u8, value: []const u8) Error!void {
    const name_offset = try self.intern(name);
    try writeBig(&self.structure, self.gpa, u32, @intFromEnum(types.Token.prop));
    try writeBig(&self.structure, self.gpa, u32, @intCast(value.len));
    try writeBig(&self.structure, self.gpa, u32, name_offset);
    try self.structure.appendSlice(self.gpa, value);
    try pad(&self.structure, self.gpa);
}

/// A property with no value, such as `interrupt-controller`.
pub fn propEmpty(self: *Builder, name: []const u8) Error!void {
    return self.prop(name, &.{});
}

pub fn propString(self: *Builder, name: []const u8, value: []const u8) Error!void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(self.gpa);
    try buffer.appendSlice(self.gpa, value);
    try buffer.append(self.gpa, 0);
    return self.prop(name, buffer.items);
}

pub fn propU32(self: *Builder, name: []const u8, value: u32) Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    return self.prop(name, &bytes);
}

pub fn propU64(self: *Builder, name: []const u8, value: u64) Error!void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    return self.prop(name, &bytes);
}

/// A list of big endian cells, which is how `reg` and `interrupts` are written.
pub fn propCells(self: *Builder, name: []const u8, cells: []const u32) Error!void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(self.gpa);
    for (cells) |cell| try writeBig(&buffer, self.gpa, u32, cell);
    return self.prop(name, buffer.items);
}

/// Memory a guest must not use, such as the blob itself.
pub fn reserve(self: *Builder, address: u64, size: u64) Error!void {
    try self.reservations.append(self.gpa, .{ .address = address, .size = size });
}

/// The finished blob. The caller owns it.
pub fn finish(self: *Builder) Error![]u8 {
    if (self.depth != 0) return Error.Unbalanced;
    try writeBig(&self.structure, self.gpa, u32, @intFromEnum(types.Token.end));

    const header_size = @sizeOf(types.Header);
    const rsvmap_size = (self.reservations.items.len + 1) * @sizeOf(types.ReserveEntry);

    const off_mem_rsvmap = std.mem.alignForward(usize, header_size, 8);
    const off_dt_struct = std.mem.alignForward(usize, off_mem_rsvmap + rsvmap_size, 4);
    const off_dt_strings = off_dt_struct + self.structure.items.len;
    const total = off_dt_strings + self.strings.items.len;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.gpa);
    try out.ensureTotalCapacity(self.gpa, total);

    try writeBig(&out, self.gpa, u32, types.magic);
    try writeBig(&out, self.gpa, u32, @intCast(total));
    try writeBig(&out, self.gpa, u32, @intCast(off_dt_struct));
    try writeBig(&out, self.gpa, u32, @intCast(off_dt_strings));
    try writeBig(&out, self.gpa, u32, @intCast(off_mem_rsvmap));
    try writeBig(&out, self.gpa, u32, version);
    try writeBig(&out, self.gpa, u32, last_comp_version);
    try writeBig(&out, self.gpa, u32, 0);
    try writeBig(&out, self.gpa, u32, @intCast(self.strings.items.len));
    try writeBig(&out, self.gpa, u32, @intCast(self.structure.items.len));

    while (out.items.len < off_mem_rsvmap) try out.append(self.gpa, 0);
    for (self.reservations.items) |entry| {
        try writeBig(&out, self.gpa, u64, entry.address);
        try writeBig(&out, self.gpa, u64, entry.size);
    }
    // The reservation block always ends with an entry of two zeroes.
    try writeBig(&out, self.gpa, u64, 0);
    try writeBig(&out, self.gpa, u64, 0);

    while (out.items.len < off_dt_struct) try out.append(self.gpa, 0);
    try out.appendSlice(self.gpa, self.structure.items);
    try out.appendSlice(self.gpa, self.strings.items);

    return out.toOwnedSlice(self.gpa);
}

const Reader = @import("reader.zig");

fn sample(gpa: Allocator) ![]u8 {
    var builder = Builder.init(gpa);
    defer builder.deinit();

    try builder.beginNode("");
    try builder.propU32("#address-cells", 2);
    try builder.propU32("#size-cells", 2);
    try builder.propString("compatible", "linux,dummy-virt");

    try builder.beginNode("memory@40000000");
    try builder.propString("device_type", "memory");
    try builder.propCells("reg", &.{ 0, 0x4000_0000, 0, 0x0800_0000 });
    try builder.endNode();

    try builder.endNode();
    return builder.finish();
}

test "a built blob is accepted by the reader" {
    const gpa = std.testing.allocator;
    const blob = try sample(gpa);
    defer gpa.free(blob);

    const tree = try Reader.initBuffer(blob);
    defer tree.deinit();

    try std.testing.expectEqual(types.magic, tree.hdr.magic);
    try std.testing.expectEqual(@as(u32, @intCast(blob.len)), tree.hdr.totalsize);
}

test "a root property reads back as the number it was written as" {
    const gpa = std.testing.allocator;
    const blob = try sample(gpa);
    defer gpa.free(blob);

    const tree = try Reader.initBuffer(blob);
    defer tree.deinit();

    try std.testing.expectEqual(@as(u32, 2), try tree.findAs(u32, &.{ "", "#address-cells" }));
    try std.testing.expectEqual(@as(u32, 2), try tree.findAs(u32, &.{ "", "#size-cells" }));
}

test "a nested node and its properties survive the round trip" {
    const gpa = std.testing.allocator;
    const blob = try sample(gpa);
    defer gpa.free(blob);

    const tree = try Reader.initBuffer(blob);
    defer tree.deinit();

    try std.testing.expectEqualSlices(
        u8,
        "memory\x00",
        try tree.find(&.{ "", "memory@40000000", "device_type" }),
    );

    // Four big endian cells: a 64 bit address then a 64 bit size.
    const reg = try tree.find(&.{ "", "memory@40000000", "reg" });
    try std.testing.expectEqual(@as(usize, 16), reg.len);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), std.mem.readInt(u64, reg[0..8], .big));
    try std.testing.expectEqual(@as(u64, 0x0800_0000), std.mem.readInt(u64, reg[8..16], .big));
}

test "a name used twice is written to the strings block once" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    try builder.beginNode("");
    try builder.beginNode("a");
    try builder.propU32("shared-name", 1);
    try builder.endNode();
    try builder.beginNode("b");
    try builder.propU32("shared-name", 2);
    try builder.endNode();
    try builder.endNode();

    try std.testing.expectEqual(@as(usize, "shared-name".len + 1), builder.strings.items.len);

    const blob = try builder.finish();
    defer gpa.free(blob);

    const tree = try Reader.initBuffer(blob);
    defer tree.deinit();
    try std.testing.expectEqual(@as(u32, 1), try tree.findAs(u32, &.{ "", "a", "shared-name" }));
    try std.testing.expectEqual(@as(u32, 2), try tree.findAs(u32, &.{ "", "b", "shared-name" }));
}

test "finishing while a node is still open is refused" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    try builder.beginNode("");
    try std.testing.expectError(Error.Unbalanced, builder.finish());
}

test "ending a node that was never begun is refused" {
    const gpa = std.testing.allocator;
    var builder = Builder.init(gpa);
    defer builder.deinit();

    try std.testing.expectError(Error.Unbalanced, builder.endNode());
}
