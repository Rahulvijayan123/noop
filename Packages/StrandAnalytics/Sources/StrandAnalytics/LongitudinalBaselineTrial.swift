import Foundation

// LongitudinalBaselineTrial.swift — Phase B: treatment events, qualify-before-freeze,
// immutable Usual-before bundle, Usual-since epoch, MDC / Theil–Sen / r1.
//
// Spec: FRWHOOP_BASELINE_IMPLEMENTATION.md §8 Phase B
// Contract: FRWHOOP_BASELINE_CONDENSED_PLAN.md §1.8
// UI names: FRWHOOP_BASELINE_FRONTEND.md (Non-treatment usual / On-treatment usual)
//
// Nothing here infers a start from HR. Charge is untouched. No NARA views.

// MARK: - Events (frontend Treatment form → this store)

public enum LBTreatmentEventType: String, Equatable, Sendable, Codable {
    case start
    case dose
    case doseChange = "dose_change"
    case interruption
    case restart
    case stop
}

public enum LBTreatmentKind: String, Equatable, Sendable, Codable, CaseIterable {
    case medication
    case supplement
    case procedure
    case other

    public var displayLabel: String {
        switch self {
        case .medication: return "Medication"
        case .supplement: return "Supplement"
        case .procedure: return "Procedure"
        case .other: return "Other"
        }
    }
}

/// How the wearer takes the logged course. Label only — never inferred from heart rate.
public enum LBMedSchedule: String, Equatable, Sendable, Codable, CaseIterable, Hashable {
    case daily
    case asNeeded = "as_needed"
    case course

    public var displayLabel: String {
        switch self {
        case .daily: return "Every day"
        case .asNeeded: return "As needed"
        case .course: return "A course"
        }
    }
}

/// Whether today's log says they took the scheduled course. Extra / another med is a separate flag.
public enum LBScheduledMedStatus: String, Equatable, Sendable, Codable, CaseIterable, Hashable {
    case unspecified
    case taken
    case missed

    public var displayLabel: String {
        switch self {
        case .unspecified: return "Not logged"
        case .taken: return "Took scheduled"
        case .missed: return "Missed scheduled"
        }
    }
}

public enum LBEnteredBy: String, Equatable, Sendable, Codable {
    case patient
    case caregiver
}

public enum LBStopReason: String, Equatable, Sendable, Codable, CaseIterable {
    case completed
    case doctorStopped = "doctor_stopped"
    case sideEffects = "side_effects"
    case missedSupply = "missed_supply"
    case other
}

public enum LBConfounder: String, Equatable, Sendable, Codable, CaseIterable {
    case illness
    case hospitalization
    case travel
    case sleepDisruption = "sleep_disruption"
    case exerciseChange = "exercise_change"
    case concomitantMed = "concomitant_med"
    case dietChange = "diet_change"

    public var displayLabel: String {
        switch self {
        case .illness: return "Illness"
        case .hospitalization: return "Hospitalization"
        case .travel: return "Travel"
        case .sleepDisruption: return "Sleep disruption"
        case .exerciseChange: return "Exercise change"
        case .concomitantMed: return "Another medication"
        case .dietChange: return "Diet change"
        }
    }

    /// Acute flags still skip primary Change since start. Workout is not in this list — it is a stratum.
    public var isAcute: Bool {
        switch self {
        case .illness, .hospitalization, .travel, .concomitantMed: return true
        case .sleepDisruption, .exerciseChange, .dietChange: return false
        }
    }
}

/// How hard the day was, logged every day — not only when a reading looks off.
public enum LBWorkoutLoad: String, Equatable, Sendable, Codable, CaseIterable, Hashable {
    case none
    case easy
    case moderate
    case hard

    public var displayLabel: String {
        switch self {
        case .none: return "No workout"
        case .easy: return "Easy"
        case .moderate: return "Moderate"
        case .hard: return "Hard"
        }
    }

    public var habitClass: LBHabitClass { self == .none ? .rest : .trained }
}

public enum LBDayMood: String, Equatable, Sendable, Codable, CaseIterable, Hashable {
    case low
    case okay
    case good

    public var displayLabel: String {
        switch self {
        case .low: return "Low"
        case .okay: return "Okay"
        case .good: return "Good"
        }
    }
}

public enum LBActiveWindow: String, Equatable, Sendable, Codable, CaseIterable, Hashable {
    case morning
    case afternoon
    case evening
    case spread
    case rest

    public var displayLabel: String {
        switch self {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        case .spread: return "Spread out"
        case .rest: return "Mostly rest"
        }
    }
}

public enum LBDayEnergy: String, Equatable, Sendable, Codable, CaseIterable, Hashable {
    case faded
    case steady
    case wired

    public var displayLabel: String {
        switch self {
        case .faded: return "Faded"
        case .steady: return "Steady"
        case .wired: return "Wired"
        }
    }
}

/// Mental / schedule load. Distinct from workout so a desk-heavy rest day is not labeled like an easy day.
public enum LBDayDemand: String, Equatable, Sendable, Codable, CaseIterable, Hashable {
    case light
    case usual
    case heavy

    public var displayLabel: String {
        switch self {
        case .light: return "Light day"
        case .usual: return "Usual day"
        case .heavy: return "Heavy day"
        }
    }
}

/// Rest vs trained usuals so a hard session is compared to other hard days, not to rest-day RHR.
public enum LBHabitClass: String, Equatable, Sendable, Codable {
    case unspecified
    case rest
    case trained
}

/// Morning (or end-of-day) log. Filled whether or not last night was OFF, so OFF does not cue the answers.
public struct LBDayLog: Equatable, Sendable, Codable {
    public var workout: LBWorkoutLoad
    public var alcohol: Bool
    public var travel: Bool
    public var feltIll: Bool
    public var sleepTypical: Bool
    public var dietTypical: Bool
    public var extraMed: Bool
    /// Scheduled course from the Treatment tab — does not drop the night from usuals.
    public var scheduledMed: LBScheduledMedStatus
    /// Wearer note. Never used as a drug-cause claim.
    public var medNote: String?
    public var notes: String?
    public var mood: LBDayMood
    public var activeWindow: LBActiveWindow
    public var energy: LBDayEnergy
    public var demand: LBDayDemand

