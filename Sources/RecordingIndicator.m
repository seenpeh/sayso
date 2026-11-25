#import "RecordingIndicator.h"
#import <QuartzCore/QuartzCore.h>

enum { barCount = 12, spokeCount = 8, trailingCount = barCount - spokeCount };
static const CGFloat indicatorScale = 1.3;
static const CGFloat barWidth = 2.7 * 1.3;
static const CGFloat waveformCapsuleWidth = 60 * 1.3;
static const CGFloat waveformCapsuleHeight = 40 * 1.3;
static const CFTimeInterval morphDuration = 1.04;
static const CFTimeInterval revolutionDuration = 1.8;
static const CGFloat barSpacing = 4.7;
static const CGFloat ringRadius = 11;
static const CGFloat spokeHeight = 7;

typedef NS_ENUM(NSUInteger, WaveMode) { WaveHidden, WaveListening, WavePending };

@interface LevelView : NSView {
    CALayer *_pivots[barCount];
    CALayer *_bars[barCount];
    CGFloat _levels[barCount];
    BOOL _reduceMotion;
}
@property (nonatomic) WaveMode mode;
- (void)addLevel:(CGFloat)level;
@end

@implementation LevelView
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.hidden = YES;
    for (NSUInteger i = 0; i < barCount; i++) {
        CALayer *pivot = [CALayer layer];
        CATransform3D perspective = CATransform3DIdentity;
        perspective.m34 = -1.0 / 90;
        pivot.sublayerTransform = perspective;
        _pivots[i] = pivot;
        [self.layer addSublayer:pivot];
        CALayer *bar = [CALayer layer];
        bar.cornerRadius = barWidth / 2;
        bar.backgroundColor = [NSColor colorWithSRGBRed:.82 green:.80 blue:1 alpha:1].CGColor;
        _bars[i] = bar;
        [pivot addSublayer:bar];
    }
    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    _reduceMotion = workspace.accessibilityDisplayShouldReduceMotion;
    [workspace.notificationCenter addObserver:self selector:@selector(motionPreferenceChanged:)
        name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    return self;
}

- (CGFloat)heightAtIndex:(NSUInteger)i {
    static const CGFloat accents[barCount] = {8, 10, 13, 16, 18, 20, 19, 17, 15, 13, 11, 8};
    return (4 + accents[i] * (_reduceMotion ? .65 : _levels[i])) * indicatorScale;
}

- (void)addLevel:(CGFloat)level {
    if (_mode != WaveListening || _reduceMotion) return;
    CGFloat sample = MIN(1, sqrt(MAX(0, level)) * 2.5);
    CGFloat previous = _levels[barCount - 1];
    memmove(_levels, _levels + 1, sizeof(_levels) - sizeof(_levels[0]));
    _levels[barCount - 1] = previous + (sample - previous) * (sample > previous ? .72 : .35);
    [CATransaction begin];
    [CATransaction setAnimationDuration:.05];
    for (NSUInteger i = 0; i < barCount; i++)
        _bars[i].bounds = CGRectMake(0, 0, barWidth, [self heightAtIndex:i]);
    [CATransaction commit];
}

