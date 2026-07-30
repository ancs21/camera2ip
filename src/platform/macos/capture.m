#import "../capture_abi.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <sys/resource.h>

static void pumpRunLoopUntil(NSDate *deadline, BOOL (^done)(void)) {
    while (!done() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                  beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

/* Returns the default camera, or nil if none is present. */
static AVCaptureDevice *defaultCameraDeviceOrNil(void) {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
}

/* Resolves camera authorization, requesting it (and pumping the run loop
 * so the completion handler can fire from this thread) if not yet
 * determined. Returns W2I_CAPTURE_OK if authorized, or
 * W2I_CAPTURE_PERMISSION_DENIED otherwise. */
static w2i_capture_result_t ensureCameraAuthorized(int32_t timeout_ms) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        return W2I_CAPTURE_OK;
    }
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        return W2I_CAPTURE_PERMISSION_DENIED;
    }

    __block BOOL granted = NO;
    __block BOOL responded = NO;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                              completionHandler:^(BOOL grantedResult) {
                                granted = grantedResult;
                                responded = YES;
                              }];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(timeout_ms / 1000.0)];
    pumpRunLoopUntil(deadline, ^BOOL {
      return responded;
    });

    return (responded && granted) ? W2I_CAPTURE_OK : W2I_CAPTURE_PERMISSION_DENIED;
}

bool w2i_encode_jpeg_rgba(const uint8_t *rgba, int32_t width, int32_t height, int32_t bytes_per_row, w2i_jpeg_t *out_jpeg) {
    out_jpeg->data = NULL;
    out_jpeg->length = 0;

    @autoreleasepool {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef provider = CGDataProviderCreateWithData(
            NULL, rgba, (size_t)bytes_per_row * (size_t)height, NULL);
        CGImageRef cgImage = CGImageCreate(
            (size_t)width, (size_t)height,
            /* bitsPerComponent */ 8, /* bitsPerPixel */ 32, (size_t)bytes_per_row,
            colorSpace, kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast,
            provider, NULL, false, kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(colorSpace);

        if (cgImage == NULL) {
            return false;
        }

        CFMutableDataRef jpegData = CFDataCreateMutable(kCFAllocatorDefault, 0);
        CGImageDestinationRef dest = CGImageDestinationCreateWithData(jpegData, CFSTR("public.jpeg"), 1, NULL);
        if (dest == NULL) {
            CGImageRelease(cgImage);
            CFRelease(jpegData);
            return false;
        }

        CGImageDestinationAddImage(dest, cgImage, NULL);
        bool finalized = CGImageDestinationFinalize(dest);
        CFRelease(dest);
        CGImageRelease(cgImage);

        if (!finalized) {
            CFRelease(jpegData);
            return false;
        }

        CFIndex length = CFDataGetLength(jpegData);
        uint8_t *buffer = malloc((size_t)length);
        if (buffer == NULL) {
            CFRelease(jpegData);
            return false;
        }
        CFDataGetBytes(jpegData, CFRangeMake(0, length), buffer);
        CFRelease(jpegData);

        out_jpeg->data = buffer;
        out_jpeg->length = (int64_t)length;
        return true;
    }
}

void w2i_free_jpeg(w2i_jpeg_t *jpeg) {
    if (jpeg != NULL && jpeg->data != NULL) {
        free(jpeg->data);
        jpeg->data = NULL;
    }
}

@interface W2IContinuousCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(atomic, assign) w2i_frame_callback_t callback;
/* CIContext is documented by Apple as expensive to create and meant to
 * be created once and reused -- NOT recreated per frame. A first
 * implementation that did recreate it per frame showed slow, steady
 * memory growth (~14KB/s) over a 2-minute soak test; caching it here
 * is the fix, not just a micro-optimization. */
@property(atomic, strong) CIContext *ciContext;
@end

@implementation W2IContinuousCaptureDelegate {
    CGColorSpaceRef _colorSpace;
    CFAbsoluteTime _lastProcessedTime;
}

/* Target interval between *processed* frames (~10fps). The camera
 * delivers frames much faster than this. Checked here, before the
 * CVPixelBuffer->RGBA conversion below, not just in Zig's onFrame --
 * profiling showed that conversion (CIContext render, GPU/Metal work)
 * is itself a major cost, and a throttle placed only after it (as an
 * earlier version of this code did, in Zig) still paid that cost on
 * every single camera frame, saving only the JPEG-encode step. */
static const CFTimeInterval kMinFrameIntervalSeconds = 0.1;

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _ciContext = [CIContext contextWithOptions:nil];
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        _lastProcessedTime = 0;
    }
    return self;
}

