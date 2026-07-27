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
    /// Previous sample, for computing fps/cpu% deltas in onFrame. Only
    /// ever touched from within onFrame's own critical section, never
    /// concurrently from two different onFrame calls (AVFoundation
    /// delivers frames serially on one queue; seedFrameForTesting calls
    /// are not truly concurrent with each other in practice either),
    /// but guarded by the same mutex anyway since it lives in the same
    /// struct as fields that genuinely are shared with readers.
    last_frame_ns: ?i96 = null,
    last_cpu_seconds: f64 = 0,
};

const overlay_name = "webcam2ip";

/// Pure formatting logic, kept separate from the drawing/camera calls
/// so it's testable without hardware.
pub fn formatOverlayText(buf: []u8, name: []const u8, fps: f64, cpu_percent: f64, rss_bytes: i64, unix_secs: i64) ![:0]u8 {
    const epoch = std.time.epoch;
    const es = epoch.EpochSeconds{ .secs = @intCast(unix_secs) };
    const day = es.getEpochDay();
    const day_secs = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const rss_mb = @as(f64, @floatFromInt(rss_bytes)) / (1024.0 * 1024.0);

    return std.fmt.bufPrintZ(
        buf,
        "{s} | {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} | {d:.1} fps | cpu {d:.0}% | ram {d:.0} MB",
        .{
            name,
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
            fps,
            cpu_percent,
            rss_mb,
        },
    );
}

var g_io: Io = undefined;
var g_gpa: std.mem.Allocator = undefined;
var g_slot: FrameSlot = .{};

fn onFrame(rgba: [*]u8, width: i32, height: i32, bytes_per_row: i32) callconv(.c) void {
    const len: usize = @as(usize, @intCast(bytes_per_row)) * @as(usize, @intCast(height));

    // Zig 0.16 moved wall-clock/monotonic time under Io.Timestamp --
    // std.time.timestamp()/nanoTimestamp() no longer exist. .awake is
    // monotonic (unaffected by wall-clock adjustments) for the fps/cpu
    // delta; .real is wall-clock, used only for the displayed date/time.
    const now_ns = Io.Timestamp.now(g_io, .awake).nanoseconds;
    const utc_secs: i64 = @intCast(@divTrunc(Io.Timestamp.now(g_io, .real).nanoseconds, std.time.ns_per_s));
    const display_offset_secs: i64 = 7 * std.time.s_per_hour; // GMT+7 for the overlay's displayed time
    const unix_secs = utc_secs + display_offset_secs;
    const stats = macos.getProcessStats();

    g_slot.mutex.lock(g_io) catch return;
    const prev_frame_ns = g_slot.last_frame_ns;
    const prev_cpu_seconds = g_slot.last_cpu_seconds;
    g_slot.mutex.unlock(g_io);

    var fps: f64 = 0;
    var cpu_percent: f64 = 0;
    if (prev_frame_ns) |prev_ns| {
        const delta_ns = now_ns - prev_ns;
        if (delta_ns > 0) {
            const delta_ns_f: f64 = @floatFromInt(delta_ns);
            fps = 1e9 / delta_ns_f;
            cpu_percent = (stats.cpu_seconds - prev_cpu_seconds) / (delta_ns_f / 1e9) * 100.0;
        }
    }

    var text_buf: [128]u8 = undefined;
    if (formatOverlayText(&text_buf, overlay_name, fps, cpu_percent, stats.rss_bytes, unix_secs)) |text| {
        macos.drawOverlayRgba(rgba[0..len], width, height, bytes_per_row, text);
    } else |_| {}

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
    g_slot.last_frame_ns = now_ns;
    g_slot.last_cpu_seconds = stats.cpu_seconds;
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

/// Test-only: seeds the module context and stores `rgba` as the latest
/// frame, bypassing the real capture session. Exposed so other
/// modules' tests (e.g. http.zig's /snapshot.jpg test) don't depend on
/// this file's own tests having already run first to initialize
/// things -- explicit over implicit cross-file test ordering.
pub fn seedFrameForTesting(io: Io, gpa: std.mem.Allocator, rgba: []u8, width: i32, height: i32, bytes_per_row: i32) void {
    g_io = io;
    g_gpa = gpa;
    onFrame(rgba.ptr, width, height, bytes_per_row);
}

/// Test-only: resets the frame slot to its initial (no frame yet)
/// state. The slot is a global shared across the whole test binary,
/// potentially concurrently with earlier tests' still-finishing
/// detached connection-handler threads -- so this must take the same
/// lock every other accessor does, not just poke the field directly
/// (an earlier unsynchronized version of this function caused an
/// intermittent "switch on corrupt value" crash inside Io.Mutex
/// itself, consistent with the data race it was).
pub fn resetForTesting(io: Io) void {
    g_io = io;
    g_slot.mutex.lock(io) catch return;
    defer g_slot.mutex.unlock(io);
    g_slot.frame_count = 0;
}

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

test "formatOverlayText formats name, date, fps, cpu, and ram" {
    var buf: [128]u8 = undefined;
    // unix_secs = 0 -> 1970-01-01 00:00:00, a fixed known point so the
    // expected string is exact, not "some plausible-looking date."
    const text = try formatOverlayText(&buf, "webcam2ip", 12.3, 45.0, 2 * 1024 * 1024, 0);
    try std.testing.expectEqualStrings("webcam2ip | 1970-01-01 00:00:00 | 12.3 fps | cpu 45% | ram 2 MB", text);
}

test "copyLatestFrame returns null before any frame has arrived" {
    const io = std.testing.io;
    resetForTesting(io); // don't assume this runs before other tests touch the global slot
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
