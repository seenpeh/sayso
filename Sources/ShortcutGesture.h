#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, RecordingMode) { ToggleRecording, HoldRecording };
typedef NS_ENUM(NSInteger, GestureKind) { TapGesture, HoldGesture, DoubleTapGesture };

@interface ShortcutGesture : NSObject
@property RecordingMode mode;
@property GestureKind kind;
@property (readonly) BOOL pressed;
@property (copy) void (^activate)(void);
@property (copy) void (^releaseHold)(void);
- (void)edge:(BOOL)pressed at:(NSTimeInterval)time;
- (void)cancel;
@end
