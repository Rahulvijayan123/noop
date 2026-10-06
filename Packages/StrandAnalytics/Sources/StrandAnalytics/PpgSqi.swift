import Foundation
import WhoopProtocol

// PpgSqi.swift — deterministic PPG signal-quality index for the WHOOP 5/MG v26 optical path.
//
// Pure, Foundation-only, DB-free, network-free: every number below is a pure function of the input
// window, so the same window always produces the same score (the whole pipeline is covered by
// deterministic synthetic-waveform tests). The input is the stored v26 form — one absolute `baseCode`
// plus 24 i16 deltas per second (`PpgWaveformSample`) — reconstructed with WhoopProtocol's own
// `ppgWaveformAbsolute` rather than re-implemented here.
//
// The composite is deliberately NOT a calibrated probability: it is a versioned 0...1 quality index
// whose component thresholds are marked CALIBRATE where they were chosen by inspection rather than
// measured against ground truth. Method sources: Elgendi et al. 2016 (10.3390/s16081097p) for the
// skewness component, Orphanidou et al. 2015 for the template-matching component, and NeuroKit2 (MIT)
// for the feature-extraction approach to both; the periodicity component mirrors WhoopProtocol.PpgHr.

/// Configuration for `PpgSqi.evaluate`. Safe constants are marked; CALIBRATE fields are placeholders
/// that need measurement against real captured PPG before production thresholds are trusted.
public struct PpgSqiConfig: Equatable, Sendable {
    /// Minimum consecutive usable seconds of v26 PPG required before any score is produced. Safe
    /// constant: the same 3 s floor `PpgHr` needs to resolve a low HR (PpgHr.windowSeconds / 2+1).
    public var minCoverageSeconds: Double = 3.0

    /// A delta whose magnitude reaches this threshold counts as encoder-saturated. Default 32767
    /// mirrors `WhoopProtocol.isSaturatedPpgDelta` (the Int16 rails ±32767/±32768), so the default
    /// configuration is exactly that function's semantics; raising it widens what the saturation gate
    /// tolerates. Safe constant.
    public var saturationDeltaLimit: Int = 32767

    /// CALIBRATE: absolute-reconstructed-count band for the detrended RMS amplitude of a usable
    /// window. Placeholders only — real ADC counts depend on strap hardware and optical coupling.
    /// A window whose RMS is outside this band scores 0 (amplitude_out_of_band).
    public var amplitudeMin: Double = 200
    public var amplitudeMax: Double = 8000

    /// Periodicity band (bpm) handed to `PpgHr.estimate`. Safe constants, mirroring PpgHr.hrLoBpm /
    /// PpgHr.hrHiBpm.
    public var hrLoBpm: Double = 30.0
    public var hrHiBpm: Double = 220.0

    /// Minimum normalised ACF peak before a window counts as periodic. Safe constant, mirroring
    /// PpgHr.minConfidence.
    public var minPeriodicityConfidence: Double = 0.3

    /// Absolute bpm tolerance between the PPG-derived rate and the strap HR before the window is
    /// penalised for disagreement. Safe constant (a single bpm is a hard threshold; real straps jitter
    /// a few bpm, so 10 is deliberately loose).
    public var hrAgreementToleranceBpm: Int = 10

    /// Semantic version of the index. Fixed per build; bump when the composition changes so stored
    /// scores stay interpretable.
    public let version = "ppg-sqi-1.0.0"

    /// The shipped configuration.
    public static let standard = PpgSqiConfig()

    public init() {}

    /// Full memberwise init so tests and callers can tune one field without mutating after init.
    public init(minCoverageSeconds: Double = 3.0, saturationDeltaLimit: Int = 32767,
                amplitudeMin: Double = 200, amplitudeMax: Double = 8000,
                hrLoBpm: Double = 30.0, hrHiBpm: Double = 220.0,
                minPeriodicityConfidence: Double = 0.3, hrAgreementToleranceBpm: Int = 10) {
        self.minCoverageSeconds = minCoverageSeconds
        self.saturationDeltaLimit = saturationDeltaLimit
        self.amplitudeMin = amplitudeMin
        self.amplitudeMax = amplitudeMax
        self.hrLoBpm = hrLoBpm
        self.hrHiBpm = hrHiBpm
        self.minPeriodicityConfidence = minPeriodicityConfidence
        self.hrAgreementToleranceBpm = hrAgreementToleranceBpm
    }
}

