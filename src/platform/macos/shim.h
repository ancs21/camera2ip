#ifndef WEBCAM2IP_SHIM_H
#define WEBCAM2IP_SHIM_H

#include <stdint.h>

/*
 * ABI ownership convention for this shim and everything added under
 * src/platform/macos/ later:
 *   - Objective-C objects are ARC-managed inside the .m files and never
 *     cross the C ABI boundary directly.
 *   - Buffers/strings returned to Zig are malloc()'d C-side; the Zig
 *     caller must free them with a matching w2i_*_free() function.
 *   - Core Foundation types (CF*), when used later (e.g. CVPixelBuffer,
 *     CGImage), are retained/released explicitly with CFRetain/CFRelease
 *     since ARC does not manage them.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Builds a greeting via NSString and returns its length. Exists purely to
 * prove Foundation actually links and runs -- not just that C linking
 * works. */
int32_t w2i_shim_greeting_length(void);

#ifdef __cplusplus
}
#endif

#endif /* WEBCAM2IP_SHIM_H */
