import Foundation
import GuardCore

/// Answers: what Egress Guard does in each round, and when the next round starts — runs 3 probe tracks concurrently,
/// passes results to `EgressGuard` for verdict, and pushes each round's result to the App.
/// Verdict rules reside in GuardCore, probe details in each Probe; this layer only orchestrates; does not draw UI, nor intercept (interception belongs to firewall, docs/firewall.md).
/// Runs only while App is running: stops when App terminates or the stream is cancelled (docs/egress-guard.md "When to check").
///
/// Network path (whether physical network exists) is only used to annotate unknown reasons (offline / probeFailed), without affecting verdict.
public struct GuardMonitor: Sendable {
    public var probes: Probes
    /// Fetches allowlist at the start of each round: changes in Settings take effect on the next round
    public var allowlist: @Sendable () async -> Set<IPv4>
    public var interval: Duration = .seconds(5)
    /// Total deadline for a round. 2s longer than EgressProbe's 6s HTTP timeout;
    /// that timeout is connection idle duration, not capping total request duration.
    /// Probes that miss the deadline count as "no result", see `Deadline`
    public var roundDeadline: Duration = .seconds(8)
    public var now: @Sendable () -> Date = Date.init

    public init(probes: Probes, allowlist: @escaping @Sendable () async -> Set<IPv4>) {
        self.probes = probes
        self.allowlist = allowlist
    }

    /// Probes to run in a round. Subbed with stubs in tests; `live()` uses real probes (network path monitor created here, called only once)
    public struct Probes: Sendable {
        public var route: @Sendable () async -> String?
        public var clash: @Sendable () -> Bool?
        public var path: any NetworkPathSource
        public var egress: EgressProbe

        public init(route: @escaping @Sendable () async -> String?, clash: @escaping @Sendable () -> Bool?,
                    path: any NetworkPathSource, egress: EgressProbe) {
            self.route = route
            self.clash = clash
            self.path = path
            self.egress = egress
        }

        public static func live() -> Probes {
            Probes(route: { await RouteProbe.current() }, clash: { ClashProbe.current() }, path: LiveNetworkPath(), egress: .live)
        }
    }

    /// Starts monitoring: yields a result after each round (even if unchanged, subscriber compares).
    /// Buffers newest 1, slow subscriber won't accumulate stale results.
    /// When subscriber stops iterating (task cancelled or stream deallocated), in-flight probes are cancelled, and interrupted round is not yielded.
    public func displays() -> AsyncStream<GuardDisplay> {
        let (stream, continuation) = AsyncStream.makeStream(of: GuardDisplay.self, bufferingPolicy: .bufferingNewest(1))
        let loop = Task {
            await run { continuation.yield($0) }
            continuation.finish()
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }

    func run(_ publish: (GuardDisplay) -> Void) async {
        var egressGuard = EgressGuard()
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let start = clock.now
            let allowlist = await allowlist()
            let round = await Self.observe(deadline: start + roundDeadline, clock: clock, probes: probes)
            if Task.isCancelled { break } // Probes cancelled, this round's data is incomplete
            let checkedAt = now()
            let verdict = egressGuard.observe(round.observation, allowlist: allowlist, at: checkedAt)
            publish(GuardDisplay(verdict: verdict, observation: round.observation, allowlist: allowlist, networkPath: round.path,
                                 violatedSince: egressGuard.violatedSince, checkedAt: checkedAt))
            // Never start next round before previous finishes (route child process, HTTP up to 6s can exceed interval);
            // does not catch up if slow, starts next immediately.
            // ContinuousClock progresses across sleep: checks immediately when Mac wakes up
            let next = max(start + interval, clock.now)
            do { try await Task.sleep(until: next, clock: clock) } catch { break } // Only cancellation throws
        }
    }

    /// Probe results for a round. `path == nil` means network snapshot unavailable (missed deadline or monitor has not fired yet)
    struct Round {
        var observation: Observation
        var path: NetworkPath?
    }

    /// Route + Clash, Egress IP, Network Path run concurrently with a shared deadline;
    /// each times out independently so a stall in one does not block the other two.
    /// Clash is a quick syscall dispatched to GCD thread to avoid blocking Swift concurrency pool;
    /// route subprocess is terminated on timeout (`RouteProbe.output`).
    static func observe(deadline: ContinuousClock.Instant, clock: ContinuousClock, probes: Probes) async -> Round {
        let route = probes.route, clashProbe = probes.clash, pathSource = probes.path, egressProbe = probes.egress
        async let local = Deadline.run(by: deadline, clock: clock) { () async -> (String?, Bool?) in
            async let clash = withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async { c.resume(returning: clashProbe()) }
            }
            return (await route(), await clash)
        }
        async let egress = Deadline.run(by: deadline, clock: clock) { await egressProbe.current() }
        async let path = Deadline.run(by: deadline, clock: clock) { await pathSource.current() }
        return Round(observation: merge(local: await local, egress: await egress), path: await path ?? nil)
    }

    /// Merges probe results that made/missed the deadline into a round observation.
    /// `nil` means missed deadline: counts strictly as "no result", never as "good"
    static func merge(local: (String?, Bool?)?, egress: EgressProbe.Sample?) -> Observation {
        Observation(clashRunning: local?.1, routeInterface: local?.0, egressIPs: egress?.ips ?? [])
    }
}