/// The outcome of one `PpgSqi.evaluate` call.
public struct PpgSqiResult: Equatable, Sendable {
    /// 0...1 composite quality index, or nil when the waveform is UNUSABLE — either a needed second
    /// lacks its absolute `baseCode` (reason base_code_missing) or there is no usable coverage at all
    /// (reason coverage_low, coverageSeconds == 0). A score of 0 (not nil) means the window was usable
    /// but failed a hard gate or component. NOT a calibrated probability: see PpgSqi.
    public let score: Double?
    /// Longest run of consecutive usable seconds in the window (the analysis window).
    public let coverageSeconds: Double
    /// Normalised ACF peak behind `derivedBpm` (0...1), nil when no pulsatile peak cleared
    /// `minPeriodicityConfidence` (flat/garbage PPG).
    public let periodicityConfidence: Double?
    /// Mean Pearson correlation of each ACF-lag-aligned beat with the mean pulse template (0...1),
    /// nil when the beat length is out of the 12...48-sample template band or no beats could be cut.
    public let templateCorrelation: Double?
    /// Skewness of the detrended reconstructed waveform (raw third-moment statistic; the 0...1
    /// mapping lives inside the score). 0 for a flat/DC signal.
    public let skewness: Double?
    /// PPG-derived bpm (whole bpm), nil when periodicity failed.
    public let derivedBpm: Int?
    /// Every failed gate/component, in evaluation order, plus observation-only reasons
    /// (no_hr_reference when no strap HR was supplied). Empty for a clean pass.
    public let reasons: [String]

    public init(score: Double?, coverageSeconds: Double, periodicityConfidence: Double?,
                templateCorrelation: Double?, skewness: Double?, derivedBpm: Int?,
                reasons: [String]) {
        self.score = score
        self.coverageSeconds = coverageSeconds
        self.periodicityConfidence = periodicityConfidence
        self.templateCorrelation = templateCorrelation
        self.skewness = skewness
        self.derivedBpm = derivedBpm
        self.reasons = reasons
    }
}

/// Deterministic PPG signal-quality index over a v26 waveform window.
public enum PpgSqi {
    /// 24 samples per 1-second record — mirrors PpgHr.sampleRateHz and the v26 wire format.
    public static let sampleRateHz = PpgHr.sampleRateHz

    // -- Internal constants (all documented; only the amplitude band and skew mapping are CALIBRATE) --

    /// Maximum peak-to-peak swing (reconstructed absolute counts) below which the window is a flatline.
    /// Safe constant: an encoder-saturated or dead strap reads a constant DC, not sub-count noise.
    static let flatlineEpsilon = 1.0
    /// Saturation gate: more than this fraction of deltas at an Int16 rail fails the window.
    static let maxSaturationFraction = 0.02
    /// Skewness component floor/scale for the smooth 0...1 clamp (CALIBRATE — see `skewNorm`).
    static let skewFloor = 0.3
    static let skewScale = 1.5
    /// HR-agreement penalty: a window whose derived rate disagrees with the strap HR is multiplied by
    /// this factor. Safe constant, deliberately harsh (a clean window that disagrees is a wrong window).
    static let hrDisagreementPenalty = 0.3
    /// Template band at 24 Hz: a beat shorter than 12 samples (>120 bpm) or longer than 48 samples
    /// (<30 bpm) has too few/many samples to make a stable template. Safe constant, from Orphanidou
    /// 2015 (the paper's template is a mean beat over the detected period).
    static let templateMinSamples = 12
    static let templateMaxSamples = 48
    /// Composite weights (CALIBRATE). Renormalised over the available components when tmcc is nil.
    static let skewWeight = 0.4
    static let tmccWeight = 0.4
    static let amplitudeWeight = 0.2