- (void)dealloc {
    CGColorSpaceRelease(_colorSpace);
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
            fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (_lastProcessedTime != 0 && (now - _lastProcessedTime) < kMinFrameIntervalSeconds) {
            return;
        }
        _lastProcessedTime = now;

        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer == NULL) {
            return;
        }

        size_t width = CVPixelBufferGetWidth(pixelBuffer);
        size_t height = CVPixelBufferGetHeight(pixelBuffer);
        size_t bytesPerRow = width * 4;

        uint8_t *buffer = malloc(bytesPerRow * height);
        if (buffer == NULL) {
            return;
        }

        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        [self.ciContext render:ciImage
                       toBitmap:buffer
                       rowBytes:(NSInteger)bytesPerRow
                         bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                         format:kCIFormatRGBA8
                     colorSpace:_colorSpace];

        if (self.callback != NULL) {
            self.callback(buffer, (int32_t)width, (int32_t)height, (int32_t)bytesPerRow);
        }

        free(buffer);
    }
}
@end

w2i_capture_result_t w2i_capture_run_continuous(int32_t setup_timeout_ms, w2i_frame_callback_t callback) {
    @autoreleasepool {
        if (defaultCameraDeviceOrNil() == nil) {
            return W2I_CAPTURE_NO_CAMERA;
        }

        w2i_capture_result_t auth = ensureCameraAuthorized(setup_timeout_ms);
        if (auth != W2I_CAPTURE_OK) {
            return auth;
        }

        AVCaptureDevice *device = defaultCameraDeviceOrNil();
        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (input == nil) {
            return W2I_CAPTURE_SESSION_ERROR;
        }

        /* Ask the camera hardware/driver itself to only deliver ~10fps,
         * not just discard extra frames in software after the fact.
         * Profiling found that a software-only throttle (return early
         * in the delegate below, or in Zig's onFrame) barely moved CPU
         * usage even once it was confirmed working (overlay showed the
         * intended ~8fps) -- AVFoundation's own internal capture
         * pipeline (sensor read + format conversion) was still running
         * at the camera's native ~24-30fps regardless of how many of
         * the delivered frames got processed further. This is the
         * actual fix; the delegate-level throttle below is now mostly
         * a backstop for whatever rate the hardware actually settles
         * on (device frame rate requests are a preference, not a
         * hard guarantee). */
        NSError *lockError = nil;
        if ([device lockForConfiguration:&lockError]) {
            CMTime frameDuration = CMTimeMake(1, 10); // 1/10s = 10fps
            device.activeVideoMinFrameDuration = frameDuration;
            device.activeVideoMaxFrameDuration = frameDuration;
            [device unlockForConfiguration];
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        if (![session canAddInput:input]) {
            return W2I_CAPTURE_SESSION_ERROR;
        }
        [session addInput:input];

        W2IContinuousCaptureDelegate *delegate = [[W2IContinuousCaptureDelegate alloc] init];
        delegate.callback = callback;
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        dispatch_queue_t queue = dispatch_queue_create("com.webcam2ip.continuous-capture", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:delegate queue:queue];

        if (![session canAddOutput:output]) {
            return W2I_CAPTURE_SESSION_ERROR;
        }
        [session addOutput:output];

        [session startRunning];

        /* Run forever -- keeps this thread (and the ObjC objects above,
         * which nothing else retains) alive for the process lifetime.
         * Frame delivery itself happens on the dispatch queue above,
         * independent of this run loop; this loop mainly exists so the
         * function never returns and its locals never get deallocated. */
        while (true) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
    }
}

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
    *out_rss_bytes = (int64_t)usage.ru_maxrss; /* macOS: bytes, not KB */
}

