import Foundation

// ActivityContextMotionHeadsFusion.swift — how Inertia-1 head probabilities become decoder evidence.
//
// Per head, the window's calibrated distribution q over supported classes is turned into a likelihood
// RATIO against the calibration prior π: r(y) = q(y) / π(y). An uninformative head (q = π) therefore gives
// r ≡ 1 and changes nothing, whatever the class set. Before that:
//   • an abstained class is merged into its `merge_into` partner (q and π summed), so the distinction the
//     bundle could not make carries no evidence; an abstained class without a partner is conditioned out
//     (q and π renormalised over the rest) and its mass lowers the window's reliability instead;
//   • a covering class (`covers`) stands for every class it absorbed.
// The per-mode likelihood is L(m) = clip(Σ_g A[m,g]·r(g), 0.1, 10), where A is NOT a new hand-tuned table:
// it is the decoder's own soft mapping of mode m onto the head (`ModeProfile.posture` / `.locomotion`, or the
// identity for the arm chain) without `unknown`, an ε = 0.02 floor and renormalisation, coarsened to the
// merge groups. Covering classes take the element-wise max over the rows of the classes they cover.
//
// The channels (all distinct from HART's encoder channel, never averaged with it):
//   • locomotion → body chain, weight w_l·rel, × (1 − hartRedundancy) while the HART channel speaks;
//   • posture    → body chain, but renormalised INSIDE the stationary / transition set S against the
//                  current belief, so it moves mass only within S and never changes P(S) (moving modes and
//                  `unknown` get 1);
//   • arm        → the arm chain only: arm[i] *= L_arm(i)^(armTemperature · w_a · rel);
//   • transition and movement_intensity are carried and logged only (v1).
// All body terms are added with `isEvidence: false`: they never reduce the missing-sensor unknown bonus.
// rel = Σ_g q_g·γ_g with γ = 1 (strong), 0.5 (weak), 0 (abstained without a partner). An OOD window
// contributes nothing at all. Classes are always iterated in the bundle's fixed class order.

/// One head of a bundle, prepared once per decoder: groups, prior, reliability and compatibility rows.
struct PreparedMotionHead: Sendable {
    let head: MotionHead
    /// Supported classes that carry evidence (abstained classes without a partner removed), in class order.
    let classes: [String]
    /// Group index of each entry of `classes`.
    let groupOf: [Int]
    /// The class each group is named after (the partner every abstained class was merged into).
    let roots: [String]
    /// π per group, renormalised over the kept classes.
    let groupPrior: [Double]
    /// γ per group (status of its root).
    let gamma: [Double]
    let rootStatus: [MotionHeadClassStatus]
    /// τ of each group's root, when the bundle gives one.
    let rootTau: [Double?]
    /// Supported classes conditioned out of the evidence (abstained, no partner); they only lower `rel`.
    let dropped: [String]
    /// Compatibility row per target (body mode index, or arm-state index), over groups. nil = neutral (1).
    let compat: [[Double]?]

    static let epsilon = 0.02
    static let lrClip: ClosedRange<Double> = 0.1...10

    /// The per-target likelihoods for one window (clipped, unknown/neutral rows = 1) and the window's
    /// reliability. nil when the window does not carry this head or puts no mass on the kept classes.
    func evaluate(_ q: [String: Double]?) -> (L: [Double], rel: Double, groupMass: [Double])? {
        guard let q, !classes.isEmpty else { return nil }
        var qg = [Double](repeating: 0, count: roots.count)
        for (i, c) in classes.enumerated() { qg[groupOf[i]] += q[c] ?? 0 }
        var rel = 0.0, kept = 0.0
        for g in 0..<qg.count { rel += qg[g] * gamma[g]; kept += qg[g] }
        guard kept > 0, kept.isFinite else { return nil }
        var r = [Double](repeating: 1, count: qg.count)
        for g in 0..<qg.count { r[g] = max(qg[g] / kept, 1e-9) / groupPrior[g] }
        var L = [Double](repeating: 1, count: compat.count)
        for t in 0..<compat.count {
            guard let row = compat[t] else { continue }
            var s = 0.0
            for g in 0..<row.count { s += row[g] * r[g] }
            L[t] = min(Self.lrClip.upperBound, max(Self.lrClip.lowerBound, s))
        }
        return (L, min(1, max(0, rel)), qg)
    }

