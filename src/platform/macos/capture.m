#import "capture.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

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

@interface W2ICaptureProbeDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(atomic, assign) BOOL didReceiveFrame;
@end

@implementation W2ICaptureProbeDelegate
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
            fromConnection:(AVCaptureConnection *)connection {
    self.didReceiveFrame = YES;
}
@end

w2i_capture_result_t w2i_capture_probe_run(int32_t timeout_ms) {
    @autoreleasepool {
        if (defaultCameraDeviceOrNil() == nil) {
            return W2I_CAPTURE_NO_CAMERA;
        }

        w2i_capture_result_t auth = ensureCameraAuthorized(timeout_ms);
        if (auth != W2I_CAPTURE_OK) {
            return auth;
        }

        AVCaptureDevice *device = defaultCameraDeviceOrNil();
        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (input == nil) {
            return W2I_CAPTURE_SESSION_ERROR;
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        if (![session canAddInput:input]) {
            return W2I_CAPTURE_SESSION_ERROR;
        }
        [session addInput:input];

        W2ICaptureProbeDelegate *delegate = [[W2ICaptureProbeDelegate alloc] init];
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        dispatch_queue_t queue = dispatch_queue_create("com.webcam2ip.capture-probe", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:delegate queue:queue];

        if (![session canAddOutput:output]) {
            return W2I_CAPTURE_SESSION_ERROR;
        }
        [session addOutput:output];

        [session startRunning];

        NSDate *frameDeadline = [NSDate dateWithTimeIntervalSinceNow:(timeout_ms / 1000.0)];
        pumpRunLoopUntil(frameDeadline, ^BOOL {
          return delegate.didReceiveFrame;
        });

        [session stopRunning];

        return delegate.didReceiveFrame ? W2I_CAPTURE_OK : W2I_CAPTURE_TIMEOUT;
    }
}

@interface W2IFrameCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(atomic, assign) BOOL didReceiveFrame;
@property(atomic, assign) BOOL convertFailed;
@property(atomic, assign) uint8_t *frameData;
@property(atomic, assign) int32_t frameWidth;
@property(atomic, assign) int32_t frameHeight;
@property(atomic, assign) int32_t frameBytesPerRow;
@end

@implementation W2IFrameCaptureDelegate
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
            fromConnection:(AVCaptureConnection *)connection {
    /* Only convert the first frame -- later callbacks are ignored. */
    if (self.didReceiveFrame || self.convertFailed) {
        return;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == NULL) {
        self.convertFailed = YES;
        return;
    }

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t bytesPerRow = width * 4; /* RGBA8, tightly packed -- we choose
                                        this layout, sidestepping the
                                        source buffer's native stride. */

    uint8_t *buffer = malloc(bytesPerRow * height);
    if (buffer == NULL) {
        self.convertFailed = YES;
        return;
    }

    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CIContext *ciContext = [CIContext contextWithOptions:nil];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [ciContext render:ciImage
              toBitmap:buffer
              rowBytes:(NSInteger)bytesPerRow
                bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                format:kCIFormatRGBA8
            colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    self.frameData = buffer;
    self.frameWidth = (int32_t)width;
    self.frameHeight = (int32_t)height;
    self.frameBytesPerRow = (int32_t)bytesPerRow;
    self.didReceiveFrame = YES;
}
@end

w2i_capture_result_t w2i_capture_frame_rgba(int32_t timeout_ms, w2i_frame_t *out_frame) {
    out_frame->data = NULL;
    out_frame->width = 0;
    out_frame->height = 0;
    out_frame->bytes_per_row = 0;

    @autoreleasepool {
        if (defaultCameraDeviceOrNil() == nil) {
            return W2I_CAPTURE_NO_CAMERA;
        }

        w2i_capture_result_t auth = ensureCameraAuthorized(timeout_ms);
        if (auth != W2I_CAPTURE_OK) {
            return auth;
        }

        AVCaptureDevice *device = defaultCameraDeviceOrNil();
        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (input == nil) {
            return W2I_CAPTURE_SESSION_ERROR;
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        if (![session canAddInput:input]) {
            return W2I_CAPTURE_SESSION_ERROR;
        }
        [session addInput:input];

        W2IFrameCaptureDelegate *delegate = [[W2IFrameCaptureDelegate alloc] init];
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        dispatch_queue_t queue = dispatch_queue_create("com.webcam2ip.frame-capture", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:delegate queue:queue];

        if (![session canAddOutput:output]) {
            return W2I_CAPTURE_SESSION_ERROR;
        }
        [session addOutput:output];

        [session startRunning];

        NSDate *frameDeadline = [NSDate dateWithTimeIntervalSinceNow:(timeout_ms / 1000.0)];
        pumpRunLoopUntil(frameDeadline, ^BOOL {
          return delegate.didReceiveFrame || delegate.convertFailed;
        });

        [session stopRunning];

        if (delegate.convertFailed) {
            return W2I_CAPTURE_CONVERT_ERROR;
        }
        if (!delegate.didReceiveFrame) {
            return W2I_CAPTURE_TIMEOUT;
        }

        out_frame->data = delegate.frameData;
        out_frame->width = delegate.frameWidth;
        out_frame->height = delegate.frameHeight;
        out_frame->bytes_per_row = delegate.frameBytesPerRow;
        return W2I_CAPTURE_OK;
    }
}

void w2i_free_frame(w2i_frame_t *frame) {
    if (frame != NULL && frame->data != NULL) {
        free(frame->data);
        frame->data = NULL;
    }
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
