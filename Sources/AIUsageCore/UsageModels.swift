import Foundation

public enum SourceStatus: String, Codable, Equatable, Sendable {
    case idle
    case ok
    case failed
    case disabled
}

public struct UsageSnapshot: Equatable, Sendable {
    public var sourceID: String
    public var label: String
    public var enabled: Bool
    public var percentUsed: Int?
    public var displayValue: String?
    public var status: SourceStatus
    public var updatedAt: Date?
    public var resetDescription: String?
    public var errorMessage: String?

    public init(
        sourceID: String,
        label: String,
        enabled: Bool,
        percentUsed: Int?,
        displayValue: String? = nil,
        status: SourceStatus,
        updatedAt: Date?,
        resetDescription: String? = nil,
        errorMessage: String?
    ) {
        self.sourceID = sourceID
        self.label = label
        self.enabled = enabled
        self.percentUsed = percentUsed.map { min(100, max(0, $0)) }
        self.displayValue = displayValue
        self.status = status
        self.updatedAt = updatedAt
        self.resetDescription = resetDescription
        self.errorMessage = errorMessage
    }

    public static func idle(from config: SourceConfig) -> UsageSnapshot {
        UsageSnapshot(
            sourceID: config.id,
            label: config.label,
            enabled: config.enabled,
            percentUsed: nil,
            displayValue: nil,
            status: config.enabled ? .idle : .disabled,
            updatedAt: nil,
            resetDescription: nil,
            errorMessage: nil
        )
    }
}

public protocol UsageProbing: Sendable {
    var sourceID: String { get }
    var label: String { get }
    var enabled: Bool { get }

    func readUsage() async -> UsageSnapshot
}
