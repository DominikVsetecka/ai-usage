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
                    let previous = snapshots[index]
                    if snapshot.status == .failed {
                        // On failure preserve any last-known values so the menu bar and popover don't go blank
                        var merged = snapshot
                        if merged.percentUsed == nil { merged.percentUsed = previous.percentUsed }
                        if merged.resetDescription == nil { merged.resetDescription = previous.resetDescription }
                        if merged.fiveHour == nil { merged.fiveHour = previous.fiveHour }
                        if merged.oneWeek == nil { merged.oneWeek = previous.oneWeek }
                        if merged.extraWindows.isEmpty { merged.extraWindows = previous.extraWindows }
                        snapshots[index] = merged
                    } else {
                        snapshots[index] = snapshot
                    }
                } else {
                    snapshots.append(snapshot)
                }
                onUpdate?(snapshots)
            }
        }
        return snapshots
    }
}
