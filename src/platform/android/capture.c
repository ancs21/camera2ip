/*
 * Android capture backend: implements ../capture_abi.h with the NDK's
 * Camera2 + AImageReader, and AndroidBitmap_compress for JPEG.
 *
 * Deliberately JNI-free -- no JavaVM, no Activity, no NativeActivity.
 * That means this builds as a plain ELF executable you push with `adb
 * push` and run from `adb shell`, exactly like the macOS binary, instead
 * of dragging in an APK, a manifest, and a Gradle build. The tradeoff is
 * how camera permission is obtained: a process with no package can't
 * show a permission dialog, so it inherits whatever the invoking UID
 * already holds (the `shell` user is granted android.permission.CAMERA
 * on userdebug builds and emulators). On a device where that isn't true,
 * openCamera returns ACAMERA_ERROR_PERMISSION_DENIED and the process
 * exits saying so -- see README for the APK path if you need it.
 */

#include "../capture_abi.h"

#include <android/bitmap.h>
#include <android/data_space.h>
#include <android/native_window.h>
#include <camera/NdkCameraCaptureSession.h>
#include <camera/NdkCameraDevice.h>
#include <camera/NdkCameraError.h>
#include <camera/NdkCameraManager.h>
#include <camera/NdkCameraMetadata.h>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

/* Quality hint for AndroidBitmap_compress. 80 keeps a 640x480 frame
 * around 30-40KB, which is what actually bounds throughput over wifi. */
#define W2I_JPEG_QUALITY 80

/* How often to check the reader for a new frame. Deliberately faster
 * than the ~10fps the Zig side wants: two throttles with the same period
 * beat against each other (a frame arriving 1ms early gets dropped, and
 * the effective rate halves), so this polls at ~20fps and lets
 * capture_loop.zig's throttle be the only thing deciding output rate.
 * ponytail: polling, not an AImageReader listener -- upgrade to
 * ACAMERA_CONTROL_AE_TARGET_FPS_RANGE if the camera's own power draw at
 * its native rate starts to matter (macOS pins the driver rate; the
 * equivalent here is device-dependent and can fail session config). */
#define W2I_POLL_INTERVAL_US (50 * 1000)

/* Preferred capture size; the closest advertised YUV_420_888 size wins. */
#define W2I_TARGET_WIDTH 640
#define W2I_TARGET_HEIGHT 480

/* ---------------------------------------------------------------- JPEG */

typedef struct {
    uint8_t *data;
    size_t length;
    size_t capacity;
    bool failed;
} jpeg_sink_t;

static bool jpeg_sink_write(void *context, const void *data, size_t size) {
    jpeg_sink_t *sink = (jpeg_sink_t *)context;
    if (sink->failed) {
        return false;
    }
    if (sink->length + size > sink->capacity) {
        size_t capacity = sink->capacity ? sink->capacity * 2 : 64 * 1024;
        while (capacity < sink->length + size) {
            capacity *= 2;
        }
        uint8_t *grown = realloc(sink->data, capacity);
        if (grown == NULL) {
            sink->failed = true;
            return false;
        }
        sink->data = grown;
        sink->capacity = capacity;
    }
    memcpy(sink->data + sink->length, data, size);
    sink->length += size;
    return true;
}

bool w2i_encode_jpeg_rgba(const uint8_t *rgba, int32_t width, int32_t height, int32_t bytes_per_row, w2i_jpeg_t *out_jpeg) {
    out_jpeg->data = NULL;
    out_jpeg->length = 0;

    AndroidBitmapInfo info = {
        .width = (uint32_t)width,
        .height = (uint32_t)height,
        .stride = (uint32_t)bytes_per_row,
        .format = ANDROID_BITMAP_FORMAT_RGBA_8888,
        /* The alpha channel is filled with 0xFF during conversion;
         * saying so avoids an unnecessary un-premultiply pass. */
        .flags = ANDROID_BITMAP_FLAGS_ALPHA_OPAQUE,
    };

    jpeg_sink_t sink = {0};
    int status = AndroidBitmap_compress(&info, ADATASPACE_SRGB, rgba,
                                        ANDROID_BITMAP_COMPRESS_FORMAT_JPEG,
                                        W2I_JPEG_QUALITY, &sink, jpeg_sink_write);
    if (status != ANDROID_BITMAP_RESULT_SUCCESS || sink.failed || sink.length == 0) {
        free(sink.data);
        return false;
    }

    out_jpeg->data = sink.data;
    out_jpeg->length = (int64_t)sink.length;
    return true;
}