    /// Evaluate the PPG signal-quality index for one v26 window.
    ///
    /// - Parameters:
    ///   - window: per-second v26 records (ts + 24 i16 deltas + absolute baseCode). Duplicate ts are
    ///     last-write-wins; records are analysed as their longest run of consecutive seconds.
    ///   - strapHrBpm: a concurrently measured strap HR, if any (used only for the agreement gate).
    ///   - config: tuning knobs; defaults to `.standard`.
    /// - Returns: a `PpgSqiResult` (never nil — the *score* is nil when the window is unusable).
    public static func evaluate(_ window: [PpgWaveformSample], strapHrBpm: Int?,
                                config: PpgSqiConfig = .standard) -> PpgSqiResult {
        // 1. Deduplicate by ts (last write wins) and sort ascending — mirrors PpgHr.derivePpgHr.
        var byTs: [Int: PpgWaveformSample] = [:]
        for r in window { byTs[r.ts] = r }
        let records = byTs.keys.sorted().map { byTs[$0]! }

        // 2. base_code_missing: any needed second without its absolute base makes the window unusable
        //    (a delta series cannot be inverted without its starting point — WhoopProtocol is explicit
        //    that this nil is TRUE, not merely absent). Checked BEFORE coverage so a window of
        //    base-less seconds reports the true cause, not a secondary coverage_low.
        if records.contains(where: { $0.baseCode == nil }) {
            let usable = records.filter { $0.baseCode != nil }
            return PpgSqiResult(score: nil,
                                coverageSeconds: Self.longestConsecutiveSeconds(usable),
                                periodicityConfidence: nil, templateCorrelation: nil,
                                skewness: nil, derivedBpm: nil,
                                reasons: ["base_code_missing"])
        }

        // 3. Analysis window = longest run of consecutive seconds. Phase is only continuous within a
        //    run, so a gap breaks the waveform (mirrors PpgHr.derivePpgHr's run handling).
        let run = Self.longestRun(records)
        let coverage = Double(run.count)

        // Hard gate: coverage. 0 usable seconds is unusable (nil); some-but-too-little scores 0.
        if coverage == 0 {
            return PpgSqiResult(score: nil, coverageSeconds: 0,
                                periodicityConfidence: nil, templateCorrelation: nil,
                                skewness: nil, derivedBpm: nil, reasons: ["coverage_low"])
        }
        if coverage < config.minCoverageSeconds {
            return PpgSqiResult(score: 0, coverageSeconds: coverage,
                                periodicityConfidence: nil, templateCorrelation: nil,
                                skewness: nil, derivedBpm: nil, reasons: ["coverage_low"])
        }

        // Reconstruct the absolute waveform (WhoopProtocol's own convention: sample[0]=baseCode,
        // sample[i+1]=sample[i]+delta[i]) and keep the raw deltas for the saturation gate + PpgHr.
        // Each record's 25 reconstructed values span times [s*24 ... s*24+24]; the 25th value is the
        // first sample of the NEXT second, so consecutive records share one boundary instant. Drop
        // that duplicate per record (24 values/second) so the waveform stays continuous and periodic —
        // a naive 25-per-record join inserts a stutter at every seam and corrupts periodicity measures.
        var absolute = [Int]()
        var deltas = [Int]()
        for r in run {
            guard let abs = ppgWaveformAbsolute(baseCode: r.baseCode, deltas: r.samples) else { continue }
            absolute.append(contentsOf: abs.dropLast())
            deltas.append(contentsOf: r.samples)
        }
        guard !absolute.isEmpty else {
            return PpgSqiResult(score: nil, coverageSeconds: coverage,
                                periodicityConfidence: nil, templateCorrelation: nil,
                                skewness: nil, derivedBpm: nil, reasons: ["coverage_low"])
        }

        // Hard gate: flatline (dead/constant signal). Checked on the reconstructed absolute swing.
        let minAbs = absolute.min() ?? 0
        let maxAbs = absolute.max() ?? 0
        if Double(maxAbs - minAbs) < Self.flatlineEpsilon {
            return Self.gateFail(coverage: coverage, reason: "flatline")
        }

        // Hard gate: saturation. A delta at an Int16 rail reconstructs only approximately, so more than
        // a small fraction of them means the window cannot be trusted. `saturationDeltaLimit` default
        // makes `abs(delta) >= limit` exactly `isSaturatedPpgDelta` (Int16.min == -32768, max == 32767).
        let saturated = deltas.lazy.filter { isSaturatedPpgDelta($0) || abs($0) >= config.saturationDeltaLimit }.count
        if !deltas.isEmpty && Double(saturated) / Double(deltas.count) > Self.maxSaturationFraction {
            return Self.gateFail(coverage: coverage, reason: "saturation")
        }

        // Detrended waveform: shared by the amplitude gate, the skewness component and the template.
        let x = Self.detrend(absolute.map(Double.init))
        let rms = Self.rms(x)

        // Hard gate: amplitude. The detrended RMS must sit inside the CALIBRATE band.
        if rms < config.amplitudeMin || rms > config.amplitudeMax {
            return Self.gateFail(coverage: coverage, reason: "amplitude_out_of_band")
        }

        // 4. Periodicity: reuse PpgHr's PUBLIC windowed-ACF estimator (8 s window, linear detrend,
        //    record-rate notch, normalised peak, fundamental-period preference). PpgHr.estimate is
        //    the production estimator and takes exactly the v26 delta samples PpgHr.derivePpgHr feeds
        //    it, so mirroring it here means the index and the HR path agree on what is periodic.
        let est = PpgHr.estimate(deltas, fs: PpgHr.sampleRateHz,
                                 loBpm: config.hrLoBpm, hiBpm: config.hrHiBpm,
                                 minConf: config.minPeriodicityConfidence, subLagInterp: false)

        var reasons = [String]()

        // 5. Components (all uncalibrated placeholders, each in 0...1).
        let skew = Self.skewness(x)
        let skewNorm = Self.skewNorm(skew)
        let amplitudeNorm = Self.amplitudeNorm(rms, config: config)

        var tmcc: Double?
        if let est {
            // Beat length from the ACF-lag-derived rate: 60/bpm * fs samples = 1440/bpm at 24 Hz.
            let beatLength = Int((Double(PpgHr.sampleRateHz) * 60.0 / est.bpm).rounded())
            if beatLength < Self.templateMinSamples || beatLength > Self.templateMaxSamples {
                reasons.append("template_too_short_or_long")
            } else {
                tmcc = Self.templateCorrelation(x, beatLength: beatLength)
            }
        } else {
            reasons.append("periodicity_low")
        }

        // 6. HR-agreement gate (only when we reach scoring; a hard-gated window already returned).
        var penalty = 1.0
        if let strapHrBpm {
            if let derivedBpm = est.map { Int($0.bpm) },
               abs(derivedBpm - strapHrBpm) > config.hrAgreementToleranceBpm {
                reasons.append("hr_disagreement")
                penalty = Self.hrDisagreementPenalty
            }
        } else {
            reasons.append("no_hr_reference")
        }

        let derivedBpm = est.map { Int($0.bpm) }
        let periodicityConfidence = est?.conf

        // 7. Composite: periodicity gates the whole index; tmcc nil renormalises its weight over the
        //    available components. Score can never exceed 1 (all factors are in 0...1, plus the
        //    <=1 penalty).
        guard let est else {
            return PpgSqiResult(score: 0, coverageSeconds: coverage,
                                periodicityConfidence: nil, templateCorrelation: nil,
                                skewness: skew, derivedBpm: nil, reasons: reasons)
        }
        var composite: Double
        if let tmcc {
            composite = Self.skewWeight * skewNorm + Self.tmccWeight * tmcc + Self.amplitudeWeight * amplitudeNorm
        } else {
            let available = Self.skewWeight + Self.amplitudeWeight
            composite = (Self.skewWeight * skewNorm + Self.amplitudeWeight * amplitudeNorm) / available
        }
        let score = min(1.0, max(0.0, est.conf * composite * penalty))
        return PpgSqiResult(score: score, coverageSeconds: coverage,
                            periodicityConfidence: periodicityConfidence,
                            templateCorrelation: tmcc, skewness: skew,
                            derivedBpm: derivedBpm, reasons: reasons)
    }