    public init(workout: LBWorkoutLoad = .none, alcohol: Bool = false, travel: Bool = false,
                feltIll: Bool = false, sleepTypical: Bool = true, dietTypical: Bool = true,
                extraMed: Bool = false, scheduledMed: LBScheduledMedStatus = .unspecified,
                medNote: String? = nil, notes: String? = nil,
                mood: LBDayMood = .okay, activeWindow: LBActiveWindow = .spread,
                energy: LBDayEnergy = .steady, demand: LBDayDemand = .usual) {
        self.workout = workout
        self.alcohol = alcohol
        self.travel = travel
        self.feltIll = feltIll
        self.sleepTypical = sleepTypical
        self.dietTypical = dietTypical
        self.extraMed = extraMed
        self.scheduledMed = scheduledMed
        self.medNote = medNote
        self.notes = notes
        self.mood = mood
        self.activeWindow = activeWindow
        self.energy = energy
        self.demand = demand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workout = try c.decodeIfPresent(LBWorkoutLoad.self, forKey: .workout) ?? .none
        alcohol = try c.decodeIfPresent(Bool.self, forKey: .alcohol) ?? false
        travel = try c.decodeIfPresent(Bool.self, forKey: .travel) ?? false
        feltIll = try c.decodeIfPresent(Bool.self, forKey: .feltIll) ?? false
        sleepTypical = try c.decodeIfPresent(Bool.self, forKey: .sleepTypical) ?? true
        dietTypical = try c.decodeIfPresent(Bool.self, forKey: .dietTypical) ?? true
        extraMed = try c.decodeIfPresent(Bool.self, forKey: .extraMed) ?? false
        scheduledMed = try c.decodeIfPresent(LBScheduledMedStatus.self, forKey: .scheduledMed) ?? .unspecified
        medNote = try c.decodeIfPresent(String.self, forKey: .medNote)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        mood = try c.decodeIfPresent(LBDayMood.self, forKey: .mood) ?? .okay
        activeWindow = try c.decodeIfPresent(LBActiveWindow.self, forKey: .activeWindow) ?? .spread
        energy = try c.decodeIfPresent(LBDayEnergy.self, forKey: .energy) ?? .steady
        demand = try c.decodeIfPresent(LBDayDemand.self, forKey: .demand) ?? .usual
    }

    public var habitClass: LBHabitClass { workout.habitClass }

    /// Illness, travel, extra med, alcohol, off-typical sleep or diet — nights that must not build the usual.
    public var confoundsUsual: Bool {
        feltIll || travel || extraMed || alcohol || !sleepTypical || !dietTypical
    }

    /// Short everyday label: mood, rest vs trained, demand, plus whatever stood out.
    public var summaryLine: String {
        var parts = [mood.displayLabel, workout.habitClass == .trained ? "Trained" : "Rest",
                     demand.displayLabel]
        if energy != .steady { parts.append(energy.displayLabel) }
        if alcohol { parts.append("Alcohol") }
        if travel { parts.append("Travel") }
        if feltIll { parts.append("Felt ill") }
        if !sleepTypical { parts.append("Sleep off-typical") }
        if !dietTypical { parts.append("Diet off-typical") }
        if extraMed { parts.append("Another med") }
        if scheduledMed == .taken { parts.append("Took scheduled") }
        if scheduledMed == .missed { parts.append("Missed scheduled") }
        return parts.joined(separator: " · ")
    }

    /// Maps onto the old chip list so trial eligibility can still read acute days.
    public var acuteConfounders: [LBConfounder] {
        var chips: [LBConfounder] = []
        if feltIll { chips.append(.illness) }
        if travel { chips.append(.travel) }
        if extraMed { chips.append(.concomitantMed) }
        return chips
    }
}

/// Wearer-facing medication labels for one civil day. Never a cause claim.
public struct LBMedicationDayLabel: Equatable, Sendable {
    public var courseName: String?
    public var kind: LBTreatmentKind?
    public var schedule: LBMedSchedule?
    public var phase: LBTrialPhase
    public var scheduledStatus: LBScheduledMedStatus
    public var extraMed: Bool
    public var wearerLine: String

    public static func make(asOf: String, events: [LBTreatmentEvent],
                            log: LBDayLog?) -> LBMedicationDayLabel {
        let clock = LongitudinalBaseline.trialClock(events: events, asOf: asOf)
        let extra = log?.extraMed ?? false
        let scheduled = log?.scheduledMed ?? .unspecified
        var parts: [String] = []
        if let start = clock.start, clock.phase != .none {
            parts.append(start.bannerName)
            parts.append(start.kind.displayLabel)
            parts.append(start.schedule.displayLabel)
            switch clock.phase {
            case .settlingIn: parts.append("Settling in")
            case .onTreatment: parts.append("On course")
            case .washingOut: parts.append("Washing out")
            case .ended: parts.append("Ended")
            case .none: break
            }
            if scheduled != .unspecified { parts.append(scheduled.displayLabel) }
        }
        if extra { parts.append("Another medication today") }
        if parts.isEmpty { parts.append("No medication label today") }
        return LBMedicationDayLabel(
            courseName: clock.start?.bannerName,
            kind: clock.start?.kind,
            schedule: clock.start?.schedule,
            phase: clock.phase,
            scheduledStatus: scheduled,
            extraMed: extra,
            wearerLine: parts.joined(separator: " · "))
    }
}

public enum LBTrialPhase: String, Equatable, Sendable {
    case none
    case settlingIn = "settling_in"     // frontend: Settling in
    case onTreatment = "on_treatment"   // frontend: On treatment
    case washingOut = "washing_out"     // frontend: Washing out
    case ended
}

/// Frontend layout shape (FRWHOOP_BASELINE_FRONTEND.md). Engine only; no views.
public enum LBNaraShape: String, Equatable, Sendable {
    case building
    case monitoring
    case trial
    case washingOut = "washing_out"
    case ended
}

public struct LBProvenance: Equatable, Sendable, Codable {
    public var deviceModel: String
    public var firmware: String
    public var decoderVersion: String
    public var metricDefVersion: String
    public var sensorSource: String
    public var rawRef: String

    public init(deviceModel: String = "WHOOP5", firmware: String = "",
                decoderVersion: String = "v1", metricDefVersion: String = "v1",
                sensorSource: String = "whoop", rawRef: String = "") {
        self.deviceModel = deviceModel
        self.firmware = firmware
        self.decoderVersion = decoderVersion
        self.metricDefVersion = metricDefVersion
        self.sensorSource = sensorSource
        self.rawRef = rawRef
    }

