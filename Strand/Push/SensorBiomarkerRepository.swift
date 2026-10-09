import Foundation
import CryptoKit
import SwiftUI

// SensorBiomarkerRepository.swift — the phone's read side of the supplemental sensor-biomarker
// documents (spec-31 §8/§9, CONTRACTS.md §1/§2/§6).
//
// The server owns every number here. The phone reads ONE route on the `scores` edge function:
//
//   GET {scores}/sensor-biomarkers?day=YYYY-MM-DD&deviceId=<id>   → { sensor_biomarkers: <document>, identity }
//
// The outer envelope is read with JSONSerialization (unknown members are ignored, absent ones
// tolerated); the document is the CONTRACTS §3 JSONB shape (schema_version, analysis_version,
// input_revision, interval bounds, processed_at, families). A 200 with `sensor_biomarkers: null`
// means the server has no document for the day — that is a "no data" state, never a zeroed result.
// Results are cached per (owner, device, day) on disk (owner-checked, atomic, pruned), exactly like
// `ServerScoreRepository` and `PhysiologyContextRepository`. Nothing here computes a number.

// MARK: - Feature flag

/// The enabled-by-default gate for the sensor-biomarker section (spec-31 §9, CONTRACTS §1).
///
/// Absent means ON; a stored false means OFF: no route is called and no section renders. This is the
/// iOS-side settings/debug gate; the worker-side `FRWHOOP_*` env flags are separate and live on the
/// server. The key follows the app's `noop.`-prefixed preference convention.
public enum SensorBiomarkerFeature {
    /// The exact UserDefaults key: `noop.sensorBiomarkersEnabled` (default ON).
    public static let enabledKey = "noop.sensorBiomarkersEnabled"

    /// The value an absent key reads as; `@AppStorage` readers of the key use the same default.
    public static let defaultEnabled = true

    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled }

    /// Test seam / settings hook. Absent is identical to true, so turning it off stores false.
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}

// MARK: - Document model

/// One measurement entry from a family's `measurements` object (CONTRACTS §2/§3). Every entry
/// carries a finite value or null, a unit where relevant, a denominator, a count and provenance.
/// A null value is a REAL absence (the family said so), never a fabricated zero.
public struct SensorBiomarkerMeasurement: Sendable, Equatable {
    public let key: String
    public let value: Double?
    public let unit: String?
    public let denominator: String?
    public let count: Int?
    public let method: String?
    /// Native sensor sample rate in Hz when the server reported one (pulse shape, quality).
    public let nativeRateHz: Double?
    /// A server-provided native timing resolution string (e.g. "40 ms per sample") when the server
    /// reported one without a numeric rate. Numeric `native_rate_hz` wins in the UI.
    public let nativeTimingResolution: String?
    /// Opaque optical configuration identity (pulse shape; amplitudes are not comparable across
    /// configurations, so the UI shows which one a measurement belongs to).
    public let configuration: String?

    public init(key: String, value: Double?, unit: String?, denominator: String?, count: Int?,
                method: String?, nativeRateHz: Double?, nativeTimingResolution: String?,
                configuration: String?) {
        self.key = key
        self.value = value
        self.unit = unit
        self.denominator = denominator
        self.count = count
        self.method = method
        self.nativeRateHz = nativeRateHz
        self.nativeTimingResolution = nativeTimingResolution
        self.configuration = configuration
    }
}

/// One family of a day document (CONTRACTS §3): independent status, coverage and measurements.
/// Families are independent: a failed optional family never discards valid ones.
public struct SensorBiomarkerFamily: Sendable, Equatable {
    public let key: String
    /// `ok`, `withheld` or `error` (CONTRACTS §3). Any non-`ok` family must never render a measured zero.
    public let status: String
    public let releaseTier: String?
    public let providerRevision: String?
    public let observedSeconds: Double?
    public let eligibleSeconds: Double?
    public let contactState: String?
    /// Precise withheld reason (`unknown_wrist_placement`, `missing_ppg_anchor`, ...) or nil.
    public let reason: String?
    public let reasonCounts: [String: Int]
    public let measurements: [String: SensorBiomarkerMeasurement]

    /// Whether the family published usable measurements. The ONLY status that may render values.
    public var isUsable: Bool { status == "ok" }

