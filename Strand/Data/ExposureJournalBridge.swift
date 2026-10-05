import Foundation
import GRDB
import StrandAnalytics

// MARK: - Journal and caffeine → exposure event revisions

/// Turns the existing journal and caffeine flows into revisioned exposure events (contracts §10).
///
/// Journal answers are day-granular: `occurred` is the local day `[midnight, next midnight)` in the phone's zone,
/// `time_precision = day_only`, `source = journal_day_answer`. Yes ⇒ `confirmed`, no ⇒ `denied` (explicit absence),
/// cleared ⇒ `retracted`; a numeric answer is `confirmed` with the value as `dose_amount` and the catalog unit
/// (`dose_provenance = catalog_default`; a numeric 0 is `denied` with dose 0). The event id is deterministic from
/// (owner, day, canonical question), so every edit of one answer is the next revision of one event.
///
/// Caffeine intakes keep their own id (the intake UUID, which for Apple Health is the sample UUID), an exact time
/// `[t, t+1)` and the mg dose; `user_entered`, or `imported` for Apple Health. Removing an intake is a retraction.
/// `CaffeineLogStore` prunes after 48 h; that pruning is NOT a retraction — the revisions stored here are the
/// durable record.
///
/// The hooks never throw into or block the journal and caffeine flows: they hand the work to one serial queue (so
/// edits apply in the order they were made), log failures, and do nothing when an answer did not change.
enum ExposureJournalBridge {

    enum JournalAnswer: Equatable {
        case yes, no, numeric(Double), cleared
    }

    enum CaffeineChange: Equatable {
        case logged(CaffeineIntake)
        case removed(CaffeineIntake)
    }

    private static let queue = DispatchQueue(label: "noop.exposure-bridge", qos: .utility)

    /// Wait until every hook handed to the bridge so far has been applied (tests).
    static func waitForPendingWork() { queue.sync {} }

    // MARK: Hooks (fire-and-forget)

    /// Called by `Repository` after a native journal write. `writer` is the store the journal row went to.
    @MainActor
    static func journalAnswered(day: String, question: String, answer: JournalAnswer, writer: any DatabaseWriter) {
        ExposureEventStoreLocator.remember(writer)
        let owner = currentOwner()
        let unit = catalogUnit(for: question)
        let zone = TimeZone.current
        let now = Date()
        queue.async {
            do {
                let store = try ExposureEventStore(dbQueue: writer)
                try apply(journal: answer, day: day, question: question, unit: unit, owner: owner, zone: zone,
                          now: now, store: store)
            } catch {
                NSLog("ExposureJournalBridge: journal revision not recorded: \(error)")
            }
        }
    }

    /// Changes waiting for the store to be located, in the order they happened.
    @MainActor private static var caffeineBacklog: [CaffeineChange] = []
    @MainActor private static var draining = false

