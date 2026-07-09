import Foundation

@MainActor
public final class UsageMonitor {
    public private(set) var snapshots: [UsageSnapshot]
    public private(set) var isRefreshing = false
    public let refreshIntervalSeconds: TimeInterval

    private let probes: [UsageProbing]

    public init(config: AppConfig, probes: [UsageProbing]? = nil) {
        self.refreshIntervalSeconds = config.refreshIntervalSeconds
        self.probes = probes ?? UsageProbeFactory.makeProbes(config: config)
        self.snapshots = config.sources.map(UsageSnapshot.idle(from:))
    }

    public func refresh(
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
                    await probe.readUsage()
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

    /// Fills in any missing window from the last-known-good snapshot,
    /// regardless of the new snapshot's overall status. A probe can report
    /// `.ok` while still failing to parse a single window this cycle (e.g. a
    /// Claude CLI `/usage` TUI redraw glitch that only garbles one section) —
    /// without this, that one field silently goes blank in the popover and
    /// stays that way until the next fully-clean parse, which in practice can
    /// mean "only a restart fixes it" if the same glitch keeps recurring.
    /// Preserving per field, not just on hard failure, closes that gap.
    private static func merged(new: UsageSnapshot, previous: UsageSnapshot) -> UsageSnapshot {
        var merged = new
        if merged.percentUsed == nil { merged.percentUsed = previous.percentUsed }
        if merged.resetDescription == nil { merged.resetDescription = previous.resetDescription }
        if merged.fiveHour == nil { merged.fiveHour = previous.fiveHour }
        if merged.oneWeek == nil { merged.oneWeek = previous.oneWeek }
        if merged.extraWindows.isEmpty { merged.extraWindows = previous.extraWindows }
        return merged
    }
}
