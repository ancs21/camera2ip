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
