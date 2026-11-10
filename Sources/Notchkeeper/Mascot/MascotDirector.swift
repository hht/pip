import AppKit
import QuartzCore
import MascotCore

/// Shared across all Pips: registers visible Pips, wakes at moments determined by `MascotClock` to dispatch cues, forwards mouse events, halts on display sleep / screen lock.
/// Timing for blinks, idle micro-movements, gaze reset, drowsiness, and dizziness recovery is governed by `MascotClock`; agnostic to Pip rendering and kinematics.
/// Clock stops when no Pips are visible, or when display sleeps / screen locks (docs/mascot.md §5 "Rendering").
@MainActor
final class MascotDirector: ObservableObject {
    static let shared = MascotDirector()

    /// Mirror of `MascotClock`, published on change: views overlay dizziness and sleepiness (`shown`).
    @Published private(set) var drowsy = false
    @Published private(set) var dizzy = false
    /// Display asleep or screen locked. Not published as views don't read directly; evaluated individually per Pip via `refreshActive`.
    var paused: Bool { !away.isEmpty }
    /// Changes in paused state: card queue pauses/resumes accordingly (docs/ui.md "Card" 8).
    var onPausedChange: ((Bool) -> Void)?

    /// Mouse within this distance of notch is considered near (prevents drowsiness).
    static let nearDistance: CGFloat = 150

    private enum Away { case screensAsleep, locked }
    private var away: Set<Away> = []

    private var notchRect: () -> NSRect = { .zero }
    private var views: [Weak] = []
    private var clock = MascotClock(seed: UInt64.random(in: 1...UInt64.max), now: CACurrentMediaTime())
    private var timer: Timer?
    /// Wake time scheduled for timer; nil = stopped.
    private var timerAt: CFTimeInterval?
    /// "Follow mouse" setting in preferences.
    private var followsMouse = true

    private struct Weak {
        weak var view: MascotLayerView?
    }

    private var all: [MascotFigureView] { views.compactMap { $0.view as? MascotFigureView } }
    private var live: [MascotFigureView] { all.filter(\.active) }

    /// Called once at App startup with notch screen rectangle.
    func start(notchRect: @escaping () -> NSRect) {
        self.notchRect = notchRect
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        // Lock screen has no public API notification; com.apple.screenIsLocked / Unlocked are system distributed notifications.
        // If a macOS version discontinues them, only lock screen detection is affected; display sleep and window occlusion still halt Pip.
        // @see https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification
        // @see https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification
        // @see https://developer.apple.com/documentation/foundation/distributednotificationcenter
        let sources: [(NotificationCenter, Notification.Name, Away, Bool)] = [
            (ws, NSWorkspace.screensDidSleepNotification, .screensAsleep, true),
            (ws, NSWorkspace.screensDidWakeNotification, .screensAsleep, false),
            (dn, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (dn, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
        ]
        for (center, name, reason, on) in sources {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MascotDirector.shared.set(reason, on) }
            }
        }
    }

    private func set(_ reason: Away, _ on: Bool) {
        let was = paused
        if on { away.insert(reason) } else { away.remove(reason) }
        guard paused != was else { return }
        views.forEach { $0.view?.refreshActive() }
        onPausedChange?(paused)
    }

    /// Actual look to render: overlays dizziness/sleepiness onto base look.
    func shown(_ look: Look) -> Look { look.shown(drowsy: drowsy, dizzy: dizzy) }

    /// Distance from point to rectangle; 0 if inside.
    nonisolated static func distance(from p: NSPoint, to r: NSRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    private func mouseNear(_ p: NSPoint) -> Bool { Self.distance(from: p, to: notchRect()) <= Self.nearDistance }

    // MARK: Pip Registration

    func attach(_ v: MascotLayerView) {
        views.removeAll { $0.view == nil || $0.view === v }
        views.append(Weak(view: v))
    }

    func detach(_ v: MascotLayerView) {
        views.removeAll { $0.view == nil || $0.view === v }
        activityChanged()
    }

    /// When Pip visibility changes or screen locks/sleeps: clock pauses/resumes.
    func activityChanged() {
        let on = !live.isEmpty
        guard on != (timerAt != nil) else { return }
        if on {
            clock.resume(at: CACurrentMediaTime())
            schedule()
        } else if !clock.dizzy {
            // Keep running if dizzy (at most 1.6s remaining): often triggered when SwiftUI updates views (`playing` changes);
            // dizziness cleanup deferred to scheduled tick, keeping published mirror updates inside timer callback.
            timer?.invalidate()
            stopClock()
        }
    }

    /// Stop clock. If Pips became invisible while dizzy, clear dizziness (`MascotClock.suspend`) and update mirror.
    private func stopClock() {
        timer = nil
        timerAt = nil
        clock.suspend()
        clockChanged()
    }

    // MARK: Clock

    private func schedule() {
        timer?.invalidate()
        let at = clock.nextWake
        let t = Timer(fire: Date(timeIntervalSinceNow: max(0, at - CACurrentMediaTime())), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { MascotDirector.shared.tick() }
        }
        // Blinks and micro-movements tolerate minor jitter; allow system timer coalescing.
        // @see https://developer.apple.com/documentation/foundation/timer/tolerance
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerAt = at
    }

    /// Clock updated: sync mirrors; reschedule timer if wake time moved earlier (postponed wakes adjust on next tick).
    private func clockChanged() {
        if drowsy != clock.drowsy { drowsy = clock.drowsy }
        if dizzy != clock.dizzy { dizzy = clock.dizzy }
        if let at = timerAt, clock.nextWake < at { schedule() }
    }

    private func tick() {
        let views = live
        // Visible Pips vanished without refreshActive: stop clock.
        guard !views.isEmpty else { return stopClock() }
        let t = clock.tick(now: CACurrentMediaTime(), mouseNear: mouseNear(NSEvent.mouseLocation))
        if t.gazeRested { all.forEach { $0.follow(mouse: nil) } }
        for cue in t.cues { views.forEach { $0.perform(cue) } }
        clockChanged()
        schedule()
    }

    /// "Play action": visible Pips perform action once regardless of current look.
    func play(_ cue: Cue) {
        live.forEach { $0.perform(cue, force: true) }
    }

    /// Poke Pip in panel: triggers dizziness briefly.
    func poke() {
        clock.poke(now: CACurrentMediaTime())
        clockChanged()
    }

    // MARK: Mouse

    /// When disabled, eyes reset forward without peeking, observing only mouse proximity to notch (drowsiness).
    func setFollowsMouse(_ on: Bool) {
        guard on != followsMouse else { return }
        followsMouse = on
        guard !on else { return }
        clock.endGaze()
        for v in all {
            v.follow(mouse: nil)
            v.setPeeking(false)
        }
    }

    /// Global mouse moved event from NotchController (screen coordinates). Pip tracks mouse and peeks when cursor is on notch (docs/mascot.md §5 "Follow Mouse").
    func mouseMoved(to p: NSPoint) {
        var looking = false
        if followsMouse {
            let peek = Self.distance(from: p, to: notchRect()) == 0
            for v in live {
                v.follow(mouse: p)
                v.setPeeking(peek)
                looking = looking || v.isLooking
            }
        }
        clock.mouseMoved(near: mouseNear(p), looking: looking, now: CACurrentMediaTime())
        clockChanged()
    }
}
