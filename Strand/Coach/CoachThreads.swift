import Foundation

// MARK: - Models

/// One saved Sana conversation as the `coach` function lists it (`docs/COACH_MEMORY.md` §4 "Shapes").
/// Every field past `id` decodes leniently: a missing or malformed value falls back to its default, so a
/// server that adds or drops a column never empties the sidebar.
struct CoachThread: Codable, Identifiable, Equatable, Sendable {
    /// Lowercased client-generated UUID.
    var id: String
    var title: String?
    /// `none | auto | user | fallback | legacy`.
    var titleSource: String?
    var folderId: String?
    var pinned: Bool
    var origin: String?
    var createdAt: String?
    var updatedAt: String?
    var lastMessageAt: String?
    var messageCount: Int
    var preview: String?
    var topics: [String]
    /// `message_count - summary_messages`: turns the server has not folded into the summary yet.
    var pendingMessages: Int
    /// Search hit context, `«term»`-marked, only on search results.
    var snippet: String?
    /// Set on a row the phone created optimistically and the server has not confirmed yet. Never sent.
    var localOnly: Bool?

    init(id: String, title: String? = nil, titleSource: String? = nil, folderId: String? = nil, pinned: Bool = false,
         origin: String? = nil, createdAt: String? = nil, updatedAt: String? = nil, lastMessageAt: String? = nil,
         messageCount: Int = 0, preview: String? = nil, topics: [String] = [], pendingMessages: Int = 0,
         snippet: String? = nil, localOnly: Bool? = nil) {
        self.id = id.lowercased()
        self.title = title
        self.titleSource = titleSource
        self.folderId = folderId?.lowercased()
        self.pinned = pinned
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.preview = preview
        self.topics = topics
        self.pendingMessages = pendingMessages
        self.snippet = snippet
        self.localOnly = localOnly
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, titleSource, folderId, pinned, origin, createdAt, updatedAt, lastMessageAt
        case messageCount, preview, topics, pendingMessages, snippet, localOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id).lowercased()
        title = c.lossy(String.self, .title).flatMap { $0.isEmpty ? nil : $0 }
        titleSource = c.lossy(String.self, .titleSource)
        folderId = c.lossy(String.self, .folderId)?.lowercased()
        pinned = c.lossy(Bool.self, .pinned) ?? false
        origin = c.lossy(String.self, .origin)
        createdAt = c.lossy(String.self, .createdAt)
        updatedAt = c.lossy(String.self, .updatedAt)
        lastMessageAt = c.lossy(String.self, .lastMessageAt)
        messageCount = c.lossy(Int.self, .messageCount) ?? 0
        preview = c.lossy(String.self, .preview)
        topics = c.lossy([String].self, .topics) ?? []
        pendingMessages = c.lossy(Int.self, .pendingMessages) ?? 0
        snippet = c.lossy(String.self, .snippet)
        localOnly = c.lossy(Bool.self, .localOnly)
    }

    /// The moment the thread last moved: its newest message, else its last edit, else its creation.
    var activityDate: Date? {
        CoachDates.parse(lastMessageAt) ?? CoachDates.parse(updatedAt) ?? CoachDates.parse(createdAt)
    }

    /// Title as the sidebar shows it.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let preview, !preview.isEmpty { return CoachThreadTitle.fallback(from: preview) }
        return "New chat"
    }

    /// A title the user typed is never replaced by a generated one.
    var hasUserTitle: Bool { titleSource == "user" }
}

struct CoachFolder: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var sortOrder: Int
    var createdAt: String?
    var updatedAt: String?

    init(id: String, name: String, sortOrder: Int = 0, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id.lowercased()
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, sortOrder, createdAt, updatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id).lowercased()
        name = try c.decode(String.self, forKey: .name)
        sortOrder = c.lossy(Int.self, .sortOrder) ?? 0
        createdAt = c.lossy(String.self, .createdAt)
        updatedAt = c.lossy(String.self, .updatedAt)
    }
}

/// `GET threads`: one page of the list. Pinned threads lead the first page; the cursor covers the rest.
struct CoachThreadPage: Decodable, Equatable, Sendable {
    var threads: [CoachThread]
    var folders: [CoachFolder]
    var hasMore: Bool
    var nextCursor: String?

    init(threads: [CoachThread] = [], folders: [CoachFolder] = [], hasMore: Bool = false, nextCursor: String? = nil) {
        self.threads = threads
        self.folders = folders
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey { case threads, folders, hasMore, nextCursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = c.lossyList(CoachThread.self, .threads)
        folders = c.lossyList(CoachFolder.self, .folders)
        hasMore = c.lossy(Bool.self, .hasMore) ?? false
        nextCursor = c.lossy(String.self, .nextCursor)
    }
}

/// `GET messages?threadId=`: one page of a thread, oldest first.
struct CoachMessagePage: Decodable, Equatable, Sendable {
    var messages: [CoachStoredMessage]
    var hasMore: Bool
    var nextCursor: String?

    init(messages: [CoachStoredMessage] = [], hasMore: Bool = false, nextCursor: String? = nil) {
        self.messages = messages
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey { case messages, hasMore, nextCursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = c.lossyList(CoachStoredMessage.self, .messages)
        hasMore = c.lossy(Bool.self, .hasMore) ?? false
        nextCursor = c.lossy(String.self, .nextCursor)
    }
}

// MARK: - Sections

/// One group of the sidebar.
struct CoachThreadSection: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case pinned
        case folder(CoachFolder)
        case today, yesterday, previous7Days, previous30Days, older
    }

    let id: String
    let title: String
    let kind: Kind
    let threads: [CoachThread]
}

