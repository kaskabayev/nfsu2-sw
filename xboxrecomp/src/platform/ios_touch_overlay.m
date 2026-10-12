/* ios_touch_overlay.m -- visible on-screen controls over the SDL window.
 * Pure UIKit: a transparent view with one labeled ellipse per touch zone,
 * drawn from the same table the touch layer hit-tests (xinput_ios.c). The
 * overlay itself never takes touches except the gear button and its panel
 * (hitTest: returns nil for everything else, SDL keeps them). */
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
extern int xbox_ios_touch_stick(int side, float *bx, float *by, float *kx, float *ky);
extern int xbox_ios_touch_zone_pressed(int idx);
extern int nv2a_vk_fps_x10(void);

/* Settings (Documents/nfsu2_env.txt, loaded in main.c; changed live by the
 * panel). Keys NFSU2_SHOW_FPS / NFSU2_OVERLAY_ALPHA. */
extern float nfsu2_cfg_overlay_alpha(void);
extern int   nfsu2_cfg_show_fps(void);

static const char *zone_label_by_id(int id)
{
    switch (id) {
    case 4:  return "LB";
    case 5:  return "LT";
    case 6:  return "RB";
    case 7:  return "RT";
    case 8:  return "A";
    case 9:  return "B";
    case 10: return "X";
    case 11: return "Y";
    default: return NULL;   /* BACK/START/DPAD stay shapes */
    }
}

@class Nfsu2GearTarget;
static Nfsu2GearTarget *s_target;

@interface Nfsu2Overlay : UIView
- (void)applyVisibility:(BOOL)vis;
@property (nonatomic, assign) BOOL shapesHidden;   /* controls off / pad on */
@end

@implementation Nfsu2Overlay
- (id)initWithFrame:(CGRect)f
{
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;   /* only the gear/panel eat touches */
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.alpha = nfsu2_cfg_overlay_alpha();
        self.shapesHidden = NO;
        self.tag = 0x4E463531;             /* 'NF51' */
    }
    return self;
}

/* Everything passes through to SDL except the gear and the settings panel. */
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e
{
    for (UIView *sub in self.subviews) {
        if (sub.userInteractionEnabled && sub.hidden == NO &&
            CGRectContainsPoint(sub.frame, p)) {
            CGPoint local = [self convertPoint:p toView:sub];
            return [sub hitTest:local withEvent:e];
        }
    }
    return nil;
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
    if (self.shapesHidden)
        return;                 /* controls off / pad connected: gear+FPS stay */
    for (int i = 0; i < n; i++) {
        CGRect r = CGRectMake((z[i].cx - z[i].rx) * W,
                              (z[i].cy - z[i].ry) * H,
                              z[i].rx * 2 * W,
                              z[i].ry * 2 * H);
        int pressed = xbox_ios_touch_zone_pressed(i);
        CGContextSetRGBFillColor(c, 1, 1, 1, pressed ? 0.42 : 0.16);
        CGContextSetRGBStrokeColor(c, 1, 1, 1, pressed ? 1.0 : 0.85);
        CGContextSetLineWidth(c, 1.5);
        CGPathRef p = CGPathCreateWithEllipseInRect(r, NULL);
        CGContextAddPath(c, p);
        CGContextDrawPath(c, kCGPathFillStroke);
        CGPathRelease(p);
        const char *lbl = zone_label_by_id(z[i].id);
        if (lbl) {
            NSDictionary *attrs = @{
                NSFontAttributeName:
                    [UIFont boldSystemFontOfSize:H * 0.042f],
                NSForegroundColorAttributeName:
                    [UIColor colorWithWhite:1 alpha:0.95]
            };
            NSString *str = [NSString stringWithUTF8String:lbl];
            CGSize sz = [str sizeWithAttributes:attrs];
            [str drawAtPoint:CGPointMake(z[i].cx * W - sz.width / 2,
                                         z[i].cy * H - sz.height / 2)
              withAttributes:attrs];
        }
    }

    /* The sticks: dynamic (the touch-down point is the centre), so the
     * visual floats under the thumb - base ring at the down point, knob
     * at the finger, clamped to full deflection (0.12 of the width). */
    for (int side = 0; side < 2; side++) {
        float bx, by, kx, ky;
        if (!xbox_ios_touch_stick(side, &bx, &by, &kx, &ky))
            continue;
        CGFloat R = 0.12f * W;
        CGPoint base = CGPointMake(bx * W, by * H);
        CGPoint knob = CGPointMake(kx * W, ky * H);
        CGFloat vx = knob.x - base.x, vy = knob.y - base.y;
        CGFloat d = sqrt(vx * vx + vy * vy);
        if (d > R) {
            knob.x = base.x + vx / d * R;
            knob.y = base.y + vy / d * R;
        }
        CGRect ring = CGRectMake(base.x - R, base.y - R, 2 * R, 2 * R);
        CGContextSetRGBFillColor(c, 1, 1, 1, 0.10);
        CGContextSetRGBStrokeColor(c, 1, 1, 1, 0.55);
        CGContextSetLineWidth(c, 1.5);
        CGPathRef rp = CGPathCreateWithEllipseInRect(ring, NULL);
        CGContextAddPath(c, rp);
        CGContextDrawPath(c, kCGPathFillStroke);
        CGPathRelease(rp);
        CGFloat kr = R * 0.42f;
        CGRect knobR = CGRectMake(knob.x - kr, knob.y - kr, 2 * kr, 2 * kr);
        CGContextSetRGBFillColor(c, 1, 1, 1, 0.38);
        CGContextSetRGBStrokeColor(c, 1, 1, 1, 0.95);
        CGPathRef kp = CGPathCreateWithEllipseInRect(knobR, NULL);
        CGContextAddPath(c, kp);
        CGContextDrawPath(c, kCGPathFillStroke);
        CGPathRelease(kp);
    }
}

