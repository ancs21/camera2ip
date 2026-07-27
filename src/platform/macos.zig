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

extern "c" fn w2i_capture_probe_run(timeout_ms: i32) i32;
extern "c" fn w2i_capture_frame_rgba(timeout_ms: i32, out_frame: *Frame) i32;
extern "c" fn w2i_free_frame(frame: *Frame) void;

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

/// Runs a full AVCaptureSession probe on the calling thread, blocking for
/// up to ~2x timeout_ms (permission wait + first-frame wait). Must be
/// called from a dedicated thread, not the main/HTTP thread, since it
/// pumps a run loop -- this is the pattern the real capture thread (T9)
/// will use.
pub fn captureProbe(timeout_ms: i32) CaptureResult {
    return @enumFromInt(w2i_capture_probe_run(timeout_ms));
}

/// Mirrors w2i_frame_t in capture.h. `data` is malloc()'d C-side; free it
/// with `freeFrame` once done (per the ABI ownership convention above).
pub const Frame = extern struct {
    data: ?[*]u8 = null,
    width: i32 = 0,
    height: i32 = 0,
    bytes_per_row: i32 = 0,
};

pub const CaptureFrameError = error{
    Timeout,
    NoCamera,
    PermissionDenied,
    SessionError,
    ConvertError,
    UnknownCaptureResult,
};

/// Same threading contract as `captureProbe`, but on success also
/// converts the first captured frame to tightly-packed RGBA8 (no source
/// stride padding to worry about -- the shim renders into a layout it
/// controls). Caller must `freeFrame` the result.
pub fn captureFrameRgba(timeout_ms: i32) CaptureFrameError!Frame {
    var frame: Frame = .{};
    const result: CaptureResult = @enumFromInt(w2i_capture_frame_rgba(timeout_ms, &frame));
    return switch (result) {
        .ok => frame,
        .timeout => error.Timeout,
        .no_camera => error.NoCamera,
        .permission_denied => error.PermissionDenied,
        .session_error => error.SessionError,
        .convert_error => error.ConvertError,
        _ => error.UnknownCaptureResult,
    };
}

pub fn freeFrame(frame: *Frame) void {
    w2i_free_frame(frame);
}

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
