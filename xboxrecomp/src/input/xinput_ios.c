/*
 * xinput_ios.c -- the touchscreen as the Xbox gamepad (iOS only).
 *
 * A phone has no keys and no mouse; a device without a Bluetooth pad must
 * still get past "Press START". This layer turns touches into the virtual
 * controller that answers for port 0 whenever no real one is attached (see
 * xbox_InputGetState: a pad that is attached never reaches it, so a real
 * pad always outranks the screen).
 *
 * The sticks are dynamic, the way most mobile ports do it: nothing is on
 * screen for them, a touch that lands on the bare half of the screen
 * becomes that stick's centre, and the deflection is the offset from there,
 * so the thumb never has to find a fixed circle first. Everything else is
 * a fixed zone (xinput_ios.h's XBOX_IOS_TOUCH_ZONE): a touch that lands in
 * one presses it and holds it until the finger lifts, wherever the finger
 * drifts meanwhile -- re-testing every motion would drop a button the
 * moment a thumb slides half a zone over, which reads as a missed press.
 *
 * Events, not polling: SDL's UIKit backend queues SDL_FINGER* events as
 * the touches happen, and the renderers pump SDL's event queue once per
 * present (d3d8_gl.c's dev_Present, nv2a_vk.c's vk_flip). An SDL event
 * watch sees everything the pump drains, discarded or not, so no renderer
 * had to change. The watch also follows window resizes -- touch positions
 * are normalized to the window, and stick deflection needs real pixels,
 * so the height/width ratio is kept from SDL_WINDOWEVENT_SIZE_CHANGED
 * (16:9 until the first one arrives; iOS reports the window as it is
 * created, well before the title's first poll in practice).
 *
 * RECOMP_TOUCH=0 turns the layer off, e.g. to prove a Bluetooth pad works
 * with the touch code out of the way.
 *
 * Kept out of xinput_device.c the same way xinput_nx.c is kept out: this
 * file is compiled only for iOS, and everything here is meaningless
 * elsewhere. Apple clang rejects nested functions, so every callback is a
 * file-scope static.
 */
#if defined(__APPLE__) && (defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__) || \
                           defined(__IPHONE_OS_VERSION_MIN_REQUIRED__))
#define NFSU2_IOS 1
#endif

#ifdef NFSU2_IOS

#include <SDL.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xinput_xbox.h"
#include "xinput_ios.h"

/* ------------------------------------------------------------------ */
/* The on-screen pad                                                   */
/* ------------------------------------------------------------------ */

/* Coordinates normalized to the window, laid out on an 852x393 landscape
 * phone screen (radii are a circle of n pixels: rx = n/852, ry = n/393).
 * On a portrait window the same numbers still hit-test, just squashed --
 * zones are relative to the window, not the device orientation.
 *
 *   BACK                          START
 *
 *        LB                  RB
 *
 *                    Y
 *  (left half:   X       B    (right half: right stick,
 *   left stick)      A     drag = deflection)
 *     dpad
 */
