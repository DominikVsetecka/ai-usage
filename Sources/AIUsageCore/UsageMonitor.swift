import Foundation

@MainActor
public final class UsageMonitor {
    public private(set) var snapshots: [UsageSnapshot]
    public private(set) var isRefreshing = false
    public let refreshIntervalSeconds: TimeInterval

    private let probes: [UsageProbing]

    public init(
        config: AppConfig,
        probes: [UsageProbing]? = nil,
        oauthService: ClaudeOAuthUsageService? = nil
    ) {
        self.refreshIntervalSeconds = config.refreshIntervalSeconds
        self.probes = probes ?? UsageProbeFactory.makeProbes(config: config, oauthService: oauthService)
        self.snapshots = config.sources.map(UsageSnapshot.idle(from:))
    }

    public func refresh(
        force: Bool = false,
        onUpdate: (@MainActor ([UsageSnapshot]) -> Void)? = nil
    ) async -> [UsageSnapshot] {
        guard !isRefreshing else {
            return snapshots
        }

        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: UsageSnapshot.self) { group in
            for probe in probes {
                group.addTask {
                    if force, let probe = probe as? any ForceRefreshableUsageProbing {
                        return await probe.readUsage(force: true)
                    }
                    return await probe.readUsage()
                }
            }

            for await snapshot in group {
                if let index = snapshots.firstIndex(where: { $0.sourceID == snapshot.sourceID }) {
                    snapshots[index] = Self.merged(new: snapshot, previous: snapshots[index])
                } else {
                    snapshots.append(snapshot)
                }
                onUpdate?(snapshots)
            }
        }
        return snapshots
    }

    /// Fills in missing windows from the last-known-good snapshot unless the
    /// probe says its standard-window set is authoritative. Text/TUI probes can
    /// report `.ok` while failing to parse one section this cycle (e.g. a
    /// Claude CLI `/usage` redraw glitch), so they keep the old per-field
    /// preservation. Structured probes can instead clear missing windows when
    /// a provider really stops reporting them.
    private static func merged(new: UsageSnapshot, previous: UsageSnapshot) -> UsageSnapshot {
        var merged = new
        if merged.percentUsed == nil { merged.percentUsed = previous.percentUsed }
        if merged.resetDescription == nil { merged.resetDescription = previous.resetDescription }
        if !merged.standardWindowsAuthoritative {
            if merged.fiveHour == nil { merged.fiveHour = previous.fiveHour }
            if merged.oneWeek == nil { merged.oneWeek = previous.oneWeek }
        }
        if merged.extraWindows.isEmpty { merged.extraWindows = previous.extraWindows }
        return merged
    }
}
