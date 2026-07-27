#import "capture.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

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

static void pumpRunLoopUntil(NSDate *deadline, BOOL (^done)(void)) {
    while (!done() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                  beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

w2i_capture_probe_result_t w2i_capture_probe_run(int32_t timeout_ms) {
    @autoreleasepool {
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (device == nil) {
            return W2I_CAPTURE_PROBE_NO_CAMERA;
        }

        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
            return W2I_CAPTURE_PROBE_PERMISSION_DENIED;
        }

        if (status == AVAuthorizationStatusNotDetermined) {
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

            if (!responded || !granted) {
                return W2I_CAPTURE_PROBE_PERMISSION_DENIED;
            }
        }

        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (input == nil) {
            return W2I_CAPTURE_PROBE_SESSION_ERROR;
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        if (![session canAddInput:input]) {
            return W2I_CAPTURE_PROBE_SESSION_ERROR;
        }
        [session addInput:input];

        W2ICaptureProbeDelegate *delegate = [[W2ICaptureProbeDelegate alloc] init];
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        dispatch_queue_t queue = dispatch_queue_create("com.webcam2ip.capture-probe", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:delegate queue:queue];

        if (![session canAddOutput:output]) {
            return W2I_CAPTURE_PROBE_SESSION_ERROR;
        }
        [session addOutput:output];

        [session startRunning];

        NSDate *frameDeadline = [NSDate dateWithTimeIntervalSinceNow:(timeout_ms / 1000.0)];
        pumpRunLoopUntil(frameDeadline, ^BOOL {
          return delegate.didReceiveFrame;
        });

        [session stopRunning];

        return delegate.didReceiveFrame ? W2I_CAPTURE_PROBE_OK : W2I_CAPTURE_PROBE_TIMEOUT;
    }
}
