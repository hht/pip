# Pip: Looks and Motion

Pip is Notchkeeper's original mascot, expressing current status via facial expressions in the left notch ear, expanded panel, and cards. This document records the meaning of each look, precedence rules, motion guidelines, and rationales. **Values are governed by code**: look data in `Sources/MascotCore/Look.swift`, decoration shapes in `Shapes.swift`, eye paths in `Eyes.swift`, choreographies in `Choreography.swift`, idle dispatching in `IdleDirector.swift`, clock (sleepiness, recentering, dizziness) in `MascotClock.swift`, mouse tracking in `Gaze.swift`. These values were individually confirmed by the user; consult the user before modifying.

## 1. Geometry

### Canvas

Coordinates use "canvas units", origin at top-left, +y downward. For a 40pt Pip, 1 unit = 2pt. The left-ear instance is scaled down from the 32pt panel Pip by 20/32 without separate artwork (§5 "Collapse and Expand").

- Body is a perfect circle with vertical gradient, no stroke, highlight, or drop shadow.
- Ink color `#16171A` draws eyes and decoration symbols.
- Decoration area sits at top-right, does not rotate with head, does not clip circular body; third Z may overflow canvas.

### Spherical Model (2D Simulating 3D)

The body is a sphere with eyes affixed to the spherical surface. All motions, including mouse tracking, are expressed via **head orientation**: yaw (positive = turns right), pitch (positive = tilts up), roll (positive = clockwise).

- Eye positions calculate spherical latitude and longitude based on resting centers; each eye offsets ~20° from center, so frontal width is slightly narrower than flat projection, which is the expected 3D result. Eyes rotated to the back are culled.
- **Body circle and gradient do not rotate**: light comes from above, head turns move only eyes; keeping circle out of rotation transforms stabilizes edge antialiasing.

Layer tree (Core Animation, outside-in):

```
stage ─┬─ body (breathing, anchor at body bottom)
       │   └─ disc (circular mask, non-rotating)
       │       ├─ gradient
       │       └─ pose ⊃ yaw ⊃ pitch ⊃ roll ⊃ left eye, right eye
       └─ decorations
```

`pose` stores resting look orientation; yaw / pitch handle mouse tracking; motion layers additively onto yaw / pitch / roll. Verified in flipped view: `rotation.y` positive = faces right, `rotation.x` positive = tilts up, `rotation.z` positive = rotates clockwise.

### Placement in Notch

The center of left-ear Pip body and right-ear indicator sit exactly in the visible center of their respective ears, symmetrically flanking the camera (HIG Live Activities compact: horizontal balance). When right ear is empty its width remains unchanged: working dots pulsing on and off with varying width is distracting. Positions are dynamically calculated from notch dimensions.

## 2. 16 Looks

Each look consists of body gradient, eye paths (§3), resting head orientation, decorations (§4), and right-ear indicator. Decorations are split into two categories:

- **Mood decoration**: part of the character (Z, thinking cloud, stars…), remaining on left-ear Pip when collapsed.
- **Sign**: indicates an event (×, ▲!, hourglass, !!, lock, offline), moving to right ear as an icon when collapsed, leaving left ear with face only. Expanded panel Pip also omits signs, as egress status is conveyed by top-right badge (`docs/ui.md` "Panel Layout"); cards and Settings Pip retain them.

