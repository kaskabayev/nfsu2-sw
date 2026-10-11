/* ios_touch_overlay.m -- visible on-screen controls over the SDL window.
 * Pure UIKit: a transparent view with one ellipse per touch zone, drawn
 * from the same table the touch layer hit-tests (xinput_ios.h). The view
 * does not take touches; SDL underneath keeps owning them. */
#import <UIKit/UIKit.h>
/* Mirror the XBOX_IOS_TOUCH_ZONE layout (xinput_ios.h) instead of including
 * it: that header pulls the Win32 vocabulary, and its `typedef int BOOL`
 * collides with ObjC's own BOOL. int/float pairs keep identical layout in
 * both worlds, so a parallel declaration is safe. */
typedef struct XBOX_IOS_TOUCH_ZONE_MIRROR {
    int   id;
    float cx, cy, rx, ry;
    int   kind, value;
} XBOX_IOS_TOUCH_ZONE_MIRROR;
extern const void *xbox_ios_touch_zones(int *count);

/* One-letter labels for the buttons; triggers/shoulders get two. */
static const char *zone_label(int value)
{
    switch (value) {
    case 0:  return "A";
    case 1:  return "B";
    case 2:  return "X";
    case 3:  return "Y";
    case 4:  return "LB";
    case 5:  return "LT";
    case 6:  return "RB";
    case 7:  return "RT";
    default: return NULL;   /* sticks and the bare halves stay unlabeled */
    }
}

@interface Nfsu2Overlay : UIView
@end
@implementation Nfsu2Overlay
- (id)initWithFrame:(CGRect)f
{
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.alpha = 0.55f;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}
- (void)drawRect:(CGRect)rect
{
    (void)rect;
    CGContextRef c = UIGraphicsGetCurrentContext();
    int n = 0;
    const XBOX_IOS_TOUCH_ZONE_MIRROR *z =
        (const XBOX_IOS_TOUCH_ZONE_MIRROR *)xbox_ios_touch_zones(&n);
    if (!c || !z || n <= 0)
        return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    for (int i = 0; i < n; i++) {
        /* Label the stick halves with a small ring at their rest centre
         * instead of a huge ellipse that would obscure the game. */
        float rr = z[i].rx * z[i].ry > 0.06f ? 0.045f : z[i].rx;
        float ry2 = z[i].rx * z[i].ry > 0.06f ? 0.045f * (z[i].ry / z[i].rx) : z[i].ry;
        CGRect r = CGRectMake((z[i].cx - rr) * W,
                              (z[i].cy - ry2) * H,
                              rr * 2 * W,
                              ry2 * 2 * H);
        CGContextSetRGBFillColor(c, 1, 1, 1, 0.18);
        CGContextSetRGBStrokeColor(c, 1, 1, 1, 0.85);
        CGContextSetLineWidth(c, 1.5);
        CGPathRef p = CGPathCreateWithEllipseInRect(r, NULL);
        CGContextAddPath(c, p);
        CGContextDrawPath(c, kCGPathFillStroke);
        CGPathRelease(p);
        /* Button label, centred. */
        const char *lbl = zone_label(z[i].value);
        if (lbl) {
            NSDictionary *attrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:H * 0.045f],
                NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.95]
            };
            NSString *str = [NSString stringWithUTF8String:lbl];
            CGSize sz = [str sizeWithAttributes:attrs];
            [str drawAtPoint:CGPointMake(z[i].cx * W - sz.width / 2,
                                         z[i].cy * H - sz.height / 2)
              withAttributes:attrs];
        }
    }
    (void)zone_label_kind;
}
@end

/* Called from main.c (iOS) after the SDL window exists. uiwindow is the
 * SDL UIWindow obtained via SDL_GetWindowWMInfo. */
void ios_touch_overlay_install(void *uiwindow)
{
    UIWindow *win = (__bridge UIWindow *)uiwindow;
    if (!win)
        return;
    /* If a previous install exists, refresh its frame instead of stacking. */
    for (UIView *sub in win.subviews)
        if ([sub isKindOfClass:[Nfsu2Overlay class]]) {
            [sub removeFromSuperview];
            break;
        }
    Nfsu2Overlay *ov = [[Nfsu2Overlay alloc] initWithFrame:win.bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.tag = 0x4E463531;                 /* 'NF51' */
    /* Add ABOVE SDL's view (SDL reassigns rootViewController.view when the
     * Metal view is created, so a plain addSubview can land underneath) and
     * force it to the front of the z-order. */
    [win addSubview:ov];
    [win bringSubviewToFront:ov];
    /* Draw once now; without this the first frame may not invalidate. */
    [ov setNeedsDisplay];
    fprintf(stderr, "nfsu2: overlay frame %g x %g subviews %lu\n",
            (double)ov.frame.size.width, (double)ov.frame.size.height,
            (unsigned long)win.subviews.count);
}