    /// Prepare one head. `rowSource(target, class)` is the raw compatibility of a target with a head class
    /// (the decoder's own mapping); a target whose row has no mass is neutral.
    static func prepare(_ spec: MotionHeadSpec, head: MotionHead, targets: Int,
                        neutralTargets: Set<Int>, rowSource: (Int, String) -> Double) -> PreparedMotionHead? {
        let supported = spec.supportedClasses
        guard !supported.isEmpty else { return nil }
        func root(_ c: String) -> String {
            var cur = c
            var hops = 0
            while let next = spec.mergeInto[cur], hops < 32 { cur = next; hops += 1 }
            return cur
        }
        var dropped: [String] = []
        var kept: [String] = []
        for c in supported {
            if spec.status[c] == .abstain && spec.mergeInto[c] == nil { dropped.append(c) } else { kept.append(c) }
        }
        guard !kept.isEmpty else { return nil }
        // Groups in the order their root first appears in class order.
        var roots: [String] = []
        var groupOf: [Int] = []
        for c in kept {
            let r = root(c)
            if let g = roots.firstIndex(of: r) { groupOf.append(g) } else { roots.append(r); groupOf.append(roots.count - 1) }
        }
        var keptPrior = 0.0
        for c in kept { keptPrior += spec.prior[c] ?? 0 }
        guard keptPrior > 0 else { return nil }
        var groupPrior = [Double](repeating: 0, count: roots.count)
        for (i, c) in kept.enumerated() { groupPrior[groupOf[i]] += (spec.prior[c] ?? 0) / keptPrior }
        let rootStatus = roots.map { spec.status[$0] ?? .weak }
        let gamma = rootStatus.map { s -> Double in
            switch s {
            case .strong: return 1
            case .weak: return 0.5
            case .abstain: return 0
            }
        }
        var compat: [[Double]?] = []
        for t in 0..<targets {
            if neutralTargets.contains(t) { compat.append(nil); continue }
            var raw = [Double](repeating: 0, count: kept.count)
            for (i, c) in kept.enumerated() {
                // A covering class reads as every class it covers: the max over their rows.
                var v = rowSource(t, c)
                for covered in spec.covers[c] ?? [] { v = max(v, rowSource(t, covered)) }
                raw[i] = v
            }
            let total = raw.reduce(0, +)
            guard total > 0 else { compat.append(nil); continue }
            var row = raw.map { $0 / total + epsilon }
            let s = row.reduce(0, +)
            row = row.map { $0 / s }
            var grouped = [Double](repeating: 0, count: roots.count)
            for (i, v) in row.enumerated() { grouped[groupOf[i]] += v }
            compat.append(grouped)
        }
        return PreparedMotionHead(head: head, classes: kept, groupOf: groupOf, roots: roots, groupPrior: groupPrior,
                                  gamma: gamma, rootStatus: rootStatus, rootTau: roots.map { spec.tau[$0] },
                                  dropped: dropped, compat: compat)
    }
}

/// The Inertia channels of one decoder, prepared from an accepted `MotionHeadsEvidenceConfig`.
struct PreparedMotionHeads: Sendable {
    let stamp: String
    /// A window applies each second while its age (since the second it was attached to) is below this.
    let holdS: Int
    let locomotionWeight: Double
    let postureWeight: Double
    let armWeight: Double
    let transitionWeight: Double
    let bodyBudget: Double
    let armBudget: Double
    let hartRedundancy: Double
    let locomotion: PreparedMotionHead?
    let posture: PreparedMotionHead?
    let arm: PreparedMotionHead?

    /// Stationary and transition modes: the posture channel moves mass only among these.
    static let postureSet: [BodyMode] = [.bedRest, .seated, .upright, .vehicle, .sitToStand, .standToSit,
                                         .lyingDown, .gettingUp]

    /// Specialist modes Inertia may let through (with the locomotion class that names them).
    static let specialistClass: [(BodyMode, String)] = [(.stairs, "stairs"), (.cycling, "cycling"),
                                                        (.vehicle, "vehicle_motion"), (.otherExercise, "other")]

