const std = @import("std");

/// Ownership convention for this module and everything under
/// src/platform/macos/: ObjC objects are ARC-managed inside the .m files
/// and never cross the C ABI directly. Buffers/strings returned to Zig are
/// malloc()'d C-side, freed via a matching w2i_*_free() function. Core
/// Foundation types, when used later, are retained/released explicitly
/// (CFRetain/CFRelease) since ARC does not manage them.
extern "c" fn w2i_shim_greeting_length() i32;

/// Length of an NSString built inside the ObjC shim -- proves Foundation
/// actually links and runs, not just that C linking works.
pub fn shimGreetingLength() i32 {
    return w2i_shim_greeting_length();
}

test "shimGreetingLength returns the length of the ObjC-built greeting string" {
    try std.testing.expectEqual(@as(i32, 25), shimGreetingLength());
}

/// Mirrors w2i_capture_result_t in capture.h.
pub const CaptureResult = enum(i32) {
    ok = 0,
    /// Permission was granted and a session started, but no frame
    /// arrived within the timeout.
    timeout = 1,
    /// No default video capture device is present.
    no_camera = 2,
    /// Access denied/restricted, or the permission prompt went
    /// unanswered within the timeout.
    permission_denied = 3,
    /// The capture session could not be configured or started.
    session_error = 4,
    /// A frame arrived but could not be converted to RGBA8.
    convert_error = 5,
    _,
};

extern "c" fn w2i_encode_jpeg_rgba(rgba: [*]const u8, width: i32, height: i32, bytes_per_row: i32, out_jpeg: *Jpeg) bool;
extern "c" fn w2i_free_jpeg(jpeg: *Jpeg) void;

/// Mirrors w2i_jpeg_t in capture.h. `data` is malloc()'d C-side; free it
/// with `freeJpeg` once done.
pub const Jpeg = extern struct {
    data: ?[*]u8 = null,
    length: i64 = 0,
};

/// Encodes tightly-packed RGBA8 pixels (bytes_per_row == width*4) to
/// JPEG via ImageIO. Pure function of its inputs -- no camera/session
/// involved. Caller must `freeJpeg` the result on success.
pub fn encodeJpegRgba(width: i32, height: i32, bytes_per_row: i32, rgba: []const u8) error{EncodeFailed}!Jpeg {
    var jpeg: Jpeg = .{};
    if (!w2i_encode_jpeg_rgba(rgba.ptr, width, height, bytes_per_row, &jpeg)) {
        return error.EncodeFailed;
    }
    return jpeg;
}

pub fn freeJpeg(jpeg: *Jpeg) void {
    w2i_free_jpeg(jpeg);
}

pub const FrameCallback = *const fn (rgba: [*]u8, width: i32, height: i32, bytes_per_row: i32) callconv(.c) void;

extern "c" fn w2i_capture_run_continuous(setup_timeout_ms: i32, callback: FrameCallback) i32;

/// Starts a persistent capture session on the calling thread and pumps
/// its run loop forever, invoking `callback` synchronously for each
/// frame. Only returns early on a permission/session-setup failure --
/// call from a dedicated thread that lives for the process lifetime.
pub fn runCaptureContinuous(setup_timeout_ms: i32, callback: FrameCallback) CaptureResult {
    return @enumFromInt(w2i_capture_run_continuous(setup_timeout_ms, callback));
}

extern "c" fn w2i_get_process_stats(out_cpu_seconds: *f64, out_rss_bytes: *i64) void;

pub const ProcessStats = struct {
    /// Total user+sys CPU time consumed by this process so far.
    cpu_seconds: f64,
    /// Peak resident set size, in bytes.
    rss_bytes: i64,
};

/// Snapshot of this process's cumulative CPU time and peak RSS.
/// Callers compute CPU% themselves from the delta between two samples
/// over a known wall-clock interval.
pub fn getProcessStats() ProcessStats {
    var stats: ProcessStats = undefined;
    w2i_get_process_stats(&stats.cpu_seconds, &stats.rss_bytes);
    return stats;
}

extern "c" fn w2i_draw_overlay_rgba(rgba: [*]u8, width: i32, height: i32, bytes_per_row: i32, text: [*:0]const u8) void;

/// Draws `text` as a single line, top-left, over a translucent
/// background box, directly into `rgba` in place (tightly packed,
/// bytes_per_row == width*4). Pure function of its inputs -- no
/// camera/session involved.
pub fn drawOverlayRgba(rgba: []u8, width: i32, height: i32, bytes_per_row: i32, text: [:0]const u8) void {
    w2i_draw_overlay_rgba(rgba.ptr, width, height, bytes_per_row, text.ptr);
}

test "encodeJpegRgba produces bytes with valid JPEG SOI/EOI markers" {
    // 4x4 solid-red RGBA, tightly packed -- content doesn't matter here,
    // only that ImageIO actually produces a real JPEG bitstream.
    var rgba: [4 * 4 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        rgba[i] = 255;
        rgba[i + 1] = 0;
        rgba[i + 2] = 0;
        rgba[i + 3] = 255;
    }

    var jpeg = try encodeJpegRgba(4, 4, 16, &rgba);
    defer freeJpeg(&jpeg);

    try std.testing.expect(jpeg.length > 2);
    const bytes = jpeg.data.?[0..@intCast(jpeg.length)];
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xD8), bytes[1]); // SOI marker
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[bytes.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), bytes[bytes.len - 1]); // EOI marker
}
