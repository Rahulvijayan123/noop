import Foundation

// ActivityDecoderPersonalization.swift — the heart-rate reference the activity decoder judges effort against.
//
// The decoder reads heart rate relative to the wearer: "98 bpm" is a brisk effort for someone whose resting rate
// is 48 and barely above rest for someone at 80. With no profile it assumes 60 / 190. This turns a resting
// heart rate (the median of recent nights) and a maximum into a config the decoder can use, refusing anything
// implausible rather than trusting it.
//
// The values are QUANTISED (resting to 3 bpm, maximum to 5 bpm) and exposed as a `cacheTag`. The decoder's
// state is resumable, so a cached day decoded against one reference must not be continued against another;
// the tag goes into the cache key, and quantising means a resting rate that wobbles by a beat between nights
// does not throw away every cached day.

extension ActivityDecoderConfig {
    public static let restingHeartRateBounds: ClosedRange<Double> = 35...100
    public static let maxHeartRateBounds: ClosedRange<Double> = 140...220
    /// The smallest heart-rate reserve (max - resting) worth trusting.
    public static let minimumHeartRateReserve = 60.0

    /// A config for this wearer. Each input that is missing or outside plausible bounds keeps the decoder default.
    public static func personalized(restingHeartRate: Double?, maxHeartRate: Double?) -> ActivityDecoderConfig {
        var config = ActivityDecoderConfig()
        if let rest = restingHeartRate, restingHeartRateBounds.contains(rest) {
            config.restingHeartRate = (rest / 3).rounded() * 3
        }
        if let peak = maxHeartRate, maxHeartRateBounds.contains(peak) {
            config.maxHeartRate = (peak / 5).rounded() * 5
        }
        if config.maxHeartRate - config.restingHeartRate < minimumHeartRateReserve {
            let fallback = ActivityDecoderConfig()
            config.maxHeartRate = max(fallback.maxHeartRate, config.restingHeartRate + minimumHeartRateReserve)
        }
        return config
    }

    /// The wearer's typical resting heart rate: the median of their latest 14 nightly values (oldest first;
    /// nights with no reading are skipped). Fewer than 3 readings is too thin to call typical.
    public static func typicalRestingHeartRate(fromNightly values: [Int?]) -> Double? {
        let recent = values.compactMap { $0 }.suffix(14).sorted()
        guard recent.count >= 3 else { return nil }
        let mid = recent.count / 2
        return recent.count % 2 == 1 ? Double(recent[mid]) : Double(recent[mid - 1] + recent[mid]) / 2
    }

    /// A short, filename-safe tag that differs whenever the heart-rate reference does, and (only when
    /// Inertia-1 evidence is active) whenever its bundle or evidence config does. This is the config's view; a
    /// caller keying a decoded track input uses `ActivityContextTrackBuilder.effectiveConfig(for:config:).cacheTag`, which
    /// drops the Inertia suffix when that input's windows are not from the config's bundle (or it has none).
    ///
    /// ElderNet adds its own suffix (`-eg<weights12><cfgtag>`) only while its evidence is active, after Inertia's,
    /// an adopted personal profile its own (`-pp<tag>`), and a personal sit / stand head its own (`-ss<version><tag>`) last.
    public var cacheTag: String {
        var tag = "r\(Int(restingHeartRate.rounded()))m\(Int(maxHeartRate.rounded()))"
        if let heads = motionHeads, heads.evidenceRefusal == nil {
            tag += "-ih\(heads.bundle.bundle12)\(heads.configTag)"
        }
        if let gait = gaitQuality, gait.evidenceRefusal == nil {
            tag += "-eg\(gait.model.weights12)\(gait.configTag)"
        }
        if let personal = personalProfile, !personal.modes.isEmpty {
            tag += "-pp\(personal.tag)"
        }
        // The personal sit / stand head (`-ss<version><weights hash>`), only while one is set and usable.
        if let head = sitStandHead, head.isUsable {
            tag += "-ss\(head.modelVersion.filter { $0.isLetter || $0.isNumber })\(head.tag)"
        }
        // A non-wrist placement (`-pl<hash>`) and an adopted heart-rate-by-posture model (`-ph<tag>`), hsmm-2.0.
        if let placement = placementTag { tag += "-pl\(placement)" }
        if let hr = postureHeartRate, hr.isUsable { tag += "-ph\(hr.tag)" }
        if stillDurationPrior == false { tag += "-nd" }
        // Per-placement calibration, in key order so the tag is stable.
        for (key, profile) in (placementProfiles ?? [:]).sorted(by: { $0.key < $1.key }) where !profile.modes.isEmpty {
            tag += "-pp\(key.prefix(1))\(profile.tag)"
        }
        for (key, model) in (placementPostureHeartRate ?? [:]).sorted(by: { $0.key < $1.key }) where model.isUsable {
            tag += "-ph\(key.prefix(1))\(model.tag)"
        }
        return tag
    }
}
