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
                    // On failure keep the last known percentUsed so the menu bar doesn't go blank
                    if snapshot.status == .failed, snapshot.percentUsed == nil, let lastPercent = previous.percentUsed {
                        snapshots[index] = UsageSnapshot(
                            sourceID: snapshot.sourceID,
                            label: snapshot.label,
                            enabled: snapshot.enabled,
                            percentUsed: lastPercent,
                            displayValue: snapshot.displayValue,
                            status: .failed,
                            updatedAt: snapshot.updatedAt,
                            resetDescription: previous.resetDescription,
                            errorMessage: snapshot.errorMessage
                        )
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
