/**
 * Xbox Input Compatibility Layer - iOS Touchscreen Gamepad
 *
 * Declares the touch virtual-pad layer that backs xbox_InputGetState on
 * iOS when no real (GameController) pad is attached. iOS has no keyboard
 * and no mouse, so without this layer a device with no Bluetooth pad
 * connected cannot even pass a press-start screen.
 *
 * The layer is event-driven: SDL's UIKit backend delivers SDL_FINGERDOWN /
 * FINGERMOTION / FINGERUP events whenever the runtime pumps events (the
 * renderers do that once per present), and an SDL event watch accumulates
 * them into a virtual controller. Reading is lock-protected because the
 * pump runs on the render thread while the game polls input from its own.
 *
 * Layout constants and the hit-test table live in xinput_ios.c; the zones
 * are exposed here so an on-screen overlay can draw them later.
 */

#ifndef NFSU2_XINPUT_IOS_H
#define NFSU2_XINPUT_IOS_H

#include "xinput_xbox.h"

/* What a zone drives. ZONE_FLAG sets a wButtons bit (ZONE's `value` is the
 * XBOX_GAMEPAD_* flag), ZONE_ANALOG presses an analog button (`value` is an
 * XBOX_BUTTON_* index, pressed = 255), ZONE_DPAD maps the touch's offset
 * from the zone centre to D-pad flags (diagonals included). */
#define XBOX_IOS_ZONE_FLAG   0
#define XBOX_IOS_ZONE_ANALOG 1
#define XBOX_IOS_ZONE_DPAD   2

/* One touchable zone of the on-screen pad, in coordinates normalized to
 * the window (0..1, origin top left). The radii describe an ellipse in
 * normalized space, which is round on screen only when rx / ry matches the
 * window aspect -- the table in xinput_ios.c is laid out for a landscape
 * phone. */
typedef struct XBOX_IOS_TOUCH_ZONE {
    int   id;      /* stable id, for a future overlay to key on */
    float cx, cy;  /* centre */
    float rx, ry;  /* radii */
    int   kind;    /* XBOX_IOS_ZONE_* */
    int   value;   /* wButtons flag or XBOX_BUTTON_* index (dpad: unused) */
} XBOX_IOS_TOUCH_ZONE;

/* Install the event hooks. Idempotent and safe to call from any thread;
 * returns 1 when the touch layer is live, 0 when disabled (RECOMP_TOUCH=0)
 * or its mutex could not be created -- callers simply retry on their next
 * poll. */
int xbox_ios_touch_init(void);

/* Build the state the touches currently imply. Fills *pState with zeros
 * where nothing is touched (a connected pad that presses nothing), bumps
 * the packet number, and returns 1. Returns 0 only when the layer is not
 * initialized; the caller then reports no device. */
int xbox_ios_touch_state(XBOX_INPUT_STATE *pState);

/* The hit-test zones, for a future on-screen overlay. Never NULL; *count
 * receives the number of zones. */
const XBOX_IOS_TOUCH_ZONE *xbox_ios_touch_zones(int *count);

#endif /* NFSU2_XINPUT_IOS_H */
