import Foundation
import StrandAnalytics

/// On-disk cache of each day's decoded ActivityContext (`ActivityContextDayDocument`).
///
/// It is derived data: every byte can be rebuilt from the stored streams, so it lives beside the database
/// in its own folder, is left out of device backups, and is never part of a `.noopbak`. Files are written
/// atomically and carry a version header; anything unreadable is treated as a miss and deleted.
///
/// A document holds the day as compact runs plus the decoder's state, so the next open continues from the
/// last second decoded instead of replaying the day.
final class ActivityContextFileStore: @unchecked Sendable {
    static let shared = ActivityContextFileStore()

    /// Days older than this are removed the next time a document is written.
    static let retentionDays = 45

    private static let magic = Data("ACX1".utf8)
    private static let fileExtension = "acx"

    private let directory: URL
    private let lock = NSLock()

    /// `directory` is for tests; production uses `<AppSupport>/OpenWhoop/ActivityContext`.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let fm = FileManager.default
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
            self.directory = base.appendingPathComponent("OpenWhoop/ActivityContext", isDirectory: true)
        }
        Self.prepare(self.directory)
    }

    func load(source: String, dayStart: Int) -> ActivityContextDayDocument? {
        let url = fileURL(source: source, dayStart: dayStart)
        guard let raw = try? Data(contentsOf: url) else { return nil }
        guard let document = Self.decode(raw) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return document
    }

    func save(_ document: ActivityContextDayDocument, source: String, now: Date = Date()) {
        guard let data = Self.encode(document) else { return }
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(source: source, dayStart: document.dayStart)
        try? data.write(to: url, options: [.atomic])
        prune(keeping: url, now: now)
    }

    /// Remove every cached day whose source key mentions `deviceId` (used when a device's data is deleted).
    func removeAll(forDevice deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        let needle = Self.sanitize(deviceId)
        for url in files() where url.lastPathComponent.contains(needle) {
            try? FileManager.default.removeItem(at: url)
        }
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
        for url in files() where url != keep {
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
        // Same class as the store: readable after the first unlock, so a background sync can still read it.
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                              ofItemAtPath: dir.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    // MARK: Encoding

    static func encode(_ document: ActivityContextDayDocument) -> Data? {
        guard let json = try? JSONEncoder().encode(document),
              let packed = try? (json as NSData).compressed(using: .lzfse) else { return nil }
        return magic + (packed as Data)
    }

    static func decode(_ raw: Data) -> ActivityContextDayDocument? {
        guard raw.starts(with: magic),
              let json = try? (Data(raw.dropFirst(magic.count)) as NSData).decompressed(using: .lzfse) else { return nil }
        return try? JSONDecoder().decode(ActivityContextDayDocument.self, from: json as Data)
    }
}
