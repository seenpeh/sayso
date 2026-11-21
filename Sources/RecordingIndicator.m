#import "RecordingIndicator.h"

@interface LevelView : NSView {
    CGFloat _levels[9];
}
- (void)addLevel:(CGFloat)level;
@end

@implementation LevelView
- (void)addLevel:(CGFloat)level {
    memmove(_levels, _levels + 1, sizeof(_levels) - sizeof(CGFloat));
    _levels[8] = MIN(1, sqrt(MAX(0, level)) * 2.6);
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    [NSColor.systemTealColor setFill];
    BOOL still = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    for (int i = 0; i < 9; i++) {
        CGFloat height = still ? 6 + (i * 7 % 15) : 3 + 23 * _levels[i];
        NSRect bar = NSMakeRect(i * 5, (NSHeight(self.bounds) - height) / 2, 3, height);
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.5 yRadius:1.5] fill];
    }
}
@end

@interface RecordingIndicator ()
@property NSPanel *panel;
@property LevelView *wave;
@property NSProgressIndicator *spinner;
@property NSTextField *label;
@property NSTimer *dismissal;
@end

@implementation RecordingIndicator
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _panel = [[NSPanel alloc] initWithContentRect:NSZeroRect
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    _panel.level = NSStatusWindowLevel;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.hidesOnDeactivate = NO;
    _panel.ignoresMouseEvents = YES;
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    NSVisualEffectView *surface = [NSVisualEffectView new];
    surface.material = NSVisualEffectMaterialHUDWindow;
    surface.state = NSVisualEffectStateActive;
    surface.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    surface.wantsLayer = YES;
    surface.layer.cornerRadius = 16;
    surface.layer.masksToBounds = YES;
    _panel.contentView = surface;
    _wave = [[LevelView alloc] initWithFrame:NSMakeRect(16, 9, 44, 28)];
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(16, 15, 16, 16)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _label = [NSTextField wrappingLabelWithString:@""];
    _label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    for (NSView *view in @[_wave, _spinner, _label]) [surface addSubview:view];
    return self;
}
- (void)show:(NSString *)text listening:(BOOL)listening pending:(BOOL)pending {
    [self.dismissal invalidate];
    BOOL spin = pending && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    self.wave.hidden = !listening;
    self.spinner.hidden = !spin;
    if (spin) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
    self.label.stringValue = text;
    CGFloat start = listening ? 70 : spin ? 42 : 16;
    NSSize labelSize = [self.label.cell cellSizeForBounds:NSMakeRect(0, 0, 320, CGFLOAT_MAX)];
    CGFloat height = MAX(46, ceil(labelSize.height) + 24);
    CGFloat width = ceil(labelSize.width) + start + 16;
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (!screen) return;
    NSRect area = screen.visibleFrame;
    [self.panel setFrame:NSMakeRect(round(NSMidX(area) - width / 2), NSMinY(area) + 24, width, height) display:NO];
    self.label.frame = NSMakeRect(start, floor((height - labelSize.height) / 2), ceil(labelSize.width), ceil(labelSize.height));
    [self.panel orderFrontRegardless];
}
- (void)showListening { [self show:@"Listening" listening:YES pending:NO]; }
- (void)showPending:(NSString *)message { [self show:message listening:NO pending:YES]; }
- (void)showNotice:(NSString *)message {
    [self show:message listening:NO pending:NO];
    __weak RecordingIndicator *indicator = self;
    self.dismissal = [NSTimer scheduledTimerWithTimeInterval:5 repeats:NO block:^(NSTimer *timer) { [indicator hide]; }];
}
- (void)addLevel:(CGFloat)level { [self.wave addLevel:level]; }
- (void)hide {
    [self.dismissal invalidate];
    self.dismissal = nil;
    [self.spinner stopAnimation:nil];
    [self.panel orderOut:nil];
}
@end