enum CoachThreadSections {
    /// Pinned → each folder (in its sort order, shown even when empty) → Today → Yesterday → Previous 7 Days →
    /// Previous 30 Days → Older. A pinned thread shows only under Pinned; a thread in a folder that no longer
    /// exists falls back to its date group. Each group is newest first; empty date groups are left out.
    static func sections(threads: [CoachThread], folders: [CoachFolder], now: Date = Date(),
                         calendar: Calendar = .current) -> [CoachThreadSection] {
        let newestFirst = threads.sorted { a, b in
            let da = a.activityDate ?? .distantPast, db = b.activityDate ?? .distantPast
            return da != db ? da > db : a.id < b.id
        }
        let folderIds = Set(folders.map(\.id))
        var out: [CoachThreadSection] = []

        let pinned = newestFirst.filter(\.pinned)
        if !pinned.isEmpty { out.append(CoachThreadSection(id: "pinned", title: "Pinned", kind: .pinned, threads: pinned)) }

        let orderedFolders = folders.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            let ca = CoachDates.parse(a.createdAt) ?? .distantPast, cb = CoachDates.parse(b.createdAt) ?? .distantPast
            return ca != cb ? ca < cb : a.id < b.id
        }
        for folder in orderedFolders {
            let members = newestFirst.filter { !$0.pinned && $0.folderId == folder.id }
            out.append(CoachThreadSection(id: "folder." + folder.id, title: folder.name, kind: .folder(folder), threads: members))
        }

        var buckets: [CoachThreadSection.Kind: [CoachThread]] = [:]
        let today = calendar.startOfDay(for: now)
        for thread in newestFirst where !thread.pinned && !(thread.folderId.map(folderIds.contains) ?? false) {
            let day = calendar.startOfDay(for: thread.activityDate ?? .distantPast)
            let age = calendar.dateComponents([.day], from: day, to: today).day ?? Int.max
            let kind: CoachThreadSection.Kind
            switch age {
            case ...0: kind = .today
            case 1: kind = .yesterday
            case 2...7: kind = .previous7Days
            case 8...30: kind = .previous30Days
            default: kind = .older
            }
            buckets[kind, default: []].append(thread)
        }
        let dated: [(CoachThreadSection.Kind, String, String)] = [
            (.today, "today", "Today"), (.yesterday, "yesterday", "Yesterday"),
            (.previous7Days, "previous7", "Previous 7 Days"), (.previous30Days, "previous30", "Previous 30 Days"),
            (.older, "older", "Older"),
        ]
        for (kind, id, title) in dated {
            if let members = buckets[kind], !members.isEmpty {
                out.append(CoachThreadSection(id: id, title: title, kind: kind, threads: members))
            }
        }
        return out
    }
}

extension CoachThreadSection.Kind: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .pinned: hasher.combine(0)
        case .folder(let f): hasher.combine(1); hasher.combine(f.id)
        case .today: hasher.combine(2)
        case .yesterday: hasher.combine(3)
        case .previous7Days: hasher.combine(4)
        case .previous30Days: hasher.combine(5)
        case .older: hasher.combine(6)
        }
    }
}

// MARK: - Titles

enum CoachThreadTitle {
    /// The title a new thread carries until the model names it: the first six words of the question,
    /// whitespace collapsed and trailing punctuation dropped. A photo with no text is "Photo".
    static func fallback(from question: String) -> String {
        let words = question.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty else { return "Photo" }
        var title = words.prefix(6).joined(separator: " ")
        while let last = title.last, ".,;:!?…-–—".contains(last) { title.removeLast() }
        if title.count > 60 {
            let cut = String(title.prefix(60))
            title = cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut
        }
        return title.isEmpty ? "Photo" : title
    }
}

// MARK: - Launch

enum CoachThreadLaunch {
    /// The thread the Coach tab opens on launch: the newest cached thread when it was active on the same local
    /// day, otherwise nil (a new chat).
    static func pick(threads: [CoachThread], now: Date = Date(), calendar: Calendar = .current) -> CoachThread? {
        let newest = threads.compactMap { t in t.activityDate.map { (t, $0) } }.max { $0.1 < $1.1 }
        guard let newest, calendar.isDate(newest.1, inSameDayAs: now) else { return nil }
        return newest.0
    }
}

// MARK: - Dates

enum CoachDates {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO 8601 with or without fractional seconds; Postgres' `+00:00` offset and a space separator are accepted.
    static func parse(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.count > 10, s[s.index(s.startIndex, offsetBy: 10)] == " " {
            s.replaceSubrange(s.index(s.startIndex, offsetBy: 10)...s.index(s.startIndex, offsetBy: 10), with: "T")
        }
        if let d = fractional.date(from: s) ?? whole.date(from: s) { return d }
        // More than millisecond precision (`.123456`), which the formatter rejects: trim to three digits.
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = s[s.index(after: dot)..<end]
            if digits.count > 3 {
                s.replaceSubrange(s.index(after: dot)..<end, with: digits.prefix(3))
                return fractional.date(from: s)
            }
        }
        return nil
    }

    static func string(_ date: Date) -> String { fractional.string(from: date) }

    /// `yyyy-MM-dd` in the given zone, the shape day keys and the context tools use.
    static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Lossy decoding

extension KeyedDecodingContainer {
    /// The value when present and well-formed, otherwise nil. Never throws.
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Decodes an array element by element, dropping any element that fails instead of failing the whole list.
    func lossyList<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [T] = []
        while !list.isAtEnd {
            if let value = try? list.decode(T.self) {
                out.append(value)
            } else if (try? list.decode(CoachSkippedValue.self)) == nil {
                break
            }
        }
        return out
    }
}

/// Consumes one element of any shape so a lossy list can step past it.
struct CoachSkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}