    // MARK: - Internals

    /// Longest run of records with consecutive ts (the analysis window). Returns empty for no records.
    static func longestRun(_ records: [PpgWaveformSample]) -> [PpgWaveformSample] {
        guard var prev = records.first else { return [] }
        var best = [prev]
        var cur = [prev]
        for r in records.dropFirst() {
            if r.ts == prev.ts + 1 { cur.append(r) } else { cur = [r] }
            if cur.count > best.count { best = cur }
            prev = r
        }
        return best
    }

    /// Longest run of CONSECUTIVE ts among the given records, as a Double (0 when none).
    static func longestConsecutiveSeconds(_ records: [PpgWaveformSample]) -> Double {
        Double(longestRun(records).count)
    }

    /// Early-return for a hard-gate failure: score 0, coverage still reported, one reason.
    static func gateFail(coverage: Double, reason: String) -> PpgSqiResult {
        PpgSqiResult(score: 0, coverageSeconds: coverage,
                     periodicityConfidence: nil, templateCorrelation: nil,
                     skewness: nil, derivedBpm: nil, reasons: [reason])
    }

    /// Linear detrend — mirrors PpgHr.detrend (WhoopProtocol/PpgHr.swift) so every statistic here is
    /// computed on the same baseline-removed signal the HR estimator sees. Source: PpgHr.detrend.
    static func detrend(_ x: [Double]) -> [Double] {
        let n = x.count
        guard n > 1 else { return x.map { _ in 0 } }
        let nD = Double(n)
        let sumI = nD * (nD - 1) / 2
        let sumI2 = (nD - 1) * nD * (2 * nD - 1) / 6
        var sumY = 0.0, sumIY = 0.0
        for (i, y) in x.enumerated() { let id = Double(i); sumY += y; sumIY += id * y }
        let denom = nD * sumI2 - sumI * sumI
        guard denom != 0 else {
            let mean = sumY / nD
            return x.map { $0 - mean }
        }
        let slope = (nD * sumIY - sumI * sumY) / denom
        let intercept = (sumY - slope * sumI) / nD
        return x.enumerated().map { (i, y) in y - (slope * Double(i) + intercept) }
    }

