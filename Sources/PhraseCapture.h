#import <Foundation/Foundation.h>

// Call on the main thread. Delivers mono 16 kHz Float32 phrases in capture order.
@interface PhraseCapture : NSObject
@property (copy) void (^phrase)(NSData *samples);
@property (copy) void (^interrupted)(void);
- (BOOL)start:(NSError **)error;
- (void)stop;
@end