static const XBOX_IOS_TOUCH_ZONE s_zones[] = {
    /* id   cx      cy      rx      ry      kind               value            */
    /* Shoulders ABOVE triggers, both near the top edge; clear of the
     * Dynamic Island (x 11-48 pt, y 133-260 pt in landscape) and of the
     * d-pad/stick areas. Numerically checked on 852x393. */
    {  1,  0.056f, 0.102f, 0.035f, 0.076f, XBOX_IOS_ZONE_FLAG,   XBOX_GAMEPAD_BACK  },
    {  2,  0.944f, 0.102f, 0.035f, 0.076f, XBOX_IOS_ZONE_FLAG,   XBOX_GAMEPAD_START },
    {  4,  0.165f, 0.130f, 0.042f, 0.091f, XBOX_IOS_ZONE_ANALOG, XBOX_BUTTON_BLACK    },  /* LB */
    {  6,  0.835f, 0.130f, 0.042f, 0.091f, XBOX_IOS_ZONE_ANALOG, XBOX_BUTTON_WHITE    },  /* RB */
    {  5,  0.165f, 0.370f, 0.048f, 0.104f, XBOX_IOS_ZONE_ANALOG, XBOX_BUTTON_LTRIGGER },  /* LT */
    {  7,  0.835f, 0.370f, 0.048f, 0.104f, XBOX_IOS_ZONE_ANALOG, XBOX_BUTTON_RTRIGGER },  /* RT */
    /* ABXY diamond, right-bottom; centres >=0.065 apart, rx 0.038. */
    {  8,  0.840f, 0.860f, 0.038f, 0.082f, XBOX_IOS_ZONE_ANALOG, XBOX_BUTTON_A      },
    {  9,  0.905f, 0.770f, 0.038f, 0.082f, XBOX_IOS_ZONE_ANALOG, XBOX_BUTTON_B      },
    { 10,  0.775f, 0.770f, 0.038f, 0.082f, XBOX_IOS_ZONE_ANALOG, XBOX_BUTTON_X      },
    { 11,  0.840f, 0.680f, 0.038f, 0.082f, XBOX_IOS_ZONE_ANALOG, XBOX_BUTTON_Y      },
    {  3,  0.080f, 0.810f, 0.058f, 0.126f, XBOX_IOS_ZONE_DPAD,   0                  },
};
#define ZONE_COUNT (sizeof s_zones / sizeof s_zones[0])

/* Table order is hit-test priority: the first zone whose ellipse contains
 * the touch wins, which settles the handful of pixels where neighbours
 * overlap. */
static int zone_at(float x, float y)
{
    unsigned i;
    for (i = 0; i < ZONE_COUNT; i++) {
        float dx = (x - s_zones[i].cx) / s_zones[i].rx;
        float dy = (y - s_zones[i].cy) / s_zones[i].ry;
        if (dx * dx + dy * dy <= 1.0f)
            return (int)i;
    }
    return -1;
}

/* ------------------------------------------------------------------ */
/* Finger bookkeeping                                                  */
/* ------------------------------------------------------------------ */

#define TOUCH_MAX_FINGERS 5   /* two sticks and all the buttons, with slack */

/* What a tracked finger drives. Zone fingers carry the zone's table index
 * offset from ROLE_ZONE(0). */
#define ROLE_NONE   0
#define ROLE_LSTICK 1
#define ROLE_RSTICK 2
#define ROLE_ZONE(i) (100 + (i))

typedef struct {
    Sint64 id;      /* SDL's finger id, -1 = slot free */
    float  x, y;    /* latest position, normalized to the window */
    float  sx, sy;  /* position when it went down: a stick's centre */
    int    role;    /* ROLE_* */
} TouchFinger;

static SDL_mutex  *s_lock;
static TouchFinger s_finger[TOUCH_MAX_FINGERS];
static float       s_aspect = 9.0f / 16.0f;   /* window height / width (landscape) */
static DWORD       s_packet;
static int         s_live;                    /* the watch is installed */
static int         s_disabled = -1;           /* RECOMP_TOUCH, then settings */

/* Settings hooks (nfsu2_env.txt / gear panel). Called from the main thread
 * between polls; races with a poll in flight settle on the next poll. */
void xbox_ios_touch_set_enabled(int on)
{
    if (on)
        s_disabled = 0;
    else if (s_disabled < 0)
    {
        const char *v = getenv("RECOMP_TOUCH");
        s_disabled = (v && strcmp(v, "0") == 0) || !on;
    }
    else
        s_disabled = !on;
}

/* A stick's maximum deflection, as a fraction of the screen width -- the
 * same in normalized x units on every device, which is why the radius is
 * not normalized to the height. */
#define TOUCH_STICK_RADIUS 0.12f

/* Below this fraction of full deflection a stick reads zero; the game
 * applies its own deadzone on top, this only keeps a resting thumb from
 * creeping. */
#define TOUCH_DEADZONE 0.10f