    /// Root-mean-square of `x` (0 for an empty input).
    static func rms(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let sumSq = x.reduce(0.0) { $0 + $1 * $1 }
        return (sumSq / Double(x.count)).squareRoot()
    }

    /// Third-moment skewness of `x` (0 when the variance is 0). Method source: Elgendi et al. 2016
    /// (10.3390/s16081097p), skewness-based SQI; feature extraction mirrors NeuroKit2 (MIT) `ppg_sqi`.
    static func skewness(_ x: [Double]) -> Double {
        let n = x.count
        guard n > 1 else { return 0 }
        let mean = x.reduce(0.0, +) / Double(n)
        var m2 = 0.0, m3 = 0.0
        for v in x {
            let d = v - mean
            m2 += d * d
            m3 += d * d * d
        }
        let variance = m2 / Double(n)
        guard variance > 0 else { return 0 }
        let std = variance.squareRoot()
        return (m3 / Double(n)) / (std * std * std)
    }

    /// Smooth 0...1 clamp of |skewness|. CALIBRATE placeholder: the shape is a soft saturating
    /// exponential (0.18 at |skew| = 0, ~0.58 at 1, ~0.78 at 2) so a clean symmetric synthetic pulse
    /// still contributes, while a strongly skewed real PPG pulse saturates toward 1. Needs calibration
    /// against measured PPG before the values are treated as probabilities.
    static func skewNorm(_ skew: Double) -> Double {
        let v = 1.0 - exp(-(abs(skew) + Self.skewFloor) / Self.skewScale)
        return min(1.0, max(0.0, v))
    }

    /// Amplitude component: detrended RMS mapped to 1 at the CALIBRATE band midpoint and 0 at the band
    /// edges (triangular, smooth enough for a placeholder). Uncalibrated: the band itself is
    /// amplitudeMin...amplitudeMax and must be measured against real straps.
    static func amplitudeNorm(_ rms: Double, config: PpgSqiConfig) -> Double {
        let mid = (config.amplitudeMin + config.amplitudeMax) / 2
        let halfWidth = mid - config.amplitudeMin
        guard halfWidth > 0 else { return rms == mid ? 1 : 0 }
        return min(1.0, max(0.0, 1.0 - abs(rms - mid) / halfWidth))
    }

    /// Template-matching component (TMCC, Orphanidou et al. 2015): cut the detrended waveform into
    /// beats of `beatLength` samples starting at sample 0 (the ACF period IS the beat length, so this
    /// is phase-aligned for a periodic window), average them into a mean template, and return the mean
    /// Pearson correlation of each beat with that template, clamped to 0...1. Method source:
    /// Orphanidou 2015 + NeuroKit2 (MIT) `ppg_sqi`/template-matching approach. Noise caveat: at 24 Hz
    /// a beat is only 12...48 samples, so the template is short and the correlation is permissive.
    /// nil when fewer than 2 full beats fit in the window (can't form a template from one beat).
    static func templateCorrelation(_ x: [Double], beatLength: Int) -> Double? {
        let n = x.count
        var beats = [[Double]]()
        var start = 0
        while start + beatLength <= n {
            beats.append(Array(x[start..<(start + beatLength)]))
            start += beatLength
        }
        guard beats.count >= 2 else { return nil }
        var template = [Double](repeating: 0, count: beatLength)
        for beat in beats {
            for (i, v) in beat.enumerated() { template[i] += v }
        }
        let k = Double(beats.count)
        template = template.map { $0 / k }
        var sum = 0.0
        for beat in beats { sum += Self.pearson(beat, template) }
        let mean = sum / Double(beats.count)
        return min(1.0, max(0.0, mean))
    }

    /// Pearson correlation of two equal-length sequences (0 when either has no variance).
    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = a.count
        guard n > 1 else { return 0 }
        let ma = a.reduce(0.0, +) / Double(n)
        let mb = b.reduce(0.0, +) / Double(n)
        var num = 0.0, sa = 0.0, sb = 0.0
        for i in 0..<n {
            let da = a[i] - ma
            let db = b[i] - mb
            num += da * db
            sa += da * da
            sb += db * db
        }
        let denom = (sa * sb).squareRoot()
        guard denom > 0 else { return 0 }
        return num / denom
    }
}