| Look | When | Orientation | Decoration | Right Ear (Collapsed) |
|---|---|---|---|---|
| idle | Default | Frontal | None | None |
| sleeping | Mouse away from notch for 120s | Head drooping | mood: Z | None |
| thinking | Unwired (sessions file lacks signal) | Tilts diagonally up | mood: thinking cloud | 3 blue dots |
| working | Agent working | Head down working | None | 3 blue dots |
| longTurn | Agent working for 10 min (`docs/agent-integration.md`) | Head down working | mood: sweat drop | 3 blue dots |
| question | Agent needs intervention, non-permission (`docs/agent-integration.md`) | Cocking head waiting | mood: bubble with ? | Cyan dot |
| approval | Agent needs intervention, permission | Looking up at you | mood: raised hand | Lime dot |
| finished | Agent turn ended; egress recovered. Drops after 5.2s per priority | Looking up proudly | mood: stars | None |
| error | On error cards; unrendered when collapsed | Flinches | sign: × | Sign icon |
| interrupted | Unwired | Frontal | None | None |
| dizzy | Clicking Pip in panel, lasts 1.6s | Frontal | None | None |
| offline | Guard unknown, reason offline | Frontal | sign: Wi-Fi with slash | Sign icon |
| mismatch | Egress IP not in allowed list | Frontal | sign: ▲! | Sign icon |
| stale | Unwired (no "stale" after guard merged into App) | Listless | sign: hourglass | Sign icon |
| danger | Egress violated | Frontal | sign: !! | Sign icon |
| shielded | Egress violated, but blocked by firewall (`docs/egress-guard.md`; Step 5) | Composed | sign: lock | Sign icon |

"Unwired" looks remain implemented and switchable in Status Test page, ready to connect when event sources appear (user decision).

### Right Ear Indicator

The right ear occupies a single slot conveying the same state as the left ear, without splitting into separate network/agent channels.

- **Sign icon**: sign decorations migrate to right ear, matching 40pt Pip size and panel looping rhythms.
- **Dots**: 3 blue dots illuminate sequentially; cyan and lime dots stay solid.
- **Gray hollow ring**: probe returned no result (probeFailed). This unknown does not change mascot look, relying on right ear to prevent being misread as normal. Precedence: sign icon > gray ring > dots (user decision).

### Precedence

When multiple states hold simultaneously, render the highest; multiple sessions pick the highest session (user decision).

1. Guard: danger / shielded (mutually exclusive) > mismatch > offline
2. Dizzy
3. Agent: approval > question > longTurn > working > finished
4. Sleeping
5. Idle

thinking, error, interrupted do not enter precedence evaluation.

## 3. Eye Paths

Each look defines its eye paths (round, O, smiling, > <, spiral…); right eye mirrors left eye, with a few "aligned" looks looking in the same direction.

