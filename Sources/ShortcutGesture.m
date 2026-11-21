#import "ShortcutGesture.h"
#import <AppKit/AppKit.h>

@interface ShortcutGesture ()
@property (readwrite) BOOL pressed;
@property BOOL secondTap;
@property NSTimeInterval downTime;
@property NSTimeInterval firstRelease;
@property NSTimer *holdTimer;
@end

@implementation ShortcutGesture
- (void)edge:(BOOL)pressed at:(NSTimeInterval)time {
    if (pressed == self.pressed) return;
    self.pressed = pressed;
    NSTimeInterval tapInterval = NSEvent.doubleClickInterval;
    if (tapInterval <= 0) tapInterval = 0.5;
    if (pressed) {
        self.downTime = time;
        self.secondTap = self.firstRelease > 0 && time - self.firstRelease <= tapInterval;
        self.firstRelease = 0;
        if (self.kind == HoldGesture) {
            __weak ShortcutGesture *gesture = self;
            self.holdTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *timer) {
                if (gesture.pressed) gesture.activate();
            }];
        } else if (self.mode == HoldRecording && (self.kind == TapGesture || self.secondTap)) {
            self.activate();
        }
        return;
    }
    [self.holdTimer invalidate];
    self.holdTimer = nil;
    if (self.mode == HoldRecording) self.releaseHold();
    if (self.kind == TapGesture && self.mode == ToggleRecording) self.activate();
    if (self.kind == DoubleTapGesture && time - self.downTime <= tapInterval) {
        if (!self.secondTap) self.firstRelease = time;
        else if (self.mode == ToggleRecording) self.activate();
    }
    self.secondTap = NO;
}
- (void)cancel {
    [self.holdTimer invalidate];
    self.holdTimer = nil;
    if (self.pressed && self.mode == HoldRecording && self.releaseHold) self.releaseHold();
    self.pressed = self.secondTap = NO;
    self.firstRelease = 0;
}
@end
