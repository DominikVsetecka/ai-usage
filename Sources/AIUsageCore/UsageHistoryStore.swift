import Foundation

public struct UsageHistoryEntry: Codable, Sendable {
    public let ts: Date
    public let sources: [String: WindowSnapshot]

    public struct WindowSnapshot: Codable, Sendable {
        public let fiveHour: Int?
        public let oneWeek: Int?
    }
}

public actor UsageHistoryStore {
    private let directory: URL
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
            let new = UsageHistoryEntry.WindowSnapshot(
                fiveHour: snap.fiveHour?.percentUsed,
                oneWeek: snap.oneWeek?.percentUsed
            )
            if let last = lastRecorded[snap.sourceID] {
                let fhDiff = abs((new.fiveHour ?? -1) - (last.fiveHour ?? -1))
                let owDiff = abs((new.oneWeek ?? -1) - (last.oneWeek ?? -1))
                if fhDiff >= changeThreshold || owDiff >= changeThreshold {
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
                (snap.sourceID, UsageHistoryEntry.WindowSnapshot(
                    fiveHour: snap.fiveHour?.percentUsed,
                    oneWeek: snap.oneWeek?.percentUsed
                ))
            })
        )
        try? append(entry: entry, date: now)
        cleanOldFiles(relativeTo: now)
    }

    public func load(days: Int = 1) -> [UsageHistoryEntry] {
        let calendar = Calendar.current
        let today = Date()
        var entries: [UsageHistoryEntry] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        for offset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            guard let data = try? Data(contentsOf: filePath(for: date)) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                if let entry = try? decoder.decode(UsageHistoryEntry.self, from: Data(line)) {
                    entries.append(entry)
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
