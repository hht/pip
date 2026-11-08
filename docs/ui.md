# UI: Light and Dark, Localization, Panel Layout, Cards

Read "Principles" before modifying UI; inspect subsequent sections as needed for details. Mascot looks and motions are in `docs/mascot.md`; guard rendering is in `docs/egress-guard.md`.

## Principles

- **Motion**: restrained amplitude with brisk pacing: spring and sinusoidal easing, slightly slower entrance and faster exit; "Reduce Motion" uses fade in/out only; continuous loops belong to Core Animation, never redrawn frame-by-frame on main thread.
- **Unobtrusive by default**: collapses into notch when idle, expands on hover or click; red card stays until recovery, temporary cards return to it after playback.
- **Status = Color + Icon + Text**: green healthy, amber egressMismatch, gray unknown, red violated.
- Elements attached to notch are strictly white text on black background; only Settings window follows light/dark mode; only visible shapes receive clicks, transparent areas pass through.
- Text source language is English, clear in a single sentence; buttons state the action itself ("Recheck"); managed via String Catalog with Simplified Chinese translation.
- Follow "Dynamic Island Specs" section; attach screenshots per "Screenshots" section when modifying UI.

## Light and Dark Modes

**Elements attached to the notch are always white text on black background** (ears, panel, all cards; external displays also draw black blocks); only Settings window follows system appearance (user decision).

- Rationale per "Dynamic Island Specs" 1: background is permanently black, never varying in color, pattern, or lighting; motion is applied only to contents (Pip, text, meteor). The black shape itself morphs using springs as usual.
- Notch window must set `appearance = .darkAqua`: hardcoded black background alone is insufficient; system controls, `.secondary`, SF Symbols hierarchical colors, and tooltips follow window appearance. Settings window sets neither appearance nor `NSApp.appearance`.
- Pip in Settings is placed on a black-background "stage": Pip color palette is designed for black backgrounds and is nearly invisible on white; this avoids bifurcating look data across appearances.
- Status dots in Settings must have contrast ratio ≥ 3:1 against both light and dark backgrounds (WCAG 1.4.11).

## Localization

