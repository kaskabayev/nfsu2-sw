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

static int zone_label_kind(int kind)
{
    /* Buttons get a brighter fill than the stick halves. */
    return kind;
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
        CGContextSetRGBFillColor(c, 1, 1, 1, 0.12);
        CGContextSetRGBStrokeColor(c, 1, 1, 1, 0.85);
        CGContextSetLineWidth(c, 1.5);
        CGPathRef p = CGPathCreateWithEllipseInRect(r, NULL);
        CGContextAddPath(c, p);
        CGContextDrawPath(c, kCGPathFillStroke);
        CGPathRelease(p);
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
    Nfsu2Overlay *ov = [[Nfsu2Overlay alloc] initWithFrame:win.bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.tag = 0x4E463531;                 /* 'NF51' */
    [win addSubview:ov];
}
