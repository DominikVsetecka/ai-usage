import AIUsageCore
import Foundation

@main
struct AIUsageSnapshot {
    static func main() async {
        do {
            let config = try AppConfig.load(from: AppConfig.defaultConfigURL())
            let monitor = UsageMonitor(config: config)
            let snapshots = await monitor.refresh()

            print(UsageFormatter.menuBarTitle(
                for: snapshots,
                remainingCountdown: config.showsRemainingCountdown
            ))

            for snapshot in snapshots where snapshot.enabled {
                let value = snapshot.displayValue ?? snapshot.percentUsed.map {
                    let display = UsageFormatter.displayPercent(
                        percentUsed: $0,
                        remainingCountdown: config.showsRemainingCountdown
                    )
                    return "\(display)%"
                } ?? "--%"
                let error = snapshot.errorMessage.map { " | \($0)" } ?? ""
                print("\(snapshot.label): \(value) \(snapshot.status.rawValue)\(error)")
            }
        } catch {
            fputs("AIUsageSnapshot failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