- English (source language) and Simplified Chinese, **following system language**; App does not switch internally; Settings page offers "Change Language in System Settings…" jumping to per-app language settings in macOS (WWDC19 403: "do not attempt to set the application language manually in code").
- String Catalogs are located in `Resources/`: `Localizable.xcstrings` (keys are English source strings using default `Bundle.main`) and `InfoPlist.xcstrings` (permission descriptions). Run `scripts/strings.sh` after modifying UI text: extracts strings via compiler like Xcode, adding new keys and marking deleted ones stale, then supply translations.
- Pitfall: storing as `String` before `Text(someString)` fails to localize; retrieve translation via `String(localized:)` before storage (<https://developer.apple.com/documentation/swiftui/text/init(_:tablename:bundle:comment:)>).
- Pitfall: `swift build` does not compile `.xcstrings`, copying them verbatim; compiled into `.lproj` by `scripts/run.sh` using `xcrun xcstringstool compile` (user agreed to depend on Xcode tools).
- Pitfall: Info.plist declares `CFBundleDevelopmentRegion = en` and `CFBundleLocalizations = [zh-Hans, en]`, omitting `CFBundleAllowMixedLocalizations` (tested: under Japanese locale judges en but displays Chinese).
- Do not translate: egress IP, project names; repository content is in English, chat with me in Chinese.
- Testing: `swift test` parses catalog, requiring every key to have translation and no stale keys (referenced bitchat's `LocalizationCoverageTests`).

## Panel Layout

Dimensions in `NotchLayout` and `PanelShape` in `NotchCore`; rendering in `NotchRoot.corners` and `NotchDashboard` in `Notch.swift`, governed by code.

- **Layout** (HIG: relative positions of elements preserved between expanded and collapsed states): top-left Pip (enlarged version of left ear), top-right egress status badge (position of right ear), directly under notch is egress title and IP, middle contains plugin sections, bottom bar contains only gear icon on the right (user 10-31: bottom bar is global, hosts no plugin-specific items; no plugin is indispensable). Panel and cards share same width, morphing only height when switching.
- **Sectioned by plugin** (user 10-31): egress guard section is the top status area and badge, fixed at top, not rendered if guard is disabled. Claude Code and external plugins each have a section (rounded container), rows use common template `PanelRow`: icon, title, optional subtitle, status indicator, right-hand "relative time" or short value, click destination. User configures enabled state, ordering, and max rows in Settings › Plugins; all sections together display at most 6 rows, earlier sections take priority, excess rows scroll within section. Empty sections do not render; if all sections empty, a single-line placeholder renders; if no plugins enabled, shows "No enabled plugins" and "Open Plugin Settings".
- **External plugin activities** (modeled after ActivityKit): start / update / end, latest timestamp wins, up to 8 hours duration, occupying one row in plugin section; pops card on `alert`, subsequent updates refresh that card in place without re-popping or sound.
- **Collapsed lead selection** (modeled after Dynamic Island relevanceScore): each enabled plugin reports an urgency (calm / active / attention / critical; critical reserved for guard; external plugins take maximum urgency among active activities). When collapsed, Pip and right ear show the most urgent; if equally urgent, guard takes precedence, others follow section order; when all calm, shows resident plugin (defaults to guard, optionally none), if none shows idle Pip with empty right ear. Settings › Pip can turn off Pip when collapsed: with empty right ear, renders as a pure black notch (modeled after boring.notch idle face).
- **Alignment lines**: Pip body center aligns with session icon center; badge, gear icon, and time column align to right edge.
- Pip and badge are 32pt (user decided: 40pt is overly large).
- **Session rows** (Claude Code section): no background pill (user decision); agent vendor logo + `cwd` full path (`~` abbreviation, head-truncated if too long) + status indicator + time (user decision).
  - Never display session name: it might be inferred from conversation.
  - Status indicated by visual cues without text: working uses 3 blue dots, waiting for answer / approval uses corresponding Pip look decorations; stopped is unrendered, dimming logo and path, keeping time undimmed (preserves contrast). Never use green (green reserved for normal egress).
  - Time uniformly formatted as "relative time since status change", using system relative time format.
  - Ordered by process launch time, invariant to status changes; clicking row jumps to Ghostty (`docs/agent-integration.md` "Jump to Ghostty").
- Small text (≤ 17pt) against black background must maintain at least 4.5:1 contrast (HIG Accessibility).

## Cards

Only one card displays under the notch at a time, governed by `CardQueue` in `NotchCore` regarding selection, duration, and sound. Two tiers:

- **Red card**: bottom layer during active violation (presence decided by `ViolationAlert`, `docs/egress-guard.md`). When "Keep red card resident" is disabled, red card collapses after one "card duration", counting as dismissed for this instance.
- **Temporary cards**: done card (Glass), error card (Funk), needs-you card (Ping), recovery card (Glass). Count down per "card duration", recovery card fixed at 4 seconds; auto-collapses on expiration, returning to red card if still active.

Rules:

1. **Single queue**: all temporary cards queue FIFO, displaying one at a time. Two sessions finishing simultaneously will not preempt each other.
2. **Latest only per session**: queued old cards are replaced in place by subsequent cards from the same session; only one recovery card queues at any time; same applies to external plugins sharing the same `group`. **Needs-you cards expire**: they represent "waiting for you right now"; once session no longer needs intervention, queued or playing cards are immediately dismissed; done and recovery cards represent completed events and are not dismissed.
3. **Sound follows card**: plays sound at the exact moment card appears; interrupted cards do not re-play sound on resume. What is heard matches what is seen.
4. **Violation start preempts to head**: playing temporary card returns to head of queue, red card plays for one full "card duration" before queue resumes.
5. **Layering over red card thereafter**: after red card finishes its first playback, new temporary cards from built-in plugins layer on top, returning to red card upon completion; external plugin cards wait in queue and play after red card dismisses (recovery card queues ahead of them). Each external plugin queues at most 3 cards, dropping oldest on overflow (user 10-31). Disabling a plugin dismisses its queued and active cards.
6. **Needs-you cards also auto-collapse** (user decision): subsequent waiting state conveyed via collapsed Pip look and right-ear indicator.
7. **Pip**: Pip on card is the left-ear instance, springing to card left side (on same vertical line as panel top-left Pip, moving strictly vertically when switching between panel and card without horizontal shift), adopting the card's look (finished for done/recovery, question / approval for needs-you, error for error, danger for red card); springs back on collapse (user decision: must ease back from original position).
8. **Never display when invisible**: timers pause when screen is off or locked; new cards queue without displaying or playing sound; new violations still attach red card, deferring Basso until return; recoveries occurring while absent do not play sound.

- **Meteor**: when card appears, two meteors travel from top corners along edges to bottom center once, **not representing a countdown** (user decision). Shape and duration in `CardEdge.swift` (modeled after Magic UI Border Beam). Resident red card and reduced motion draw a faint hairline in matching color instead (Dynamic Island `keylineTint`). Rejected alternatives: progress bars, looping beams, colorful glows, diffused glows without solid head.
- **Sections and Content Blocks** (user decision, modeled after Dynamic Island expanded sections): first row has Pip + title / subtitle + right-hand short value + ×; underneath at most one content block — text body (Markdown subset), log tail (monospace, last few lines), key-value facts, checklist, progress bar. Block names follow Adaptive Cards (TextBlock, FactSet). Natural size layout (body text wraps up to 3 lines; log lines truncate), App measures height, shape smoothly morphs via springs without precalculating height (user decision). Text body supports only bold, italic, inline code, stripping links (interactions routed through card click and buttons). External plugin cards prefix subtitle with plugin icon and name. Avoid HTML layout: WebView runs in separate process, breaking animation coordination with Pip and shape.
- **Card clicks and buttons**: cards may carry one click action and up to two buttons, with three actions supported: open URL (https and schemes in Settings › Plugins link whitelist; blocked requests log scheme only), activate App, jump to terminal. Any click dismisses the card. Claude Code cards jump to Ghostty session; red and recovery cards carry no actions.
- **Colors** (meteor and hairline): done and normal messages silver-white, error light orange, waiting for answer and attention cyan, waiting for approval lime, recovery green, red card red; normal messages silent. Green reserved for normal egress; Claude orange looks reddish on black and is avoided.
- **Copywriting**: title states who experienced what ("Claude Code is done"), subtitle is session path. VoiceOver reads title when card appears.
- **Hover calculated per card**: hovering pauses countdown only after mouse moves over card; card appearing under stationary mouse counts down as usual.

## Dynamic Island Specs

Notch UI follows iPhone Dynamic Island principles. Apple has not yet published Mac Dynamic Island guidelines; cross-check when released (`HANDOFF.md`). References: [HIG Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities) (HIG), [Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities), [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion), WWDC23 10194 "Design dynamic Live Activities", WWDC23 10158 "Animate with springs", WWDC18 803 "Designing Fluid Interfaces".

| # | Guideline (Reference) | Our Implementation |
|---|---|---|
| 1 | Solid opaque black background, immutable (HIG: "use a black opaque background") | Elements attached to notch are strictly black background; background color invariant, motion applied to content |
| 2 | Keyline outline in dark appearance matching content color (HIG, `keylineTint`) | Panel has white 0.08 hairline; resident red card and reduced motion draw matching color hairline |
| 3 | Existing elements move to new positions on state change without disappearing and re-entering; only moved items animate (HIG: "animating existing elements to their new positions") | Pip flies from left ear to panel / card, right ear morphs into badge; panel and cards share width, varying only height; session row positions invariant to status changes |
| 4 | Custom animations at most 2 seconds; purposeful motion, restrained on frequent interactions (HIG, HIG Motion) | Shape, content entrance, meteor finish within 2 seconds; meteor runs once without looping |
| 5 | Text changes use blur transitions, numbers use `numericText`, symbols use Replace (Displaying live data) | Card content blurs in; IP numbers roll; badge icons use Replace |
| 6 | Springs default to bounce 0, not exceeding ~0.4; collapse without outward momentum uses 100% damping (WWDC23 10158, WWDC18 803) | Expand and card pop use same spring configuration (user decision) with subtle bounce; collapse has minimal bounce (`NotchSpring`) |
| 7 | Alert only for critical events; expand and play sound on alert; emphasize triggering item (HIG, WWDC23 10194) | Card title states who experienced what, Pip morphs into card look; card right side omits duplicate status cues or extra icons |
| 8 | Only one expanded at a time; low-priority dismisses itself (HIG) | One card at a time, temporary cards auto-collapse, red card stays resident |
| 9 | Tapping opens related location in App; expanded state aims for single primary interaction (HIG) | Clicking card jumps to Ghostty session; only button on card is × |
| 10 | Collapsed state balanced symmetrically around camera (HIG compact) | Right ear indicator centered in visible ear area, symmetrical with left ear Pip; does not shrink with content (three dots pulsing on/off with shifting width is distracting) |
| 11 | Typography uses medium weight or heavier, minimal small text; ≤ 17pt contrast ratio at least 4.5:1; macOS minimum font size 10pt (HIG, HIG Accessibility, HIG Typography) | Small text uses medium weight, white ≥ 0.5; × at 10pt touches lower bound |
| 12 | Reduce Motion: replace translation and scaling with fade in/out, remove blur transitions, tighten springs (HIG Accessibility) | Content, Pip, badge fade in/out; black shape springs tightened to eliminate overshoot (`NotchSpring`) |
| 13 | VoiceOver reads status; motion must not be sole channel for critical info (HIG Accessibility, HIG Motion) | Pip exposes `accessibilityValue`, card announces title; Status = Color + Icon + Text + Sound |
| 14 | Concentricity: inner radius = outer radius − padding; content hugs top, no empty forehead (HIG, WWDC23 10194) | Panel conforms (outer radius 28, margin 14, session container 14); cards align left/right per Pip alignment line; Pip in panel sits left of notch hugging top |

Intentional Deviations:

- Screen remains off during lock/sleep; cards queue until user returns ("Cards" 8, user decision).
- Panel is taller than expanded 84–160pt: it serves as user-invoked detail inspection.
- Egress IP displayed in full (user decision, on hover panel only); card subtitle displays full path without shortening to project name (user decision).
- Pip and right-ear indicators maintain persistent loops (stars spinning, !! jumping, 3 blue dots): Pip is a character, not a one-off animation.
- Collapsed ears do not tightly hug camera: ear widths are fixed, indicators centered in visible region.
- Session row vendor logos include a subtle background pill (HIG recommends logos without containers).
- Meteor is an extra animation not in Dynamic Island alerts (user requested, single run).
- Expands on hover rather than click as Apple does on Mac: no false triggers observed; tune delay based on measurement if issues arise.

## Screenshots

Attach screenshots when changing UI: light and dark mode on notch display (both should have black background attached to notch); English and Chinese versions for text changes; additional notchless screenshot if external display is connected.