    public init(key: String, status: String, releaseTier: String?, providerRevision: String?,
                observedSeconds: Double?, eligibleSeconds: Double?, contactState: String?,
                reason: String?, reasonCounts: [String: Int],
                measurements: [String: SensorBiomarkerMeasurement]) {
        self.key = key
        self.status = status
        self.releaseTier = releaseTier
        self.providerRevision = providerRevision
        self.observedSeconds = observedSeconds
        self.eligibleSeconds = eligibleSeconds
        self.contactState = contactState
        self.reason = reason
        self.reasonCounts = reasonCounts
        self.measurements = measurements
    }
}

/// One owner-scoped sensor-biomarker day, as the edge served it (CONTRACTS §3).
///
/// The raw decoded JSON is RETAINED alongside the typed fields: the server contract has more
/// members than this type models, and silently dropping what is not modelled would make a future
/// UI change look like a server change.
public struct SensorBiomarkerDocument: Sendable, Equatable {
    public let day: String
    public let deviceId: String
    public let schemaVersion: Int?
    public let analysisVersion: String?
    public let inputRevision: String?
    public let intervalStartUTC: String?
    public let intervalEndUTC: String?
    public let processedAtUTC: String?
    public let families: [String: SensorBiomarkerFamily]
    /// Fetched-at (unix ms), from the cache envelope. 0 for a fresh network read.
    public let fetchedAtMs: Int
    public let rawJSON: Data

    public init(day: String, deviceId: String, schemaVersion: Int?, analysisVersion: String?,
                inputRevision: String?, intervalStartUTC: String?, intervalEndUTC: String?,
                processedAtUTC: String?, families: [String: SensorBiomarkerFamily],
                fetchedAtMs: Int, rawJSON: Data) {
        self.day = day
        self.deviceId = deviceId
        self.schemaVersion = schemaVersion
        self.analysisVersion = analysisVersion
        self.inputRevision = inputRevision
        self.intervalStartUTC = intervalStartUTC
        self.intervalEndUTC = intervalEndUTC
        self.processedAtUTC = processedAtUTC
        self.families = families
        self.fetchedAtMs = fetchedAtMs
        self.rawJSON = rawJSON
    }
}

// MARK: - Repository

