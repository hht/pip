import Foundation
import GuardCore

/// Answers: what is this machine's public egress IPv4 as seen from outside.
/// Queries several public IP echo services concurrently, parsing each response at the boundary into `IPv4`;
/// failed, non-200, or unparseable answers are neither guessed nor padded,
/// only counted by type for troubleshooting unknown states (counts do not contain IPs).
/// Uses third-party echo services only, never accessing any Claude / Anthropic domains (CLAUDE.md hard rule).
///
/// Limitation: echo services and other apps may be dispatched by Clash to different proxy nodes,
/// in which case the reported IP is not that of those apps.
/// Therefore egress IP mismatch is only verdicted egressMismatch (amber), see docs/egress-guard.md.
public struct EgressProbe: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    public enum Failure: Error, Hashable, Sendable { case timeout, transport, badStatus, unparseable }

    public struct Sample: Sendable {
        /// Successfully retrieved IPs; empty array if none (counts as unknown in verdict).
        public var ips: [IPv4] = []
        public var failures: [Failure: Int] = [:]

        public init(ips: [IPv4] = [], failures: [Failure: Int] = [:]) {
            self.ips = ips
            self.failures = failures
        }
    }

    public let endpoints: [URL]
    let fetch: Fetch

    public init(endpoints: [URL], fetch: @escaping Fetch) {
        self.endpoints = endpoints
        self.fetch = fetch
    }

    public static let live = EgressProbe(
        endpoints: ["https://api.ipify.org", "https://ipinfo.io/ip", "https://ifconfig.me/ip"].compactMap(URL.init(string:)),
        fetch: { url in
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
            req.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent") // These services decide plaintext vs HTML based on UA
            let (data, resp) = try await session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    )

    private static let session = URLSession(configuration: .ephemeral)

    public func current() async -> Sample {
        await withTaskGroup(of: Result<IPv4, Failure>.self) { group in
            for url in endpoints {
                group.addTask { await ask(url) }
            }
            return await group.reduce(into: Sample()) { sample, result in
                switch result {
                case let .success(ip): sample.ips.append(ip)
                case let .failure(f): sample.failures[f, default: 0] += 1
                }
            }
        }
    }

    private func ask(_ url: URL) async -> Result<IPv4, Failure> {
        let data: Data, status: Int
        do { (data, status) = try await fetch(url) } catch let e as URLError where e.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.transport)
        }
        guard status == 200 else { return .failure(.badStatus) }
        guard let ip = IPv4(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.unparseable)
        }
        return .success(ip)
    }
}