/* Deflection of a dynamic stick from its finger: offset from the touch-down
 * point, scaled so TOUCH_STICK_RADIUS of screen width is full travel,
 * rescaled past the deadzone so travel starts smoothly, y inverted (screen
 * y grows downward, the Xbox stick's grows upward). */
static void stick_deflection(const TouchFinger *f, float aspect,
                             float *ox, float *oy)
{
    float dx = f->x - f->sx;              /* already width-relative */
    float dy = (f->y - f->sy) * aspect;   /* y is normalized by the height */
    float r = sqrtf(dx * dx + dy * dy);
    float m, k;

    *ox = 0.0f;
    *oy = 0.0f;
    if (r < 1e-5f)
        return;
    m = r / TOUCH_STICK_RADIUS;
    if (m > 1.0f) {
        dx *= 1.0f / m;
        dy *= 1.0f / m;
        m = 1.0f;
    }
    if (m <= TOUCH_DEADZONE)
        return;
    /* Rescale deadzone→full travel onto the FULL Xbox axis range: at m=1 the
     * deflection magnitude must be 1.0 (dx has magnitude TOUCH_STICK_RADIUS
     * there), hence the extra 1/TOUCH_STICK_RADIUS. */
    k = ((m - TOUCH_DEADZONE) / (1.0f - TOUCH_DEADZONE)) / m
        / TOUCH_STICK_RADIUS;
    *ox = dx * k;
    *oy = -dy * k;
}

static SHORT to_short(float v)
{
    int n = (int)(v * 32767.0f);
    if (n >  32767) n =  32767;
    if (n < -32767) n = -32767;
    return (SHORT)n;
}

/* Everything a held finger means, folded into the caller's accumulators.
 * Called with s_lock held. */
static void fold_finger(const TouchFinger *f, float aspect, WORD *flags,
                        BYTE *analog, float *lstick, float *rstick,
                        int *have_l, int *have_r)
{
    if (f->role >= ROLE_ZONE(0)) {
        const XBOX_IOS_TOUCH_ZONE *z = &s_zones[f->role - ROLE_ZONE(0)];
        switch (z->kind) {
        case XBOX_IOS_ZONE_FLAG:
            *flags |= (WORD)z->value;
            break;
        case XBOX_IOS_ZONE_ANALOG:
            analog[z->value] = 255;
            break;
        default: {  /* dpad: the touch's quadrant inside the zone, centre
                     * neutral, diagonals when both axes clear the mark */
            float nx = (f->x - z->cx) / z->rx;
            float ny = (f->y - z->cy) / z->ry;
            if (nx * nx + ny * ny > 0.16f) {   /* 0.4^2 */
                if (ny < -0.4f) *flags |= XBOX_GAMEPAD_DPAD_UP;
                if (ny >  0.4f) *flags |= XBOX_GAMEPAD_DPAD_DOWN;
                if (nx < -0.4f) *flags |= XBOX_GAMEPAD_DPAD_LEFT;
                if (nx >  0.4f) *flags |= XBOX_GAMEPAD_DPAD_RIGHT;
            }
            break;
        }
        }
    } else if (f->role == ROLE_LSTICK && !*have_l) {
        stick_deflection(f, aspect, &lstick[0], &lstick[1]);
        *have_l = 1;
    } else if (f->role == ROLE_RSTICK && !*have_r) {
        stick_deflection(f, aspect, &rstick[0], &rstick[1]);
        *have_r = 1;
    }
}

/* ------------------------------------------------------------------ */
/* Event accumulation (the watch runs where SDL pumps events)          */
/* ------------------------------------------------------------------ */

static void touch_clear_locked(void)
{
    int i;
    for (i = 0; i < TOUCH_MAX_FINGERS; i++)
        s_finger[i].id = -1;
}

