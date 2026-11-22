#import "RecordingIndicator.h"
#import <QuartzCore/QuartzCore.h>

enum { barCount = 12, spokeCount = 8, trailingCount = barCount - spokeCount };
static const CGFloat indicatorScale = 1.3;
static const CGFloat barWidth = 2.7 * 1.3;
static const CGFloat waveformCapsuleWidth = 60 * 1.3;
static const CGFloat waveformCapsuleHeight = 40 * 1.3;
static const CFTimeInterval morphDuration = 1.04;
static const CFTimeInterval revolutionDuration = 1.8;
static const CGFloat rowGap = 5.6;
static const CGFloat routeScale = 4.5 * 1.3 / 7;

static CAMediaTimingFunction *curlTiming(void) {
    return [CAMediaTimingFunction functionWithControlPoints:1.0/3 :.25 :2.0/3 :1];
}

typedef NS_ENUM(NSUInteger, WaveMode) { WaveHidden, WaveListening, WavePending };

// Arc-length samples of the three cubics from the saved path editor.
enum { stepsPerBend = 180, sampleCount = 3 * stepsPerBend + 1 };
typedef struct { CGFloat x, y, angle, distance; } TrailSample;
static TrailSample trail[sampleCount];

static void prepareTrail(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const CGPoint points[] = {{0, 0},
            {4.37965425532, -6.59142287234}, {9.54288563830, -9.47473404255}, {14.06382978723, -7.52293882979},
            {25.18118351064, -4.74833776596}, {23.87267287234, 11.63597074468}, {12.73038563830, 12.71609042553},
            {2.78590425532, 13.57878989362}, {4.79554521277, 9.20744680851}, {-7, 12.8}};
        for (int i = 1; i < sampleCount; i++) {
            const CGPoint *p = points + 3 * ((i-1) / stepsPerBend);
            CGFloat t = (1 + (i-1) % stepsPerBend) / (CGFloat)stepsPerBend, u = 1-t;
            CGFloat x = u*u*u*p[0].x + 3*u*u*t*p[1].x + 3*u*t*t*p[2].x + t*t*t*p[3].x;
            CGFloat y = u*u*u*p[0].y + 3*u*u*t*p[1].y + 3*u*t*t*p[2].y + t*t*t*p[3].y;
            TrailSample prev = trail[i-1];
            trail[i] = (TrailSample){x,y,atan2(y-prev.y,x-prev.x),prev.distance+hypot(x-prev.x,y-prev.y)};
        }
    });
}
static CGFloat smoothStep(CGFloat t) {
    t = MIN(1,MAX(0,t));
    return t*t*(3-2*t);
}
static TrailSample sampleTrail(CGFloat distance) {
    CGFloat entry = trail[sampleCount-1].distance;
    if (distance <= 0) return (TrailSample){distance,0,0,0};
    if (distance >= entry) {
        CGFloat a = M_PI_2 + (distance-entry)/12.8;
        return (TrailSample){-7+12.8*cos(a),12.8*sin(a),a+M_PI_2,distance};
    }
    int lo=0, hi=sampleCount-1;
    while (hi-lo>1) {
        int mid=(lo+hi)/2;
        if (trail[mid].distance<distance) lo=mid; else hi=mid;
    }
    TrailSample a=trail[lo], b=trail[hi];
    CGFloat f=(distance-a.distance)/(b.distance-a.distance);
    return (TrailSample){a.x+f*(b.x-a.x),a.y+f*(b.y-a.y),b.angle,distance};
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
    CGPoint center = CGPointMake(CGRectGetMidX(_rotor.bounds), CGRectGetMidY(_rotor.bounds));
    prepareTrail();
    CFTimeInterval start = [_rotor convertTime:CACurrentMediaTime() fromLayer:nil];
    [_rotor removeAllAnimations];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat ringGap = 2*M_PI*12.8/spokeCount;
    CGFloat entry = trail[sampleCount-1].distance, closed = entry + (spokeCount-1)*ringGap;
    const int frames = 90;
    NSMutableArray *positions[barCount], *angles[barCount], *sizes[barCount];
    CGFloat previousAngles[barCount] = {}, initialHeights[barCount];
    for (int i=0; i<barCount; i++) {
        CALayer *bar = _bars[i];
        initialHeights[i] = (bar.presentationLayer ?: bar).bounds.size.height;
        [bar removeAllAnimations];
        if (_mode == WaveListening) {
            bar.position = CGPointMake(center.x+(i-(barCount-1)*.5)*rowGap*routeScale,center.y);
            bar.transform = CATransform3DIdentity;
            bar.bounds = CGRectMake(0,0,barWidth,[self heightAtIndex:i]);
            bar.opacity = 1;
        }
        if (morph) {
            positions[i]=[NSMutableArray array]; angles[i]=[NSMutableArray array]; sizes[i]=[NSMutableArray array];
        }
    }
    if (_mode == WavePending) {
        for (int frame=morph?0:frames; frame<=frames; frame++) {
            CGFloat t=frame/(CGFloat)frames;
            CGFloat head=closed*smoothStep(t)+(2*M_PI*12.8/revolutionDuration)*morphDuration*t*t*(t-1);
            CGFloat gap=rowGap+(ringGap-rowGap)*smoothStep(head/closed);
            TrailSample poses[barCount];
            CGFloat rowOffset = (barCount-1)*rowGap/2;
            CGFloat offset = rowOffset + (7-rowOffset)*smoothStep(head/(entry*.52));
            for (int i=0; i<barCount; i++)
                poses[i]=sampleTrail(head-(barCount-1-i)*gap);
            for (int i=0; i<barCount; i++) {
                TrailSample p=poses[i];
                CGPoint pos=CGPointMake(center.x+(p.x+offset)*routeScale, center.y-p.y*routeScale);
                CGFloat angle=previousAngles[i]+remainder(-p.angle-previousAngles[i],2*M_PI);
                previousAngles[i]=angle;
                CGFloat height=initialHeights[i]+(7.2*routeScale-initialHeights[i])*smoothStep((head-(barCount-1-i)*gap)/entry);
                for (int j=0; j<barCount; j++) {
                    CGFloat dx=poses[j].x-p.x,dy=poses[j].y-p.y,d=hypot(dx,dy);
                    if (d<.001) continue;
                    CGFloat projection=fabs((-dx*sin(p.angle)+dy*cos(p.angle))/d);
                    if (projection>.001) height=MIN(height,barWidth+MAX(0,d*routeScale-barWidth-1.5*routeScale)/projection);
                }
                CGFloat size = 1;
                if (i < trailingCount) {
                    CGFloat delay = .08 + .045*i;
                    size -= smoothStep((t-delay)/.42);
                }
                CGRect bounds=CGRectMake(0,0,barWidth*size,height*size);
                if (morph) {
                    [positions[i] addObject:[NSValue valueWithPoint:pos]];
                    [angles[i] addObject:@(angle)];
                    [sizes[i] addObject:[NSValue valueWithRect:bounds]];
                }
                if (frame!=frames) continue;
                CALayer *bar=_bars[i];
                bar.position=pos; bar.transform=CATransform3DMakeRotation(angle,0,0,1);
                bar.bounds=bounds; bar.opacity=i < trailingCount ? 0 : 1-.55*(i-trailingCount)/(spokeCount-1);
                if (morph) {
                    NSDictionary *tracks=@{@"position":positions[i],@"transform.rotation.z":angles[i],@"bounds":sizes[i]};
                    for (NSString *key in tracks) {
                        CAKeyframeAnimation *animation=[CAKeyframeAnimation animationWithKeyPath:key];
                        animation.values=tracks[key]; animation.duration=morphDuration;
                        animation.beginTime=[bar convertTime:start fromLayer:_rotor];
                        [bar addAnimation:animation forKey:key];
                    }
                    CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
                    fade.fromValue=@1; fade.toValue=@(bar.opacity); fade.duration=morphDuration;
                    [bar addAnimation:fade forKey:@"opacity"];
                }
            }
        }
        if (!_reduceMotion) {
            CABasicAnimation *spin=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            spin.fromValue=@0; spin.toValue=@(-2*M_PI); spin.duration=revolutionDuration;
            spin.repeatCount=HUGE_VALF; spin.beginTime=start+(morph?morphDuration:0);
            spin.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
            [_rotor addAnimation:spin forKey:@"spin"];
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
        morph.timingFunction = finishing ? curlTiming() : [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
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
