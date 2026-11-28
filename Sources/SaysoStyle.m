#import "SaysoStyle.h"
#import <QuartzCore/QuartzCore.h>

static NSColor *RGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1];
}

NSImageView *SaysoMark(CGFloat size) {
    NSImage *mark = [NSBundle.mainBundle imageForResource:@"VoiceKey"] ?: [NSImage imageNamed:NSImageNameApplicationIcon];
    NSImageView *view = [NSImageView imageViewWithImage:mark];
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    [view.widthAnchor constraintEqualToConstant:size].active = YES;
    [view.heightAnchor constraintEqualToConstant:size].active = YES;
    [view setAccessibilityElement:NO];
    return view;
}

NSFont *SaysoHeadingFont(CGFloat size) {
    NSFont *base = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    NSFontDescriptor *serif = [base.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignSerif];
    return serif ? [NSFont fontWithDescriptor:serif size:size] : base;
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

@implementation VoiceCard
- (void)drawRect:(NSRect)dirty {
    NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, .5, .5)
                                                          xRadius:14 yRadius:14];
    [RGB(.08, .18, .18) setFill];
    [plate fill];
    [RGB(.26, .37, .36) setStroke];
    [plate stroke];

    // The two brass stops and scale echo the carriage on Sayso’s typewriter.
    CGFloat left = 20, right = NSWidth(self.bounds) - left, top = NSMaxY(self.bounds) - 12;
    NSBezierPath *scale = [NSBezierPath bezierPath];
    [scale moveToPoint:NSMakePoint(left, top)];
    [scale lineToPoint:NSMakePoint(right, top)];
    for (NSInteger tick = 1; left + tick * 6 < right - 2; tick++) {
        CGFloat x = left + tick * 6;
        [scale moveToPoint:NSMakePoint(x, top)];
        [scale lineToPoint:NSMakePoint(x, top - (tick % 5 == 0 ? 6 : 3))];
    }
    [RGB(.36, .47, .44) setStroke];
    scale.lineWidth = .75;
    [scale stroke];
    [RGB(.96, .81, .40) setFill];
    for (NSNumber *stop in @[@(left), @(right)]) {
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(stop.doubleValue - 1.5, top - 5, 3, 7)
                                         xRadius:1 yRadius:1] fill];
    }
}
@end

@implementation DictationActionButton {
    NSTrackingArea *_hoverArea;
    BOOL _hovered;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(super.intrinsicContentSize.width + 20, 36);
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
    NSColor *fill = RGB(1, .84, .39);
    if (!self.enabled) fill = RGB(.23, .32, .31);
    else if (self.highlighted) fill = RGB(.92, .71, .26);
    else if (_hovered) fill = RGB(1, .89, .55);
    [fill setFill];
    [shape fill];

    NSColor *ink = self.enabled ? RGB(.12, .16, .13) : RGB(.82, .86, .83);
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
