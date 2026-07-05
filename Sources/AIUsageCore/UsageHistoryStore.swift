import Foundation

public struct UsageHistoryEntry: Codable, Sendable {
    public let ts: Date
    public let sources: [String: WindowSnapshot]

    public init(ts: Date, sources: [String: WindowSnapshot]) {
        self.ts = ts
        self.sources = sources
    }

    public struct WindowSnapshot: Codable, Sendable {
        public let fiveHour: Int?
        public let oneWeek: Int?
        /// Extra named windows (e.g. a model-scoped weekly cap like "Fable"),
        /// keyed by display name. Nil (not empty) when a source reports none,
        /// so older history files without this key decode unchanged.
        public let extra: [String: Int]?

        public init(fiveHour: Int?, oneWeek: Int?, extra: [String: Int]? = nil) {
            self.fiveHour = fiveHour
            self.oneWeek = oneWeek
            self.extra = extra
        }
    }
}

public actor UsageHistoryStore {
    public nonisolated let directory: URL
    private var lastRecorded: [String: UsageHistoryEntry.WindowSnapshot] = [:]
    private var lastWriteDate: Date?
    private var lastCleanDate: Date?
    private let changeThreshold = 1
    private let anchorInterval: TimeInterval = 30 * 60
    private let retentionDays = 30

    public init(directory: URL) {
        self.directory = directory
    }

    public func record(_ snapshots: [UsageSnapshot]) {
        let now = Date()
        let enabled = snapshots.filter(\.enabled)
        var anyChanged = false

        for snap in enabled {
            let new = Self.windowSnapshot(for: snap)
            if let last = lastRecorded[snap.sourceID] {
                let fhDiff = abs((new.fiveHour ?? -1) - (last.fiveHour ?? -1))
                let owDiff = abs((new.oneWeek ?? -1) - (last.oneWeek ?? -1))
                let extraChanged = (new.extra ?? [:]) != (last.extra ?? [:])
                if fhDiff >= changeThreshold || owDiff >= changeThreshold || extraChanged {
                    anyChanged = true
                }
            } else {
                anyChanged = true
            }
            lastRecorded[snap.sourceID] = new
        }

        let anchorDue = lastWriteDate.map { now.timeIntervalSince($0) >= anchorInterval } ?? true
        guard anyChanged || anchorDue else { return }
        lastWriteDate = now

        let entry = UsageHistoryEntry(
            ts: now,
            sources: Dictionary(uniqueKeysWithValues: enabled.map { snap in
                (snap.sourceID, Self.windowSnapshot(for: snap))
            })
        )
        try? append(entry: entry, date: now)
        cleanOldFiles(relativeTo: now)
    }

    private static func windowSnapshot(for snap: UsageSnapshot) -> UsageHistoryEntry.WindowSnapshot {
        UsageHistoryEntry.WindowSnapshot(
            fiveHour: snap.fiveHour?.percentUsed,
            oneWeek: snap.oneWeek?.percentUsed,
            extra: snap.extraWindows.isEmpty ? nil : snap.extraWindows.mapValues(\.percentUsed)
        )
    }

    public func load(days: Int = 1, now: Date = Date()) -> [UsageHistoryEntry] {
        let dayCount = max(1, days)
        let cutoff = now.addingTimeInterval(-TimeInterval(dayCount) * 86_400)
        return load(from: cutoff, to: now)
    }

    public func load(from start: Date, to end: Date = Date()) -> [UsageHistoryEntry] {
        let calendar = Calendar.current
        let lowerBound = min(start, end)
        let upperBound = max(start, end)
        var entries: [UsageHistoryEntry] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let startOfLowerDay = calendar.startOfDay(for: lowerBound)
        let startOfUpperDay = calendar.startOfDay(for: upperBound)
        let daySpan = calendar.dateComponents([.day], from: startOfLowerDay, to: startOfUpperDay).day ?? 0

        for offset in 0...max(0, daySpan) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: startOfLowerDay) else { continue }
            guard let data = try? Data(contentsOf: filePath(for: date)) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                if let entry = try? decoder.decode(UsageHistoryEntry.self, from: Data(line)) {
                    if entry.ts >= lowerBound && entry.ts <= upperBound {
                        entries.append(entry)
                    }
                }
            }
        }
        return entries.sorted { $0.ts < $1.ts }
    }

    private func append(entry: UsageHistoryEntry, date: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = try encoder.encode(entry)
        data.append(UInt8(ascii: "\n"))
        let path = filePath(for: date)
        if fm.fileExists(atPath: path.path) {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try data.write(to: path, options: .atomic)
        }
    }

    private func cleanOldFiles(relativeTo now: Date) {
        if let last = lastCleanDate, Calendar.current.isDate(last, inSameDayAs: now) { return }
        lastCleanDate = now
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for file in files where file.pathExtension == "jsonl" {
            let name = file.deletingPathExtension().lastPathComponent
            if let fileDate = formatter.date(from: name), fileDate < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func filePath(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return directory.appendingPathComponent("\(formatter.string(from: date)).jsonl")
    }
}