    public func differs(from other: LBProvenance) -> Bool {
        deviceModel != other.deviceModel
            || firmware != other.firmware
            || decoderVersion != other.decoderVersion
            || metricDefVersion != other.metricDefVersion
            || sensorSource != other.sensorSource
            || rawRef != other.rawRef
    }
}

/// One timestamped treatment event. Clock time is required; never inferred from the series.
public struct LBTreatmentEvent: Equatable, Sendable, Codable {
    public var trialId: String
    public var type: LBTreatmentEventType
    public var civilDay: String
    public var clockTime: String
    public var displayName: String
    public var kind: LBTreatmentKind
    public var doseText: String?
    public var enteredBy: LBEnteredBy
    public var stopReason: LBStopReason?
    public var notes: String?
    public var onsetDays: Int?
    public var washoutDays: Int?
    public var lastDoseDay: String?
    public var lastDoseClock: String?
    public var patientSaysClear: Bool
    public var patientStillFeeling: Bool
    public var primarySeries: [LBSeries]
    public var schedule: LBMedSchedule

    public init(trialId: String, type: LBTreatmentEventType, civilDay: String,
                clockTime: String = "07:00", displayName: String,
                kind: LBTreatmentKind = .medication, doseText: String? = nil,
                enteredBy: LBEnteredBy = .patient, stopReason: LBStopReason? = nil,
                notes: String? = nil, onsetDays: Int? = nil, washoutDays: Int? = nil,
                lastDoseDay: String? = nil, lastDoseClock: String? = nil,
                patientSaysClear: Bool = false, patientStillFeeling: Bool = false,
                primarySeries: [LBSeries] = [],
                schedule: LBMedSchedule = .daily) {
        self.trialId = trialId
        self.type = type
        self.civilDay = civilDay
        self.clockTime = clockTime
        self.displayName = displayName
        self.kind = kind
        self.doseText = doseText
        self.enteredBy = enteredBy
        self.stopReason = stopReason
        self.notes = notes
        self.onsetDays = onsetDays
        self.washoutDays = washoutDays
        self.lastDoseDay = lastDoseDay
        self.lastDoseClock = lastDoseClock
        self.patientSaysClear = patientSaysClear
        self.patientStillFeeling = patientStillFeeling
        self.primarySeries = primarySeries
        self.schedule = schedule
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trialId = try c.decode(String.self, forKey: .trialId)
        type = try c.decode(LBTreatmentEventType.self, forKey: .type)
        civilDay = try c.decode(String.self, forKey: .civilDay)
        clockTime = try c.decode(String.self, forKey: .clockTime)
        displayName = try c.decode(String.self, forKey: .displayName)
        kind = try c.decodeIfPresent(LBTreatmentKind.self, forKey: .kind) ?? .medication
        doseText = try c.decodeIfPresent(String.self, forKey: .doseText)
        enteredBy = try c.decodeIfPresent(LBEnteredBy.self, forKey: .enteredBy) ?? .patient
        stopReason = try c.decodeIfPresent(LBStopReason.self, forKey: .stopReason)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        onsetDays = try c.decodeIfPresent(Int.self, forKey: .onsetDays)
        washoutDays = try c.decodeIfPresent(Int.self, forKey: .washoutDays)
        lastDoseDay = try c.decodeIfPresent(String.self, forKey: .lastDoseDay)
        lastDoseClock = try c.decodeIfPresent(String.self, forKey: .lastDoseClock)
        patientSaysClear = try c.decodeIfPresent(Bool.self, forKey: .patientSaysClear) ?? false
        patientStillFeeling = try c.decodeIfPresent(Bool.self, forKey: .patientStillFeeling) ?? false
        primarySeries = try c.decodeIfPresent([LBSeries].self, forKey: .primarySeries) ?? []
        schedule = try c.decodeIfPresent(LBMedSchedule.self, forKey: .schedule) ?? .daily
    }

    public var bannerName: String {
        if let doseText, !doseText.isEmpty { return "\(displayName) \(doseText)" }
        return displayName
    }
}

/// Caller input for Phase B. Default `.none` keeps Phase A tests unchanged.
public struct LBTrialRequest: Equatable, Sendable {
    public var events: [LBTreatmentEvent]
    /// If already persisted, evaluate must not rewrite it.
    public var freeze: LBFreezeBundle?
    public var provenanceNow: LBProvenance
    /// Civil-day → Other things going on. Kept for older chips; daily log is the product path.
    public var confoundersByDay: [String: [LBConfounder]]
    /// Everyday habit log. Used to stratum rest vs trained usuals. Not an “explain this OFF” form.
    public var dayLogsByDay: [String: LBDayLog]

    public init(events: [LBTreatmentEvent] = [], freeze: LBFreezeBundle? = nil,
                provenanceNow: LBProvenance = LBProvenance(),
                confoundersByDay: [String: [LBConfounder]] = [:],
                dayLogsByDay: [String: LBDayLog] = [:]) {
        self.events = events
        self.freeze = freeze
        self.provenanceNow = provenanceNow
        self.confoundersByDay = confoundersByDay
        self.dayLogsByDay = dayLogsByDay
    }

    public func acuteFlags(on day: String) -> [LBConfounder] {
        if let log = dayLogsByDay[day] { return log.acuteConfounders }
        return (confoundersByDay[day] ?? []).filter(\.isAcute)
    }

    public static let none = LBTrialRequest()
}

/// Immutable Usual-before-treatment bundle (condensed §1.8). Post-t0 nights never edit it.
public struct LBFreezeBundle: Equatable, Sendable, Codable {
    public var trialId: String
    public var t0CivilDay: String
    public var tFreeze: String
    public var center7: Double
    public var spread7: Double
    public var center7Raw: Double?
    public var centerLong: Double
    public var spreadLong: Double
    public var gap: Double?
    public var gapZ: Double?
    public var slopeLong: Double
    public var n7: Int
    public var nLearn: Double
    public var nLong: Int
    public var coverageLong: Double
    public var confidencePct7: Int
    public var confidencePctLong: Int
    public var dFirst: String
    public var dLast: String
    public var paramSet: String
    public var version7: String
    public var versionLong: String
    public var provenance: LBProvenance
    public var sigmaMeas: Double
    public var mdc95: Double
    /// √max(spread_long² − σ_meas², 0). Immutable with the freeze. Does not change MDC.
    public var sigmaBio: Double
    public var r1: Double
    public var nEff: Double
    public var displayName: String
    public var slopeUsable: Bool = false
    public var primarySeries: [LBSeries] = []
}

