import Foundation

public enum UsageFormatter {
    public static func menuBarTitle(
        for snapshots: [UsageSnapshot],
        remainingCountdown: Bool = false
    ) -> String {
        let parts = snapshots
            .filter(\.enabled)
            .map { snapshot in
                if let displayValue = snapshot.displayValue {
                    return "\(snapshot.label) \(displayValue)"
                }

                if let percentUsed = snapshot.percentUsed {
                    return "\(snapshot.label) \(displayPercent(percentUsed: percentUsed, remainingCountdown: remainingCountdown))%"
                }

                return "\(snapshot.label) --%"
            }

        return parts.isEmpty ? "AI --%" : parts.joined(separator: "  ")
    }

    public static func displayPercent(percentUsed: Int, remainingCountdown: Bool) -> Int {
        remainingCountdown ? max(0, 100 - percentUsed) : percentUsed
    }

    public static func shortTime(_ date: Date?, calendar: Calendar = .current) -> String {
        guard let date else {
            return "Never"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
