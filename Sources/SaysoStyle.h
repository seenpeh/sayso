#import <AppKit/AppKit.h>

NSImageView *SaysoMark(CGFloat size);
void SaysoReveal(NSView *view, CGFloat offset);

/// The ink curves reveal once when the dictation popover opens.
@interface VoiceCard : NSView
- (void)revealWave;
@end

@interface DictationActionButton : NSButton
@end
