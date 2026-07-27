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

/// Mirrors w2i_capture_probe_result_t in capture.h.
pub const CaptureProbeResult = enum(i32) {
    /// The sample-buffer delegate fired at least once.
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
    _,
};

/// Runs a full AVCaptureSession probe on the calling thread, blocking for
/// up to ~2x timeout_ms (permission wait + first-frame wait). Must be
/// called from a dedicated thread, not the main/HTTP thread, since it
/// pumps a run loop -- this is the pattern the real capture thread (T9)
/// will use.
pub fn captureProbe(timeout_ms: i32) CaptureProbeResult {
    return @enumFromInt(w2i_capture_probe_run(timeout_ms));
}
