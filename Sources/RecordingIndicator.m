#import "RecordingIndicator.h"
#import <QuartzCore/QuartzCore.h>

enum { barCount = 8 };
static const CGFloat indicatorScale = 1.3;
static const CGFloat barWidth = 2.7 * 1.3;
static const CFTimeInterval morphDuration = .39;

typedef NS_ENUM(NSUInteger, WaveMode) { WaveHidden, WaveListening, WavePending };

// Bend the row as one chain. Every adjoining pair turns through the same angle.
static void curlPositions(CGPoint points[barCount], CGPoint center, CGFloat progress) {
    CGFloat turn = 2 * M_PI / barCount;
    CGFloat spacing = indicatorScale * (4.5 + progress * (2 * 8.4 * sin(turn / 2) - 4.5));
    points[0] = CGPointZero;
    CGFloat left = 0, right = 0, bottom = 0, top = 0;
    for (NSUInteger i = 1; i < barCount; i++) {
        CGFloat tangent = -(i - .5) * turn * progress;
        points[i] = CGPointMake(points[i - 1].x + spacing * cos(tangent),
                                points[i - 1].y + spacing * sin(tangent));
        left = MIN(left, points[i].x);
        right = MAX(right, points[i].x);
        bottom = MIN(bottom, points[i].y);
        top = MAX(top, points[i].y);
    }
    for (NSUInteger i = 0; i < barCount; i++) {
        points[i].x += center.x - (left + right) / 2;
        points[i].y += center.y - (bottom + top) / 2;
    }
}

@interface LevelView : NSView {
    CALayer *_rotor;
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
    _rotor = [CALayer layer];
    _rotor.frame = self.bounds;
    [self.layer addSublayer:_rotor];
    for (NSUInteger i = 0; i < barCount; i++) {
        CALayer *bar = [CALayer layer];
        bar.cornerRadius = barWidth / 2;
        bar.backgroundColor = [NSColor colorWithSRGBRed:.82 green:.80 blue:1 alpha:1].CGColor;
        _bars[i] = bar;
        [_rotor addSublayer:bar];
    }
    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    _reduceMotion = workspace.accessibilityDisplayShouldReduceMotion;
    [workspace.notificationCenter addObserver:self selector:@selector(motionPreferenceChanged:)
        name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    return self;
}

- (CGFloat)heightAtIndex:(NSUInteger)i {
    static const CGFloat accents[barCount] = {8, 12, 16, 20, 18, 15, 12, 9};
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
    CGPoint center = CGPointMake(CGRectGetMidX(_rotor.bounds), CGRectGetMidY(_rotor.bounds));
    [_rotor removeAnimationForKey:@"spin"];
    [CATransaction begin];
    [CATransaction setDisableActions:!morph];
    [CATransaction setAnimationDuration:morphDuration];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    NSMutableArray<NSValue *> *paths[barCount];
    CGPoint positions[barCount];
    if (_mode == WavePending) {
        if (morph) {
            for (NSUInteger i = 0; i < barCount; i++) paths[i] = [NSMutableArray array];
            for (NSUInteger frame = 0; frame <= 30; frame++) {
                curlPositions(positions, center, frame / 30.0);
                for (NSUInteger i = 0; i < barCount; i++)
                    [paths[i] addObject:[NSValue valueWithPoint:positions[i]]];
            }
        } else {
            curlPositions(positions, center, 1);
        }
    }
    for (NSUInteger i = 0; i < barCount; i++) {
        CALayer *bar = _bars[i];
        if (!morph) [bar removeAllAnimations];
        if (_mode == WaveHidden) continue;
        if (_mode == WaveListening) {
            bar.position = CGPointMake(center.x + (i - (barCount - 1) * .5) * 4.5 * indicatorScale, center.y);
            bar.bounds = CGRectMake(0, 0, barWidth, [self heightAtIndex:i]);
            bar.transform = CATransform3DIdentity;
            bar.opacity = 1;
        } else {
            CGFloat rotation = -(CGFloat)i * (2 * M_PI / barCount);
            bar.position = positions[i];
            bar.bounds = CGRectMake(0, 0, barWidth, 5.6 * indicatorScale);
            bar.transform = CATransform3DMakeRotation(rotation, 0, 0, 1);
            bar.opacity = 1 - .66 * i / (barCount - 1);
            if (morph) {
                CAKeyframeAnimation *curl = [CAKeyframeAnimation animationWithKeyPath:@"position"];
                curl.values = paths[i];
                curl.duration = morphDuration;
                curl.timingFunction = CATransaction.animationTimingFunction;
                [bar addAnimation:curl forKey:@"position"];
                CABasicAnimation *tilt = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
                tilt.fromValue = @0;
                tilt.toValue = @(rotation);
                tilt.duration = morphDuration;
                tilt.timingFunction = curl.timingFunction;
                [bar removeAnimationForKey:@"transform"];
                [bar addAnimation:tilt forKey:@"transform"];
            }
        }
    }
    [CATransaction commit];
    if (_mode == WavePending && !_reduceMotion) {
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0;
        spin.toValue = @(-2 * M_PI);
        spin.duration = .9;
        spin.beginTime = [_rotor convertTime:CACurrentMediaTime() fromLayer:nil] + (morph ? morphDuration : 0);
        spin.repeatCount = HUGE_VALF;
        spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [_rotor addAnimation:spin forKey:@"spin"];
    }
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
    _wave = [[LevelView alloc] initWithFrame:NSMakeRect(0, 0, 36 * indicatorScale, 38 * indicatorScale)];
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
    if (!hasLabel) width = mode == WaveListening ? NSWidth(self.wave.frame) + 20 * scale : height;
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (!screen) return;
    NSRect area = screen.visibleFrame;
    // Keep the window centered while its visible surface changes between states.
    CGFloat panelWidth = MAX(390, width + 12);
    [self.panel setFrame:NSMakeRect(round(NSMidX(area) - panelWidth / 2), NSMinY(area) + 14, panelWidth, height + 12) display:NO];
    self.surface.frame = NSMakeRect(round((panelWidth - width) / 2), 6, width, height);
    self.surface.layer.cornerRadius = 19 * scale;
    self.label.frame = NSMakeRect(start, floor((height - labelSize.height) / 2), ceil(labelSize.width), ceil(labelSize.height));
    CGFloat waveX = hasLabel ? 15 * scale : (width - NSWidth(self.wave.frame)) / 2;
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
        morph.timingFunction = [CAMediaTimingFunction functionWithName:finishing ? kCAMediaTimingFunctionEaseInEaseOut : kCAMediaTimingFunctionEaseOut];
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