void w2i_free_jpeg(w2i_jpeg_t *jpeg) {
    if (jpeg == NULL) {
        return;
    }
    free(jpeg->data);
    jpeg->data = NULL;
    jpeg->length = 0;
}

/* --------------------------------------------------------------- stats */

void w2i_get_process_stats(double *out_cpu_seconds, int64_t *out_rss_bytes) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        *out_cpu_seconds = 0;
        *out_rss_bytes = 0;
        return;
    }
    double user = (double)usage.ru_utime.tv_sec + (double)usage.ru_utime.tv_usec / 1e6;
    double sys = (double)usage.ru_stime.tv_sec + (double)usage.ru_stime.tv_usec / 1e6;
    *out_cpu_seconds = user + sys;
    /* Linux/bionic reports ru_maxrss in kilobytes; macOS reports bytes. */
    *out_rss_bytes = (int64_t)usage.ru_maxrss * 1024;
}

/* ------------------------------------------------------------- overlay */

void w2i_draw_overlay_rgba(uint8_t *rgba, int32_t width, int32_t height, int32_t bytes_per_row, const char *text) {
    /* ponytail: no-op -- drawing text needs a font rasterizer, and the
     * NDK has none (Canvas/Paint are Java-only). Frames stream fine
     * without it; the upgrade is either a bundled bitmap font or JNI
     * into android.graphics.Canvas, both of which cost more than the
     * overlay is worth for a first port. */
    (void)rgba;
    (void)width;
    (void)height;
    (void)bytes_per_row;
    (void)text;
}

/* -------------------------------------------------------------- camera */

/*
 * Set from the NDK's callback thread when the camera goes away -- another
 * app taking it (routine on Android; the system evicts us), the device
 * erroring out, USB/hardware loss. A global rather than a context pointer
 * because the capture session is a process-wide singleton by design:
 * w2i_capture_run_continuous is called exactly once, from one dedicated
 * thread, and never returns while frames flow.
 */
static atomic_bool g_camera_lost;

static void on_device_disconnected(void *context, ACameraDevice *device) {
    (void)context;
    (void)device;
    atomic_store_explicit(&g_camera_lost, true, memory_order_relaxed);
}

static void on_device_error(void *context, ACameraDevice *device, int error) {
    (void)context;
    (void)device;
    (void)error;
    atomic_store_explicit(&g_camera_lost, true, memory_order_relaxed);
}

static void on_session_closed(void *context, ACameraCaptureSession *session) {
    (void)context;
    (void)session;
}

static void on_session_ready(void *context, ACameraCaptureSession *session) {
    (void)context;
    (void)session;
}

