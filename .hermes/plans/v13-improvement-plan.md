# NFSU2 iOS — v13 improvement plan (draft for Opus validation)

## User feedback (v12, device-verified)
1. Image is dark for some reason.
2. Buttons overlap again; LT/RT and LB/RB are grouped on one side each — should be **LT/LB on left, RT/RB on right** in proper order (shoulder above trigger, per side).
3. Left-edge zones sit on top of the left-stick area → stick unusable.
4. Overlay must **auto-hide when a GameController connects**, reappear on disconnect.
5. Add an **FPS counter**.
6. Reach **60 fps** (performance work).
7. Add a **settings overlay** (configure stuff at runtime).
8. Free rein on other useful improvements.

## Findings

### F1 — Dark image (root cause identified)
`vk_flip` letterboxes the guest 640×480 into the window with `vkCmdClearColorImage` + a blit. With **ALLOW_HIGHDPI** the swapchain is now ~2556×1179 and every frame starts from a black clear; the movie/game surface is blitted **unfiltered (VK_FILTER_NEAREST default)** — but darkness is not sharpness. The real suspect: **sRGB**. Metal layer draws linear values as-is; the guest outputs gamma-space (2.2) colors, and MoltenVK swapchain images are **UNORM, not sRGB**, so no conversion should darken… unless the blit reads the source as linear and the compositor applies none — actual darkening vector: the **present-scale blit drops from 1280×720 to native with NEAREST while the old path scaled 852×393**, no. Definitive root cause to verify in code: `create_swapchain` picks `VK_FORMAT_B8G8R8A8_UNORM`; the guest render targets are 8-bit gamma; **iOS composites the CAMetalLayer as sRGB when `drawableSize` colorspace is extended** — MoltenVK 1.4.2 defaults `MVKLayer` colorPrimaries to sRGB but writes raw values → double-darkened midtones. Fix candidates (ordered):
- (a) set `srgb = YES` / `CAMetalLayer.colorspace = CGColorSpaceCreateSRGB` via MoltenVK env `MVK_CONFIG_SWAPCHAIN_CONTENT_SOURCE` equivalent — actually simplest reliable: **use `VK_FORMAT_B8G8R8A8_SRGB` swapchain** if MoltenVK supports SRGB pixel formats for swapchains (it does for Metal CAMetalLayer) — verify against MoltenVK MVKPixelFormats before choosing;
- (b) if SRGB swapchain unsupported: apply gamma 1/2.2 in the blit via a tiny shader — costly;
- (c) cheapest probe first: log `vkGetPhysicalDeviceSurfaceFormatsKHR` results at init; if only UNORM is listed, (a) is out.

**Opus action:** read `create_swapchain` + MoltenVK format table, confirm which fix applies.

### F2 — Zone layout (straightforward)
Current table put LB/LT at x≈0.130 — on top of the left-stick half (stick = bare left half). New layout, landscape 852×393 normalized:
- LT (trigger, gas/brake priority) **above** LB? Gaming convention on touch: triggers at TOP corners, shoulders below. Final:
  - left edge: LT cy=0.28, LB cy=0.52, both cx=0.055, rx=0.045, ry=0.10
  - right edge: RT cy=0.28, RB cy=0.52, both cx=0.945
  - ABXY diamond unchanged (right-bottom), d-pad bottom-left, sticks = bare halves
  - **left-half stick must ignore touches inside the LB/LT ellipses** — zone hit-test already prioritizes table order; put trigger/shoulder zones BEFORE the stick fallback in hit priority (they already are; the bug was geometric overlap, now fixed by moving up the edge)
- START/BACK stay top corners.

### F3 — Auto-hide overlay on GameController (straightforward)
`xinput_device.c` already reconciles pads by instance ID and knows attachment. Add `xbox_ios_touch_set_visible(int)` (atomic flag read by overlay's `drawRect` → skip drawing) called from the pad reconcile path: connected → hide, disconnected → show. SDL_EVENT_GAMEPAD/CONTROLLER events arrive on main; overlay redraw: `setNeedsDisplay` on change.

### F4 — FPS counter (straightforward)
Ring buffer of last 120 frame times in `vk_flip` (rdtsc or CLOCK_MONOTONIC), `nfsu2_fps()` accessor. Draw via a second tiny CATextLayer in the overlay (main thread, updated 2×/s by the watchdog) — zero GPU cost.

### F5 — 60 fps performance
Current: per-layout pipelines (MoltenVK has no dynamic vertex input) → **pipeline churn**; every frame: `vkCmdClearColorImage` + blit + present; shader cache unused on iOS (`cache_dir()` returns ""); `prewarm` skipped in fallback mode. Biggest wins, ordered:
1. **Pipeline cache on disk**: re-enable prewarm in fallback mode but key records by (pipe key WITHOUT layout hash + layout hash) — records already carry the full key; the earlier blocker was key-size change corruption, solved by the new PIPE_REC_MAGIC… verify size math then enable read+write. Removes first-run stutter, not steady-state.
2. **Frame graph**: one render pass, clear+blit is already minimal; the win is **removing the per-frame `vkDeviceWaitIdle` on SIZE_CHANGED only when size actually changed** (compare extent first — likely already fine).
3. **Resolution scale setting**: render guest at 640×480 → upscale. Offer 0.5×/0.75×/1× native scale of the SWAPCHAIN (blit target), so users trade sharpness for fps. MoltenVK on A17 Pro should already hit 60 at native; measure first with the FPS counter, optimize after.
4. **Threaded presentation already in place**; check `s_ios_bg` park loop spins at 20 ms — fine.
5. Verify vsync: MoltenVK defaults to `CAMetalLayer.maximumDrawableCount=3`; if fps caps at 40 (half of 120 ProMotion), set `SDL_HINT_FRAMEBUFFER_ACCELERATION`/`MVK_CONFIG_SYNC_QUEUE_SUBMIT`… simplest: set `CAMetalLayer.maximumDrawableCount = 2` via MoltenVK private API `MVKSetLayerDrawableSize`? — needs Opus to confirm the supported knob; **do not guess private API**.
6. **Metal misalignment logging** (NV2A_IOS not defined in nv2a_vk.c TU!) — define NFSU2_IOS for nv2a_vk.c compile so the MISALIGNED warn and any iOS blocks activate.

### F6 — Settings overlay
Native UIKit table presented modally on a **3-finger tap** (game keeps 1–2 finger gestures):
- Show FPS on/off
- Overlay opacity slider (0.2–0.8)
- Render scale (50% / 75% / 100%)
- Touch stick sensitivity slider
- Disable touch layer entirely
Persist to `Documents/nfsu2_settings.ini` (tiny INI parser, already have file IO). Settings read at flip-time via the existing accessors — no renderer restart needed except render-scale (mark swapchain dirty).

## Implementation order (2 builds max)
Build A (v13): F1 probe (log surface formats; apply sRGB fix if listed), F2 zones, F3 auto-hide, F4 FPS, F6 settings (opacity, FPS toggle, touch disable). 
Build B (v14): F5 perf (pipeline cache re-enable, render scale, drawable-count), guided by FPS counter numbers from v13 logs + user.

## Validation before CI
- Local syntax checks both arms (iPhone sim decls + Linux full TU).
- `strings` gate on artifact.
- **Opus round: plan review + line-level check of new files BEFORE the build** (user-mandated).