- (void)applyVisibility:(BOOL)vis
{
    self.shapesHidden = !vis;
    [self setNeedsDisplay];
}
@end

/* ── FPS counter + gear + panel ─────────────────────────────── */

@interface Nfsu2Panel : UIView
@end
@implementation Nfsu2Panel
- (id)initWithFrame:(CGRect)f
{
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
        self.layer.cornerRadius = 10;
        self.hidden = YES;
        self.userInteractionEnabled = YES;
    }
    return self;
}
@end

static Nfsu2Overlay *s_ov;
static UILabel *s_fps;
static Nfsu2Panel *s_panel;
/* Nfsu2GearTarget's @implementation declares s_target again below; keep a
 * single definition. */

static void panel_add_switch(Nfsu2Panel *panel, NSString *title, float y,
                             BOOL on, SEL action, id target)
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, y, 130, 24)];
    l.text = title;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:13];
    [panel addSubview:l];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(150, y - 4, 51, 31)];
    sw.on = on;
    [sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    [panel addSubview:sw];
}

static void toggle_fps(void)
{
    /* Called from the switch's target: flip the setting and the label. */
    s_fps.hidden = s_fps.hidden ? NO : YES;
}

static void toggle_overlay(void)
{
    s_ov.shapesHidden = !s_ov.shapesHidden;
    [s_ov setNeedsDisplay];
}

static void build_panel(void)
{
    Nfsu2Panel *panel =
        [[Nfsu2Panel alloc] initWithFrame:CGRectMake(40, 40,
                                                     s_ov.bounds.size.width - 80, 150)];
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [s_ov addSubview:panel];
    s_panel = panel;
    panel_add_switch(panel, @"Show FPS", 12, nfsu2_cfg_show_fps() != 0,
                     @selector(nfsu2ToggleFps), s_target);
    panel_add_switch(panel, @"Touch controls", 56, !s_ov.shapesHidden,
                     @selector(nfsu2ToggleOverlay), s_target);
    UILabel *hint =
        [[UILabel alloc] initWithFrame:CGRectMake(12, 100, panel.bounds.size.width - 24, 40)];
    hint.text = @"More settings: edit nfsu2_env.txt in Files.";
    hint.textColor = [UIColor lightGrayColor];
    hint.font = [UIFont systemFontOfSize:11];
    hint.numberOfLines = 2;
    [panel addSubview:hint];
}

/* UISwitch target: NSObject categories can't reach our statics, so route
 * through a small helper object. */