static void on_session_active(void *context, ACameraCaptureSession *session) {
    (void)context;
    (void)session;
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static uint8_t clamp_u8(int32_t value) {
    if (value < 0) {
        return 0;
    }
    if (value > 255) {
        return 255;
    }
    return (uint8_t)value;
}

/*
 * Converts a YUV_420_888 image to tightly-packed RGBA8, rotating by
 * `rotation` degrees clockwise on the way (phone camera sensors are
 * mounted landscape, so a portrait-held phone reports 90 and its frames
 * would otherwise arrive sideways). Iterating over destination pixels
 * and sampling the source keeps the rotation to index arithmetic --
 * no second buffer, no separate rotate pass.
 *
 * Returns false if the image's planes can't be read.
 */
static bool convert_to_rgba(AImage *image, int32_t rotation, uint8_t *rgba, int32_t dst_width, int32_t dst_height) {
    int32_t src_width = 0, src_height = 0;
    if (AImage_getWidth(image, &src_width) != AMEDIA_OK ||
        AImage_getHeight(image, &src_height) != AMEDIA_OK) {
        return false;
    }

    uint8_t *y_plane = NULL, *u_plane = NULL, *v_plane = NULL;
    int y_len = 0, u_len = 0, v_len = 0;
    int32_t y_stride = 0, uv_stride = 0, uv_pixel_stride = 0;
    if (AImage_getPlaneData(image, 0, &y_plane, &y_len) != AMEDIA_OK ||
        AImage_getPlaneData(image, 1, &u_plane, &u_len) != AMEDIA_OK ||
        AImage_getPlaneData(image, 2, &v_plane, &v_len) != AMEDIA_OK ||
        AImage_getPlaneRowStride(image, 0, &y_stride) != AMEDIA_OK ||
        AImage_getPlaneRowStride(image, 1, &uv_stride) != AMEDIA_OK ||
        AImage_getPlanePixelStride(image, 1, &uv_pixel_stride) != AMEDIA_OK) {
        return false;
    }

    /*
     * The loop below indexes the planes using the geometry the *image*
     * reports, while writing into a buffer sized from the geometry that was
     * *configured*. A mismatch is a memory-safety problem rather than a
     * cosmetic one: at rotation 90, a shorter-than-expected image drives sy
     * negative, and (size_t)sy is then astronomically large.
     */
    const bool quarter_turn = (rotation == 90 || rotation == 270);
    if (src_width < 2 || src_height < 2 ||
        src_width != (quarter_turn ? dst_height : dst_width) ||
        src_height != (quarter_turn ? dst_width : dst_height)) {
        return false;
    }

    /* Trust the reported strides no further than the buffers they describe. */
    if ((size_t)(src_height - 1) * (size_t)y_stride + (size_t)(src_width - 1) >= (size_t)y_len) {
        return false;
    }
    const size_t max_uv_index = (size_t)(src_height / 2 - 1) * (size_t)uv_stride +
                                (size_t)(src_width / 2 - 1) * (size_t)uv_pixel_stride;
    if (max_uv_index >= (size_t)u_len || max_uv_index >= (size_t)v_len) {
        return false;
    }

    for (int32_t dy = 0; dy < dst_height; dy++) {
        uint8_t *out = rgba + (size_t)dy * (size_t)dst_width * 4;
        for (int32_t dx = 0; dx < dst_width; dx++) {
            int32_t sx, sy;
            switch (rotation) {
                case 90:
                    sx = dy;
                    sy = src_height - 1 - dx;
                    break;
                case 180:
                    sx = src_width - 1 - dx;
                    sy = src_height - 1 - dy;
                    break;
                case 270:
                    sx = src_width - 1 - dy;
                    sy = dx;
                    break;
                default:
                    sx = dx;
                    sy = dy;
                    break;
            }

            int32_t y = y_plane[(size_t)sy * (size_t)y_stride + (size_t)sx];
            size_t uv_index = (size_t)(sy / 2) * (size_t)uv_stride + (size_t)(sx / 2) * (size_t)uv_pixel_stride;
            int32_t u = u_plane[uv_index];
            int32_t v = v_plane[uv_index];

            /* BT.601 video range, integer math (<<10 fixed point). */
            int32_t c = (y - 16) * 1192;
            int32_t d = u - 128;
            int32_t e = v - 128;
            out[0] = clamp_u8((c + 1634 * e) >> 10);
            out[1] = clamp_u8((c - 401 * d - 832 * e) >> 10);
            out[2] = clamp_u8((c + 2066 * d) >> 10);
            out[3] = 255;
            out += 4;
        }
    }
    return true;
}

/*
 * Steady state: drains the reader into `callback` forever. `rgba` must
 * hold width*height*4 bytes. Split out from the session setup below
 * because it owns none of those resources -- it only ever hands back a
 * result code, and only if the first frame never shows up within
 * setup_timeout_ms. Frames start arriving some time after the session
 * goes active, and until the first one lands a stalled camera looks
 * exactly like a slow one, so that wait is bounded the same way the
 * macOS backend bounds it.
 */
static w2i_capture_result_t pump_frames(AImageReader *reader, int32_t rotation, uint8_t *rgba,
                                        int32_t width, int32_t height, int32_t setup_timeout_ms,
                                        w2i_frame_callback_t callback) {
    /* Re-armed after every delivered frame, not just at startup, reusing
     * the same budget as a stall timeout: a feed that stops has to be
     * reported, because the slot upstream keeps handing out the last frame
     * it was given and a frozen picture served with 200 OK is
     * indistinguishable from a live one.
     * ponytail: exits rather than reopening the camera -- main.zig treats a
     * returned result as fatal. Reconnect logic is the upgrade if losing
     * the stream to a passing camera app turns out to be annoying. */
    int64_t deadline = now_ms() + setup_timeout_ms;

    while (true) {
        if (atomic_load_explicit(&g_camera_lost, memory_order_relaxed)) {
            return W2I_CAPTURE_SESSION_ERROR;
        }

        AImage *image = NULL;
        if (AImageReader_acquireLatestImage(reader, &image) != AMEDIA_OK || image == NULL) {
            if (now_ms() > deadline) {
                return W2I_CAPTURE_TIMEOUT;
            }
            usleep(W2I_POLL_INTERVAL_US);
            continue;
        }

        if (convert_to_rgba(image, rotation, rgba, width, height)) {
            callback(rgba, width, height, width * 4);
        }
        AImage_delete(image);
        deadline = now_ms() + setup_timeout_ms;

        usleep(W2I_POLL_INTERVAL_US);
    }
}

/* Picks the advertised YUV_420_888 output size closest in area to
 * W2I_TARGET_*; falls back to leaving *out_* untouched if the metadata
 * has no usable entry. */
static bool choose_size(ACameraMetadata *characteristics, int32_t *out_width, int32_t *out_height) {
    ACameraMetadata_const_entry entry;
    if (ACameraMetadata_getConstEntry(characteristics, ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS, &entry) != ACAMERA_OK) {
        return false;
    }

    const int64_t target_area = (int64_t)W2I_TARGET_WIDTH * W2I_TARGET_HEIGHT;
    int64_t best_distance = INT64_MAX;
    for (uint32_t i = 0; i + 3 < entry.count; i += 4) {
        int32_t format = entry.data.i32[i];
        int32_t width = entry.data.i32[i + 1];
        int32_t height = entry.data.i32[i + 2];
        int32_t is_input = entry.data.i32[i + 3];
        if (is_input != ACAMERA_SCALER_AVAILABLE_STREAM_CONFIGURATIONS_OUTPUT ||
            format != AIMAGE_FORMAT_YUV_420_888) {
            continue;
        }

        int64_t area = (int64_t)width * height;
        int64_t distance = area > target_area ? area - target_area : target_area - area;
        if (distance < best_distance) {
            best_distance = distance;
            *out_width = width;
            *out_height = height;
        }
    }
    return best_distance != INT64_MAX;
}

/* Sensor orientation in degrees clockwise, or 0 if the camera doesn't
 * report one. */
static int32_t sensor_orientation(ACameraMetadata *characteristics) {
    ACameraMetadata_const_entry entry;
    if (ACameraMetadata_getConstEntry(characteristics, ACAMERA_SENSOR_ORIENTATION, &entry) != ACAMERA_OK ||
        entry.count == 0) {
        return 0;
    }
    return entry.data.i32[0];
}

/* The camera to capture from, plus what its metadata says about frame
 * geometry -- one value instead of a return plus three out-params. */
typedef struct {
    /* malloc()'d camera id, or NULL if the device has no usable camera. */
    char *id;
    int32_t rotation;
    int32_t width;
    int32_t height;
} camera_choice_t;

/* Prefers the back camera, falling back to whichever comes first. Free
 * .id when done. */
static camera_choice_t select_camera(ACameraManager *manager) {
    camera_choice_t choice = {
        .id = NULL,
        .rotation = 0,
        .width = W2I_TARGET_WIDTH,
        .height = W2I_TARGET_HEIGHT,
    };

    ACameraIdList *ids = NULL;
    if (ACameraManager_getCameraIdList(manager, &ids) != ACAMERA_OK || ids == NULL) {
        return choice;
    }

    for (int i = 0; i < ids->numCameras; i++) {
        ACameraMetadata *characteristics = NULL;
        if (ACameraManager_getCameraCharacteristics(manager, ids->cameraIds[i], &characteristics) != ACAMERA_OK) {
            continue;
        }

        ACameraMetadata_const_entry facing;
        bool is_back = ACameraMetadata_getConstEntry(characteristics, ACAMERA_LENS_FACING, &facing) == ACAMERA_OK &&
                       facing.count > 0 && facing.data.u8[0] == ACAMERA_LENS_FACING_BACK;

        if (choice.id == NULL || is_back) {
            free(choice.id);
            choice.id = strdup(ids->cameraIds[i]);
            choice.rotation = sensor_orientation(characteristics);
            if (!choose_size(characteristics, &choice.width, &choice.height)) {
                choice.width = W2I_TARGET_WIDTH;
                choice.height = W2I_TARGET_HEIGHT;
            }
        }

        ACameraMetadata_free(characteristics);
        if (is_back) {
            break;
        }
    }

    ACameraManager_deleteCameraIdList(ids);
    return choice;
}

/*
 * cameraserver delivers capture results and buffer-available notifications
 * as *incoming* binder transactions. An app process inherits a binder
 * thread pool from the zygote; a bare executable has none, so without this
 * every outgoing call succeeds (open, configure, setRepeatingRequest) and
 * nothing ever comes back -- the session goes active, then no frame ever
 * arrives. That failure is silent, which is what makes it worth this much
 * comment.
 *
 * dlopen rather than a link: libbinder_ndk exports the symbol on every
 * device, but the NDK's stub libraries don't (it's a system API, outside
 * the public NDK surface), so linking it fails at build time.
 */
static void start_binder_thread_pool(void) {
    void *lib = dlopen("libbinder_ndk.so", RTLD_NOW);
    if (lib == NULL) {
        fprintf(stderr, "webcam2ip: dlopen(libbinder_ndk.so) failed (%s) -- "
                        "no binder thread pool, so no frame will ever arrive\n",
                dlerror());
        return;
    }
    void (*start_thread_pool)(void) = (void (*)(void))dlsym(lib, "ABinderProcess_startThreadPool");
    if (start_thread_pool == NULL) {
        fprintf(stderr, "webcam2ip: ABinderProcess_startThreadPool not found -- "
                        "no binder thread pool, so no frame will ever arrive\n");
        return;
    }
    start_thread_pool();
    /* Deliberately not dlclose()'d: the pool's threads outlive this call. */
}

w2i_capture_result_t w2i_capture_run_continuous(int32_t setup_timeout_ms, w2i_frame_callback_t callback) {
    atomic_store_explicit(&g_camera_lost, false, memory_order_relaxed);
    start_binder_thread_pool();

    ACameraManager *manager = ACameraManager_create();
    if (manager == NULL) {
        return W2I_CAPTURE_SESSION_ERROR;
    }

    camera_choice_t camera = select_camera(manager);
    if (camera.id == NULL) {
        ACameraManager_delete(manager);
        return W2I_CAPTURE_NO_CAMERA;
    }

    /* Rotating a quarter turn swaps the frame's dimensions. */
    const bool quarter_turn = (camera.rotation == 90 || camera.rotation == 270);
    const int32_t out_width = quarter_turn ? camera.height : camera.width;
    const int32_t out_height = quarter_turn ? camera.width : camera.height;

    ACameraDevice_StateCallbacks device_callbacks = {
        .context = NULL,
        .onDisconnected = on_device_disconnected,
        .onError = on_device_error,
    };
    ACameraDevice *device = NULL;
    camera_status_t open_status = ACameraManager_openCamera(manager, camera.id, &device_callbacks, &device);
    free(camera.id);
    if (open_status != ACAMERA_OK) {
        ACameraManager_delete(manager);
        /* Nothing here can raise a permission dialog, so a denial is
         * terminal -- main.zig exits on it rather than retrying. */
        return open_status == ACAMERA_ERROR_PERMISSION_DENIED ? W2I_CAPTURE_PERMISSION_DENIED
                                                             : W2I_CAPTURE_SESSION_ERROR;
    }

    /* 4 buffers, not the 2 this loop strictly holds: acquireLatestImage
     * has to release the older images before handing one over, so a
     * tight maxImages lets the camera stall waiting for a free slot. */
    AImageReader *reader = NULL;
    if (AImageReader_new(camera.width, camera.height, AIMAGE_FORMAT_YUV_420_888, 4, &reader) != AMEDIA_OK) {
        ACameraDevice_close(device);
        ACameraManager_delete(manager);
        return W2I_CAPTURE_SESSION_ERROR;
    }

    ANativeWindow *window = NULL;
    ACaptureSessionOutputContainer *outputs = NULL;
    ACaptureSessionOutput *output = NULL;
    ACameraOutputTarget *target = NULL;
    ACaptureRequest *request = NULL;
    ACameraCaptureSession *session = NULL;
    ACameraCaptureSession_stateCallbacks session_callbacks = {
        .context = NULL,
        .onClosed = on_session_closed,
        .onReady = on_session_ready,
        .onActive = on_session_active,
    };

    w2i_capture_result_t result = W2I_CAPTURE_SESSION_ERROR;
    uint8_t *rgba = NULL;

    if (AImageReader_getWindow(reader, &window) != AMEDIA_OK ||
        ACaptureSessionOutputContainer_create(&outputs) != ACAMERA_OK ||
        ACaptureSessionOutput_create(window, &output) != ACAMERA_OK ||
        ACaptureSessionOutputContainer_add(outputs, output) != ACAMERA_OK ||
        ACameraOutputTarget_create(window, &target) != ACAMERA_OK ||
        ACameraDevice_createCaptureRequest(device, TEMPLATE_PREVIEW, &request) != ACAMERA_OK ||
        ACaptureRequest_addTarget(request, target) != ACAMERA_OK ||
        ACameraDevice_createCaptureSession(device, outputs, &session_callbacks, &session) != ACAMERA_OK ||
        ACameraCaptureSession_setRepeatingRequest(session, NULL, 1, &request, NULL) != ACAMERA_OK) {
        goto cleanup;
    }

    rgba = malloc((size_t)out_width * (size_t)out_height * 4);
    if (rgba == NULL) {
        result = W2I_CAPTURE_CONVERT_ERROR;
        goto cleanup;
    }

    result = pump_frames(reader, camera.rotation, rgba, out_width, out_height, setup_timeout_ms, callback);

cleanup:
    free(rgba);
    if (session != NULL) {
        ACameraCaptureSession_close(session);
    }
    if (request != NULL) {
        ACaptureRequest_free(request);
    }
    if (target != NULL) {
        ACameraOutputTarget_free(target);
    }
    if (output != NULL) {
        ACaptureSessionOutput_free(output);
    }
    if (outputs != NULL) {
        ACaptureSessionOutputContainer_free(outputs);
    }
    AImageReader_delete(reader);
    ACameraDevice_close(device);
    ACameraManager_delete(manager);
    return result;
}