- (void)applyModeAnimated:(BOOL)morph {
    CGPoint center = CGPointMake(NSMidX(self.bounds), NSMidY(self.bounds));
    CFTimeInterval start = CACurrentMediaTime();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < barCount; i++) {
        CALayer *pivot = _pivots[i];
        CALayer *bar = _bars[i];
        CGRect previousBounds = (bar.presentationLayer ?: bar).bounds;
        [pivot removeAllAnimations];
        [bar removeAllAnimations];
        CGFloat rowX = center.x + (i - (barCount - 1) * .5) * barSpacing;
        pivot.position = CGPointMake(rowX, center.y);
        bar.transform = CATransform3DIdentity;
        bar.opacity = 1;
        bar.bounds = CGRectMake(0, 0, barWidth, [self heightAtIndex:i]);
        if (_mode != WavePending) continue;

        BOOL spoke = i >= trailingCount;
        CGFloat angle = spoke ? (i - trailingCount) * 2 * M_PI / spokeCount : 0;
        CGPoint destination = CGPointMake(center.x + ringRadius * sin(angle),
                                          center.y + ringRadius * cos(angle));
        pivot.position = destination;
        bar.opacity = spoke ? 1 : 0;
        bar.bounds = CGRectMake(0, 0, barWidth, spokeHeight);
        CATransform3D radial = CATransform3DMakeRotation(-angle, 0, 0, 1);
        bar.transform = radial;
        if (morph) {
            CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position"];
            move.fromValue = [NSValue valueWithPoint:CGPointMake(rowX, center.y)];
            move.toValue = [NSValue valueWithPoint:destination];
            move.duration = morphDuration;
            move.timingFunction = ease;
            move.beginTime = [pivot convertTime:start fromLayer:nil];
            [pivot addAnimation:move forKey:@"formRing"];

            CABasicAnimation *size = [CABasicAnimation animationWithKeyPath:@"bounds"];
            size.fromValue = [NSValue valueWithRect:previousBounds];
            size.toValue = [NSValue valueWithRect:bar.bounds];
            CABasicAnimation *orient = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            orient.fromValue = @0;
            orient.toValue = @(remainder(-angle, 2 * M_PI));
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = @1;
            fade.toValue = @(bar.opacity);
            CAAnimationGroup *form = [CAAnimationGroup animation];
            form.animations = @[size, orient, fade];
            form.duration = morphDuration;
            form.timingFunction = ease;
            form.beginTime = [bar convertTime:start fromLayer:nil];
            [bar addAnimation:form forKey:@"formSpoke"];
        }
        if (spoke && !_reduceMotion) {
            // Turn the radial bar in its parent's coordinates, around its fixed center.
            CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"sublayerTransform.rotation.y"];
            turn.fromValue = @0;
            turn.toValue = @(2 * M_PI);
            turn.duration = revolutionDuration;
            turn.repeatCount = HUGE_VALF;
            turn.beginTime = [pivot convertTime:start fromLayer:nil] + (morph ? morphDuration : 0)
                             + (i - trailingCount) * .04;
            turn.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
            [pivot addAnimation:turn forKey:@"doorTurn"];
        }
    }
    [CATransaction commit];
}

- (void)setMode:(WaveMode)mode {
    if (_mode == mode) return;
    BOOL morph = _mode == WaveListening && mode == WavePending && !_reduceMotion;
    _mode = mode;
    self.hidden = mode == WaveHidden;
    if (mode == WaveListening) memset(_levels, 0, sizeof(_levels));
    [self applyModeAnimated:morph];
}

- (void)motionPreferenceChanged:(NSNotification *)notification {
    BOOL reduced = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (_reduceMotion == reduced) return;
    _reduceMotion = reduced;
    [self applyModeAnimated:NO];
}
@end

@interface RecordingIndicator ()
@property NSPanel *panel;
@property NSVisualEffectView *surface;
@property LevelView *wave;
@property NSImageView *symbol;
@property NSTextField *label;
@property NSTimer *dismissal;
@property NSUInteger presentation;
@property BOOL dismissing;
@property CFTimeInterval earliestDismissal;
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
    _wave = [[LevelView alloc] initWithFrame:NSMakeRect(0, 0, waveformCapsuleWidth, waveformCapsuleHeight)];
    [_wave setAccessibilityElement:NO];
    _symbol = [NSImageView new];
    _symbol.contentTintColor = [NSColor colorWithSRGBRed:.83 green:.79 blue:1 alpha:1];
    _symbol.image = [NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:nil];
    _label = [NSTextField wrappingLabelWithString:@""];
    _label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _label.textColor = NSColor.whiteColor;
    for (NSView *view in @[_wave, _symbol, _label]) [_surface addSubview:view];
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