/// Trial-log histogram of Why missing (condensed §1.8.1 item 5). Not used as a value.
public struct LBMissingnessLog: Equatable, Sendable {
    public var daysInWindow: Int
    public var none: Int
    public var poorSignal: Int
    public var charging: Int
    public var deviceOff: Int
    public var appFail: Int
    public var hospital: Int
    public var unknown: Int
    public var other: Int

    public init(daysInWindow: Int = 0, none: Int = 0, poorSignal: Int = 0, charging: Int = 0,
                deviceOff: Int = 0, appFail: Int = 0, hospital: Int = 0, unknown: Int = 0,
                other: Int = 0) {
        self.daysInWindow = daysInWindow
        self.none = none
        self.poorSignal = poorSignal
        self.charging = charging
        self.deviceOff = deviceOff
        self.appFail = appFail
        self.hospital = hospital
        self.unknown = unknown
        self.other = other
    }

    public static let empty = LBMissingnessLog()

    public var counts: [String: Int] {
        [
            "none": none,
            "poor_signal": poorSignal,
            "charging": charging,
            "device_off": deviceOff,
            "app_fail": appFail,
            "hospital": hospital,
            "unknown": unknown,
            "other": other,
        ]
    }
}

/// Phase C hook: ask “what else is going on?” only when off usual persists.
/// Never required. Never a nightly caregiver chore. Scoring does not wait on an answer.
public struct LBOutOfBoundsPrompt: Equatable, Sendable {
    public var shouldAsk: Bool
    public var required: Bool
    public var offLongerUsual: Bool
    public var offSinceStart: Bool
    public var headline: String
    public var body: String

    public static let silent = LBOutOfBoundsPrompt(
        shouldAsk: false, required: false, offLongerUsual: false, offSinceStart: false,
        headline: "", body: "")

    public init(shouldAsk: Bool, required: Bool, offLongerUsual: Bool, offSinceStart: Bool,
                headline: String, body: String) {
        self.shouldAsk = shouldAsk
        self.required = required
        self.offLongerUsual = offLongerUsual
        self.offSinceStart = offSinceStart
        self.headline = headline
        self.body = body
    }
}

public struct LBCardCopy: Equatable, Sendable {
    public var thisWeekTitle: String
    public var slowTitle: String
    public var freezeTitle: String?
    public var offThisWeek: String
    public var offSlow: String
    public var confidenceSlowLabel: String
    public var naraShape: LBNaraShape
    public var banner: String?
    public var qualifyMessage: String?

    public static func monitoring(building: Bool) -> LBCardCopy {
        LBCardCopy(
            thisWeekTitle: "This week's usual",
            slowTitle: "Longer usual",
            freezeTitle: nil,
            offThisWeek: "Off this week",
            offSlow: "Off longer usual",
            confidenceSlowLabel: "LONGER",
            naraShape: building ? .building : .monitoring,
            banner: nil,
            qualifyMessage: nil)
    }
}

public struct LBTrialEvaluation: Equatable, Sendable {
    public var trialId: String?
    public var displayName: String?
    public var enteredBy: LBEnteredBy?
    public var phase: LBTrialPhase
    public var trialFreezeOk: Bool
    public var freeze: LBFreezeBundle?
    public var expectedT: Double?
    public var deltaTrialLevel: Double?
    public var deltaTrialTraj: Double?
    public var zTrialLevel: Double?
    public var zTrialTraj: Double?
    public var aboveMdc: Bool?
    public var sigmaMeas: Double?
    public var mdc95: Double?
    public var r1: Double?
    public var nEff: Double?
    /// Lag-1 on post-start kept nights this T. Never written back onto the freeze bundle.
    public var r1Live: Double?
    public var nEffLive: Double?
    /// Today vs frozen this-week copy. Secondary; primary contrast stays z_trial_traj.
    public var deltaTrialLevel7: Double?
    public var deltaTrialTraj7: Double?
    public var zTrialLevel7: Double?
    public var zTrialTraj7: Double?
    public var provenanceBreak: Bool
    public var primaryContrastEligible: Bool
    public var qualifyReasons: [String]
    public var confoundersToday: [LBConfounder]
    public var missingness: LBMissingnessLog
    public var card: LBCardCopy
    public var expectedUntreatedDisplay: Double? = nil
    public var gapVsPathDisplay: Double? = nil
    public var gapVsFlatDisplay: Double? = nil
    public var isPrimarySeries: Bool = false
    public var judgingResponse: Bool = false
    public var summarySentence: String? = nil
    public var tooEarly: Bool = false
    public var flatModelOnly: Bool = false
    public var disclaimer: String = ""
    public var washInDaysUsed: Int = 7
    public var washoutDaysUsed: Int = 7

    public static let none = LBTrialEvaluation(
        trialId: nil, displayName: nil, enteredBy: nil, phase: .none,
        trialFreezeOk: false, freeze: nil, expectedT: nil,
        deltaTrialLevel: nil, deltaTrialTraj: nil, zTrialLevel: nil, zTrialTraj: nil,
        aboveMdc: nil, sigmaMeas: nil, mdc95: nil, r1: nil, nEff: nil,
        r1Live: nil, nEffLive: nil,
        deltaTrialLevel7: nil, deltaTrialTraj7: nil, zTrialLevel7: nil, zTrialTraj7: nil,
        provenanceBreak: false, primaryContrastEligible: false,
        qualifyReasons: [], confoundersToday: [], missingness: .empty,
        card: .monitoring(building: true))

