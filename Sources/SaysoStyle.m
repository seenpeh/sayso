#import "SaysoStyle.h"
#import <QuartzCore/QuartzCore.h>

static NSColor *RGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1];
}


NSImageView *SaysoMark(CGFloat size) {
    NSImage *mark = [NSImage imageWithSize:NSMakeSize(36, 36) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:10 yRadius:10];
        NSGradient *enamel = [[NSGradient alloc] initWithStartingColor:RGB(.56,.49,.93) endingColor:RGB(.32,.26,.69)];
        [enamel drawInBezierPath:tile angle:-75];
        [[NSColor colorWithWhite:1 alpha:.35] setStroke];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, .7, .7) xRadius:9.5 yRadius:9.5] stroke];
        CGFloat heights[] = {7, 15, 23, 13, 6};
        [NSColor.whiteColor setFill];
        for (NSInteger i = 0; i < 5; i++) {
            NSRect bar = NSMakeRect(8.5 + 4 * i, (36 - heights[i]) / 2, 3, heights[i]);
            [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.5 yRadius:1.5] fill];
        }
        return YES;
    }];
    NSImageView *view = [NSImageView imageViewWithImage:mark];
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    [view.widthAnchor constraintEqualToConstant:size].active = YES;
    [view.heightAnchor constraintEqualToConstant:size].active = YES;
    [view setAccessibilityElement:NO];
    return view;
}

void SaysoReveal(NSView *view, CGFloat offset) {
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;
    view.wantsLayer = YES;
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue = @(offset);
    slide.toValue = @0;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0;
    fade.toValue = @1;
    CAAnimationGroup *entry = [CAAnimationGroup animation];
    entry.animations = @[slide, fade];
    entry.duration = .19;
    entry.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [view.layer addAnimation:entry forKey:@"pageEntry"];
}

@implementation VoiceCard {
    NSArray<CAShapeLayer *> *_strands;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 17;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    NSMutableArray *strands = [NSMutableArray array];
    for (NSInteger i = 0; i < 9; i++) {
        CAShapeLayer *ink = [CAShapeLayer layer];
        ink.fillColor = nil;
        ink.strokeColor = RGB(.56 + .032*i, .50 + .042*i, .98).CGColor;
        ink.opacity = .28 + .07*i;
        ink.lineWidth = i == 8 ? 1.7 : 1;
        ink.lineCap = kCALineCapRound;
        [self.layer addSublayer:ink];
        [strands addObject:ink];
    }
    _strands = strands;
    return self;
}
- (void)drawRect:(NSRect)dirty {
    NSGradient *ink = [[NSGradient alloc] initWithColors:@[RGB(.11,.105,.19), RGB(.18,.16,.32), RGB(.33,.28,.58)]];
    [ink drawInRect:self.bounds angle:24];
}
- (void)layout {
    [super layout];
    // Draw one folded ribbon in the space above the status text.
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < _strands.count; i++) {
        CGFloat t = i / 8.0;
        CGMutablePathRef path = CGPathCreateMutable();
        for (NSInteger x = 0; x <= 225; x++) {
            CGFloat u = x / 225.0;
            CGFloat amplitude = pow(sin(M_PI*u), 1.25) * 22;
            CGFloat y = height - 27 + amplitude * sin(2.7*M_PI*u + 1.8*t)
                + 6*(t-.5)*sin(M_PI*u);
            if (!x) CGPathMoveToPoint(path, NULL, width-218, y);
            else CGPathAddLineToPoint(path, NULL, width-218+x, y);
        }
        _strands[i].path = path;
        CGPathRelease(path);
    }
    [CATransaction commit];
}
- (void)revealWave {
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;
    for (NSUInteger i = 0; i < _strands.count; i++) {
        CABasicAnimation *draw = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        draw.fromValue = @0;
        draw.toValue = @1;
        draw.duration = .28 + .014 * i;
        draw.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [_strands[i] addAnimation:draw forKey:@"ink"];
    }
}
@end

@implementation DictationActionButton {
    NSTrackingArea *_hoverArea;
    BOOL _hovered;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(super.intrinsicContentSize.width + 20, 38);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) [self removeTrackingArea:_hoverArea];
    _hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited |
        NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent *)event { _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { _hovered = NO; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
    NSRect rect = NSInsetRect(self.bounds, .5, .5);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:10 yRadius:10];
    NSColor *base = RGB(.34,.28,.72);
    NSColor *top = RGB(.42,.35,.79);
    if (self.highlighted) top = base = RGB(.28,.22,.62);
    else if (_hovered) top = RGB(.47,.40,.84);
    if (self.enabled) [[[NSGradient alloc] initWithStartingColor:top endingColor:base] drawInBezierPath:shape angle:90];
    else { [NSColor.quaternaryLabelColor setFill]; [shape fill]; }

    NSColor *ink = self.enabled ? NSColor.whiteColor : NSColor.secondaryLabelColor;
    NSDictionary *type = @{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                           NSForegroundColorAttributeName:ink};
    NSSize titleSize = [self.title sizeWithAttributes:type];
    CGFloat iconWidth = self.image ? 17 : 0;
    CGFloat gap = self.image ? 6 : 0;
    CGFloat left = floor(NSMidX(rect) - (iconWidth + gap + titleSize.width)/2);
    if (self.image) {
        NSImageSymbolConfiguration *palette = [NSImageSymbolConfiguration configurationWithPaletteColors:@[ink]];
        NSImage *icon = [self.image imageWithSymbolConfiguration:palette];
        [icon drawInRect:NSMakeRect(left, floor(NSMidY(rect)-8), iconWidth, 16)
                fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    [self.title drawAtPoint:NSMakePoint(left + iconWidth + gap, floor(NSMidY(rect)-titleSize.height/2))
            withAttributes:type];
}
- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] fill];
}
- (NSRect)focusRingMaskBounds { return self.bounds; }
@end
