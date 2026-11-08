import Foundation

/// One entry in an account's connection history: state changes, logins,
/// repairs and removals. Messages are user-facing text and never contain
/// tokens — at most a four-character token fingerprint.
public struct ConnectionEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case added
        case removed
        case reconnected
        case healthChanged
        case keychainDeleted
        case note
    }

    public let id: UUID
    public let ts: Date
    public let account: String
    public let kind: Kind
    public let health: ConnectionHealth?
    public let message: String

    public init(id: UUID = UUID(), ts: Date = Date(), account: String, kind: Kind, health: ConnectionHealth? = nil, message: String) {
        self.id = id
        self.ts = ts
        self.account = account
        self.kind = kind
        self.health = health
        self.message = message
    }
}

/// Append-only JSON-lines file (`~/.ai-usage/events.jsonl`), local only.
public actor ConnectionEventStore {
    public nonisolated let url: URL
    private let retentionDays: Int
    private let perAccountLimit: Int

    public init(url: URL, retentionDays: Int = 90, perAccountLimit: Int = 500) {
        self.url = url
        self.retentionDays = retentionDays
        self.perAccountLimit = perAccountLimit
    }

    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".ai-usage/events.jsonl")
    }

    public func append(_ event: ConnectionEvent) {
        guard let line = try? Self.encoder.encode(event) else { return }
        let data = line + Data([0x0A])
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Newest first. `account` nil loads every account.
    public func load(account: String? = nil, limit: Int = 300) -> [ConnectionEvent] {
        let events = readAll().filter { account == nil || $0.account == account }
        return Array(events.reversed().prefix(limit))
    }

    /// The last recorded connection state per account, so a restart doesn't
    /// log an unchanged state ("Login needed") again.
    public func latestHealth() -> [String: ConnectionHealth] {
        var result: [String: ConnectionHealth] = [:]
        for event in readAll() {
            if let health = event.health { result[event.account] = health }
        }
        return result
    }

    /// Drops events older than the retention window and keeps at most
    /// `perAccountLimit` per account; `removingAccounts` also forgets the
    /// history of removed accounts whose history the user chose not to keep.
    public func prune(now: Date = Date(), removingAccounts: Set<String> = []) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var kept: [ConnectionEvent] = []
        var counts: [String: Int] = [:]
        for event in readAll().reversed() where event.ts >= cutoff && !removingAccounts.contains(event.account) {
            let count = counts[event.account, default: 0]
            guard count < perAccountLimit else { continue }
            counts[event.account] = count + 1
            kept.append(event)
        }
        let lines = kept.reversed().compactMap { try? Self.encoder.encode($0) }
        let data = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        try? data.write(to: url, options: .atomic)
    }

    private func readAll() -> [ConnectionEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(ConnectionEvent.self, from: Data($0)) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
