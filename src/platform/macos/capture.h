#ifndef WEBCAM2IP_CAPTURE_H
#define WEBCAM2IP_CAPTURE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    /* Succeeded (delegate fired / frame captured and converted). */
    W2I_CAPTURE_OK = 0,
    /* Permission was granted and a session started, but no frame arrived
     * within timeout_ms. */
    W2I_CAPTURE_TIMEOUT = 1,
    /* No default video capture device is present. */
    W2I_CAPTURE_NO_CAMERA = 2,
    /* Camera access is denied/restricted, or the permission prompt was
     * not answered within timeout_ms. */
    W2I_CAPTURE_PERMISSION_DENIED = 3,
    /* The capture session could not be configured or started. */
    W2I_CAPTURE_SESSION_ERROR = 4,
    /* A frame arrived but could not be converted to RGBA8. */
    W2I_CAPTURE_CONVERT_ERROR = 5,
} w2i_capture_result_t;

/*
 * Runs a full AVCaptureSession probe on the CALLING thread: requests
 * camera permission if needed, configures a session with the default
 * video device, starts it, and pumps this thread's run loop until the
 * sample-buffer delegate fires at least once or timeout_ms elapses
 * (applied separately to the permission wait and the first-frame wait,
 * so worst case this blocks for up to ~2x timeout_ms).
 *
 * Must be called from a dedicated thread (not the Zig main/HTTP thread)
 * since it blocks pumping a run loop -- this is deliberate: it proves
 * the pattern the real capture thread (T9) will use.
 */
w2i_capture_result_t w2i_capture_probe_run(int32_t timeout_ms);

typedef struct {
    /* malloc()'d RGBA8 pixels, row-major, top-to-bottom, tightly packed
     * (bytes_per_row == width * 4, no stride padding). Owned by the
     * caller once returned; free with w2i_free_frame(). */
    uint8_t *data;
    int32_t width;
    int32_t height;
    int32_t bytes_per_row;
} w2i_frame_t;

/*
 * Same threading/run-loop contract as w2i_capture_probe_run, but on
 * success also converts the first captured frame to RGBA8 (via
 * CVPixelBufferLockBaseAddress + CIContext, sidestepping manual
 * YUV->RGB math and native stride handling) and returns it in
 * *out_frame. On any non-OK result, *out_frame is zeroed and owns no
 * memory.
 */
w2i_capture_result_t w2i_capture_frame_rgba(int32_t timeout_ms, w2i_frame_t *out_frame);

/* Frees the buffer in *frame (if any) and zeroes it. Safe to call on an
 * already-freed or zeroed frame. */
void w2i_free_frame(w2i_frame_t *frame);

#ifdef __cplusplus
}
#endif

#endif /* WEBCAM2IP_CAPTURE_H */
