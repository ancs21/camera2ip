#import "shim.h"
#import <Foundation/Foundation.h>

int32_t w2i_shim_greeting_length(void) {
    @autoreleasepool {
        NSString *greeting = [NSString stringWithFormat:@"webcam2ip says hello, %@", @"Zig"];
        return (int32_t)greeting.length;
    }
}