static void finger_down(SDL_TouchID touch_id, SDL_FingerID id, float x, float y)
{
    int i, zone;

    (void)touch_id;   /* iOS has the one touch screen; ids are its own */

    SDL_LockMutex(s_lock);
    for (i = 0; i < TOUCH_MAX_FINGERS; i++) {
        if (s_finger[i].id == id) {
            /* Already tracked (a device can repeat a down): just move it. */
            s_finger[i].x = x;
            s_finger[i].y = y;
            SDL_UnlockMutex(s_lock);
            return;
        }
    }
    for (i = 0; i < TOUCH_MAX_FINGERS; i++) {
        if (s_finger[i].id < 0)
            break;
    }
    if (i == TOUCH_MAX_FINGERS) {   /* more fingers than tracked: ignore */
        SDL_UnlockMutex(s_lock);
        return;
    }

    zone = zone_at(x, y);
    s_finger[i].id = id;
    s_finger[i].x = x;
    s_finger[i].y = y;
    s_finger[i].sx = x;
    s_finger[i].sy = y;
    if (zone >= 0) {
        s_finger[i].role = ROLE_ZONE(zone);
    } else {
        /* A second finger on a side whose stick is already held waits its
         * turn (ROLE_NONE). finger_up promotes it re-centred, so a finger
         * that was merely resting never jolts the stick at the moment the
         * steering thumb lifts. */
        int want_l = (x < 0.5f);
        int taken = 0, j;
        for (j = 0; j < TOUCH_MAX_FINGERS; j++)
            if (s_finger[j].id >= 0 && j != i
                    && s_finger[j].role == (want_l ? ROLE_LSTICK : ROLE_RSTICK))
                taken = 1;
        s_finger[i].role = taken ? ROLE_NONE
                         : (want_l ? ROLE_LSTICK : ROLE_RSTICK);
    }
    SDL_UnlockMutex(s_lock);
}

static void finger_move(SDL_FingerID id, float x, float y)
{
    int i;

    SDL_LockMutex(s_lock);
    for (i = 0; i < TOUCH_MAX_FINGERS; i++) {
        if (s_finger[i].id == id) {
            s_finger[i].x = x;
            s_finger[i].y = y;
            break;
        }
    }
    SDL_UnlockMutex(s_lock);
}

/* A stick's finger lifting hands the stick to a finger that has been
 * waiting on the same half (re-centred where it rests), so steering does
 * not go dead while a thumb is still on the glass. */
static void finger_up(SDL_FingerID id)
{
    int i, role = ROLE_NONE;

    SDL_LockMutex(s_lock);
    for (i = 0; i < TOUCH_MAX_FINGERS; i++) {
        if (s_finger[i].id == id) {
            role = s_finger[i].role;
            s_finger[i].id = -1;
            s_finger[i].role = ROLE_NONE;
            break;
        }
    }
    if (role == ROLE_LSTICK || role == ROLE_RSTICK) {
        int left = (role == ROLE_LSTICK);
        for (i = 0; i < TOUCH_MAX_FINGERS; i++) {
            TouchFinger *f = &s_finger[i];
            int on_left = (f->x < 0.5f);
            if (f->id >= 0 && f->role == ROLE_NONE && on_left == left) {
                f->role = role;
                f->sx = f->x;   /* the stick recentres under the thumb */
                f->sy = f->y;
                break;
            }
        }
    }
    SDL_UnlockMutex(s_lock);
}

