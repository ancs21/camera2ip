#ifndef WEBCAM2IP_CAPTURE_H
#define WEBCAM2IP_CAPTURE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    /* The sample-buffer delegate fired at least once. */
    W2I_CAPTURE_PROBE_OK = 0,
    /* Permission was granted and a session started, but no frame arrived
     * within timeout_ms. */
    W2I_CAPTURE_PROBE_TIMEOUT = 1,
    /* No default video capture device is present. */
    W2I_CAPTURE_PROBE_NO_CAMERA = 2,
    /* Camera access is denied/restricted, or the permission prompt was
     * not answered within timeout_ms. */
    W2I_CAPTURE_PROBE_PERMISSION_DENIED = 3,
    /* The capture session could not be configured or started. */
    W2I_CAPTURE_PROBE_SESSION_ERROR = 4,
} w2i_capture_probe_result_t;

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
w2i_capture_probe_result_t w2i_capture_probe_run(int32_t timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* WEBCAM2IP_CAPTURE_H */