void w2i_draw_overlay_rgba(uint8_t *rgba, int32_t width, int32_t height, int32_t bytes_per_row, const char *text) {
    @autoreleasepool {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(rgba, (size_t)width, (size_t)height, 8, (size_t)bytes_per_row,
                                                  colorSpace, kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast);
        CGColorSpaceRelease(colorSpace);
        if (ctx == NULL) {
            return;
        }

        /* Deliberately NOT flipping the CTM here. CGBitmapContext's
         * native drawing coordinate system has (0,0) at the bottom-left
         * with Y increasing upward, which maps directly onto the rgba
         * buffer's row-major top-to-bottom memory layout: Cartesian
         * y=height addresses the buffer's first row (visual top),
         * y=0 addresses the last row (visual bottom) -- no flip needed
         * to reach "near the top," just a Y position close to `height`.
         * An earlier version flipped the CTM to make y=0 mean "top,"
         * which also flipped CoreText's glyph rendering and produced
         * mirrored/upside-down text -- CoreText assumes a specific
         * handedness that a blanket CTM flip breaks. */
        NSString *nsText = [NSString stringWithUTF8String:text];
        if (nsText == nil) {
            CGContextRelease(ctx);
            return;
        }

        /* Cached, not recreated per call: CTFontCreateWithName does real
         * font lookup/matching work, and this function runs ~10-30x/sec
         * in production. Profiling (macOS `sample`) showed this exact
         * per-frame-recreation pattern was already a real, fixed cost
         * once for CIContext (see the T9 capture delegate) -- same
         * class of mistake, same fix.
         *
         * Plain lazy-init, not dispatch_once: dispatch_once triggered a
         * crash ("invalid enum value" from Zig's UBSan runtime deep
         * inside libdispatch's own _dispatch_once) under this specific
         * build toolchain -- a real interaction bug between Zig 0.16's
         * UBSan instrumentation and Apple's dispatch_once implementation,
         * not something fixable from this file. Not a problem in
         * practice: this function is always called from the capture
         * delegate's single serial dispatch queue in production, so
         * there's no real concurrent-first-call race to guard against. */
        static CTFontRef font;
        static CGColorRef white;
        if (font == NULL) {
            font = CTFontCreateWithName(CFSTR("Menlo"), 16.0, NULL);
            white = CGColorCreateGenericRGB(1, 1, 1, 1);
        }
        NSDictionary *attrs = @{
            (id)kCTFontAttributeName : (__bridge id)font,
            (id)kCTForegroundColorAttributeName : (__bridge id)white,
        };
        CFAttributedStringRef attrString =
            CFAttributedStringCreate(kCFAllocatorDefault, (__bridge CFStringRef)nsText, (__bridge CFDictionaryRef)attrs);
        CTLineRef line = CTLineCreateWithAttributedString(attrString);
        CGRect bounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);

        CGFloat padding = 6;
        CGFloat boxWidth = bounds.size.width + padding * 2;
        CGFloat boxHeight = bounds.size.height + padding * 2;
        CGFloat boxBottomY = (CGFloat)height - boxHeight; // near the top of the image
        CGContextSetRGBFillColor(ctx, 0, 0, 0, 0.6);
        CGContextFillRect(ctx, CGRectMake(0, boxBottomY, boxWidth, boxHeight));

        /* Baseline positioned so the glyphs sit inside the box, in the
         * context's native (unflipped) coordinate system. */
        CGContextSetTextPosition(ctx, padding, boxBottomY + padding - bounds.origin.y);
        CTLineDraw(line, ctx);

        CFRelease(line);
        CFRelease(attrString);
        // font/white are cached (see the lazy-init check above) -- not released.
        CGContextRelease(ctx);
    }
}
