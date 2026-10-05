import Foundation
import StrandAnalytics

/// On-disk cache of each day's strap-derived state timeline (`DayStateSegment`s), so the "Through the day"
/// list can be drawn the moment the Heart rate page opens and then refreshed from the stored streams.
///
/// Like `ActivityContextFileStore` it is derived data: rebuildable from the database, kept beside it in its own
/// folder, left out of device backups, written atomically, and anything unreadable is a miss. A record says when
/// it was built and how far into the day it reaches, so the page can tell the wearer how fresh it is.
final class DayStateFileStore: @unchecked Sendable {
    static let shared = DayStateFileStore()

    struct Record: Codable, Equatable {
        var version: Int
        var source: String
        var dayStart: Int
        /// The end of the streams the timeline was built from (the day's end, or "now" for a live day).
        var dayEnd: Int
        var builtAt: Int
        var segments: [DayStateSegment]
    }

    /// Bump when `DayStateTimeline`'s rules change so cached timelines are built again.
    static let currentVersion = 1
    static let retentionDays = 45

    private static let magic = Data("DSX1".utf8)
    private static let fileExtension = "dsx"

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let fm = FileManager.default
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
            self.directory = base.appendingPathComponent("OpenWhoop/DayStates", isDirectory: true)
        }
        Self.prepare(self.directory)
    }

    func load(source: String, dayStart: Int) -> Record? {
        let url = fileURL(source: source, dayStart: dayStart)
        guard let raw = try? Data(contentsOf: url) else { return nil }
        guard let record = Self.decode(raw), record.version == Self.currentVersion,
              record.dayStart == dayStart else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return record
    }

    func save(segments: [DayStateSegment], source: String, dayStart: Int, dayEnd: Int, now: Date = Date()) {
        let record = Record(version: Self.currentVersion, source: source, dayStart: dayStart, dayEnd: dayEnd,
                            builtAt: Int(now.timeIntervalSince1970), segments: segments)
        guard let data = Self.encode(record) else { return }
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(source: source, dayStart: dayStart)
        try? data.write(to: url, options: [.atomic])
        prune(keeping: url, now: now)
    }

    func removeEverything() {
        lock.lock(); defer { lock.unlock() }
        for url in files() { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Files

    func fileURL(source: String, dayStart: Int) -> URL {
        directory.appendingPathComponent("\(Self.sanitize(source))_\(dayStart).\(Self.fileExtension)")
    }

    private func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == Self.fileExtension }
    }

    private func prune(keeping keep: URL, now: Date) {
        let cutoff = Int(now.timeIntervalSince1970) - Self.retentionDays * 86_400
        for url in files() where url.lastPathComponent != keep.lastPathComponent {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let day = stem.split(separator: "_").last.flatMap({ Int($0) }), day < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func sanitize(_ source: String) -> String {
        String(source.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" ? $0 : "-" })
    }

    private static func prepare(_ directory: URL) {
        var dir = directory
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                              ofItemAtPath: dir.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    // MARK: Encoding

    static func encode(_ record: Record) -> Data? {
        guard let json = try? JSONEncoder().encode(record),
              let packed = try? (json as NSData).compressed(using: .lzfse) else { return nil }
        return magic + (packed as Data)
    }

    static func decode(_ raw: Data) -> Record? {
        guard raw.starts(with: magic),
              let json = try? (Data(raw.dropFirst(magic.count)) as NSData).decompressed(using: .lzfse) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: json as Data)
    }
}
