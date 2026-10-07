import Foundation
import StrandAnalytics

/// One guided calibration session's labels and the span its observations are read over.
struct CalibrationSessionSpan: Sendable {
    let id: String
    let labels: [ActivityGroundTruthLabel]
    let from: Int
    let to: Int
}

@MainActor private enum PersonalProfileRefit {
    static var running = false
    static var again = false
}

extension Repository {
    /// Observations start this long before a run's first label, so the decoder's trailing windows and its
    /// belief have settled by the time the first labelled second is scored.
    static let personalProfileLeadInS = 600

    /// Fit the wearer's personal profile from every guided calibration run on the phone and store the result
    /// (adopted, or why the defaults were kept). Skipped when nothing it would read changed since the last
    /// fit, unless `force`. A call while a fit runs makes that fit go round once more when it finishes, so
    /// labels saved meanwhile are never left out. Returns the stored record; nil without an account and strap.
    @discardableResult
    func refitActivityPersonalProfileIfNeeded(force: Bool = false) async -> ActivityPersonalProfileStore.Record? {
        let store = ActivityPersonalProfileStore.shared
        if PersonalProfileRefit.running {
            PersonalProfileRefit.again = true
            return store.record()
        }
        PersonalProfileRefit.running = true
        defer { PersonalProfileRefit.running = false }
        var record: ActivityPersonalProfileStore.Record?
        var forced = force
        repeat {
            PersonalProfileRefit.again = false
            record = await refitPersonalProfileOnce(force: forced)
            forced = false
        } while PersonalProfileRefit.again
        return record
    }

    private func refitPersonalProfileOnce(force: Bool) async -> ActivityPersonalProfileStore.Record? {
        let store = ActivityPersonalProfileStore.shared
        guard let scope = store.currentScope else { return nil }
        let base = activityBaseDecoderConfig
        let labels = ActivityGroundTruthStore.shared.all()
        let sessions = Self.calibrationSessions(labels)
        let fingerprint = await Task.detached(priority: .utility) {
            Self.personalProfileFingerprint(sessions, config: base)
        }.value
        if !force, let stored = store.record(), stored.fingerprint == fingerprint { return stored }

        var inputs: [(session: CalibrationSessionSpan, input: ActivityContextTrackInput)] = []
        for session in sessions {
            guard let input = await calibrationTrackInput(session, config: base) else { continue }
            inputs.append((session, input))
        }
        let now = Int(Date().timeIntervalSince1970)
        let result = await Task.detached(priority: .utility) {
            let runs = inputs.map { entry in
                ActivityCalibrationRun(
                    sessionId: entry.session.id,
                    observations: ActivityContextTrackBuilder.observations(for: entry.input, config: base).observations,
                    labels: entry.session.labels)
            }
            return ActivityPersonalProfileFitter.fit(runs: runs, config: base, now: now)
        }.value
        let record = ActivityPersonalProfileStore.Record(fingerprint: fingerprint, result: result)
        store.save(record, scope: scope)
        return record
    }

    /// The strap's streams over one calibration run (with lead-in) in decoder-input form, with the HART and
    /// ElderNet windows the phone holds for it. nil when the strap recorded nothing there.
    private func calibrationTrackInput(_ session: CalibrationSessionSpan,
                                       config: ActivityDecoderConfig) async -> ActivityContextTrackInput? {
        guard let signals = await stretchSignals(from: session.from, to: session.to),
              !signals.gravity.isEmpty || !signals.hr.isEmpty else { return nil }
        var input = ActivityContextTrackInput(
            dayStart: session.from, dayEnd: session.to,
            hr: signals.hr, gravity: signals.gravity, steps: signals.steps,
            sleepKnownOutsideSessions: true)
        if let encoder = ActivityEncoderWindowStore.shared.windows(from: session.from, to: session.to) {
            input.encoderWindows = encoder.windows
            input.imuWindows = encoder.features
            input.encoderId = encoder.encoderId
            input.encoderVersion = encoder.encoderVersion
            input.transitionWindows = encoder.transitions
        }
        if let gait = config.gaitQuality,
           let windows = GaitWindowStore.shared.trackInput(from: session.from, to: session.to, model: gait.model) {
            input.gaitQuality = windows
        }
        return input
    }

    /// Guided labels grouped by session, each with the span to read: lead-in before its first label to a few
    /// seconds past its last.
    nonisolated static func calibrationSessions(_ labels: [ActivityGroundTruthLabel]) -> [CalibrationSessionSpan] {
        var bySession: [String: [ActivityGroundTruthLabel]] = [:]
        for label in labels where label.source == .guided {
            guard let id = label.sessionId, !id.isEmpty else { continue }
            bySession[id, default: []].append(label)
        }
        return bySession.keys.sorted().compactMap { id in
            let rows = bySession[id] ?? []
            guard let first = rows.map(\.startTs).min(), let last = rows.map(\.endTs).max() else { return nil }
            return CalibrationSessionSpan(id: id, labels: rows.sorted { $0.startTs < $1.startTs },
                                          from: first - personalProfileLeadInS, to: last + 5)
        }
    }

    /// What a fit would read: the labels (id and edit time), how many HART and ElderNet windows cover each run,
    /// the base decoder's tag and the profile version. Equal fingerprints mean a refit would repeat the last one.
    nonisolated static func personalProfileFingerprint(_ sessions: [CalibrationSessionSpan],
                                                       config: ActivityDecoderConfig) -> String {
        var text = "\(ActivityPersonalProfile.currentVersion)|\(config.cacheTag)"
        for session in sessions {
            text += "|\(session.id):"
            for label in session.labels {
                text += "\(label.id.uuidString)@\(Int(label.updatedAt.timeIntervalSince1970)),"
            }
            let hart = ActivityEncoderWindowStore.shared.windows(from: session.from, to: session.to)?.windows.count ?? 0
            var gait = 0
            if let model = config.gaitQuality?.model {
                gait = GaitWindowStore.shared.trackInput(from: session.from, to: session.to, model: model)?.windows.count ?? 0
            }
            text += "h\(hart)g\(gait)"
        }
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
