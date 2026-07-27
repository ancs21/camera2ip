#ifndef WEBCAM2IP_CAPTURE_H
#define WEBCAM2IP_CAPTURE_H

#include <stdbool.h>
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

typedef struct {
    /* malloc()'d JPEG bytes. Owned by the caller once returned; free
     * with w2i_free_jpeg(). */
    uint8_t *data;
    int64_t length;
} w2i_jpeg_t;

/*
 * Encodes tightly-packed RGBA8 pixels (bytes_per_row == width * 4) to
 * JPEG via ImageIO. Pure function of its inputs -- no camera/session
 * involved, callable from any thread, safe to unit test without
 * hardware. Returns false (and zeroes *out_jpeg) on encode failure.
 */
bool w2i_encode_jpeg_rgba(const uint8_t *rgba, int32_t width, int32_t height, int32_t bytes_per_row, w2i_jpeg_t *out_jpeg);

/* Frees the buffer in *jpeg (if any) and zeroes it. Safe to call on an
 * already-freed or zeroed jpeg. */
void w2i_free_jpeg(w2i_jpeg_t *jpeg);

/* Called synchronously on the capture delegate's serial queue for every
 * frame -- keep it fast. rgba is mutable (callers may draw an overlay
 * in place before encoding) but only valid for the duration of the
 * call (freed immediately after); copy anything you need to keep. */
typedef void (*w2i_frame_callback_t)(uint8_t *rgba, int32_t width, int32_t height, int32_t bytes_per_row);

/*
 * Starts a persistent AVCaptureSession on the CALLING thread: requests
 * camera permission if needed, configures a session with the default
 * video device, starts it, and pumps this thread's run loop FOREVER,
 * invoking `callback` with each converted RGBA8 frame as it arrives.
 * Only returns early on a permission/session-setup failure -- a running
 * session never returns under normal operation, so call this from a
 * dedicated thread (not the Zig main/HTTP thread) that lives for the
 * process lifetime.
 */
w2i_capture_result_t w2i_capture_run_continuous(int32_t setup_timeout_ms, w2i_frame_callback_t callback);

/* Total user+sys CPU time consumed by this process so far, and its peak
 * resident set size in bytes (getrusage(RUSAGE_SELF, ...) under the
 * hood -- macOS reports ru_maxrss in bytes, not KB like Linux). Callers
 * compute CPU% themselves from the delta between two samples over a
 * known wall-clock interval. */
void w2i_get_process_stats(double *out_cpu_seconds, int64_t *out_rss_bytes);

/*
 * Draws `text` as a single line, top-left, over a translucent
 * background box, directly into `rgba` in place (tightly packed,
 * bytes_per_row == width * 4). Pure function of its inputs -- no
 * camera/session involved, callable from any thread.
 */
void w2i_draw_overlay_rgba(uint8_t *rgba, int32_t width, int32_t height, int32_t bytes_per_row, const char *text);

#ifdef __cplusplus
}
#endif

#endif /* WEBCAM2IP_CAPTURE_H */