**Eye morphing**: Core Animation interpolates paths only when point counts and structures match identically, so all eye paths normalize to the same 120-point closed polygon (modeled after [Flubber](https://github.com/veltman/flubber)): flatten, stroke to outline, resample equidistantly by arc length, unify winding order, and rotate starting vertex to minimize sum of squared point distances (prevents spinning during interpolation). Blinking is also path morphing: squash and return.

## 4. Decorations

| Look | Category | Visual | Anchor (Scale/Rotation Center) |
|---|---|---|---|
| sleeping | mood | Three Zs | Respective centers |
| thinking | mood | Cloud and three dots | Decoration area center |
| question | mood | Bubble with ? | Bubble center |
| finished | mood | Large and small star | Respective centers |
| longTurn | mood | Sweat drop | Decoration area center |
| approval | mood | Raised hand | Wrist |
| error | sign | Orange × | Center |
| offline | sign | Wi-Fi with slash | Center |
| mismatch | sign | Amber triangle ! | Center |
| stale | sign | Hourglass | Center |
| danger | sign | Two red !s, two parts | Respective centers |
| shielded | sign | Lock (shackle, body, keyhole) | Center |

idle, working, interrupted, dizzy have no decorations.

## 5. Motion

**Principles**: restrained amplitude, lively pacing. Move only 1-2 parts at a time; slightly slower entrance, faster exit; use springs and sinusoidal easing (star spin is linear).

**Rendering**: Core Animation; each motion commits once at start, intermediate frames synthesized by system compositor. Frame rate follows display refresh rate via system (user decided visual smoothness first; 120Hz continuous loop compositing cost attributed to WindowServer). Remove all animations and stop clocks when invisible (occluded, screen off, screen locked).

- **Disc rasterization matches screen scale**: without this, head turns cause eye edges to soften; with gaze tracking in panel, users perceive "blur on expand" (mechanism inferred as resampling during 3D subtree flattening). 2x rasterization causes aliasing on left ear downscale, so 1x is used. Redraw on disc movement has unmeasured cost (`HANDOFF.md`).

**Easing**: sinusoidal is symmetric ease-in-out; springs parameterized by perceptual duration `response` and damping ratio `ζ`, mapped to `CASpringAnimation` (`Choreography.swift`).

### Changing Looks

Eye paths, body gradient, head orientation, and decorations interpolate together, taking starting values from presentation layer to support interruptions mid-transition. Old decorations shrink and fade out, new decorations pop in shortly after (modeled after SF Symbols Replace, [WWDC23 10258](https://developer.apple.com/videos/play/wwdc2023/10258/)); new loops start with slight delay, old loops ease back to resting pose. Entrance motions: danger shakes horizontally, finished plays "jump completion", working plays "nodding".

### Persistent Rhythms

Loops play in-phase from the moment look changes, starting seamlessly.

**Body and Head**: all looks breathe (sleeping slower and deeper); open-eyed looks (idle, thinking, working, longTurn, question, approval, offline, mismatch, stale, shielded) blink randomly with occasional double blinks. Head loops express current activity: sleeping nods off, thinking ponders left and right, working mimics scanning lines of text (slow sweep, quick carriage return), longTurn does so more urgently, dizzy swings like a pendulum, offline searches for signal.

**Decorations**: Zs float up sequentially, cloud bobs with dots sequencing, bubble floats with ? wobbling, stars slowly spin and twinkle, sweat drop slides down, hand waves twice, × wobbles, Wi-Fi illuminates inside-out, ▲! flashes repeatedly, hourglass pauses and flips, two !s alternate jumping like alarms, lock clicks.

### Idle Motions

Superimposed on look orientation and gaze tracking: turn left/right, flip up/down, look around, nod, tilt head, shake head, gaze up, gaze down, turn sideways 90°, curious tilt, jump completion.

**Idle small motions**: trigger only in idle when mouse has stopped for > 4s (gaze recentered), firing every 8–20s without immediate repeats; turn and flip each 5%, others equiprobable.

### Gaze Tracking

- Pip turns head based on mouse offset relative to body center, linear across both axes, reaching maximum angles (yaw 25°, pitch 20°) at 400pt; stays at maximum angle beyond that without snapping back.
- Mouse motionless for 4s slowly recenters gaze.
- Only open-eyed looks track mouse; toggleable in Settings (`mascotFollowsMouse` in `config.json`, defaults to on).
- Peeking when mouse hovers over notch: body and eyes slightly enlarge, subject to same conditions.

### Collapse and Expand

- Black shape collapses to notch plus two ears, expanding into panel or card; both states use the same path structure to enable interpolation. Springs configured in `Common.swift` `NotchSpring` (user-tuned feel).
- **Pip is the same character**: scaled left-ear panel Pip travels and expands to panel position via shape spring, reversing on collapse. Layers are not rebuilt during morphing to preserve loop phase and prevent replaying entrance; left ear mood decorations are also scaled down from large artwork.
- Right ear and panel top-right egress badge are two forms of the same anchor: expanding fades out right ear and scales/fades in badge, moving to panel top-right; collapsing reverses.
- In card mode Pip springs to card left side, assuming card look, restoring signs while right-hand group fades out (`docs/ui.md` "Cards"). Transparent group pauses animations (`MascotLayerView.playing`), as window occlusion does not reflect SwiftUI opacity.

### Reduce Motion

Retains opacity changes only: no translation, scaling, or rotation; look orientation applies directly; motions and gaze tracking disabled; colors and eye shapes crossfade; blinks and opacity pulsing preserved (3 blue dots, thinking dots, offline signal). Shape morphs as usual; Pip and right ear / badge crossfade in place when switching states.

### Performance Acceptance

Notch display 120Hz, collapsed idle for 60s, App CPU average < 0.5%; continuous mouse movement for 60s < 3%. Measured with `top -l 70 -s 1 -pid <pid>`, results recorded in commit messages.