public actor SensorBiomarkerRepository {

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case notConfigured
        case missingIdentity
        case http(Int, String?)
        case malformed(String)
        /// The day document exceeded the CONTRACTS §6 256 KiB budget and was rejected.
        case oversized(Int)

        public var description: String {
            switch self {
            case .notConfigured: return "cloud: scores endpoint not configured"
            case .missingIdentity: return "cloud: no installation identity"
            case .http(let code, _): return "cloud: sensor-biomarkers HTTP \(code)"
            case .malformed(let why): return "cloud: malformed sensor-biomarkers response: \(why)"
            case .oversized(let bytes): return "cloud: sensor-biomarkers document \(bytes) bytes exceeds the 256 KiB budget"
            }
        }
    }

    /// The per-day document budget (CONTRACTS §6). Anything larger is rejected, network or cached.
    public static let maxDocumentBytes = 256 * 1024
    /// Bounded retry: at most this many retries after a transient failure (network, 5xx).
    public static let maxRetries = 2
    /// Base backoff for the bounded retry, scaled by attempt (0.5 s, 1 s).
    public static let retryDelayBaseNanoseconds: UInt64 = 500_000_000
    /// Cache entries older than this are deleted on the next write.
    static let cacheRetention: TimeInterval = 14 * 86_400

    private let session: URLSession
    private let endpoint: URL?
    private let identity: @Sendable () -> CloudPushIdentity?
    private let directory: URL
    private let now: @Sendable () -> Int
    private let maxRetries: Int
    private let retryDelay: @Sendable (Int) -> UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void

    /// `identity` supplies the credential to read with. The app passes one bound to the running
    /// account's scope (`CloudPushRuntime.credentialProvider`), so a repository made for account A
    /// never reads with B's. `maxRetries`/`retryDelay`/`sleep` are injectable so a test can run the
    /// bounded-retry path without sleeping.
    public init(session: URLSession = .shared,
                endpoint: URL? = nil,
                directory: URL? = nil,
                identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() },
                now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
                maxRetries: Int = SensorBiomarkerRepository.maxRetries,
                retryDelay: @escaping @Sendable (Int) -> UInt64 = { UInt64($0) * SensorBiomarkerRepository.retryDelayBaseNanoseconds },
                sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.session = session
        self.endpoint = endpoint ?? SensorBiomarkerRepository.derivedEndpoint()
        self.directory = directory ?? ((try? CloudJournalPaths.defaultDirectory())
            .map { $0.appendingPathComponent("sensor-biomarkers", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("noop-sensor-biomarkers",
                                                                              isDirectory: true))
        self.identity = identity
        self.now = now
        self.maxRetries = max(0, maxRetries)
        self.retryDelay = retryDelay
        self.sleep = sleep
    }

    /// The `scores` edge route, derived from the push receiver exactly as `ServerScoreRepository`
    /// derives it; the sensor-biomarkers route lives on the same function host.
    public static func derivedEndpoint() -> URL? { ServerScoreRepository.derivedEndpoint() }

    // MARK: - Reads

    /// Fetch one day from the server, validate it (256 KiB budget, contract shape), then cache it.
    /// Returns nil when the server explicitly has no document for the day (`sensor_biomarkers: null`).
    /// Throws `notConfigured` (touching no network) when this build carries no receiver.
    @discardableResult
    public func refresh(day: String, deviceId: String) async throws -> SensorBiomarkerDocument? {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }

        var components = URLComponents(url: endpoint.appendingPathComponent("sensor-biomarkers"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "day", value: day),
                                  URLQueryItem(name: "deviceId", value: deviceId)]
        guard let url = components?.url else { throw ReadError.malformed("endpoint") }

        do {
            let body = try await get(url: url, identity: identity)
            guard let document = try SensorBiomarkerRepository.parse(day: day, deviceId: deviceId,
                                                                     envelope: body, fetchedAtMs: 0) else {
                return nil   // the server explicitly has no document for the day
            }
            writeCache(document, ownerId: identity.ownerId, deviceId: deviceId)
            return document
        } catch ReadError.http(let status, _) where status == 404 {
            // The route's explicit absent answer: no stored document for the day. That is
            // "no data", never a failed refresh and never a retried error (CONTRACTS §6).
            return nil
        }
    }

    /// The cached day for the CURRENT owner. A pure local read: no network, and no configuration
    /// requirement, because showing the last known result offline is the point of the cache.
    ///
    /// A cache written by a DIFFERENT owner is not returned and is NOT deleted: the previous owner's
    /// results must still be there if they sign back in.
    public func cachedDay(day: String, deviceId: String) -> SensorBiomarkerDocument? {
        guard let ownerId = identity()?.ownerId else { return nil }
        let url = cacheURL(ownerId: ownerId, deviceId: deviceId, day: day)
        guard let data = try? Data(contentsOf: url),
              data.count <= Self.maxDocumentBytes + 8192,   // cheap guard before parsing a blob
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storedOwner = envelope["ownerId"] as? String,
              storedOwner.lowercased() == ownerId.lowercased(),
              let payload = envelope["payload"] as? [String: Any] else { return nil }
        let fetchedAt = (envelope["fetchedAtMs"] as? NSNumber)?.intValue ?? 0
        // The cache stores the INNER document, so it is re-wrapped before parsing: `parse` expects
        // the edge's `{ "sensor_biomarkers": … }` envelope, and a cached read must produce exactly
        // the same result as the network read that wrote it — including the oversized rejection.
        return try? SensorBiomarkerRepository.parse(day: day, deviceId: deviceId,
                                                    envelope: ["sensor_biomarkers": payload],
                                                    fetchedAtMs: fetchedAt)
    }

    /// Drop a cached day (used when a local edit makes it stale).
    public func invalidate(day: String, deviceId: String) {
        guard let ownerId = identity()?.ownerId else { return }
        try? FileManager.default.removeItem(at: cacheURL(ownerId: ownerId, deviceId: deviceId, day: day))
    }

    // MARK: - Transport

    /// GET with the account's credential through the same `CloudReceiverAuth` path as every other
    /// score read, with a BOUNDED retry: transient failures (network, HTTP 5xx) are retried at most
    /// `maxRetries` times with a short backoff. 4xx, malformed and cancellation are never retried.
    private func get(url: URL, identity: CloudPushIdentity) async throws -> [String: Any] {
        var lastError: Error = ReadError.malformed("no response")
        for attempt in 0...maxRetries {
            do {
                return try await getOnce(url: url, identity: identity)
            } catch ReadError.http(let status, let body) where (500...599).contains(status) {
                lastError = ReadError.http(status, body)
            } catch let error as URLError {
                guard error.code != .cancelled else { throw error }
                lastError = error
            } catch {
                throw error
            }
            guard attempt < maxRetries else { break }
            try await sleep(retryDelay(attempt + 1))
        }
        throw lastError
    }

    private func getOnce(url: URL, identity: CloudPushIdentity) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        CloudReceiverAuth.apply(identity, to: &request)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReadError.malformed("no response") }
        guard http.statusCode == 200 else {
            throw ReadError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.malformed("not a JSON object")
        }
        return object
    }

    // MARK: - Parsing

    /// Turn the edge envelope into a document. The route's wire shape (serverScores.ts
    /// `readSensorBiomarkers`, pinned by the route tests and mirrored by the cross-layer
    /// fixture test) is `{ days: [ { day, document, ...row } ], identity }` with an HTTP 404
    /// when no requested day has a stored document. Returns nil for an explicit no-document
    /// answer (`days: []`); throws for a 200 that does not speak the contract or that exceeds
    /// the 256 KiB budget. Every member is optional and one bad family never costs the rest.
    static func parse(day: String, deviceId: String, envelope: [String: Any],
                      fetchedAtMs: Int) throws -> SensorBiomarkerDocument? {
        let raw: [String: Any]
        if let days = envelope["days"] as? [[String: Any]] {
            // The route shape: one row per stored day; the row's `document` is the day document.
            guard let row = days.first(where: { ($0["day"] as? String) == day }) else {
                return nil   // the requested day has no stored document
            }
            guard let document = row["document"] as? [String: Any] else {
                throw ReadError.malformed("days row without a document")
            }
            raw = document
        } else if let object = envelope["sensor_biomarkers"] as? [String: Any] {
            // Tolerated legacy/test shape: the document under a `sensor_biomarkers` key.
            raw = object
        } else if envelope["sensor_biomarkers"] == nil && Self.looksLikeDocument(envelope) {
            // Tolerated: a bare top-level document.
            raw = envelope
        } else if envelope["sensor_biomarkers"] is NSNull {
            return nil
        } else {
            throw ReadError.malformed("neither a days envelope nor a document")
        }

        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else {
            throw ReadError.malformed("document is not JSON")
        }
        guard data.count <= maxDocumentBytes else {
            throw ReadError.oversized(data.count)
        }
        guard let familiesRaw = raw["families"] as? [String: Any] else {
            throw ReadError.malformed("document has no families")
        }
        var families: [String: SensorBiomarkerFamily] = [:]
        for (name, value) in familiesRaw {
            if let family = parseFamily(key: name, object: value) { families[name] = family }
        }
        func string(_ key: String) -> String? { (raw[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func integer(_ key: String) -> Int? {
            guard let number = raw[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.intValue
        }
        return SensorBiomarkerDocument(
            day: day, deviceId: deviceId,
            schemaVersion: integer("schema_version"),
            analysisVersion: string("analysis_version"),
            inputRevision: string("input_revision"),
            intervalStartUTC: string("interval_start_utc"),
            intervalEndUTC: string("interval_end_utc"),
            processedAtUTC: string("processed_at_utc"),
            families: families,
            fetchedAtMs: fetchedAtMs,
            rawJSON: data)
    }

    static func looksLikeDocument(_ object: [String: Any]) -> Bool {
        object["families"] is [String: Any] && object["schema_version"] != nil
    }

    static func parseFamily(key: String, object: Any) -> SensorBiomarkerFamily? {
        guard let dict = object as? [String: Any] else { return nil }
        func string(_ name: String) -> String? { (dict[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func double(_ name: String) -> Double? {
            guard let number = dict[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        func integer(_ name: String) -> Int? {
            guard let number = dict[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.intValue
        }

        var measurements: [String: SensorBiomarkerMeasurement] = [:]
        if let raw = dict["measurements"] as? [String: Any] {
            for (name, value) in raw {
                if let measurement = parseMeasurement(key: name, object: value) {
                    measurements[name] = measurement
                }
            }
        }
        var reasonCounts: [String: Int] = [:]
        if let raw = dict["reason_counts"] as? [String: Any] {
            for (name, value) in raw {
                if let count = integer(name), count >= 0 { reasonCounts[name] = count }
            }
        }
        // Native rate / configuration may ride at family level or per measurement; the family-level
        // value (when present) is the authoritative one the UI quotes for the whole family.
        let familyNativeRate = double("native_rate_hz") ?? double("native_resolution_hz")
        let familyNativeTiming = string("native_timing_resolution") ?? string("native_resolution")
        let familyConfiguration = string("configuration") ?? string("config")
        let decorated = measurements.mapValues { measurement in
            SensorBiomarkerMeasurement(
                key: measurement.key,
                value: measurement.value,
                unit: measurement.unit,
                denominator: measurement.denominator,
                count: measurement.count,
                method: measurement.method,
                nativeRateHz: measurement.nativeRateHz ?? familyNativeRate,
                nativeTimingResolution: measurement.nativeTimingResolution ?? familyNativeTiming,
                configuration: measurement.configuration ?? familyConfiguration)
        }
        return SensorBiomarkerFamily(
            key: key,
            status: dict["status"] as? String ?? "unknown",
            releaseTier: string("release_tier"),
            providerRevision: string("provider_revision"),
            observedSeconds: double("observed_seconds"),
            eligibleSeconds: double("eligible_seconds"),
            contactState: string("contact_state"),
            reason: string("reason"),
            reasonCounts: reasonCounts,
            measurements: decorated)
    }

    static func parseMeasurement(key: String, object: Any) -> SensorBiomarkerMeasurement? {
        guard let dict = object as? [String: Any] else { return nil }
        func string(_ name: String) -> String? { (dict[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func double(_ name: String) -> Double? {
            guard let number = dict[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        func integer(_ name: String) -> Int? {
            guard let number = dict[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.intValue
        }
        return SensorBiomarkerMeasurement(
            key: key,
            value: double("value"),
            unit: string("unit"),
            denominator: string("denominator"),
            count: integer("count"),
            method: string("method"),
            nativeRateHz: double("native_rate_hz") ?? double("native_resolution_hz"),
            nativeTimingResolution: string("native_timing_resolution") ?? string("native_resolution"),
            configuration: string("configuration") ?? string("config"))
    }

    // MARK: - Cache

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        // Written from background wakes as well, so it takes the same after-first-unlock protection
        // as the store and the journal (see Strand/Collect/StorePaths.swift for the original reasoning).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
        #endif
    }

    /// Cache file name: a digest of owner+device+day, so no user data appears in a path.
    private func cacheURL(ownerId: String, deviceId: String, day: String) -> URL {
        let name = "\(ownerId.lowercased())|\(deviceId.lowercased())|\(day)"
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    private func writeCache(_ document: SensorBiomarkerDocument, ownerId: String, deviceId: String) {
        ensureDirectory()
        pruneCache()
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "ownerId": ownerId,
            "deviceId": deviceId,
            "day": document.day,
            "fetchedAtMs": now(),
            "inputRevision": document.inputRevision ?? "",
            "payload": (try? JSONSerialization.jsonObject(with: document.rawJSON)) ?? [:],
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return }
        let target = cacheURL(ownerId: ownerId, deviceId: deviceId, day: document.day)
        let temporary = target.appendingPathExtension("tmp")
        // Atomic: a reader never observes a half-written cache entry.
        do {
            try data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    /// A day's entry is not read again once the day is weeks old, so old entries are deleted, not kept.
    private func pruneCache() {
        let cutoff = Date().addingTimeInterval(-Self.cacheRetention)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}

// MARK: - Store

/// The section's view of the sensor-biomarker day: the last read per day, kept in memory so reopening
/// a day paints at once, backed by the repository's on-disk owner-scoped cache so a cold launch (or no
/// network) still shows the last document the server published.
///
/// The server owns every value here; nothing is computed on the phone. `reset()` is called when the
/// signed-in account ends (the same clearing path as `IntradaySeriesStore`/`PhysiologyContextStore`),
/// so nothing read with one account's credential stays on screen for the next one. The on-disk cache
/// is owner-keyed and survives sign-out, exactly like the other score caches.
@MainActor
final class SensorBiomarkerStore: ObservableObject {
    static let shared = SensorBiomarkerStore()

    /// What the store reads its preconditions and repository from (injectable for tests).
    struct Environment {
        var featureEnabled: @MainActor () -> Bool
        var cloudEnabled: @MainActor () -> Bool
        var repository: @MainActor () -> SensorBiomarkerRepository?

        static let live = Environment(
            featureEnabled: { SensorBiomarkerFeature.isEnabled },
            cloudEnabled: { CloudPushSettings.isEnabled && CloudPushSettings.isConfigured },
            repository: { SensorBiomarkerStore.runningAccountRepository() })
    }

    /// One day's state. Every load ends in a definite state; a read that cannot start says so
    /// instead of sitting on "Loading…" forever.
    enum State: Equatable {
        case idle
        case loading
        case available(SensorBiomarkerDocument)
        /// The server has no document for the day (and none is queued).
        case noData
        /// Cloud off, signed out, or the account's cloud path has not started yet.
        case unavailable(reason: String)
        /// The last read failed; whatever was shown before (if anything) is kept.
        case failed(cached: SensorBiomarkerDocument?, message: String)

        var shownDocument: SensorBiomarkerDocument? {
            switch self {
            case .available(let document): return document
            case .failed(let document, _): return document
            default: return nil
            }
        }
    }

    @Published private(set) var states: [String: State] = [:]
    /// Bumped on account change / read-candidate change; the section keys its load on it.
    @Published private(set) var epoch = 0
    /// The registered device the route resolves the owner through (the app keeps this equal to the
    /// strap it reads scores for, `AppModel.hostedReadDeviceId`).
    private(set) var readDeviceId = "my-whoop"
    private var readCandidates = ["my-whoop"]
    /// Stale-response guard: a read captures it before its await and writes only if it is unchanged
    /// afterwards, so a response read with one account's credential never lands in the next
    /// account's screens.
    private var generation = 0
    private var inFlight: Set<String> = []
    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// Point the section at the ids the app model reads. `candidates` is best first and never empty.
    func setReadCandidates(_ candidates: [String]) {
        guard let first = candidates.first else { return }
        let changed = candidates != readCandidates
        readDeviceId = first
        readCandidates = candidates
        if changed { epoch &+= 1 }
    }

    /// Forget everything shown. Called when the signed-in account ends: what is on screen was read
    /// with the previous account's credential and must not be visible to the next one.
    func reset() {
        generation &+= 1
        epoch &+= 1
        states = [:]
        inFlight = []
        readDeviceId = "my-whoop"
        readCandidates = ["my-whoop"]
        Self.liveRepository = nil
    }

    func state(for day: String) -> State? { states[day] }

    /// Show the cached document at once (when nothing is shown yet), then read the server. Always
    /// ends in a definite state. A no-op when the feature flag is off: no route is ever called.
    func load(day: String) async {
        guard environment.featureEnabled() else { return }
        guard environment.cloudEnabled() else {
            states[day] = .unavailable(reason: Self.cloudOffMessage)
            return
        }
        guard let repository = environment.repository() else {
            states[day] = .unavailable(reason: Self.notSignedInMessage)
            return
        }
        guard !inFlight.contains(day) else { return }
        let started = generation
        inFlight.insert(day)
        defer { if started == generation { inFlight.remove(day) } }

        // Cached first (a pure local read), then the server. A settled answer stays on screen while
        // a re-read runs; only a first read shows loading.
        if states[day] == nil || states[day] == .idle {
            states[day] = .loading
            if let cached = await repository.cachedDay(day: day, deviceId: readDeviceId),
               started == generation {
                states[day] = .available(cached)
            }
        }
        do {
            let document = try await repository.refresh(day: day, deviceId: readDeviceId)
            guard started == generation else { return }
            states[day] = document.map { .available($0) } ?? .noData
        } catch {
            guard !Task.isCancelled, started == generation else { return }
            states[day] = .failed(cached: states[day]?.shownDocument, message: Self.describe(error))
        }
    }

    // MARK: - Live repository

    /// One repository per running account, reading with that account's own credential only.
    private static var liveRepository: (scope: CloudDataScope, repository: SensorBiomarkerRepository)?

    static func runningAccountRepository() -> SensorBiomarkerRepository? {
        guard let scope = CloudPushRuntime.shared.runningScope else { return nil }
        if let live = liveRepository, live.scope == scope { return live.repository }
        let created = SensorBiomarkerRepository(identity: CloudPushRuntime.credentialProvider(for: scope))
        liveRepository = (scope, created)
        return created
    }

    static var cloudOffMessage: String { String(localized: "Sensor biomarkers need cloud sync to be on.") }
    static var notSignedInMessage: String { String(localized: "Sign in to your Nara account to see sensor biomarkers.") }

    /// A short, log-safe reason (never a URL, id or body).
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let e as SensorBiomarkerRepository.ReadError:
            switch e {
            case .notConfigured: return "not-configured"
            case .missingIdentity: return "no-credential"
            case .http(let code, _): return "http-\(code)"
            case .malformed: return "malformed"
            case .oversized: return "oversized"
            }
        case let e as URLError: return "network-\(e.code.rawValue)"
        default: return "error"
        }
    }
}