    public var consoleBlock: String {
        var lines = ["  trial  phase=\(phase.rawValue)  freeze_ok=\(trialFreezeOk ? "1" : "0")  shape=\(card.naraShape.rawValue)"]
        if let name = displayName { lines.append("         name=\(name)") }
        lines.append("         cards: \(card.thisWeekTitle) | \(card.slowTitle)"
                     + (card.freezeTitle.map { " | \($0)" } ?? ""))
        if let f = freeze {
            lines.append(String(format: "         frozen long=%.4f  slope=%.4f  T_freeze=%@",
                                f.centerLong, f.slopeLong, f.tFreeze))
        }
        lines.append(String(format: "         expected=%@  z_traj=%@  z_level=%@  above_mdc=%@  prov_break=%@",
                            expectedT.map { String(format: "%.4f", $0) } ?? "—",
                            zTrialTraj.map { String(format: "%.3f", $0) } ?? "—",
                            zTrialLevel.map { String(format: "%.3f", $0) } ?? "—",
                            aboveMdc.map { $0 ? "1" : "0" } ?? "—",
                            provenanceBreak ? "1" : "0"))
        lines.append(String(format: "         σ_meas=%@  σ_bio=%@  z_level_7=%@  r1_freeze=%@  r1_live=%@",
                            sigmaMeas.map { String(format: "%.4f", $0) } ?? "—",
                            freeze.map { String(format: "%.4f", $0.sigmaBio) } ?? "—",
                            zTrialLevel7.map { String(format: "%.3f", $0) } ?? "—",
                            r1.map { String(format: "%.3f", $0) } ?? "—",
                            r1Live.map { String(format: "%.3f", $0) } ?? "—"))
        if missingness.daysInWindow > 0 {
            lines.append("         missing: none=\(missingness.none) hospital=\(missingness.hospital) unknown=\(missingness.unknown) other=\(missingness.other)")
        }
        if !qualifyReasons.isEmpty {
            lines.append("         qualify: " + qualifyReasons.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public var phaseBStatisticLedger: [(planName: String, value: String)] {
        func n(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "—" }
        return [
            ("trial_id", trialId ?? "—"),
            ("display_name", displayName ?? "—"),
            ("phase", phase.rawValue),
            ("nara_shape", card.naraShape.rawValue),
            ("slow_title", card.slowTitle),
            ("freeze_title", card.freezeTitle ?? "—"),
            ("trial_freeze_ok", trialFreezeOk ? "1" : "0"),
            ("center_long_frozen", n(freeze?.centerLong)),
            ("center_7_frozen", n(freeze?.center7)),
            ("slope_long", n(freeze?.slopeLong)),
            ("expected_t", n(expectedT)),
            ("delta_trial_level", n(deltaTrialLevel)),
            ("delta_trial_traj", n(deltaTrialTraj)),
            ("z_trial_level", n(zTrialLevel)),
            ("z_trial_traj", n(zTrialTraj)),
            ("sigma_meas", n(sigmaMeas)),
            ("sigma_bio", n(freeze?.sigmaBio)),
            ("mdc_95", n(mdc95)),
            ("above_mdc", aboveMdc.map { $0 ? "1" : "0" } ?? "—"),
            ("r1", n(r1)),
            ("n_eff", n(nEff)),
            ("r1_live", n(r1Live)),
            ("n_eff_live", n(nEffLive)),
            ("delta_trial_level_7", n(deltaTrialLevel7)),
            ("delta_trial_traj_7", n(deltaTrialTraj7)),
            ("z_trial_level_7", n(zTrialLevel7)),
            ("z_trial_traj_7", n(zTrialTraj7)),
            ("missing_none", "\(missingness.none)"),
            ("missing_hospital", "\(missingness.hospital)"),
            ("provenance_break", provenanceBreak ? "1" : "0"),
            ("primary_contrast_eligible", primaryContrastEligible ? "1" : "0"),
        ]
    }
}

extension LongitudinalBaseline {

    // MARK: - Phase clocks

    /// LABEL: active trial as of civil day T
    /// Latest start on or before T, then later events on that trial_id. Dose change does not new-epoch.
    public static func trialClock(events: [LBTreatmentEvent], asOf: String) -> (
        phase: LBTrialPhase, start: LBTreatmentEvent?, lastEvent: LBTreatmentEvent?
    ) {
        let dated = events.filter { $0.civilDay <= asOf }.sorted {
            ($0.civilDay, $0.clockTime) < ($1.civilDay, $1.clockTime)
        }
        guard let start = dated.last(where: { $0.type == .start }) else {
            return (.none, nil, dated.last)
        }
        let forTrial = dated.filter { $0.trialId == start.trialId && $0.civilDay >= start.civilDay }
        var settleDay = start.civilDay
        var stopDay: String?
        var interrupted = false
        var last = start
        for e in forTrial {
            last = e
            switch e.type {
            case .start, .restart, .doseChange:
                settleDay = e.civilDay
                interrupted = false
                stopDay = nil
            case .stop, .interruption:
                stopDay = e.civilDay
                interrupted = e.type == .interruption
            case .dose:
                break
            }
        }
        guard let tEpoch = isoEpochDay(asOf) else { return (.none, start, last) }
        let washIn = start.onsetDays ?? Params.washInDays
        let startWash = start.washoutDays ?? Params.washoutDays
        if let stopDay, let sEpoch = isoEpochDay(stopDay) {
            if last.patientSaysClear { return (.ended, start, last) }
            if last.patientStillFeeling { return (.washingOut, start, last) }
            if interrupted { return (.washingOut, start, last) }
            let tClockDay = last.lastDoseDay ?? stopDay
            let tClock = isoEpochDay(tClockDay) ?? sEpoch
            let washout = last.washoutDays ?? startWash
            if tEpoch < tClock + washout {
                return (.washingOut, start, last)
            }
            return (.ended, start, last)
        }
        if let aEpoch = isoEpochDay(settleDay), tEpoch - aEpoch < washIn {
            return (.settlingIn, start, last)
        }
        return (.onTreatment, start, last)
    }

    /// Civil day strictly before t0 (T_freeze).
    public static func freezeAsOfDay(t0CivilDay: String) -> String? {
        guard let z = isoEpochDay(t0CivilDay) else { return nil }
        return isoFromEpochDay(z - 1)
    }

    // MARK: - Theil–Sen, σ_meas, r1

    /// LABEL: Theil–Sen slope
    /// Median of pairwise (y_j − y_i) / (x_j − x_i). Frozen at t0 so untreated drift is not a flat control.
    public static func theilSenSlope(xs: [Double], ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        var slopes: [Double] = []
        for i in 0..<xs.count {
            for j in (i + 1)..<xs.count {
                let dx = xs[j] - xs[i]
                if abs(dx) < 1e-12 { continue }
                slopes.append((ys[j] - ys[i]) / dx)
            }
        }
        return median(slopes)
    }

    /// LABEL: test-retest σ_meas
    /// 1.4826 × MAD(δ) / √2 on consecutive quality-OK deltas. MDC_95 ≈ 2.77 × σ_meas.
    public static func measurementSigma(consecutiveDeltas: [Double]) -> Double? {
        guard consecutiveDeltas.count >= 2, let mid = median(consecutiveDeltas) else { return nil }
        let mad = median(consecutiveDeltas.map { abs($0 - mid) }) ?? 0
        return Params.madScale * mad / sqrt(2.0)
    }

    public static func mdc95(sigmaMeas: Double) -> Double {
        2.77 * sigmaMeas
    }

    /// LABEL: biological variation leftover after test-retest σ_meas
    /// σ_bio² = max(spread_long_frozen² − σ_meas², 0). Never used as today's value.
    public static func biologicalSigma(spreadLong: Double, sigmaMeas: Double) -> Double {
        sqrt(max(spreadLong * spreadLong - sigmaMeas * sigmaMeas, 0))
    }

    /// LABEL: lag-1 residual autocorrelation
    public static func lag1R1(residuals: [Double]) -> Double? {
        guard residuals.count >= 3 else { return nil }
        let x = Array(residuals.dropLast())
        let y = Array(residuals.dropFirst())
        let mx = x.reduce(0, +) / Double(x.count)
        let my = y.reduce(0, +) / Double(y.count)
        var num = 0.0, dx = 0.0, dy = 0.0
        for i in 0..<x.count {
            let a = x[i] - mx
            let b = y[i] - my
            num += a * b
            dx += a * a
            dy += b * b
        }
        let den = sqrt(dx * dy)
        guard den > 0 else { return 0 }
        return num / den
    }

    public static func nEff(n: Int, r1: Double) -> Double {
        let r = min(0.99, max(-0.99, r1))
        return Double(n) * (1.0 - r) / (1.0 + r)
    }

    // MARK: - Qualify + freeze

    /// LABEL: qualify before freeze
    /// Thin data → trial_freeze_ok = 0. Never invent a control from 3 nights.
    public static func qualifyReasons(pre: LBEvaluation, observations: [LBDailyObservation]) -> [String] {
        var reasons: [String] = []
        if !pre.show7 { reasons.append("show_7") }
        if !pre.establishedLong { reasons.append("established_long") }
        if pre.stale { reasons.append("stale") }
        if pre.regimeShift { reasons.append("regime_shift") }
        if !pre.confSpread { reasons.append("conf_spread") }
        if isSpO2Series(pre.series) {
            let okSlots = spo2LongNightsWithCoverage(asOf: pre.asOf, observations: observations)
            if okSlots < 10 { reasons.append("spo2_slots") }
        }
        return reasons
    }

    static func isSpO2Series(_ series: LBSeries) -> Bool {
        switch series {
        case .sleepSpO2Mean, .sleepSpO2Nadir, .awakeRestSpO2Mean,
             .awakeActiveSpO2Mean, .continuousSpO2Mean: return true
        default: return false
        }
    }

    static func spo2LongNightsWithCoverage(asOf t: String, observations: [LBDailyObservation]) -> Int {
        guard let tEpoch = isoEpochDay(t) else { return 0 }
        let lo = tEpoch - Params.lookbackLong
        let hi = tEpoch - Params.gapDays - 1
        return observations.filter { obs in
            guard let e = isoEpochDay(obs.day), e >= lo, e <= hi else { return false }
            return obs.qualityStatus == .ok && (obs.coverage ?? 0) >= Params.spo2MinSlots
        }.count
    }

    public static func makeFreezeBundle(pre: LBEvaluation, start: LBTreatmentEvent,
                                        observations: [LBDailyObservation],
                                        provenance: LBProvenance) -> LBFreezeBundle? {
        guard let cl = pre.copyLong?.center, let sl = pre.copyLong?.spread,
              let c7 = pre.copy7?.center, let s7 = pre.copy7?.spread else { return nil }
        let pairs = longKeptPairs(asOf: pre.asOf, series: pre.series, observations: observations)
        let xs = pairs.map { Double($0.epoch) }
        let ys = pairs.map(\.value)
        let slope = theilSenSlope(xs: xs, ys: ys) ?? 0
        var deltas: [Double] = []
        if pairs.count >= 2 {
            for i in 1..<pairs.count {
                if pairs[i].epoch == pairs[i - 1].epoch + 1 {
                    deltas.append(pairs[i].value - pairs[i - 1].value)
                }
            }
        }
        let sigma = measurementSigma(consecutiveDeltas: deltas) ?? 0
        let residuals = ys.map { $0 - cl }
        let r1 = lag1R1(residuals: residuals) ?? 0
        return LBFreezeBundle(
            trialId: start.trialId, t0CivilDay: start.civilDay, tFreeze: pre.asOf,
            center7: c7, spread7: s7, center7Raw: pre.center7Raw,
            centerLong: cl, spreadLong: sl, gap: pre.gap, gapZ: pre.gapZ,
            slopeLong: slope, n7: pre.n7, nLearn: pre.nLearn, nLong: pre.nLong,
            coverageLong: pre.copyLong?.coverage ?? 0,
            confidencePct7: pre.confidencePct7, confidencePctLong: pre.confidencePctLong,
            dFirst: pairs.first.map { isoFromEpochDay($0.epoch) } ?? pre.asOf,
            dLast: pairs.last.map { isoFromEpochDay($0.epoch) } ?? pre.asOf,
            paramSet: pre.paramSet, version7: Params.version7, versionLong: Params.versionLong,
            provenance: provenance, sigmaMeas: sigma, mdc95: mdc95(sigmaMeas: sigma),
            sigmaBio: biologicalSigma(spreadLong: sl, sigmaMeas: sigma),
            r1: r1, nEff: nEff(n: pre.nLong, r1: r1), displayName: start.bannerName,
            slopeUsable: pre.slopeUsable, primarySeries: start.primarySeries)
    }

    static func longKeptPairs(asOf t: String, series: LBSeries,
                              observations: [LBDailyObservation]) -> [(epoch: Int, value: Double)] {
        guard let tEpoch = isoEpochDay(t) else { return [] }
        let byDay = indexByDay(observations, series: series)
        let epochs = Array((tEpoch - Params.lookbackLong)...(tEpoch - Params.gapDays - 1))
        let pairs: [(Int, Double)] = epochs.compactMap { e in
            guard let x = trainableMath(byDay[e], series: series) else { return nil }
            return (e, x)
        }
        let floor = seriesSpec(series).floor
        let values = pairs.map(\.1)
        let trim = trimLongList(values, floor: floor)
        guard trim.absorbed, let m0 = median(values) else { return pairs }
        let s0 = robustSpread(values: values, center: m0, floor: floor)
        return pairs.filter { abs($0.1 - m0) / max(s0, 1e-9) < Params.kLearn }
    }

    /// LABEL: Why missing counts on [t0, T]
    /// Histogram only. Missing is never recoded as 0.
    public static func missingnessLog(from startDay: String, through asOf: String,
                                      observations: [LBDailyObservation]) -> LBMissingnessLog {
        guard let a = isoEpochDay(startDay), let b = isoEpochDay(asOf), b >= a else {
            return .empty
        }
        var byDay: [String: LBDailyObservation] = [:]
        for o in observations { byDay[o.day] = o }
        var log = LBMissingnessLog()
        log.daysInWindow = b - a + 1
        for e in a...b {
            let day = isoFromEpochDay(e)
            guard let obs = byDay[day] else {
                log.unknown += 1
                continue
            }
            if obs.qualityStatus == .ok, obs.value != nil {
                log.none += 1
                continue
            }
            switch obs.qualityReason {
            case .poorSignal: log.poorSignal += 1
            case .charging: log.charging += 1
            case .deviceOff: log.deviceOff += 1
            case .appFail: log.appFail += 1
            case .hospital: log.hospital += 1
            case .unknown: log.unknown += 1
            case .lowCoverage, .outOfRange, .sparseSleep: log.other += 1
            case nil: log.unknown += 1
            }
        }
        return log
    }

    /// LABEL: optional out-of-bounds context prompt
    /// One completed night outside this week’s or the longer usual is enough to ask the next day.
    /// Missing nights stay unknown. A confounder already on T means they already accounted for it.
    static func outOfBoundsPrompt(for ev: LBEvaluation) -> LBOutOfBoundsPrompt {
        let k = params(for: ev.series).kBand
        let tonightOk = ev.todayNative != nil
        let offWeek = tonightOk && ev.show7 && ev.usualTrustPct7 >= trustHideThreshold
            && isOffUsual(z: ev.z7, k: k)
        let offLong = tonightOk && ev.showLong && ev.usualTrustPctLong >= trustHideThreshold
            && isOffUsual(z: ev.zLong, k: k)
        let offStart = ev.trial.trialFreezeOk
            && ev.trial.primaryContrastEligible
            && (ev.trial.aboveMdc == true)
            && isOffUsual(z: ev.trial.zTrialTraj, k: k)
        let alreadyLabeled = !ev.trial.confoundersToday.isEmpty
        let shouldAsk = (offWeek || offLong || offStart) && !alreadyLabeled
        guard shouldAsk else { return .silent }
        let headline = "Last night looked unusual"
        let body = "Was something else going on — illness, travel, sleep disruption, diet, extra medication, hospital, or an exercise change? Optional. If you add a reason, that night stays on the graph in grey and is not used to judge a treatment response."
        return LBOutOfBoundsPrompt(
            shouldAsk: true, required: false,
            offLongerUsual: offLong, offSinceStart: offStart,
            headline: headline, body: body)
    }

    // MARK: - Attach trial to a Phase A evaluation

    static func attachTrial(to ev: LBEvaluation, request: LBTrialRequest,
                            observations: [LBDailyObservation],
                            qualifyReasons reasonsIn: [String]) -> LBTrialEvaluation {
        let clock = trialClock(events: request.events, asOf: ev.asOf)
        let building = !ev.show7 || !ev.showLong
        guard let start = clock.start, clock.phase != .none else {
            var idle = LBTrialEvaluation.none
            idle.card = .monitoring(building: building)
            idle.phase = .none
            return idle
        }

        let last = clock.lastEvent ?? start
        let dose = request.events.filter { $0.trialId == start.trialId && $0.civilDay <= ev.asOf }
            .sorted { ($0.civilDay, $0.clockTime) < ($1.civilDay, $1.clockTime) }
            .reversed()
            .compactMap(\.doseText)
            .first ?? start.doseText
        let labelEvent = LBTreatmentEvent(
            trialId: start.trialId, type: last.type, civilDay: start.civilDay, clockTime: start.clockTime,
            displayName: start.displayName, kind: start.kind,
            doseText: dose, enteredBy: start.enteredBy)
        let freeze = request.freeze
        let freezeOk = freeze != nil
        let reasons = freezeOk ? [] : reasonsIn

        let confounders = request.acuteFlags(on: ev.asOf)
        let missingToday = ev.todayNative == nil
        let hospital = observations.first { $0.day == ev.asOf }?.qualityReason == .hospital
        let primaries = freeze?.primarySeries ?? start.primarySeries
        let isPrimary = primaries.contains(ev.series)
        let chipBlocked = !confounders.isEmpty
        var dLevel: Double?
        var dTraj: Double?
        var zLevel: Double?
        var zTraj: Double?
        var above: Bool?
        var dLevel7: Double?
        var dTraj7: Double?
        var zLevel7: Double?
        var zTraj7: Double?
        var expected7: Double?
        var expectedDisp: Double?
        var gapPathDisp: Double?
        var gapFlatDisp: Double?
        var expected: Double?
        if let freeze, let tEpoch = isoEpochDay(ev.asOf), let fEpoch = isoEpochDay(freeze.tFreeze) {
            let expMath = expectedUntreated(level0: freeze.centerLong, slopeG0: freeze.slopeLong,
                                            usable: freeze.slopeUsable,
                                            asOfEpoch: tEpoch, freezeEpoch: fEpoch)
            expected = expMath
            expectedDisp = toDisplay(expMath, series: ev.series)
            if let today = ev.todayNative {
                let todayMath = toMath(today, series: ev.series) ?? today
                dLevel = todayMath - freeze.centerLong
                dTraj = todayMath - expMath
                gapFlatDisp = seriesDeltaDisplay(today: today, todayMath: todayMath,
                                                 other: freeze.centerLong, series: ev.series)
                gapPathDisp = seriesDeltaDisplay(today: today, todayMath: todayMath,
                                                 other: expMath, series: ev.series)
                if freeze.spreadLong > 0 {
                    zLevel = dLevel! / freeze.spreadLong
                    zTraj = dTraj! / freeze.spreadLong
                }
                above = abs(dTraj ?? 0) >= freeze.mdc95 && freeze.mdc95 > 0
                dLevel7 = todayMath - freeze.center7
                expected7 = freeze.center7 + (freeze.slopeUsable ? freeze.slopeLong * Double(min(tEpoch - fEpoch, slopeHorizonDays)) : 0)
                dTraj7 = todayMath - expected7!
                if freeze.spread7 > 0 {
                    zLevel7 = dLevel7! / freeze.spread7
                    zTraj7 = dTraj7! / freeze.spread7
                }
            }
        }
        let eligible = freezeOk && !chipBlocked && !missingToday && !hospital
            && !(freeze.map { request.provenanceNow.differs(from: $0.provenance) } ?? false)
        let provBreak = freeze.map { request.provenanceNow.differs(from: $0.provenance) } ?? false
        let tooEarly = clock.phase == .settlingIn
        let judging = eligible && isPrimary && !primaries.isEmpty && clock.phase == .onTreatment
            && freezeOk && (ev.usualTrustPctLong >= trustHideThreshold)
            && (above == true)
        let summary: String?
        if primaries.isEmpty && freezeOk {
            summary = "No primary series chosen — not judging a treatment response."
        } else if tooEarly && freezeOk && isPrimary {
            summary = "Too early to judge a response."
        } else if judging, let gap = gapPathDisp {
            let unit = ev.series.planRow.unit
            let noise = above == true ? "bigger than sensor noise" : "not bigger than sensor noise"
            summary = String(format: "Today is %.1f %@ vs the no-treatment path (%@).", gap, unit, noise)
        } else {
            summary = nil
        }

        var r1Live: Double?
        var nEffLive: Double?
        if freezeOk, let freeze {
            let liveCenter = ev.copyLong?.center ?? freeze.centerLong
            let post = longKeptPairs(asOf: ev.asOf, series: ev.series, observations: observations)
                .filter { $0.epoch >= (isoEpochDay(freeze.t0CivilDay) ?? 0) }
            if post.count >= 3 {
                let live = lag1R1(residuals: post.map { $0.value - liveCenter }) ?? 0
                r1Live = live
                nEffLive = nEff(n: post.count, r1: live)
            }
        }
        let missingness = missingnessLog(from: start.civilDay, through: ev.asOf,
                                         observations: observations)
        let short = start.displayName
        let card = cardCopy(phase: clock.phase, freezeOk: freezeOk, building: building,
                            displayName: labelEvent.bannerName, shortName: short,
                            qualifyReasons: reasons, start: start, asOf: ev.asOf)

        return LBTrialEvaluation(
            trialId: start.trialId, displayName: labelEvent.bannerName, enteredBy: start.enteredBy,
            phase: clock.phase, trialFreezeOk: freezeOk, freeze: freeze,
            expectedT: expected, deltaTrialLevel: dLevel, deltaTrialTraj: dTraj,
            zTrialLevel: zLevel, zTrialTraj: zTraj, aboveMdc: above,
            sigmaMeas: freeze?.sigmaMeas, mdc95: freeze?.mdc95, r1: freeze?.r1, nEff: freeze?.nEff,
            r1Live: r1Live, nEffLive: nEffLive,
            deltaTrialLevel7: dLevel7, deltaTrialTraj7: dTraj7,
            zTrialLevel7: zLevel7, zTrialTraj7: zTraj7,
            provenanceBreak: provBreak, primaryContrastEligible: eligible,
            qualifyReasons: reasons, confoundersToday: confounders, missingness: missingness,
            card: card,
            expectedUntreatedDisplay: expectedDisp,
            gapVsPathDisplay: gapPathDisp,
            gapVsFlatDisplay: gapFlatDisp,
            isPrimarySeries: isPrimary,
            judgingResponse: judging,
            summarySentence: summary,
            tooEarly: tooEarly,
            flatModelOnly: freeze.map { !$0.slopeUsable } ?? false,
            disclaimer: reviewDisclaimer,
            washInDaysUsed: start.onsetDays ?? Params.washInDays,
            washoutDaysUsed: last.washoutDays ?? start.washoutDays ?? Params.washoutDays)
    }

    static func seriesDeltaDisplay(today: Double, todayMath: Double, other: Double, series: LBSeries) -> Double {
        series.usesLog ? today - toDisplay(other, series: series) : todayMath - other
    }

    static func cardCopy(phase: LBTrialPhase, freezeOk: Bool, building: Bool,
                         displayName: String, shortName: String,
                         qualifyReasons: [String], start: LBTreatmentEvent,
                         asOf _: String) -> LBCardCopy {
        let phaseWord: String = {
            switch phase {
            case .settlingIn: return "Settling in"
            case .onTreatment: return "On treatment"
            case .washingOut: return "Washing out"
            case .ended: return "Ended"
            case .none: return ""
            }
        }()
        let shape: LBNaraShape = {
            switch phase {
            case .washingOut: return .washingOut
            case .ended: return .ended
            case .settlingIn, .onTreatment: return freezeOk ? .trial : (building ? .building : .monitoring)
            case .none: return building ? .building : .monitoring
            }
        }()
        if phase == .ended {
            return LBCardCopy(
                thisWeekTitle: "This week's usual",
                slowTitle: "After \(shortName) usual",
                freezeTitle: freezeOk ? "Expected without treatment" : nil,
                offThisWeek: "Off this week",
                offSlow: "Off after \(shortName) usual",
                confidenceSlowLabel: "AFTER",
                naraShape: .ended,
                banner: "\(displayName) · Ended",
                qualifyMessage: nil)
        }
        if freezeOk {
            let onLabel = "On \(shortName) usual"
            return LBCardCopy(
                thisWeekTitle: "This week's usual",
                slowTitle: onLabel,
                freezeTitle: "Expected without treatment",
                offThisWeek: "Off this week",
                offSlow: "Off on \(shortName) usual",
                confidenceSlowLabel: "ON \(shortName.uppercased())",
                naraShape: shape,
                banner: "\(displayName) · \(phaseWord) · started \(start.civilDay) \(start.clockTime)",
                qualifyMessage: nil)
        }
        return LBCardCopy(
            thisWeekTitle: "This week's usual",
            slowTitle: "Longer usual",
            freezeTitle: nil,
            offThisWeek: "Off this week",
            offSlow: "Off longer usual",
            confidenceSlowLabel: "LONGER",
            naraShape: shape,
            banner: "\(displayName) · \(phaseWord)",
            qualifyMessage: "Not enough nights to freeze non-treatment usual"
                + (qualifyReasons.isEmpty ? "" : " (" + qualifyReasons.joined(separator: ", ") + ")"))
    }
}
