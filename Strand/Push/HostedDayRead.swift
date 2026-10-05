import Foundation

extension ServerScoreRepository {

    /// The last cached day under the first of `deviceIds` that has one.
    func cachedDay(day: String, deviceIds: [String]) -> ServerScoreSnapshot? {
        for id in deviceIds {
            if let cached = cachedDay(day: day, deviceId: id) { return cached }
        }
        return nil
    }

    /// Fetch a day from the first of `deviceIds` the server has a result for.
    ///
    /// A result-less answer (the day is not scored yet under that device) moves on to the next id, and so does
    /// a failure; only when none had a result does the first answer (or the last failure) come back, so a
    /// caller still learns why there is nothing to show.
    @discardableResult
    func refresh(day: String, deviceIds: [String]) async throws -> ServerScoreSnapshot {
        var firstAnswer: ServerScoreSnapshot?
        var lastFailure: Error?
        for id in deviceIds {
            do {
                let snapshot = try await refresh(day: day, deviceId: id)
                if snapshot.hostedResult != nil || snapshot.status == .populated { return snapshot }
                firstAnswer = firstAnswer ?? snapshot
            } catch {
                lastFailure = error
            }
        }
        if let firstAnswer { return firstAnswer }
        throw lastFailure ?? ReadError.missingIdentity
    }
}

/// Reads one day's published server result from the first device id that has one.
///
/// A strap can be known to the server under more than one device id: its own `whoop-<serial>` and the
/// installation-scoped id an earlier build uploaded under. Asking only one of them is how a day that exists
/// server-side shows up empty in the app, so the read walks the candidates in order and stops at the first
/// that returns a result. What each candidate did is reported, so a day that stays empty is explained
/// rather than silently absent.
struct HostedDayRead {

    /// How one candidate answered, in a form that is safe to put in a shareable log (never a URL, id or body).
    enum Attempt: Equatable {
        case result
        case noResult
        case failed(String)
    }

    struct Outcome {
        let day: String
        let result: HostedDayResult?
        /// The candidate that supplied `result`, nil when none did.
        let servedBy: String?
        /// One entry per candidate asked, in order.
        let attempts: [(deviceId: String, attempt: Attempt)]

        var failureTokens: [String] {
            attempts.compactMap { if case .failed(let token) = $0.attempt { return token } else { return nil } }
        }

        /// No candidate had a result and at least one failed in a way that asking again could fix.
        var failedTransiently: Bool {
            result == nil && failureTokens.contains(where: HostedDayRead.isTransient)
        }
    }

    /// Whether a failure token describes something that can clear on its own: the network, a busy or failing
    /// server, or a cancelled request. A refused or unknown day will answer the same way next time.
    static func isTransient(_ token: String) -> Bool {
        if token.hasPrefix("network") || token == "cancelled" || token == "error" { return true }
        guard token.hasPrefix("http-"), let status = Int(token.dropFirst("http-".count)) else { return false }
        return status >= 500 || status == 408 || status == 425 || status == 429
    }

    static func read(day: String,
                     candidates: [String],
                     fetch: (_ deviceId: String) async throws -> HostedDayResult?) async -> Outcome {
        var attempts: [(deviceId: String, attempt: Attempt)] = []
        for candidate in candidates {
            do {
                if let result = try await fetch(candidate) {
                    attempts.append((candidate, .result))
                    return Outcome(day: day, result: result, servedBy: candidate, attempts: attempts)
                }
                attempts.append((candidate, .noResult))
            } catch {
                attempts.append((candidate, .failed(failureToken(for: error))))
            }
        }
        return Outcome(day: day, result: nil, servedBy: nil, attempts: attempts)
    }

    /// A short, secret-free description of why a read failed.
    static func failureToken(for error: Error) -> String {
        if let read = error as? ServerScoreRepository.ReadError {
            switch read {
            case .notConfigured: return "not-configured"
            case .missingIdentity: return "no-identity"
            case .http(let status, _): return "http-\(status)"
            case .malformed: return "malformed"
            case .ownershipMismatch: return "owner-mismatch"
            }
        }
        if error is CancellationError { return "cancelled" }
        if let url = error as? URLError { return "network\(url.code.rawValue)" }
        return "error"
    }

    /// One log line for a whole sync pass, or nil when there is nothing worth saying.
    ///
    /// Quiet when every requested day was served (nothing to explain). When days were not, it names how many
    /// and why, so "my history is missing" always has a line in the strap log to point at.
    static func summaryLine(outcomes: [Outcome], written: Int, candidateCount: Int) -> String? {
        guard !outcomes.isEmpty else { return nil }
        let served = outcomes.filter { $0.result != nil }
        let fromFallback = served.filter { $0.servedBy != nil && $0.attempts.first?.attempt != .result }.count
        let empty = outcomes.filter { $0.result == nil }
        let failed = empty.filter { !$0.failureTokens.isEmpty }
        if empty.isEmpty && written == 0 && fromFallback == 0 { return nil }
        var parts = ["Cloud: server results — \(served.count)/\(outcomes.count) day(s) available"]
        if written > 0 { parts.append("\(written) stored") }
        if fromFallback > 0 { parts.append("\(fromFallback) from the installation id") }
        if !empty.isEmpty {
            var tokens: [String: Int] = [:]
            for outcome in failed { for token in Set(outcome.failureTokens) { tokens[token, default: 0] += 1 } }
            let noResult = empty.count - failed.count
            if noResult > 0 { parts.append("\(noResult) with no result") }
            if !tokens.isEmpty {
                let detail = tokens.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                parts.append("\(failed.count) unreadable (\(detail))")
            }
        }
        if candidateCount > 1 { parts.append("asked \(candidateCount) ids") }
        return parts.joined(separator: " · ")
    }
}

/// Days whose server result could not be read on the pass that was asked for them, and so have to be asked for
/// again.
///
/// The server's change feed moves its cursor as soon as a page is polled. A day it announced and whose read then
/// failed (a dropped connection, a busy server) is never announced a second time, so without this it would stay
/// empty in the app until the next launch's catch-up, or for good if it is older than that. A day stays here
/// only while its failure looks temporary, and for a bounded number of passes.
struct HostedRetryLedger: Equatable {
    static let attempts = 8

    private var attemptsLeft: [String: Int] = [:]

    var days: [String] { attemptsLeft.keys.sorted() }
    var isEmpty: Bool { attemptsLeft.isEmpty }

    /// Note how a pass went: a day that was served, or failed for good, is done with; one that failed in a way that
    /// can clear is kept, with one fewer attempt left.
    mutating func record(_ outcomes: [HostedDayRead.Outcome]) {
        for outcome in outcomes {
            guard outcome.failedTransiently else {
                attemptsLeft[outcome.day] = nil
                continue
            }
            spendAttempt(on: outcome.day)
        }
    }

    /// A day whose result was read but could not be written to the store. Call after `record`, which would
    /// otherwise see the read succeed and let the day go.
    mutating func recordStoreFailure(day: String) {
        spendAttempt(on: day)
    }

    private mutating func spendAttempt(on day: String) {
        let remaining = (attemptsLeft[day] ?? Self.attempts) - 1
        attemptsLeft[day] = remaining > 0 ? remaining : nil
    }
}
