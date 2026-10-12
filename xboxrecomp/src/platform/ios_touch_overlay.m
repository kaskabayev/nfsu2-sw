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

@interface Nfsu2Overlay : UIView
- (void)applyVisibility:(BOOL)vis;
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
    for (int i = 0; i < n; i++) {
        CGRect r = CGRectMake((z[i].cx - z[i].rx) * W,
                              (z[i].cy - z[i].ry) * H,
                              z[i].rx * 2 * W,
                              z[i].ry * 2 * H);
        CGContextSetRGBFillColor(c, 1, 1, 1, 0.16);
        CGContextSetRGBStrokeColor(c, 1, 1, 1, 0.85);
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
}

- (void)applyVisibility:(BOOL)vis
{
    self.hidden = !vis;
    if (vis)
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
    BOOL v = s_ov.alpha > 0.05f;
    s_ov.alpha = v ? 0.0f : nfsu2_cfg_overlay_alpha();
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
    panel_add_switch(panel, @"Touch controls", 56, s_ov.alpha > 0.05f,
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
- (void)fpsTick
{
    if (!s_fps || s_fps.hidden)
        return;
    int x10 = nv2a_vk_fps_x10();
    s_fps.text = [NSString stringWithFormat:@"%d.%d fps", x10 / 10, x10 % 10];
}
@end

static Nfsu2GearTarget *s_target;

static void build_fps_and_gear(void)
{
    s_fps = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, 90, 24)];
    s_fps.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    s_fps.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    s_fps.hidden = nfsu2_cfg_show_fps() ? NO : YES;
    [s_ov addSubview:s_fps];

    [NSTimer scheduledTimerWithTimeInterval:0.5
                                     target:s_target
                                   selector:@selector(fpsTick)
                                   userInfo:nil
                                    repeats:YES];
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

    UIButton *gear = [UIButton buttonWithType:UIButtonTypeSystem];
    gear.frame = CGRectMake(win.bounds.size.width / 2 - 20, 6, 40, 30);
    [gear setTitle:@"..." forState:UIControlStateNormal];
    gear.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    gear.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
    [gear addTarget:s_target action:@selector(gearTapped)
   forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:gear];

    build_panel();
    build_fps_and_gear();
    [ov setNeedsDisplay];
    fprintf(stderr, "nfsu2: overlay frame %g x %g subviews %lu\\n",
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
