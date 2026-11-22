#import "RecordingIndicator.h"
#import <QuartzCore/QuartzCore.h>

@interface LevelView : NSView {
    CGFloat _levels[7];
}
- (void)addLevel:(CGFloat)level;
- (void)reset;
@end

@implementation LevelView
- (void)reset {
    memset(_levels, 0, sizeof(_levels));
    self.needsDisplay = YES;
}
- (void)addLevel:(CGFloat)level {
    if (self.hidden || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;
    CGFloat sample = MIN(1, sqrt(MAX(0, level)) * 2.5);
    CGFloat previous = _levels[6];
    memmove(_levels, _levels + 1, sizeof(_levels) - sizeof(CGFloat));
    _levels[6] = previous + (sample - previous) * (sample > previous ? .72 : .35);
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    const CGFloat stillHeights[] = {4, 8, 13, 17, 11, 7, 4};
    BOOL still = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    for (NSInteger i = 0; i < 7; i++) {
        CGFloat height = still ? stillHeights[i] : 3 + (stillHeights[i] + 2) * _levels[i];
        [[NSColor colorWithSRGBRed:.75 + .03*i green:.71 + .035*i blue:1 alpha:1] setFill];
        NSRect bar = NSMakeRect(i * 4.5, (NSHeight(self.bounds) - height) / 2, 2.7, height);
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.35 yRadius:1.35] fill];
    }
}
@end

@interface RecordingIndicator ()
@property NSPanel *panel;
@property NSVisualEffectView *surface;
@property LevelView *wave;
@property NSProgressIndicator *spinner;
@property NSImageView *symbol;
@property NSTextField *label;
@property NSTimer *dismissal;
@property NSUInteger presentation;
@property BOOL dismissing;
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
    _panel.animationBehavior = NSWindowAnimationBehaviorNone;
    _panel.contentView.wantsLayer = YES;
    _surface = [NSVisualEffectView new];
    _surface.material = NSVisualEffectMaterialHUDWindow;
    _surface.state = NSVisualEffectStateActive;
    _surface.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    _surface.wantsLayer = YES;
    _surface.layer.masksToBounds = YES;
    _surface.layer.cornerCurve = kCACornerCurveContinuous;
    _surface.layer.borderWidth = .75;
    _surface.layer.borderColor = [NSColor colorWithWhite:1 alpha:.26].CGColor;
    [_panel.contentView addSubview:_surface];
    _wave = [LevelView new];
    [_wave setAccessibilityElement:NO];
    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _symbol = [NSImageView new];
    _symbol.contentTintColor = [NSColor colorWithSRGBRed:.83 green:.79 blue:1 alpha:1];
    _label = [NSTextField wrappingLabelWithString:@""];
    _label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _label.textColor = NSColor.whiteColor;
    for (NSView *view in @[_wave, _spinner, _symbol, _label]) [_surface addSubview:view];
    return self;
}

- (void)animateCapsuleIn:(BOOL)entering {
    CALayer *layer = self.surface.layer;
    CGFloat x = NSWidth(self.surface.bounds) * (.5 - layer.anchorPoint.x);
    CGFloat y = NSHeight(self.surface.bounds) * (.5 - layer.anchorPoint.y);
    CAKeyframeAnimation *shape = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    NSMutableArray *steps = [NSMutableArray array];
    for (NSNumber *value in entering ? @[@.78, @1.018, @1] : @[@1, @.90]) {
        CGFloat scale = value.doubleValue;
        CATransform3D pose = CATransform3DMakeTranslation(x * (1-scale), y * (1-scale) - 8 * (1-scale), 0);
        [steps addObject:[NSValue valueWithCATransform3D:CATransform3DScale(pose, scale, scale, 1)]];
    }
    shape.values = steps;
    shape.keyTimes = entering ? @[@0, @.72, @1] : @[@0, @1];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = entering ? @0 : @(layer.presentationLayer ? layer.presentationLayer.opacity : 1);
    fade.toValue = entering ? @1 : @0;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[shape, fade];
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    group.duration = entering ? .23 : .13;
    group.fillMode = kCAFillModeForwards;
    group.removedOnCompletion = entering;
    [layer addAnimation:group forKey:@"capsule"];
}

- (void)show:(NSString *)text listening:(BOOL)listening pending:(BOOL)pending {
    [self.dismissal invalidate];
    self.presentation++;
    BOOL appearing = !self.panel.visible || self.dismissing;
    self.dismissing = NO;
    BOOL motion = !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    BOOL spin = pending && motion;
    self.wave.hidden = !listening;
    self.spinner.hidden = !spin;
    self.symbol.hidden = listening || spin;
    self.symbol.image = [NSImage imageWithSystemSymbolName:pending ? @"ellipsis" : @"info.circle" accessibilityDescription:nil];
    if (spin) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
    BOOL changing = !appearing && ![self.label.stringValue isEqualToString:text];
    CGFloat oldWidth = NSWidth(self.surface.bounds);
    self.label.stringValue = text;
    CGFloat start = listening ? 55 : 40;
    NSSize labelSize = [self.label.cell cellSizeForBounds:NSMakeRect(0, 0, 300, CGFLOAT_MAX)];
    CGFloat height = MAX(38, ceil(labelSize.height) + 18);
    CGFloat width = ceil(labelSize.width) + start + 17;
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (!screen) return;
    NSRect area = screen.visibleFrame;
    // Keep the window centered while its visible surface changes between states.
    CGFloat panelWidth = MAX(390, width + 12);
    [self.panel setFrame:NSMakeRect(round(NSMidX(area) - panelWidth / 2), NSMinY(area) + 14, panelWidth, height + 12) display:NO];
    self.surface.frame = NSMakeRect(round((panelWidth - width) / 2), 6, width, height);
    self.surface.layer.cornerRadius = 19;
    self.label.frame = NSMakeRect(start, floor((height - labelSize.height) / 2), ceil(labelSize.width), ceil(labelSize.height));
    self.wave.frame = NSMakeRect(15, floor((height - 22) / 2), 32, 22);
    self.symbol.frame = self.spinner.frame = NSMakeRect(15, floor((height - 17) / 2), 17, 17);
    [self.panel orderFrontRegardless];
    [self.panel invalidateShadow];
    if (changing && motion) {
        CALayer *layer = self.surface.layer;
        CABasicAnimation *resize = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        resize.fromValue = @(oldWidth);
        resize.toValue = @(width);
        CABasicAnimation *center = [CABasicAnimation animationWithKeyPath:@"position.x"];
        center.fromValue = @(layer.position.x + (oldWidth - width) * (layer.anchorPoint.x - .5));
        center.toValue = @(layer.position.x);
        CAAnimationGroup *morph = [CAAnimationGroup animation];
        morph.animations = @[resize, center];
        morph.duration = .16;
        morph.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [layer addAnimation:morph forKey:@"stateChange"];
    }
    if (appearing) {
        [self.surface.layer removeAnimationForKey:@"stateChange"];        [self.surface.layer removeAnimationForKey:@"capsule"];
        if (motion) [self animateCapsuleIn:YES];
    }
}
- (void)showListening {
    [self.wave reset];
    [self show:@"Listening" listening:YES pending:NO];
}
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
    if (!self.panel.visible || self.dismissing) return;
    NSUInteger token = ++self.presentation;
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        [self.panel orderOut:nil];
        return;
    }
    self.dismissing = YES;
    [self animateCapsuleIn:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 130 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self.presentation != token) return;
        [self.panel orderOut:nil];
        [self.surface.layer removeAnimationForKey:@"capsule"];
        self.dismissing = NO;
    });
}
@end