@interface Nfsu2GearTarget : NSObject
- (void)fpsTick;
@end
@implementation Nfsu2GearTarget
- (void)nfsu2ToggleFps { toggle_fps(); }
- (void)nfsu2ToggleOverlay { toggle_overlay(); }
- (void)gearTapped
{
    s_panel.hidden = !s_panel.hidden;
}
- (void)stickTick
{
    /* Poll the touch state at 30 fps: redraw only when something the
     * overlay draws actually changed (a stick moved or a zone pressed).
     * Idle frames cost two lock-protected scans - nothing. */
    static int s_sig;
    int sig = 0;
    float bx, by, kx, ky;
    if (xbox_ios_touch_stick(0, &bx, &by, &kx, &ky))
        sig |= 1 | (int)((kx * 96.0f) + 96) | ((int)((ky * 96.0f) + 96) << 8);
    if (xbox_ios_touch_stick(1, &bx, &by, &kx, &ky))
        sig |= 2 | ((int)((kx * 96.0f) + 96) << 16) | ((int)((ky * 96.0f) + 96) << 24);
    int n = 0;
    const void *zp = xbox_ios_touch_zones(&n);
    (void)zp;
    for (int i = 0; i < n; i++)
        if (xbox_ios_touch_zone_pressed(i))
            sig |= 0x10000 << (i % 15);
    if (sig != s_sig) {
        s_sig = sig;
        [s_ov setNeedsDisplay];
    }
}

- (void)fpsTick
{
    if (!s_fps || s_fps.hidden)
        return;
    int x10 = nv2a_vk_fps_x10();
    s_fps.text = [NSString stringWithFormat:@"%d.%d fps", x10 / 10, x10 % 10];
}
@end

static UIEdgeInsets s_safe;

static CGFloat sa2left(void)  { return s_safe.left; }
static CGFloat sa2top(void)   { return s_safe.top;  }

static void build_fps_and_gear(void)
{
    s_fps = [[UILabel alloc] initWithFrame:CGRectMake(sa2left() + 10, sa2top() + 8, 90, 24)];
    s_fps.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    s_fps.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    s_fps.hidden = nfsu2_cfg_show_fps() ? NO : YES;
    [s_ov addSubview:s_fps];

    [NSTimer scheduledTimerWithTimeInterval:0.5
                                     target:s_target
                                   selector:@selector(fpsTick)
                                   userInfo:nil
                                    repeats:YES];

    CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:s_target
                                                    selector:@selector(stickTick)];
    dl.preferredFramesPerSecond = 30;    /* touch visuals do not need 120 */
    [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}



/* Called from main.c (iOS) after the renderer init. uiwindow is the SDL
 * UIWindow obtained via SDL_GetWindowWMInfo. */
void ios_touch_overlay_install(void *uiwindow)
{
    UIWindow *win = (__bridge UIWindow *)uiwindow;
    if (!win)
        return;
    for (UIView *sub in win.subviews)
        if ([sub isKindOfClass:[Nfsu2Overlay class]]) {
            [sub removeFromSuperview];
            break;
        }
    s_target = [[Nfsu2GearTarget alloc] init];
    Nfsu2Overlay *ov = [[Nfsu2Overlay alloc] initWithFrame:win.bounds];
    ov.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:ov];
    [win bringSubviewToFront:ov];
    s_ov = ov;

    s_safe = win.safeAreaInsets;
    UIEdgeInsets sa = s_safe;
    UIButton *gear = [UIButton buttonWithType:UIButtonTypeSystem];
    gear.frame = CGRectMake(win.bounds.size.width / 2 - 22, sa.top + 4, 44, 44);
    [gear setTitle:@"..." forState:UIControlStateNormal];
    gear.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    gear.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
    [gear addTarget:s_target action:@selector(gearTapped)
   forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:gear];

    build_panel();
    build_fps_and_gear();
    [ov setNeedsDisplay];
    fprintf(stderr, "nfsu2: overlay frame %g x %g subviews %lu\n",
            (double)ov.frame.size.width, (double)ov.frame.size.height,
            (unsigned long)ov.subviews.count);
}

/* Pad connect/disconnect + RECOMP_TOUCH=0. Callable from any thread. */
void ios_touch_overlay_set_visible(int v)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_ov)
            [s_ov applyVisibility:v ? YES : NO];
    });
}