    /// Called by the shared `CaffeineLogStore` after a log, remove, clear or Apple Health replace.
    @MainActor
    static func caffeineChanged(_ changes: [CaffeineChange]) {
        guard !changes.isEmpty else { return }
        caffeineBacklog += changes
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            defer { draining = false }
            guard let store = await ExposureEventStoreLocator.resolve() else {
                NSLog("ExposureJournalBridge: no store; \(caffeineBacklog.count) caffeine change(s) not recorded")
                caffeineBacklog = []
                return
            }
            while !caffeineBacklog.isEmpty {
                let batch = caffeineBacklog
                caffeineBacklog = []
                let owner = currentOwner()
                let now = Date()
                queue.async {
                    for change in batch {
                        do { try apply(caffeine: change, owner: owner, now: now, store: store) } catch {
                            NSLog("ExposureJournalBridge: caffeine revision not recorded: \(error)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Recording (synchronous, testable)

    /// Record the revision a journal change implies, if any. Returns the recorded revision.
    @discardableResult
    static func apply(journal answer: JournalAnswer, day: String, question: String, unit: String?, owner: String,
                      zone: TimeZone, now: Date, store: ExposureEventStore) throws -> ExposureEventStore.Revision? {
        let owner = ExposureEventStore.normalized(owner)
        adoptIfOwner(owner, store: store)
        let canonical = JournalCatalogStore.norm(question)
        let eventId = ExposureEventIds.journal(owner: owner, day: day, canonicalQuestion: canonical)
        let previous = try store.latest(owner: owner, eventId: eventId)
        guard let next = journalRevision(answer: answer, day: day, question: question, unit: unit, owner: owner,
                                         previous: previous, zone: zone, now: now) else { return nil }
        try store.record(next, owner: owner, sourceKey: "journal|\(day)|\(canonical)")
        return next
    }

    @discardableResult
    static func apply(caffeine change: CaffeineChange, owner: String, now: Date,
                      store: ExposureEventStore) throws -> ExposureEventStore.Revision? {
        let owner = ExposureEventStore.normalized(owner)
        adoptIfOwner(owner, store: store)
        let intake: CaffeineIntake
        switch change { case .logged(let i), .removed(let i): intake = i }
        let eventId = intake.id.uuidString.lowercased()
        let previous = try store.latest(owner: owner, eventId: eventId)
        let next: ExposureEventStore.Revision?
        switch change {
        case .logged(let i): next = caffeineRevision(i, previous: previous, now: now)
        case .removed: next = retraction(of: previous, now: now)
        }
        guard let next else { return nil }
        try store.record(next, owner: owner)
        return next
    }

    /// Revisions recorded before anyone claimed the phone move to the owner of the on-device data before the
    /// owner's own next revision is numbered, so the history stays in entry order.
    private static func adoptIfOwner(_ owner: String, store: ExposureEventStore) {
        guard owner != ExposureEventStore.unclaimedOwner, CloudLocalDataBinding.isOwner(owner) else { return }
        do { try store.adoptUnclaimed(owner: owner) } catch {
            NSLog("ExposureJournalBridge: adopting unclaimed revisions failed: \(error)")
        }
    }

    // MARK: Pure mapping

    /// The next revision for a journal change, or nil when nothing changes (same answer again, clearing an answer
    /// that was never recorded or is already retracted, or a day key that is not a date).
    static func journalRevision(answer: JournalAnswer, day: String, question: String, unit: String?, owner: String,
                                previous: ExposureEventStore.Revision?, zone: TimeZone,
                                now: Date) -> ExposureEventStore.Revision? {
        let recordedAt = Int(now.timeIntervalSince1970)
        if answer == .cleared { return retraction(of: previous, now: now) }
        let occurred = PhysiologyContext.Engine.dayInterval(day, timezoneId: zone.identifier)
        guard occurred.isValid else { return nil }
        let label = question.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: " ")
        var confirmation: PhysiologyContext.ExposureConfirmation = .confirmed
        var dose: Double?
        var doseUnit: String?
        var provenance: String?
        switch answer {
        case .yes: confirmation = .confirmed
        case .no: confirmation = .denied
        case .numeric(let v):
            if v.isFinite && v >= 0 {
                dose = v
                confirmation = v == 0 ? .denied : .confirmed
                let u = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
                doseUnit = (u?.isEmpty ?? true) ? nil : u
                provenance = doseUnit == nil ? "user_entered" : "catalog_default"
            }
        case .cleared: break
        }
        let candidate = ExposureEventStore.Revision(
            eventId: ExposureEventIds.journal(owner: owner, day: day,
                                              canonicalQuestion: JournalCatalogStore.norm(question)),
            revision: (previous?.revision ?? 0) + 1, kind: JournalExposureMapping.kind(for: question), label: label,
            occurred: occurred, timePrecision: .dayOnly, recordedAt: recordedAt, source: .journalDayAnswer,
            confirmation: confirmation, doseAmount: dose, doseUnit: doseUnit, doseProvenance: provenance)
        if let previous, sameStatement(previous, candidate) { return nil }
        return candidate
    }

    static func caffeineRevision(_ intake: CaffeineIntake, previous: ExposureEventStore.Revision?,
                                 now: Date) -> ExposureEventStore.Revision? {
        let t = Int(intake.at.timeIntervalSince1970)
        let mg = intake.mg.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let provenance = mg == nil ? nil : (intake.isImported ? "imported" : "user_entered")
        let candidate = ExposureEventStore.Revision(
            eventId: intake.id.uuidString.lowercased(), revision: (previous?.revision ?? 0) + 1, kind: .caffeine,
            label: "caffeine", occurred: PhysiologyContext.Interval(t, t + 1), timePrecision: .exact,
            recordedAt: Int(now.timeIntervalSince1970), source: intake.isImported ? .imported : .userEntered,
            confirmation: .confirmed, doseAmount: mg, doseUnit: mg == nil ? nil : "mg", doseProvenance: provenance)
        if let previous, sameStatement(previous, candidate) { return nil }
        return candidate
    }

    static func retraction(of previous: ExposureEventStore.Revision?, now: Date) -> ExposureEventStore.Revision? {
        guard var r = previous, r.confirmation != .retracted else { return nil }
        r.revision += 1
        r.confirmation = .retracted
        r.recordedAt = Int(now.timeIntervalSince1970)
        r.receivedAt = nil
        return r
    }

    /// Same statement about the event, ignoring when it was entered or received.
    static func sameStatement(_ a: ExposureEventStore.Revision, _ b: ExposureEventStore.Revision) -> Bool {
        a.kind == b.kind && a.label == b.label && a.occurred == b.occurred && a.timePrecision == b.timePrecision
            && a.source == b.source && a.confirmation == b.confirmation && a.doseAmount == b.doseAmount
            && a.doseUnit == b.doseUnit && a.doseProvenance == b.doseProvenance
    }

    // MARK: Context

    /// Who a new revision belongs to: the signed-in account, else the account that owns the on-device data, else
    /// unclaimed (adopted later by the local-data owner, never uploaded as anyone else).
    static func currentOwner() -> String {
        CloudPushIdentityStore.currentOwnerId() ?? CloudLocalDataBinding.owner() ?? ExposureEventStore.unclaimedOwner
    }

    /// The unit label the journal catalog gives a numeric question (read from the catalog's stored items).
    static func catalogUnit(for question: String, defaults: UserDefaults = .standard) -> String? {
        guard let blob = defaults.data(forKey: JournalCatalogBackupKeys.items),
              let items = try? JSONDecoder().decode([JournalCatalogItem].self, from: blob) else { return nil }
        let key = JournalCatalogStore.norm(question)
        return items.first { JournalCatalogStore.norm($0.canonical) == key }?.kind.unitLabel
    }
}

// MARK: - Journal question → exposure kind

/// The documented mapping from a journal question to an exposure kind (notes/exposures.md). Matching is on whole
/// words of the normalized question, checked in this order; the first rule that matches wins. Anything else is
/// `other`, with the question as its label. Stress, screens, reading and sharing a bed are `other`: they are
/// recorded as the person stated them, never reinterpreted.
enum JournalExposureMapping {
    static let rules: [(kind: PhysiologyContext.ExposureKind, phrases: [String])] = [
        (.other, ["cold shower", "cold plunge", "ice bath", "cold water", "cold room", "cold weather", "fasting",
                  "fasted"]),
        (.medication, ["medication", "medications", "medicine", "meds", "pill", "pills", "painkiller", "painkillers",
                       "ibuprofen", "paracetamol", "acetaminophen", "aspirin", "antihistamine", "antihistamines",
                       "prescription", "sleeping pill", "sleep aid", "inhaler", "antibiotic", "antibiotics"]),
        (.supplement, ["magnesium", "supplement", "supplements", "melatonin", "vitamin", "vitamins", "zinc",
                       "creatine", "ashwagandha", "fish oil", "omega", "electrolytes", "probiotic", "probiotics"]),
        (.alcohol, ["alcohol", "alcoholic", "beer", "beers", "wine", "liquor", "spirits", "cocktail", "cocktails",
                    "drunk"]),
        (.caffeine, ["caffeine", "coffee", "espresso", "energy drink", "energy drinks", "pre workout", "pre-workout"]),
        (.heat, ["sauna", "steam room", "hot tub", "hot bath", "heat"]),
        (.travel, ["travel", "travelled", "traveled", "travelling", "traveling", "flight", "flew", "fly", "jet lag",
                   "jetlag", "time zone", "timezone"]),
        (.meal, ["eat", "ate", "eating", "meal", "meals", "food", "dinner", "lunch", "breakfast", "snack", "snacks"]),
        (.symptom, ["sick", "ill", "illness", "symptom", "symptoms", "fever", "headache", "migraine", "cold", "flu",
                    "sore", "nausea", "nauseous", "cough", "congestion", "congested", "pain", "injured", "injury"]),
    ]

    static func kind(for question: String) -> PhysiologyContext.ExposureKind {
        let words = words(of: question)
        let text = " " + words.joined(separator: " ") + " "
        for rule in rules {
            for phrase in rule.phrases {
                let p = " " + Self.words(of: phrase).joined(separator: " ") + " "
                if text.contains(p) { return rule.kind }
            }
        }
        return .other
    }

    static func words(of s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