static int SDLCALL touch_watch(void *arg, SDL_Event *ev)
{
    (void)arg;
    switch (ev->type) {
    case SDL_FINGERDOWN:
        finger_down(ev->tfinger.touchId, ev->tfinger.fingerId,
                    ev->tfinger.x, ev->tfinger.y);
        break;
    case SDL_FINGERMOTION:
        finger_move(ev->tfinger.fingerId, ev->tfinger.x, ev->tfinger.y);
        break;
    case SDL_FINGERUP:
        finger_up(ev->tfinger.fingerId);
        break;
    case SDL_WINDOWEVENT:
        if (ev->window.event == SDL_WINDOWEVENT_SIZE_CHANGED ||
            ev->window.event == SDL_WINDOWEVENT_RESIZED) {
            int w = ev->window.data1, h = ev->window.data2;
            if (w > 0 && h > 0) {
                SDL_LockMutex(s_lock);
                s_aspect = (float)h / (float)w;
                SDL_UnlockMutex(s_lock);
            }
        } else if (ev->window.event == SDL_WINDOWEVENT_FOCUS_LOST) {
            /* The surface can go away without a background transition
             * (a call, the app switcher); a latched button must not
             * survive it. */
            SDL_LockMutex(s_lock);
            touch_clear_locked();
            SDL_UnlockMutex(s_lock);
        }
        break;
    case SDL_APP_WILLENTERBACKGROUND:
        /* Same on suspend: iOS would hold the touches while the app is
         * frozen, and the game would drive itself after resume. */
        SDL_LockMutex(s_lock);
        touch_clear_locked();
        SDL_UnlockMutex(s_lock);
        break;
    default:
        break;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Public entry points                                                 */
/* ------------------------------------------------------------------ */

int xbox_ios_touch_init(void)
{
    static SDL_SpinLock s_spin;   /* first caller from any thread wins */
    int live;

    if (s_disabled < 0) {
        const char *v = getenv("RECOMP_TOUCH");
        s_disabled = (v && strcmp(v, "0") == 0);
    }
    if (s_disabled)
        return 0;

    SDL_AtomicLock(&s_spin);
    live = s_live;
    if (!live) {
        int i;
        for (i = 0; i < TOUCH_MAX_FINGERS; i++)
            s_finger[i].id = -1;
        /* The event system is core; the watch simply sees nothing until
         * the UIKit video backend exists and starts delivering touches.
         * SDL_AddEventWatch cannot fail, so the mutex is what can. */
        s_lock = SDL_CreateMutex();
        if (s_lock) {
            SDL_AddEventWatch(touch_watch, NULL);
            s_live = live = 1;
            fprintf(stderr, "[INPUT] iOS touch gamepad active "
                            "(RECOMP_TOUCH=0 disables)\n");
        }
    }
    SDL_AtomicUnlock(&s_spin);
    return live;
}

int xbox_ios_touch_state(XBOX_INPUT_STATE *pState)
{
    WORD  flags = 0;
    BYTE  analog[8] = { 0 };
    float lstick[2] = { 0.0f, 0.0f };
    float rstick[2] = { 0.0f, 0.0f };
    float aspect;
    DWORD packet;
    int   have_l = 0, have_r = 0, i;

    if (!pState || !s_lock)
        return 0;

    SDL_LockMutex(s_lock);
    aspect = s_aspect;
    for (i = 0; i < TOUCH_MAX_FINGERS; i++) {
        if (s_finger[i].id >= 0)
            fold_finger(&s_finger[i], aspect, &flags, analog,
                        lstick, rstick, &have_l, &have_r);
    }
    /* The input layer looks for button edges on the packet number, so it
     * has to move on every read, the way the other backends' counters do. */
    packet = ++s_packet;
    SDL_UnlockMutex(s_lock);

    /* The struct is the caller's: zero what this layer does not answer
     * for rather than assume it arrived zeroed. */
    memset(pState, 0, sizeof(*pState));
    pState->dwPacketNumber = packet;
    pState->Gamepad.wButtons = flags;
    memcpy(pState->Gamepad.bAnalogButtons, analog, sizeof analog);
    pState->Gamepad.sThumbLX = to_short(lstick[0]);
    pState->Gamepad.sThumbLY = to_short(lstick[1]);
    pState->Gamepad.sThumbRX = to_short(rstick[0]);
    pState->Gamepad.sThumbRY = to_short(rstick[1]);
    return 1;
}

const XBOX_IOS_TOUCH_ZONE *xbox_ios_touch_zones(int *count)
{
    if (count)
        *count = (int)ZONE_COUNT;
    return s_zones;
}

#endif /* NFSU2_IOS */
