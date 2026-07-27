const std = @import("std");
const Io = std.Io;
const macos = @import("platform/macos.zig");

/// Holds the most recent captured frame as JPEG bytes. Readers copy the
/// bytes out while holding the lock (a fast memcpy) rather than the
/// writer maintaining two persistent buffers -- same effect (the writer
/// is never blocked by a slow reader, since the slow part, e.g. writing
/// to a network socket, happens after the copy and outside the lock) via
/// a simpler mechanism than double-buffering.
const FrameSlot = struct {
    mutex: Io.Mutex = .init,
    jpeg: std.ArrayList(u8) = .empty,
    width: i32 = 0,
    height: i32 = 0,
    frame_count: u64 = 0,
};

var g_io: Io = undefined;
var g_gpa: std.mem.Allocator = undefined;
var g_slot: FrameSlot = .{};

fn onFrame(rgba: [*]const u8, width: i32, height: i32, bytes_per_row: i32) callconv(.c) void {
    const len: usize = @as(usize, @intCast(bytes_per_row)) * @as(usize, @intCast(height));
    var jpeg = macos.encodeJpegRgba(width, height, bytes_per_row, rgba[0..len]) catch return;
    defer macos.freeJpeg(&jpeg);
    const bytes = jpeg.data.?[0..@intCast(jpeg.length)];

    g_slot.mutex.lock(g_io) catch return;
    defer g_slot.mutex.unlock(g_io);

    g_slot.jpeg.clearRetainingCapacity();
    g_slot.jpeg.appendSlice(g_gpa, bytes) catch return;
    g_slot.width = width;
    g_slot.height = height;
    g_slot.frame_count += 1;
}

/// Starts the continuous capture session on the calling thread (which
/// must be a dedicated thread -- see macos.runCaptureContinuous). Only
/// returns early on a permission/session-setup failure.
pub fn run(io: Io, gpa: std.mem.Allocator, setup_timeout_ms: i32) macos.CaptureResult {
    g_io = io;
    g_gpa = gpa;
    return macos.runCaptureContinuous(setup_timeout_ms, &onFrame);
}

pub const Frame = struct {
    data: []u8,
    width: i32,
    height: i32,
};

/// Copies the latest JPEG frame into `allocator`-owned memory (caller
/// frees). Returns null if no frame has arrived yet.
pub fn copyLatestFrame(io: Io, allocator: std.mem.Allocator) !?Frame {
    try g_slot.mutex.lock(io);
    defer g_slot.mutex.unlock(io);

    if (g_slot.frame_count == 0) return null;
    return .{
        .data = try allocator.dupe(u8, g_slot.jpeg.items),
        .width = g_slot.width,
        .height = g_slot.height,
    };
}

test "copyLatestFrame returns null before any frame has arrived" {
    // Uses the real module-level slot -- fine since this test runs
    // before any other test in this file touches it (see next test,
    // which then leaves frame_count > 0 for the rest of the process).
    const io = std.testing.io;
    const result = try copyLatestFrame(io, std.testing.allocator);
    try std.testing.expectEqual(@as(?Frame, null), result);
}

test "onFrame updates the slot on every call, not just the first" {
    const io = std.testing.io;
    g_io = io;
    // g_slot.jpeg is a module-level global that (correctly, in
    // production) lives for the whole process and is never explicitly
    // freed -- std.testing.allocator's leak checker doesn't know that's
    // intentional, so use an untracked allocator for it specifically.
    // copyLatestFrame's *returned copies* below still use
    // std.testing.allocator and are freed normally.
    g_gpa = std.heap.page_allocator;

    var red = [_]u8{ 255, 0, 0, 255 } ** 4; // 2x2 solid red, tightly packed
    onFrame(&red, 2, 2, 8);

    const first = (try copyLatestFrame(io, std.testing.allocator)).?;
    defer std.testing.allocator.free(first.data);
    try std.testing.expectEqual(@as(i32, 2), first.width);

    var blue = [_]u8{ 0, 0, 255, 255 } ** 9; // 3x3 solid blue -- different size/content
    onFrame(&blue, 3, 3, 12);

    const second = (try copyLatestFrame(io, std.testing.allocator)).?;
    defer std.testing.allocator.free(second.data);
    try std.testing.expectEqual(@as(i32, 3), second.width);
    try std.testing.expect(!std.mem.eql(u8, first.data, second.data));
}
