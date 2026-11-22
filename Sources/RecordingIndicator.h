#import <AppKit/AppKit.h>

@interface RecordingIndicator : NSObject
- (void)showListening;
- (void)showProcessing;
- (void)showPending:(NSString *)message;
- (void)showNotice:(NSString *)message;
- (void)addLevel:(CGFloat)level;
- (void)hide;
@end