    /// nil (with the reason) when the config refuses the bundle; the decoder then runs exactly as without it.
    static func prepare(_ config: MotionHeadsEvidenceConfig?) -> (prepared: PreparedMotionHeads?, refusal: String?) {
        guard let config else { return (nil, nil) }
        if let why = config.evidenceRefusal { return (nil, why) }
        guard let stamp = config.provenanceStamp else { return (nil, "no_stamp") }
        let n = BodyMode.count
        let unknown: Set<Int> = [BodyMode.unknown.rawValue]
        let profiles = ActivityContextModel.profiles
        let loco = config.bundle.heads[.locomotion].flatMap {
            PreparedMotionHead.prepare($0, head: .locomotion, targets: n, neutralTargets: unknown) { m, c in
                LocomotionClass(rawValue: c).flatMap { profiles[m].locomotion[$0] } ?? 0
            }
        }
        let posture = config.bundle.heads[.posture].flatMap {
            PreparedMotionHead.prepare($0, head: .posture, targets: n, neutralTargets: unknown) { m, c in
                PostureClass(rawValue: c).flatMap { profiles[m].posture[$0] } ?? 0
            }
        }
        let arm = config.bundle.heads[.armBehavior].flatMap {
            PreparedMotionHead.prepare($0, head: .armBehavior, targets: ArmState.count,
                                       neutralTargets: [ArmState.unknown]) { i, c in
                ArmState.classes[i].rawValue == c ? 1 : 0
            }
        }
        guard loco != nil || posture != nil || arm != nil else { return (nil, "bundle_has_no_usable_head") }
        return (PreparedMotionHeads(stamp: stamp, holdS: max(1, config.bundle.hopS),
                                    locomotionWeight: config.locomotionWeight, postureWeight: config.postureWeight,
                                    armWeight: config.armWeight, transitionWeight: config.transitionWeight,
                                    bodyBudget: config.bodyBudget, armBudget: config.armBudget,
                                    hartRedundancy: config.hartRedundancy,
                                    locomotion: loco, posture: posture, arm: arm), nil)
    }

    /// Effective per-second weights: the HART redundancy discount on locomotion, the shared body budget
    /// (scaled down, never up) and the arm cap.
    func effectiveWeights(hartSpeaks: Bool) -> (locomotion: Double, posture: Double, arm: Double) {
        var wl = locomotionWeight, wp = postureWeight, wt = transitionWeight
        if hartSpeaks { wl *= min(1, max(0, 1 - hartRedundancy)) }
        let body = wl + wp + wt
        if body > bodyBudget, body > 0 {
            let s = bodyBudget / body
            wl *= s; wp *= s; wt *= s
        }
        return (wl, wp, min(armWeight, armBudget))
    }

    /// Everything Inertia contributes at one second.
    struct Terms {
        /// Locomotion likelihood per body mode and its weight (w_l · rel).
        var locomotion: (L: [Double], weight: Double)?
        /// Posture likelihood per body mode (1 outside S) and its weight (w_p · rel).
        var posture: (L: [Double], weight: Double)?
        /// Arm likelihood per arm state and its exponent weight (w_a · rel, before `armTemperature`).
        var arm: (L: [Double], weight: Double)?
        /// Specialist modes this window lets through (strong class, q ≥ τ, not OOD).
        var opens: Set<Int> = []
    }

    func terms(for window: MotionHeadsWindow, hartSpeaks: Bool) -> Terms? {
        guard !window.isOOD else { return nil }
        let w = effectiveWeights(hartSpeaks: hartSpeaks)
        var t = Terms()
        if let head = locomotion, let e = head.evaluate(window.locomotion) {
            t.locomotion = (e.L, w.locomotion * e.rel)
            if w.locomotion > 0 {
                for (mode, cls) in Self.specialistClass {
                    guard let g = head.roots.firstIndex(of: cls), head.rootStatus[g] == .strong,
                          let tau = head.rootTau[g], e.groupMass[g] >= tau else { continue }
                    t.opens.insert(mode.rawValue)
                }
            }
        }
        if let head = posture, let e = head.evaluate(window.posture) {
            var L = [Double](repeating: 1, count: BodyMode.count)
            for m in Self.postureSet { L[m.rawValue] = e.L[m.rawValue] }
            t.posture = (L, w.posture * e.rel)
        }
        if let head = arm, let e = head.evaluate(window.armBehavior) {
            t.arm = (e.L, w.arm * e.rel)
        }
        if t.locomotion == nil, t.posture == nil, t.arm == nil { return nil }
        return t
    }
}