- (void)show:(NSString *)text waveMode:(WaveMode)mode {
    [self.dismissal invalidate];
    self.presentation++;
    BOOL appearing = !self.panel.visible || self.dismissing;
    self.dismissing = NO;
    BOOL motion = !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    BOOL usesBars = mode != WaveHidden;
    BOOL finishing = mode == WavePending && self.wave.mode == WaveListening && motion && !appearing;
    self.earliestDismissal = finishing ? CACurrentMediaTime() + morphDuration + .23 : 0;
    self.wave.mode = mode;
    self.symbol.hidden = usesBars;
    BOOL hasLabel = text.length > 0;
    [self.wave.layer removeAnimationForKey:@"centerGlyph"];
    CGFloat oldWidth = NSWidth(self.surface.bounds);
    self.label.stringValue = text;
    self.label.hidden = !hasLabel;
    CGFloat scale = usesBars ? indicatorScale : 1;
    CGFloat start = usesBars ? 59 * scale : 40;
    NSSize labelSize = [self.label.cell cellSizeForBounds:NSMakeRect(0, 0, 300, CGFLOAT_MAX)];
    CGFloat height = MAX(38 * scale, ceil(labelSize.height) + 18);
    CGFloat width = ceil(labelSize.width) + start + 17 * scale;
    if (usesBars && !hasLabel) {
        width = waveformCapsuleWidth;
        height = waveformCapsuleHeight;
    } else if (!hasLabel) {
        width = height;
    }
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (!screen) return;
    NSRect area = screen.visibleFrame;
    // Keep the window centered while its visible surface changes between states.
    CGFloat panelWidth = MAX(390, width + 12);
    [self.panel setFrame:NSMakeRect(round(NSMidX(area) - panelWidth / 2), NSMinY(area) + 14, panelWidth, height + 12) display:NO];
    self.surface.frame = NSMakeRect(round((panelWidth - width) / 2), 6, width, height);
    self.surface.layer.cornerRadius = usesBars && !hasLabel ? height / 2 : 19 * scale;
    self.label.frame = NSMakeRect(start, floor((height - labelSize.height) / 2), ceil(labelSize.width), ceil(labelSize.height));
    CGFloat waveX = hasLabel ? 33 * scale - NSWidth(self.wave.frame) / 2 : (width - NSWidth(self.wave.frame)) / 2;
    [self.wave setFrameOrigin:NSMakePoint(waveX, (height - NSHeight(self.wave.frame)) / 2)];
    self.symbol.frame = NSMakeRect(15, floor((height - 17) / 2), 17, 17);
    [self.panel orderFrontRegardless];
    [self.panel invalidateShadow];
    if (!appearing && motion && oldWidth != width) {
        CALayer *layer = self.surface.layer;
        CABasicAnimation *resize = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        resize.fromValue = @(oldWidth);
        resize.toValue = @(width);
        CABasicAnimation *center = [CABasicAnimation animationWithKeyPath:@"position.x"];
        center.fromValue = @(layer.position.x + (oldWidth - width) * (layer.anchorPoint.x - .5));
        center.toValue = @(layer.position.x);
        CAAnimationGroup *morph = [CAAnimationGroup animation];
        morph.animations = @[resize, center];
        morph.duration = finishing ? morphDuration : .16;
        morph.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        if (!hasLabel) {
            CABasicAnimation *align = [CABasicAnimation animationWithKeyPath:@"position.x"];
            align.additive = YES;
            align.fromValue = @((oldWidth - width) / 2);
            align.toValue = @0;
            align.duration = morph.duration;
            align.timingFunction = morph.timingFunction;
            [self.wave.layer addAnimation:align forKey:@"centerGlyph"];
        }
        [layer addAnimation:morph forKey:@"stateChange"];
    }
    if (appearing) {
        [self.surface.layer removeAnimationForKey:@"stateChange"];
        [self.surface.layer removeAnimationForKey:@"capsule"];
        if (motion) [self animateCapsuleIn:YES];
    }
}
- (void)showListening {
    [self show:@"" waveMode:WaveListening];
}
- (void)showProcessing { [self show:@"" waveMode:WavePending]; }
- (void)showPending:(NSString *)message { [self show:message waveMode:WavePending]; }
- (void)showNotice:(NSString *)message {
    [self show:message waveMode:WaveHidden];
    __weak RecordingIndicator *indicator = self;
    self.dismissal = [NSTimer scheduledTimerWithTimeInterval:5 repeats:NO block:^(NSTimer *timer) { [indicator hide]; }];
}
- (void)addLevel:(CGFloat)level { [self.wave addLevel:level]; }
- (void)hide {
    [self.dismissal invalidate];
    self.dismissal = nil;
    if (!self.panel.visible || self.dismissing) return;
    NSUInteger token = ++self.presentation;
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        [self.panel orderOut:nil];
        self.wave.mode = WaveHidden;
        return;
    }
    // Let even an empty final phrase complete the visual handoff. Input is already idle.
    CFTimeInterval remaining = self.earliestDismissal - CACurrentMediaTime();
    if (remaining > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.presentation == token) [self hide];
        });
        return;
    }
    self.dismissing = YES;
    [self animateCapsuleIn:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 130 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self.presentation != token) return;
        [self.panel orderOut:nil];
        self.wave.mode = WaveHidden;
        [self.surface.layer removeAnimationForKey:@"capsule"];
        self.dismissing = NO;
    });
}
@end
