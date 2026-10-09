"""hsmm — deterministic Python port of the Swift ActivityContext HSMM decoder (hsmm-1.6).

Python twin of ActivityContextDecoder + ActivityContextModel + ActivityContextEvidence (the
body-scoring subset) from Packages/StrandAnalytics, at the working-tree decoder version hsmm-1.6
with the learned raw-IMU transition-expert evidence channel (4b) and its posture-shift discount (3b).
HART's fine (18-activity) channel and the ElderNet gait channel added in hsmm-1.6 are not ported: the
harness feeds coarse encoder windows and no gait windows, where hsmm-1.6 scores exactly as before. It exists so before/after
transition-expert metrics can be benchmarked in Python and golden-validated against the real Swift
decoder (fixtures/hsmm_golden.json, produced by the scratch Swift package /tmp/hsmm-golden).

Why a port rather than a wrapper: the benchmark harness runs in the research pipeline
(Tools/ActivityContext) and must reproduce the on-device decoder to within 1e-9 with no build-time
Swift dependency and no network. Inference is pure numpy; build-time sklearn/xgboost live elsewhere
(transition_model.py). It is deterministic by construction: every float sum iterates a fixed,
declared order (index order, never dict-iteration order), mirroring the Swift source exactly.

Scope: the subset exercised when the only inputs are per-second IMU windows (ImuWindowFeatures:
accel_rms_g, gyro_rms_dps, jerk_rms, cadence_hz, cadence_strength, orientation_change_deg) plus
optional encoder windows and optional learned transition-expert windows. HR / steps / gravity /
workouts are treated exactly as Swift treats them when those channels are absent (skipped). One
deliberate stub: display-label derivation (ActivityDisplay.derive + hysteresis) is not ported — it
is a derived view that never feeds the body posterior or events, so the published heads and events
are unaffected.

All constants below are transcribed verbatim from the Swift tables (ActivityContextModel.swift,
ActivityContextEvidence.swift, ActivityContextDecoder.swift). Do not re-derive them.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

#: The Swift decoder version this port reproduces. The Swift decoder has since moved on (see
#: ActivityContextVersions.decoder); results from this port describe THIS version only, and decoder changes are
#: validated through the Swift replay harness (Tests/StrandAnalyticsTests/ActivityReplayHarness.swift), not here.
PORTED_DECODER_VERSION = "hsmm-1.6"

# ---------------------------------------------------------------------------
# Body modes (raw order = index; matches BodyMode in ActivityContextModel.swift)
# ---------------------------------------------------------------------------

BODY_MODE_NAMES: Tuple[str, ...] = (
    "unknown", "bed_rest", "seated", "upright", "walk", "brisk_walk", "run", "stairs",
    "cycling", "vehicle", "other_exercise", "sit_to_stand", "stand_to_sit", "lying_down", "getting_up",
)

UNKNOWN, BED_REST, SEATED, UPRIGHT, WALK, BRISK_WALK, RUN, STAIRS = 0, 1, 2, 3, 4, 5, 6, 7
CYCLING, VEHICLE, OTHER_EXERCISE = 8, 9, 10
SIT_TO_STAND, STAND_TO_SIT, LYING_DOWN, GETTING_UP = 11, 12, 13, 14
_BODY_COUNT = len(BODY_MODE_NAMES)

_STATIONARY = (BED_REST, SEATED, UPRIGHT)
_TRANSITION = (SIT_TO_STAND, STAND_TO_SIT, LYING_DOWN, GETTING_UP)

# Posture / locomotion / arm head vocabulary orders (the Swift enum declaration order, which
# HeadProbabilities.total sums in so results are bit-for-bit reproducible).
POSTURE_CLASSES: Tuple[str, ...] = ("recumbent", "seated_likely", "upright_stationary",
                                    "postural_transition", "unknown")
LOCOMOTION_CLASSES: Tuple[str, ...] = ("stationary", "walking", "brisk_walking", "running", "stairs",
                                       "cycling", "vehicle_motion", "other", "unknown")
ARM_CLASSES: Tuple[str, ...] = ("quiet", "desk_like", "fidgeting", "repetitive_hand_motion",
                                "active_gesturing", "exercise_motion", "other", "unknown")
_ARM_UNKNOWN = len(ARM_CLASSES) - 1

# Posture-change event kinds, in the exact order updateTracking considers them.
POSTURAL_EVENT_KINDS: Tuple[Tuple[int, str], ...] = (
    (SIT_TO_STAND, "sit_to_stand_like"),
    (STAND_TO_SIT, "stand_to_sit_like"),
    (LYING_DOWN, "lying_down_like"),
    (GETTING_UP, "getting_up_like"),
)
WALK_START, WALK_STOP, RUN_START, RUN_STOP = "walk_start", "walk_stop", "run_start", "run_stop"

# ---------------------------------------------------------------------------
# Small math helpers (verbatim: acGauss / acSigmoid / acSoftRange)
# ---------------------------------------------------------------------------


def ac_gauss(d: float, sigma: float) -> float:
    z = d / sigma
    return math.exp(-0.5 * z * z)


def ac_sigmoid(x: float) -> float:
    return 1.0 / (1.0 + math.exp(-x))


def ac_soft_range(x: float, lo: float, hi: float, sigma: float, floor: float = 0.03) -> float:
    d = lo - x if x < lo else (x - hi if x > hi else 0.0)
    return max(floor, ac_gauss(d, sigma))

# ---------------------------------------------------------------------------
# Mode profiles (verbatim from the Swift profiles table). One dict per mode, indexed by BodyMode.
# posture/locomotion use integer class ids (see POSTURE_CLASSES / LOCOMOTION_CLASSES orders).
# ---------------------------------------------------------------------------


def _arm(*values: float) -> Tuple[float, ...]:
    s = sum(values)
    return tuple(v / s for v in values)


_STATIONARY_ARM = _arm(0.33, 0.37, 0.12, 0.06, 0.06, 0.0, 0.06)
_STATIONARY_ENC: Dict[str, float] = {"stationary": 0.86, "other_movement": 0.10,
                                     "walking": 0.03, "running": 0.01}
_TRANSITION_ENC: Dict[str, float] = {"other_movement": 0.45, "stationary": 0.35,
                                     "walking": 0.18, "running": 0.02}


def _profile(mean_dwell_s, phases, exits, posture, locomotion, move, move_is_burst,
             move_is_median, gait_expect, cadence, orient_path, hr_rel, encoder, arm,
             sleep_asleep, workout, requires_label=None):
    return dict(mean_dwell_s=mean_dwell_s, phases=phases, exits=tuple(exits),
                posture=dict(posture), locomotion=dict(locomotion),
                move_lo=move[0], move_hi=move[1], move_is_burst=move_is_burst,
                move_is_median=move_is_median, gait_expect=gait_expect,
                cadence=None if cadence is None else (cadence[0], cadence[1]),
                orient_lo=orient_path[0], orient_hi=orient_path[1],
                hr_rel=hr_rel, encoder=dict(encoder), arm=tuple(arm),
                sleep_asleep=sleep_asleep, workout=workout, requires_label=requires_label)

# Posture ids: recumbent=0, seated_likely=1, upright_stationary=2, postural_transition=3, unknown=4.
# Locomotion ids: stationary=0, walking=1, brisk_walking=2, running=3, stairs=4, cycling=5,
# vehicle_motion=6, other=7, unknown=8.
_PROFILES: Tuple[dict, ...] = (
    # unknown — re-acquisition prior; observation profile unused (flat).
    _profile(15, 1,
             ((SEATED, 0.28), (UPRIGHT, 0.20), (BED_REST, 0.10), (WALK, 0.14), (BRISK_WALK, 0.04),
              (RUN, 0.02), (STAIRS, 0.02), (CYCLING, 0.02), (VEHICLE, 0.04), (OTHER_EXERCISE, 0.04),
              (UNKNOWN, 0.10)),
             {4: 1.0}, {8: 1.0}, (0.0, 1.0), False, False, 0.5, None, (0.0, 2.0), 0.3,
             {}, _arm(1, 1, 1, 1, 1, 1, 1), 0.3, 0.5),
    # bedRest
    _profile(1800, 2,
             ((GETTING_UP, 0.60), (SEATED, 0.10), (UPRIGHT, 0.05), (WALK, 0.05), (UNKNOWN, 0.20)),
             {0: 0.88, 4: 0.12}, {0: 0.97, 8: 0.03}, (0.0, 0.20), False, True, 0.0, None,
             (0.0, 0.9), 0.06, _STATIONARY_ENC, _STATIONARY_ARM, 1.0, 0.05),
    # seated
    _profile(900, 2,
             ((SIT_TO_STAND, 0.50), (UPRIGHT, 0.06), (LYING_DOWN, 0.06), (BED_REST, 0.04),
              (WALK, 0.06), (VEHICLE, 0.05), (OTHER_EXERCISE, 0.02), (BRISK_WALK, 0.02),
              (CYCLING, 0.02), (UNKNOWN, 0.17)),
             {1: 0.84, 2: 0.10, 4: 0.06}, {0: 0.97, 8: 0.03}, (0.0, 0.50), False, False, 0.0, None,
             (0.0, 0.9), 0.08, _STATIONARY_ENC, _STATIONARY_ARM, 0.2, 0.35),
    # upright (standing, stationary)
    _profile(100, 2,
             ((WALK, 0.40), (STAND_TO_SIT, 0.18), (SEATED, 0.10), (BRISK_WALK, 0.05), (STAIRS, 0.03),
              (RUN, 0.02), (LYING_DOWN, 0.02), (CYCLING, 0.02), (VEHICLE, 0.03),
              (OTHER_EXERCISE, 0.03), (UNKNOWN, 0.12)),
             {2: 0.72, 1: 0.20, 4: 0.08}, {0: 0.97, 8: 0.03}, (0.0, 0.50), False, False, 0.0, None,
             (0.0, 0.9), 0.12, _STATIONARY_ENC, _arm(0.38, 0.12, 0.20, 0.08, 0.16, 0.0, 0.06),
             0.2, 0.6),
    # walk
    _profile(90, 2,
             ((UPRIGHT, 0.50), (BRISK_WALK, 0.10), (STAIRS, 0.06), (RUN, 0.04), (SEATED, 0.03),
              (VEHICLE, 0.03), (CYCLING, 0.03), (OTHER_EXERCISE, 0.03), (UNKNOWN, 0.18)),
             {4: 1.0}, {1: 0.93, 2: 0.04, 8: 0.03}, (0.42, 0.78), False, False, 1.0, (70.0, 125.0),
             (0.3, 1.5), 0.35, {"walking": 0.86, "other_movement": 0.07, "stationary": 0.05,
                                "running": 0.02},
             _arm(0.25, 0.0, 0.08, 0.04, 0.05, 0.04, 0.54), 0.04, 0.9),
    # briskWalk
    _profile(240, 2,
             ((WALK, 0.35), (UPRIGHT, 0.25), (RUN, 0.15), (OTHER_EXERCISE, 0.05), (STAIRS, 0.03),
              (SEATED, 0.05), (UNKNOWN, 0.12)),
             {4: 1.0}, {2: 0.88, 1: 0.08, 3: 0.02, 8: 0.02}, (0.55, 0.88), False, False, 1.0,
             (105.0, 150.0), (0.4, 1.6), 0.50,
             {"walking": 0.72, "running": 0.12, "other_movement": 0.08, "brisk_walking": 0.06,
              "stationary": 0.02},
             _arm(0.12, 0.0, 0.05, 0.03, 0.05, 0.15, 0.60), 0.04, 1.0),
    # run
    _profile(600, 2,
             ((WALK, 0.35), (UPRIGHT, 0.25), (BRISK_WALK, 0.15), (OTHER_EXERCISE, 0.05), (SEATED, 0.05),
              (UNKNOWN, 0.15)),
             {4: 1.0}, {3: 0.93, 2: 0.04, 8: 0.03}, (0.62, 1.0), False, False, 1.0, (135.0, 210.0),
             (0.4, 1.6), 0.65, {"running": 0.86, "walking": 0.10, "other_movement": 0.04},
             _arm(0.05, 0.0, 0.03, 0.02, 0.02, 0.45, 0.43), 0.04, 1.0),
    # stairs
    _profile(40, 2,
             ((WALK, 0.55), (UPRIGHT, 0.20), (BRISK_WALK, 0.08), (SEATED, 0.07), (UNKNOWN, 0.10)),
             {4: 1.0}, {4: 0.70, 1: 0.25, 8: 0.05}, (0.45, 0.85), False, False, 1.0, (60.0, 115.0),
             (0.4, 1.5), 0.50,
             {"stairs": 0.90, "walking": 0.60, "other_movement": 0.20, "running": 0.05},
             _arm(0.20, 0.0, 0.08, 0.03, 0.05, 0.08, 0.56), 0.04, 0.9, "stairs"),
    # cycling
    _profile(1200, 2,
             ((UPRIGHT, 0.35), (WALK, 0.25), (SEATED, 0.15), (VEHICLE, 0.05), (OTHER_EXERCISE, 0.05),
              (UNKNOWN, 0.15)),
             {4: 1.0}, {5: 0.80, 7: 0.10, 8: 0.10}, (0.15, 0.62), False, False, 0.15, None,
             (0.1, 1.1), 0.50,
             {"cycling": 0.90, "other_movement": 0.55, "stationary": 0.15, "walking": 0.10,
              "running": 0.03},
             _arm(0.20, 0.0, 0.05, 0.15, 0.02, 0.30, 0.28), 0.05, 1.0, "cycling"),
    # vehicle
    _profile(900, 2,
             ((UPRIGHT, 0.30), (WALK, 0.30), (SEATED, 0.20), (UNKNOWN, 0.20)),
             {1: 0.55, 4: 0.45}, {6: 0.80, 0: 0.10, 8: 0.10}, (0.05, 0.42), False, False, 0.0, None,
             (0.05, 0.9), 0.12,
             {"vehicle_motion": 0.90, "stationary": 0.40, "other_movement": 0.35, "walking": 0.05},
             _arm(0.35, 0.12, 0.20, 0.05, 0.08, 0.0, 0.20), 0.1, 0.2, "vehicle_motion"),
    # otherExercise
    _profile(300, 2,
             ((UPRIGHT, 0.35), (WALK, 0.25), (SEATED, 0.10), (RUN, 0.05), (CYCLING, 0.05),
              (BRISK_WALK, 0.05), (UNKNOWN, 0.15)),
             {4: 1.0}, {7: 0.80, 8: 0.20}, (0.45, 1.0), False, False, 0.35, None, (0.3, 1.7), 0.60,
             {"other_movement": 0.70, "running": 0.20, "walking": 0.10, "stationary": 0.05},
             _arm(0.05, 0.0, 0.08, 0.15, 0.10, 0.50, 0.12), 0.04, 1.0, "other_movement"),
    # sitToStand
    _profile(5, 2,
             ((UPRIGHT, 0.70), (WALK, 0.25), (UNKNOWN, 0.05)),
             {3: 0.80, 4: 0.20}, {0: 0.85, 7: 0.10, 8: 0.05}, (0.30, 0.85), True, False, 0.10, None,
             (0.5, 1.7), 0.20, _TRANSITION_ENC, _arm(0.20, 0.05, 0.30, 0.02, 0.10, 0.0, 0.33),
             0.3, 0.5),
    # standToSit
    _profile(5, 2,
             ((SEATED, 0.90), (UNKNOWN, 0.10)),
             {3: 0.80, 4: 0.20}, {0: 0.85, 7: 0.10, 8: 0.05}, (0.30, 0.85), True, False, 0.10, None,
             (0.5, 1.7), 0.20, _TRANSITION_ENC, _arm(0.20, 0.05, 0.30, 0.02, 0.10, 0.0, 0.33),
             0.3, 0.5),
    # lyingDown
    _profile(8, 2,
             ((BED_REST, 0.90), (UNKNOWN, 0.10)),
             {3: 0.80, 4: 0.20}, {0: 0.85, 7: 0.10, 8: 0.05}, (0.25, 0.85), True, False, 0.05, None,
             (0.5, 1.7), 0.15, _TRANSITION_ENC, _arm(0.20, 0.05, 0.30, 0.02, 0.10, 0.0, 0.33),
             0.6, 0.3),
    # gettingUp
    _profile(8, 2,
             ((SEATED, 0.35), (UPRIGHT, 0.50), (WALK, 0.10), (UNKNOWN, 0.05)),
             {3: 0.80, 4: 0.20}, {0: 0.85, 7: 0.10, 8: 0.05}, (0.25, 0.85), True, False, 0.10, None,
             (0.5, 1.7), 0.20, _TRANSITION_ENC, _arm(0.20, 0.05, 0.30, 0.02, 0.10, 0.0, 0.33),
             0.6, 0.5),
)

# ---------------------------------------------------------------------------
# Weights, "no information" constants, prior, bed-entry scaling
# ---------------------------------------------------------------------------

W_MOTION, W_GAIT, W_ORIENT, W_ENCODER, W_ARM, W_HR, W_GATE = 1.0, 1.0, 0.7, 0.8, 0.4, 0.35, 1.0
W_SHIFT, W_HR_TREND = 1.0, 0.6
# W_TRANSITION is Swift wTransition = 0.6; the HsmmDecoder.run default is 0.0 so that supplying
# transition_windows without a weight leaves Model A bit-identical (the parent sweeps it later).
W_TRANSITION = 0.6
U_MOTION, U_GAIT, U_ORIENT, U_ENCODER, U_ARM, U_HR, U_GATE = 0.20, 0.35, 0.35, 0.30, 0.25, 0.55, 0.30
U_SHIFT, U_TRANSITION = 0.30, 0.30
SHIFT_WEIGHT_WITH_EXPERT = 0.5


def _transition_age_factor(age):
    if age is None:
        return 1.0
    return 1.0 if age <= 2 else (0.8 if age <= 4 else 0.5)

MIN_CHANNELS = 3
MISSING_CHANNEL_BONUS = 0.6
SHIFT_HAZARD = 0.15

# ActivityContextDecoder constants.
POSTURAL_EVENT_FLOOR = 0.20
LEAK = 2e-3
EVENT_CAP = 24
CLEAR_FLOOR = POSTURAL_EVENT_FLOOR / 2   # 0.10
GAP_RESET_S = 120
PUBLISH_INTERVAL_S = 5
EVENT_HOLD_S = 15
HISTORY_WINDOW_S = 900

# ActivityIntensity scale anchors (ActivityContextEvidence.swift).
_INTENSITY_FLOOR_G = 0.005
_INTENSITY_CEILING_G = 1.5


def _prior() -> List[float]:
    p = [0.01] * _BODY_COUNT
    p[UNKNOWN] = 0.45
    p[SEATED] = 0.17
    p[UPRIGHT] = 0.12
    p[WALK] = 0.05
    p[BED_REST] = 0.03
    t = sum(p)
    return [v / t for v in p]


_PRIOR = _prior()


def _arm_prior() -> List[float]:
    p = [0.05] * len(ARM_CLASSES)
    p[0] = 0.25   # quiet
    p[1] = 0.15   # desk
    p[_ARM_UNKNOWN] = 0.30
    t = sum(p)
    return [v / t for v in p]


_ARM_PRIOR = _arm_prior()


def _arm_stay() -> List[float]:
    s = [0.92] * len(ARM_CLASSES)
    s[0] = 0.97; s[1] = 0.96; s[2] = 0.90; s[3] = 0.94; s[4] = 0.90; s[5] = 0.97; s[6] = 0.92
    s[_ARM_UNKNOWN] = 0.85
    return s


_ARM_STAY = _arm_stay()

# ---------------------------------------------------------------------------
# Body layout (Erlang-expanded state space; mirrors the private BodyLayout in the decoder)
# ---------------------------------------------------------------------------


def _build_layout():
    start: List[int] = []
    phases: List[int] = []
    advance: List[float] = []
    exits: List[List[Tuple[int, float]]] = []
    cursor = 0
    for m in range(_BODY_COUNT):
        p = _PROFILES[m]
        start.append(cursor)
        phases.append(p["phases"])
        advance.append(min(0.9, float(p["phases"]) / p["mean_dwell_s"]))
        cursor += p["phases"]
        w = [(to, wt) for (to, wt) in p["exits"] if wt > 0]
        t = 0.0
        for (_, wt) in w:
            t += wt
        exits.append([(to, wt / t) for (to, wt) in w])
    total = cursor

    def scaled(rows, k):
        out = []
        for row in rows:
            w = [(to, wt * k if (to == BED_REST or to == LYING_DOWN) else wt) for (to, wt) in row]
            t = 0.0
            for (_, wt) in w:
                t += wt
            out.append([(to, wt / t) for (to, wt) in w])
        return out

    exits_awake = scaled(exits, 0.5)          # bedEntryScale(.awake)
    exits_unknown = scaled(exits, 0.3)        # bedEntryScale(.unknown)
    return dict(start=start, phases=phases, advance=advance, exits=exits,
                exits_awake=exits_awake, exits_unknown=exits_unknown, total=total)


_LAYOUT = _build_layout()


def _expand(mode_mass: Sequence[float]) -> List[float]:
    s = [0.0] * _LAYOUT["total"]
    for m in range(_BODY_COUNT):
        s[_LAYOUT["start"][m]] = mode_mass[m]
    return s


# Intensity scale (ActivityIntensity.scale, ActivityContextEvidence.swift): 5 mg -> 0, 1.5 g -> 1.
_INT_LO = math.log10(_INTENSITY_FLOOR_G)
_INT_HI = math.log10(_INTENSITY_CEILING_G)


def _intensity_scale(g: float) -> float:
    if not (math.isfinite(g) and g > 0):
        return 0.0
    return min(1.0, max(0.0, (math.log10(g) - _INT_LO) / (_INT_HI - _INT_LO)))

# ---------------------------------------------------------------------------
# Causal feature window (mirrors ActivityFeatureWindow, ActivityContextEvidence.swift)
# ---------------------------------------------------------------------------

_HORIZON_S = 40


@dataclass
class _Sample:
    ts: int
    moveG: Optional[float] = None
    dynG: Optional[float] = None
    ux: Optional[float] = None
    uy: Optional[float] = None
    uz: Optional[float] = None
    ticks: Optional[int] = None
    cls: Optional[int] = None
    hr: Optional[int] = None


class FeatureWindow:
    """Causal ring of recent seconds + held imu/encoder/transition windows (Swift twin).

    Only the IMU-only observation subset is fed by HsmmDecoder.run: every observation carries a
    wear=.onWrist / sleep=.awake / inBed=false context and an optional imu/encoder/transition
    window. dynAccelG, gravity, steps, HR and workouts stay absent, exactly as in the golden.
    """

    def __init__(self):
        self.samples: List[_Sample] = []
        self.hr_buckets: List[List[int]] = []          # [t0, sum, n]
        self.imu = None                                # dict(s, e, features)
        self.encoder = None                            # dict(s, e, probs, calibrated, abstained)
        self.transition = None                         # dict(s, e, none..get_up, abstained)
        self.last_sleep = "unknown"
        self.last_sleep_ts: Optional[int] = None
        self.last_wear = "unknown"
        self.last_workout_ts: Optional[int] = None
        self.last_workout_kind = "unspecified"
        self.last_hr_ts: Optional[int] = None
        self.last_hr: Optional[int] = None
        self.imu_seen_ts: Optional[int] = None
        self.encoder_seen_ts: Optional[int] = None
        self.transition_seen_ts: Optional[int] = None

    def reset(self) -> None:
        self.__init__()

    def push(self, obs) -> dict:
        """Ingest one observation and return the features dict at its timestamp (Swift push())."""
        if obs["imu"] is not None:
            self.imu = obs["imu"]
            self.imu_seen_ts = obs["ts"]
        if obs["encoder"] is not None:
            self.encoder = obs["encoder"]
            self.encoder_seen_ts = obs["ts"]
        if obs["transition"] is not None:
            self.transition = obs["transition"]
            self.transition_seen_ts = obs["ts"]
        self.last_sleep = obs["sleep"]
        if obs["sleep"] != "unknown":
            self.last_sleep_ts = obs["ts"]
        self.last_wear = obs["wear"]
        if obs["logged_workout"]:
            self.last_workout_ts = obs["ts"]
            self.last_workout_kind = obs["workout_kind"]

        s = _Sample(ts=obs["ts"])
        d = obs.get("dyn_accel_g")
        imu = self.imu
        if d is not None and math.isfinite(d) and d >= 0:
            s.dynG = d
            s.moveG = d
        elif imu is not None and obs["ts"] - imu["e"] <= 4 and math.isfinite(imu["accel_rms_g"]):
            s.moveG = imu["accel_rms_g"]
        g = obs.get("gravity")
        if g is not None and len(g) >= 3:
            n = math.sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2])
            if math.isfinite(n) and n > 1e-6:
                s.ux = g[0] / n
                s.uy = g[1] / n
                s.uz = g[2] / n
        s.ticks = obs.get("step_ticks")
        s.cls = obs.get("strap_class")
        hr = obs.get("hr_bpm")
        if hr is not None and 30 <= hr <= 220:
            s.hr = hr
            self.last_hr = hr
            self.last_hr_ts = obs["ts"]
            self._add_heart_rate(hr, obs["ts"])

        if self.samples and self.samples[-1].ts == obs["ts"]:
            self.samples[-1] = s
        else:
            self.samples.append(s)
        cutoff = obs["ts"] - _HORIZON_S
        if self.samples and self.samples[0].ts < cutoff:
            self.samples = [x for x in self.samples if x.ts >= cutoff]

        return self._features(obs["ts"])

    def _add_heart_rate(self, hr: int, ts: int) -> None:
        bucket_s = 15
        t0 = ts - ((ts % bucket_s) + bucket_s) % bucket_s
        if self.hr_buckets and self.hr_buckets[-1][0] == t0:
            self.hr_buckets[-1][1] += hr
            self.hr_buckets[-1][2] += 1
        elif self.hr_buckets and self.hr_buckets[-1][0] > t0:
            return
        else:
            self.hr_buckets.append([t0, hr, 1])
        cutoff = ts - 270
        if self.hr_buckets and self.hr_buckets[0][0] < cutoff:
            self.hr_buckets = [b for b in self.hr_buckets if b[0] >= cutoff]

    def _slice(self, now: int, seconds: int) -> List[_Sample]:
        return [s for s in self.samples if s.ts > now - seconds]

    @staticmethod
    def _mean_move(sl: List[_Sample]) -> Optional[float]:
        total = 0.0
        n = 0
        for s in sl:
            if s.moveG is not None:
                total += s.moveG
                n += 1
        return total / n if n > 0 else None

    @staticmethod
    def _angle(a: _Sample, b: _Sample) -> Optional[float]:
        if a.ux is None or a.uy is None or a.uz is None or b.ux is None or b.uy is None or b.uz is None:
            return None
        d = min(1.0, max(-1.0, a.ux * b.ux + a.uy * b.uy + a.uz * b.uz))
        return math.acos(d) * 180.0 / math.pi

    def _net(self, now: int, seconds: int) -> Optional[float]:
        if not self.samples or self.samples[-1].ux is None:
            return None
        cur = self.samples[-1]
        best = None
        for s in self.samples:
            if s.ux is None:
                continue
            if abs((now - s.ts) - seconds) <= 1:
                if best is None or abs((now - s.ts) - seconds) < abs((now - best.ts) - seconds):
                    best = s
        if best is None:
            return None
        return self._angle(best, cur)

    def _mean_direction(self, now: int, lo: int, hi: int):
        sx = sy = sz = 0.0
        n = 0
        for s in self.samples:
            if hi >= 0 and s.ts > now - hi and s.ts <= now - lo and s.ux is not None \
                    and s.uy is not None and s.uz is not None:
                sx += s.ux
                sy += s.uy
                sz += s.uz
                n += 1
        if n == 0:
            return None
        norm = math.sqrt(sx * sx + sy * sy + sz * sz)
        if not (norm > 1e-6):
            return None
        return ([sx / norm, sy / norm, sz / norm], n)

    def _features(self, now: int) -> dict:
        w4 = self._slice(now, 4)
        w10 = self._slice(now, 10)
        w30 = self._slice(now, 30)
        w6 = self._slice(now, 6)

        m4v = self._mean_move(w4)
        m4 = _intensity_scale(m4v) if m4v is not None else None
        m10v = self._mean_move(w10)
        m30v = self._mean_move(w30)
        m10 = _intensity_scale(m10v) if m10v is not None else None
        m30 = _intensity_scale(m30v) if m30v is not None else None

        # Burst: the strongest 3-s mean inside the last 10 s.
        burst_g = None
        moves = [(s.ts, s.moveG) for s in w10 if s.moveG is not None]
        if len(moves) >= 3:
            for i in range(len(moves)):
                lo = moves[i][0]
                total = 0.0
                n = 0
                for j in range(i, len(moves)):
                    if moves[j][0] < lo + 3:
                        total += moves[j][1]
                        n += 1
                if n >= 2:
                    burst_g = max(burst_g if burst_g is not None else 0.0, total / n)
        m_burst10 = _intensity_scale(burst_g) if burst_g is not None else None

        # Burstiness over 30 s on linear acceleration.
        lin = [s.moveG for s in w30 if s.moveG is not None]
        med = None
        if len(lin) >= 10:
            sorted_lin = sorted(lin)
            mid = len(sorted_lin) // 2
            med = sorted_lin[mid] if len(sorted_lin) % 2 == 1 else (sorted_lin[mid - 1] + sorted_lin[mid]) / 2
        cv = None
        if len(lin) >= 15:
            mean = sum(lin) / len(lin)
            if mean > 1e-4:
                v = sum((x - mean) * (x - mean) for x in lin) / len(lin)
                cv = math.sqrt(v) / mean
        m_med30 = _intensity_scale(med) if med is not None else None

        # Gait from the step counter (primary) is absent in the IMU-only subset; the IMU rhythm and
        # cadence fallback below mirror the Swift exactly (including its strength bar).
        gait = None
        cadence = None
        run_share = None

        rhythm = None
        imu_live = None
        if self.imu is not None and now - self.imu["e"] <= 6:
            imu_live = self.imu
            rhythm = imu_live.get("cadence_strength")
        if gait is None and imu_live is not None and imu_live.get("cadence_hz") is not None \
                and imu_live.get("cadence_strength", 0.0) >= 0.25:
            strength = imu_live["cadence_strength"]
            gait = min(0.7, max(0.0, (strength - 0.25) / 0.35) * 0.7)
            cadence = imu_live["cadence_hz"] * 60

        # Orientation path / net change from the gravity direction (absent in the IMU-only subset;
        # net5 falls back to the window orientation change, exactly like Swift).
        path = None
        steps = 0.0
        step_n = 0
        g10 = list(w10)
        if len(g10) >= 2:
            for i in range(1, len(g10)):
                if g10[i].ts - g10[i - 1].ts <= 2:
                    a = self._angle(g10[i - 1], g10[i])
                    if a is not None:
                        steps += a
                        step_n += 1
            if step_n >= 5:
                path = steps / step_n
        net5 = self._net(now, 5)
        net30 = self._net(now, 30)
        if net5 is None and imu_live is not None and imu_live.get("orientation_change_deg") is not None:
            net5 = imu_live["orientation_change_deg"]

        # Held orientation now vs. the orientation before any recent movement burst.
        shift_net = None
        cur_dir = self._mean_direction(now, 0, 3)
        if cur_dir is not None and cur_dir[1] >= 2:
            base = self._mean_direction(now, 14, 32)
            if base is not None and base[1] >= 6:
                recent = [s for s in self.samples if s.ts > now - 3 and s.ux is not None]
                settled = True
                if recent:
                    a = self._angle(recent[0], recent[-1])
                    if a is not None and a > 20:
                        settled = False
                if settled:
                    d = min(1.0, max(-1.0, cur_dir[0][0] * base[0][0] + cur_dir[0][1] * base[0][1]
                                     + cur_dir[0][2] * base[0][2]))
                    shift_net = math.acos(d) * 180.0 / math.pi

        # Heart rate (absent in the IMU-only subset).
        hr = None
        hr_rel = None
        if self.last_hr is not None and self.last_hr_ts is not None and now - self.last_hr_ts <= 10:
            hr = float(self.last_hr)
            hr_rel = min(1.2, max(-0.3, (hr - 60.0) / max(30.0, 190.0 - 60.0)))

        # Encoder (held for a few seconds, then ignored).
        enc = None
        enc_age = None
        if self.encoder is not None and now - self.encoder["e"] <= 6:
            enc = self.encoder
            enc_age = max(0, now - self.encoder["e"])

        # Learned transition expert (held like the encoder; age measured from its arrival second).
        trans = None
        trans_age = None
        if self.transition is not None and self.transition_seen_ts is not None \
                and now - self.transition_seen_ts <= 6:
            trans = self.transition
            trans_age = max(0, now - self.transition_seen_ts)

        # Provenance over the last 30 s.
        has_dyn = any(s.dynG is not None for s in w30)
        has_grav = any(s.ux is not None for s in w30)
        has_steps = any(s.ticks is not None for s in w30)
        has_hr = any(s.hr is not None for s in w30)
        has_imu = self.imu is not None and now - self.imu["e"] <= 30
        has_enc = self.encoder is not None and now - self.encoder["e"] <= 30
        has_sleep = self.last_sleep_ts is not None and now - self.last_sleep_ts <= 30
        has_move = any(s.moveG is not None for s in w30)
        coverage = 0.0
        if has_move:
            coverage += 0.35
        if has_steps:
            coverage += 0.20
        if has_enc:
            coverage += 0.15
        if has_grav:
            coverage += 0.10
        if has_hr:
            coverage += 0.10
        if has_imu:
            coverage += 0.05
        if has_sleep:
            coverage += 0.05

        logged_workout = self.last_workout_ts is not None and now - self.last_workout_ts <= 2
        slope = None  # hrSlope needs HR buckets; absent in the IMU-only subset.
        return dict(
            ts=now, m4=m4, m10=m10, m30=m30, m_med30=m_med30, m_burst10=m_burst10, cv30=cv,
            gait_presence=gait, cadence_spm=cadence, run_share6=run_share, rhythm=rhythm,
            orient_path10=path, net5=net5, net30=net30, shift_net=shift_net, hr=hr, hr_rel=hr_rel,
            hr_slope=slope, wear=self.last_wear, sleep=self.last_sleep,
            logged_workout=logged_workout,
            workout_kind=self.last_workout_kind if logged_workout else "unspecified",
            encoder=enc, encoder_age_s=enc_age, transition=trans, transition_age_s=trans_age,
            evidence=dict(imu=has_imu, encoder=has_enc, dyn_accel=has_dyn, gravity=has_grav,
                          steps=has_steps, heart_rate=has_hr, sleep=has_sleep, coverage=coverage),
            window_fill=min(10, len(w10)),
        )

# ---------------------------------------------------------------------------
# Observation model (mirrors ActivityContextModel.score + helpers)
# ---------------------------------------------------------------------------


def _shift_strength(f: dict) -> float:
    net = f.get("shift_net")
    if net is None:
        return 0.0
    burst = f.get("m_burst10") if f.get("m_burst10") is not None else 0.0
    gait = f.get("gait_presence") if f.get("gait_presence") is not None else 0.0
    return ac_sigmoid((net - 50) / 10) * ac_sigmoid((burst - 0.38) / 0.05) * (1 - min(1, gait))


def _smooth_step(x: float) -> float:
    t = min(1, max(0, x))
    return t * t * (3 - 2 * t)


def _exertion(f: dict) -> float:
    hr = f.get("hr_rel")
    if hr is None:
        return 0.0
    level = _smooth_step((hr - 0.30) / (0.45 - 0.30))
    slope = f.get("hr_slope") if f.get("hr_slope") is not None else 0.0
    falling = min(1, max(0, -slope / 6))
    rising = min(1, max(0, slope / 6))
    onset = rising * _smooth_step((hr - 0.15) / 0.12)
    return min(1, max(0, level * (1 - 0.6 * falling) + 0.5 * onset * (1 - level)))


def _arm_pattern(f: dict) -> List[float]:
    n_arm = len(ARM_CLASSES)
    q = [0.2] * n_arm
    m = f.get("m10") if f.get("m10") is not None else f.get("m4")
    if m is None:
        q[_ARM_UNKNOWN] = 1.0
        return q
    burst = f.get("m_burst10") if f.get("m_burst10") is not None else m
    g = f.get("gait_presence") if f.get("gait_presence") is not None else 0.0
    not_gait = 1 - 0.9 * ac_sigmoid((g - 0.5) / 0.15)
    cv_high = ac_sigmoid((f["cv30"] - 0.9) / 0.2) if f.get("cv30") is not None else 0.5
    cv_low = 1 - 0.9 * ac_sigmoid((f["cv30"] - 1.1) / 0.2) if f.get("cv30") is not None else 0.7
    path = math.log10(1 + f["orient_path10"]) if f.get("orient_path10") is not None else 0.4

    q[0] = ac_soft_range(m, 0.0, 0.16, 0.05) * ac_soft_range(burst, 0.0, 0.38, 0.08)   # quiet
    q[1] = ac_soft_range(m, 0.18, 0.50, 0.05) * not_gait * cv_low * ac_soft_range(path, 0.0, 0.85, 0.2)
    q[2] = ac_soft_range(burst, 0.40, 0.95, 0.08) * ac_soft_range(m, 0.15, 0.65, 0.08) \
        * (0.1 + 0.9 * cv_high) * not_gait
    if f.get("rhythm") is not None:
        q[3] = ac_sigmoid((f["rhythm"] - 0.35) / 0.10) * ac_soft_range(m, 0.30, 0.75, 0.08) * not_gait
    else:
        q[3] = 0.15
    q[4] = ac_soft_range(m, 0.45, 0.85, 0.08) * ac_sigmoid((path - 0.8) / 0.15) * not_gait
    exercise = ac_soft_range(m, 0.72, 1.0, 0.06)
    hr = f.get("hr_rel")
    if hr is not None and hr >= 0.45:
        exercise = max(exercise, 0.6 * ac_soft_range(m, 0.5, 1.0, 0.1))
    if f["logged_workout"]:
        exercise = max(exercise, 0.7)
    walk_swing = (1 - not_gait) * (1 - ac_sigmoid((m - 0.78) / 0.04))
    if not f["logged_workout"]:
        exercise *= 1 - 0.85 * walk_swing
    q[5] = exercise
    q[6] = 0.30 + 0.5 * walk_swing
    q[_ARM_UNKNOWN] = 0.20
    return q


def _workout_covers(mode: int, kind: str) -> bool:
    if kind == "unspecified":
        return True
    if kind == "running":
        return mode == OTHER_EXERCISE
    if kind == "walking":
        return mode == STAIRS
    if kind == "cycling":
        return mode == CYCLING
    return mode == OTHER_EXERCISE or mode == STAIRS

def _score(f: dict, temperature: float, w_transition: float = 0.0):
    """Score every body mode against the features (Swift ActivityContextModel.score).

    Returns (logL, disagreement, has_motion, channels). Channel order is fixed (1, 2, 3, 3b, 4, 4b,
    5, 6, 6a, 6b, 7) so weightSum accumulation is bit-identical to Swift.
    """
    n = _BODY_COUNT
    logL = [0.0] * n
    dis = [0.0] * n
    weight_sum = 0.0
    channels = 0

    def add(values, unknown_value, weight, is_evidence=True):
        nonlocal weight_sum, channels
        if is_evidence:
            channels += 1
        weight_sum += weight
        best = max(max(values), 1e-6)
        for m in range(n):
            if m == UNKNOWN:
                logL[m] += weight * math.log(unknown_value)
                dis[m] += weight * min(0.0, math.log(unknown_value / best))
            else:
                v = max(values[m], 1e-6)
                logL[m] += weight * math.log(v)
                dis[m] += weight * math.log(v / best)

    # 1. Movement intensity.
    has_motion = False
    if f["m10"] is not None:
        has_motion = True
        v = [1.0] * n
        for m in range(n):
            if m != UNKNOWN:
                p = _PROFILES[m]
                if p["move_is_burst"]:
                    x = f["m_burst10"] if f["m_burst10"] is not None else f["m10"]
                elif p["move_is_median"]:
                    x = f["m_med30"] if f["m_med30"] is not None else f["m10"]
                else:
                    x = f["m10"]
                v[m] = ac_soft_range(x, p["move_lo"], p["move_hi"], 0.08)
        add(v, U_MOTION, W_MOTION)

    # 2. Gait presence + cadence.
    if f["gait_presence"] is not None:
        g = f["gait_presence"]
        v = [1.0] * n
        for m in range(n):
            if m != UNKNOWN:
                p = _PROFILES[m]
                l = max(0.03, ac_gauss(g - p["gait_expect"], 0.35))
                if f["cadence_spm"] is not None and p["cadence"] is not None and g >= 0.4:
                    l *= ac_soft_range(f["cadence_spm"], p["cadence"][0], p["cadence"][1], 15.0, floor=0.15)
                v[m] = l
        add(v, U_GAIT, W_GAIT)

    # 3. Orientation stability (needs gravity; absent in the IMU-only subset).
    if f["orient_path10"] is not None:
        v = [1.0] * n
        x = math.log10(1 + f["orient_path10"])
        for m in range(n):
            if m != UNKNOWN:
                p = _PROFILES[m]
                v[m] = ac_soft_range(x, p["orient_lo"], p["orient_hi"], 0.25, floor=0.1)
        add(v, U_ORIENT, W_ORIENT)

    # 3b. Posture-shift signature (net5 exists via the IMU orientation change; shiftStrength stays 0
    # without gravity, so this channel pins the transition modes to a 0.05 floor — exactly like Swift).
    # hsmm-1.6: while the learned transition expert speaks, the share of this heuristic that reports the
    # same burst (strength s) is discounted toward SHIFT_WEIGHT_WITH_EXPERT, scaled by the expert's age decay.
    trans = f["transition"]
    transition_share = 0.0
    if w_transition > 0 and trans is not None and not trans.get("abstained", False):
        transition_share = _transition_age_factor(f["transition_age_s"])
    if f["net5"] is not None:
        s = _shift_strength(f)
        v = [1.0] * n
        for m in range(n):
            if m != UNKNOWN:
                if m in _TRANSITION:
                    v[m] = 0.05 + 0.95 * s
                elif m in _STATIONARY:
                    v[m] = 1 - 0.9 * s
        add(v, U_SHIFT, W_SHIFT * (1 - (1 - SHIFT_WEIGHT_WITH_EXPERT) * s * transition_share))

    # 4. Short-window motion encoder.
    if f["encoder"] is not None:
        enc = f["encoder"]
        known = 0.0
        probs = []
        for label in sorted(enc["probs"].keys()):
            if label == "unknown":
                continue
            p = enc["probs"][label]
            if p > 0:
                probs.append((label, p))
                known += p
        if known > 0:
            v = [1.0] * n
            for m in range(n):
                if m != UNKNOWN:
                    total = 0.0
                    compat = _PROFILES[m]["encoder"]
                    for (label, p) in probs:
                        total += (p / known) * compat.get(label, 0.02)
                    v[m] = max(0.01, total)
            w = W_ENCODER
            if not enc.get("calibrated", True):
                w *= 0.6
            if enc.get("abstained", False):
                w *= 0.4
            if f["encoder_age_s"] is not None:
                age = f["encoder_age_s"]
                w *= 1.0 if age <= 2 else (0.8 if age <= 4 else 0.5)
            add(v, U_ENCODER, w)

    # 4b. Learned raw-IMU transition expert (channel added in hsmm-1.4, rebalanced in hsmm-1.5). Abstained evidence skips
    # the channel entirely (the Swift `if let trans = f.transition, !trans.abstained`); the parent
    # task text suggested a 0.4x weight instead — the golden is built from the real Swift, so the
    # skip behaviour is what parity demands. w_transition defaults to 0.0 (Model A bit-identical).
    if f["transition"] is not None and not f["transition"].get("abstained", False):
        # hsmm-1.5: every non-transition mode (moving ones too) takes P(none) support, the transition
        # modes take their class probability without a second (1 - P(none)) factor, and the unknown
        # mode takes the mean of the known values so the channel never shifts mass into/out of unknown.
        t = f["transition"]
        none_p = min(1.0, max(0.0, t["none"]))
        v = [1.0] * n
        total, count = 0.0, 0
        for m in range(n):
            if m != UNKNOWN:
                if m == SIT_TO_STAND:
                    v[m] = 0.05 + 0.95 * min(1.0, max(0.0, t["sit_to_stand"]))
                elif m == STAND_TO_SIT:
                    v[m] = 0.05 + 0.95 * min(1.0, max(0.0, t["stand_to_sit"]))
                elif m == LYING_DOWN:
                    v[m] = 0.05 + 0.95 * min(1.0, max(0.0, t["lie_down"]))
                elif m == GETTING_UP:
                    v[m] = 0.05 + 0.95 * min(1.0, max(0.0, t["get_up"]))
                else:
                    v[m] = 0.05 + 0.95 * none_p
                total += v[m]
                count += 1
        add(v, total / count if count else 1.0, w_transition * _transition_age_factor(f["transition_age_s"]))

    # 5. Instantaneous arm pattern -> body mode compat.
    if f["m10"] is not None or f["m4"] is not None:
        q = _arm_pattern(f)
        qs = 0.0
        for a in range(_ARM_UNKNOWN):
            qs += q[a]
        if qs > 0:
            v = [1.0] * n
            for m in range(n):
                if m != UNKNOWN:
                    total = 0.0
                    arm_row = _PROFILES[m]["arm"]
                    for a in range(_ARM_UNKNOWN):
                        total += (q[a] / qs) * arm_row[a]
                    v[m] = min(1.0, max(0.01, total * 3.2))
            add(v, U_ARM, W_ARM)

    # 6. Heart rate (weak).
    if f["hr_rel"] is not None:
        hr = f["hr_rel"]
        v = [1.0] * n
        for m in range(n):
            if m != UNKNOWN:
                v[m] = max(0.05, ac_gauss(hr - _PROFILES[m]["hr_rel"], 0.3))
        add(v, U_HR, W_HR)

    # 6a. Heart-rate trend (not an evidence channel).
    if f["hr_slope"] is not None and f["hr_rel"] is not None and f["hr_rel"] >= 0.25:
        recovering = min(1.0, max(0.0, (-f["hr_slope"] - 2) / 6))
        if recovering > 0:
            v = [1.0] * n
            for m in range(n):
                if m != UNKNOWN and _PROFILES[m]["hr_rel"] >= 0.45:
                    v[m] = 1 - 0.7 * recovering
            add(v, 1.0, W_HR_TREND, is_evidence=False)

    # 6b. Specialist support (stairs/cycling/vehicle/otherExercise need an encoder label or workout).
    specialists = False
    support = [1.0] * n
    effort = _exertion(f)
    for m in range(n):
        p = _PROFILES[m]
        label = p.get("requires_label")
        if label is None:
            continue
        specialists = True
        said = f["encoder"]["probs"].get(label, 0.0) if f["encoder"] is not None else 0.0
        covered = f["logged_workout"] and p["workout"] >= 0.9 and _workout_covers(m, f["workout_kind"])
        s = 1.0 if (said >= 0.15 or covered) else 0.04
        if m == OTHER_EXERCISE:
            s = max(s, 0.04 + 0.96 * effort)
        support[m] = s
    if specialists:
        add(support, 1.0, 1.0, is_evidence=False)

    # 7. Context gates: sleep and logged workouts.
    if f["sleep"] in ("asleep", "awake") or f["logged_workout"]:
        v = [1.0] * n
        for m in range(n):
            if m != UNKNOWN:
                p = _PROFILES[m]
                l = 1.0
                if f["sleep"] == "asleep":
                    l *= p["sleep_asleep"]
                if f["sleep"] == "awake" and m == BED_REST:
                    l *= 0.8
                if f["logged_workout"]:
                    l *= p["workout"]
                v[m] = max(0.01, l)
        informative = f["sleep"] == "asleep" or f["logged_workout"]
        add(v, U_GATE if informative else 1.0, W_GATE)

    if not has_motion:
        logL[UNKNOWN] += W_MOTION * math.log(1 / U_MOTION) * 0.8
    if channels < MIN_CHANNELS:
        logL[UNKNOWN] += float(MIN_CHANNELS - channels) * MISSING_CHANNEL_BONUS

    for m in range(n):
        logL[m] *= temperature
    if weight_sum > 0:
        for m in range(n):
            dis[m] /= weight_sum
    return logL, dis, has_motion, channels

# ---------------------------------------------------------------------------
# Decoder (mirrors ActivityContextDecoder / ActivityContextTrackBuilder.decode)
# ---------------------------------------------------------------------------


def _arm_context(body_post: List[float]) -> List[float]:
    ctx = [0.0] * len(ARM_CLASSES)
    for m in range(_BODY_COUNT):
        if m == UNKNOWN:
            continue
        arm_row = _PROFILES[m]["arm"]
        for a in range(_ARM_UNKNOWN):
            ctx[a] += body_post[m] * arm_row[a]
    unknown_mass = body_post[UNKNOWN]
    for a in range(_ARM_UNKNOWN):
        ctx[a] = 0.05 + 0.95 * ctx[a] + unknown_mass * (1.0 / 7.0)
    ctx[_ARM_UNKNOWN] = 0.08
    return ctx


def _normalize_head(values: Dict[int, float], classes: Tuple[str, ...]) -> Dict[str, float]:
    """HeadProbabilities(values).normalized(): positive entries, summed in vocabulary order."""
    positive = {c: v for c, v in values.items() if v > 0}
    total = 0.0
    for c in range(len(classes)):
        total += positive.get(c, 0.0)
    if total <= 0:
        return {}
    return {classes[c]: positive[c] / total for c in range(len(classes)) if positive.get(c, 0.0) > 0}


@dataclass
class RunResult:
    """Decoded track: distinct events (kind@ts, max probability) and published states.

    ``events`` mirrors ActivityContextTrack.events (deduped by kind@ts, max probability kept, in
    first-seen order). ``states`` are the 5-s publish-grid states; each carries the body-derived
    heads (posture / locomotion / arm_behavior), intensity, overall confidence/uncertainty and the
    fresh transition event field, matching what the Swift decoder publishes.
    """
    events: List[Dict[str, object]] = field(default_factory=list)
    states: List[Dict[str, object]] = field(default_factory=list)


def _clamp01(x: float) -> float:
    return min(1.0, max(0.0, x))


class HsmmDecoder:
    """Faithful port of the Swift ActivityContext HSMM decoder over IMU-only observations.

    ``run(imu_windows, start_ts, end_ts, ...)`` builds the same per-second observation stream as
    ActivityContextTrackBuilder.observations(for:) (one observation at each window end second, wear
    on-wrist, sleep awake, in-bed false) and decodes it with the hsmm-1.5 tables.
    """

    def __init__(self, temperature: float = 0.35, publish_interval_s: int = 5,
                 gap_reset_s: int = 120, event_hold_s: int = 15, history_window_s: int = 900):
        self.temperature = temperature
        self.publish_interval_s = max(1, publish_interval_s)
        self.gap_reset_s = gap_reset_s
        self.event_hold_s = event_hold_s
        self.history_window_s = history_window_s

    # -- observation stream ---------------------------------------------------

    @staticmethod
    def _parse_imu_window(win) -> Optional[dict]:
        try:
            s, e, f = win
            if not isinstance(f, dict):
                return None
            accel = float(f["accel_rms_g"])
            strength = float(f.get("cadence_strength", 0.0))
            hz = f.get("cadence_hz")
            hz = float(hz) if hz is not None else None
            orient = f.get("orientation_change_deg")
            orient = float(orient) if orient is not None else None
            if not math.isfinite(accel) or not math.isfinite(strength):
                return None
            if (hz is not None and not math.isfinite(hz)) or (orient is not None and not math.isfinite(orient)):
                return None
            return dict(s=int(s), e=int(e), accel_rms_g=accel, gyro_rms_dps=float(f.get("gyro_rms_dps", 0.0)),
                        jerk_rms=float(f.get("jerk_rms", 0.0)), cadence_hz=hz,
                        cadence_strength=strength, orientation_change_deg=orient)
        except Exception:
            return None

    @staticmethod
    def _parse_encoder_window(win) -> Optional[dict]:
        try:
            s, e, f = win
            if not isinstance(f, dict) or not isinstance(f.get("probs"), dict):
                return None
            probs = {str(k): float(v) for k, v in f["probs"].items()}
            if not all(math.isfinite(v) for v in probs.values()):
                return None
            return dict(s=int(s), e=int(e), probs=probs,
                        calibrated=bool(f.get("calibrated", True)),
                        abstained=bool(f.get("abstained", False)),
                        encoder_id=str(f.get("encoder_id", "")),
                        encoder_version=str(f.get("encoder_version", "")))
        except Exception:
            return None

    @staticmethod
    def _parse_transition_window(win) -> Optional[dict]:
        """Parse one (s, e, features) transition window; None when malformed (fail-open).

        Feature keys: none, sit_to_stand, stand_to_sit, lie_down, get_up (class probabilities),
        optional confidence / abstained. A non-finite or missing class probability drops the window.
        """
        try:
            s, e, f = win
            if not isinstance(f, dict):
                return None
            probs = {}
            for key in ("none", "sit_to_stand", "stand_to_sit", "lie_down", "get_up"):
                raw = f.get(key)
                if raw is None:
                    return None
                v = float(raw)
                if not math.isfinite(v):
                    return None
                probs[key] = v
            return dict(s=int(s), e=int(e), none=probs["none"], sit_to_stand=probs["sit_to_stand"],
                        stand_to_sit=probs["stand_to_sit"], lie_down=probs["lie_down"],
                        get_up=probs["get_up"],
                        confidence=float(f.get("confidence", max(probs.values()))),
                        abstained=bool(f.get("abstained", False)))
        except Exception:
            return None

    def run(self, imu_windows, start_ts, end_ts, encoder_windows=None, transition_windows=None,
            w_transition: float = 0.0, streams=None) -> RunResult:
        """Decode a stream and return events + published states.

        imu_windows:      list of (s, e, imu-feat-1 feature dict)
        encoder_windows:  optional list of (s, e, {probs, calibrated, abstained}) dicts
        transition_windows: optional list of (s, e, {none, sit_to_stand, stand_to_sit, lie_down,
                          get_up, confidence, abstained}) dicts (malformed ones are dropped)
        w_transition:     channel-4b weight (default 0.0 == Model A bit-identical; the Swift
                          constant is 0.6 — pass that for Swift parity with expert evidence)
        streams:          optional production-shaped per-second strap streams —
                          {"gravity": [(ts, ux, uy, uz), ...],
                           "dyn_accel": [(ts, g), ...],
                           "step_ticks": [(ts, n), ...] (optional)} —
                          the channels the phone actually feeds the decoder alongside the
                          encoder/IMU windows (the golden scenarios use None: IMU-only).
                          Feeding gravity unlocks the shift heuristic's shiftNet exactly as in
                          production, which is what an honest Model A comparison needs.
                          Malformed entries are dropped, never fatal (fail-open like every
                          optional channel).
        """
        # Fail-open: malformed transition windows are dropped, never fatal (the learned expert is an
        # optional channel). Imu/encoder windows are the harness's own data: a malformed one is a
        # contract violation and raises a clear error instead of silently changing the stream.
        imus = [self._parse_imu_window(w) for w in imu_windows]
        bad_imu = [w for w in imus if w is None]
        if bad_imu:
            raise ValueError(f"malformed imu window: {bad_imu[0]!r} "
                             "(need (s, e, {accel_rms_g, cadence_strength, ...}))")
        encs = []
        if encoder_windows is not None:
            encs = [self._parse_encoder_window(w) for w in encoder_windows]
            bad_enc = [w for w in encs if w is None]
            if bad_enc:
                raise ValueError(f"malformed encoder window: {bad_enc[0]!r} "
                                 "(need (s, e, {probs, ...}))")
        trans = []
        if transition_windows is not None:
            trans = [self._parse_transition_window(w) for w in transition_windows]
            trans = [w for w in trans if w is not None]

        # Optional production strap streams (gravity / dynAccel / step ticks per second). Dropped
        # wholesale on malformed input: they widen what the decoder can claim but must never be
        # able to fail a decode (the same fail-open contract every optional channel has).
        gravity_at: Dict[int, tuple] = {}
        dyn_at: Dict[int, float] = {}
        ticks_at: Dict[int, int] = {}
        if streams:
            try:
                for g in (streams.get("gravity") or []):
                    ts, ux, uy, uz = (int(g[0]), float(g[1]), float(g[2]), float(g[3]))
                    if math.isfinite(ux) and math.isfinite(uy) and math.isfinite(uz):
                        gravity_at[ts] = (ux, uy, uz)
                for d in (streams.get("dyn_accel") or []):
                    ts, v = int(d[0]), float(d[1])
                    if math.isfinite(v) and v >= 0:
                        dyn_at[ts] = v
                for t in (streams.get("step_ticks") or []):
                    ts, v = int(t[0]), int(t[1])
                    if v >= 0:
                        ticks_at[ts] = v
            except Exception:
                gravity_at, dyn_at, ticks_at = {}, {}, {}

        # Per-second observation stream, mirroring observations(for:) keyed by end second. Any window
        # ending inside [start_ts, end_ts) creates an observation at its end second; later windows at
        # the same second win (same as the Swift dictionaries keyed by endTs). Strap-stream seconds
        # without a window still produce an observation (the phone streams every second it has data).
        obs_at: Dict[int, dict] = {}
        for ts in sorted(set(gravity_at) | set(dyn_at) | set(ticks_at)):
            if start_ts <= ts < end_ts:
                obs_at[ts] = dict(ts=ts, imu=None)
        for w in imus:
            if start_ts <= w["e"] < end_ts:
                obs_at[w["e"]] = dict(ts=w["e"], imu=w)
        for w in encs:
            if start_ts <= w["e"] < end_ts:
                obs_at.setdefault(w["e"], dict(ts=w["e"], imu=None))["encoder"] = w
        for w in trans:
            if start_ts <= w["e"] < end_ts:
                obs_at.setdefault(w["e"], dict(ts=w["e"], imu=None))["transition"] = w

        decoder = _DecoderState(self)
        states: List[Dict[str, object]] = []
        for ts in sorted(obs_at.keys()):
            obs = obs_at[ts]
            obs["wear"] = "on_wrist"
            obs["sleep"] = "awake"
            obs["in_bed"] = False
            obs["logged_workout"] = False
            obs["workout_kind"] = "unspecified"
            obs.setdefault("encoder", None)
            obs.setdefault("transition", None)
            obs.setdefault("imu", None)
            g = gravity_at.get(ts)
            if g is not None:
                obs["gravity"] = g
            if ts in dyn_at:
                obs["dyn_accel_g"] = dyn_at[ts]
            if ts in ticks_at:
                obs["step_ticks"] = ticks_at[ts]
            st = decoder.ingest(obs, w_transition=w_transition)
            if st is not None:
                states.append(st)

        # Track events: dedupe published states' fresh transition fields by kind@ts, keep max prob
        # (ActivityContextTrackBuilder.decode).
        events: List[Dict[str, object]] = []
        index: Dict[str, int] = {}
        for st in states:
            tr = st.get("transition")
            if tr is None:
                continue
            key = f'{tr["kind"]}@{tr["ts"]}'
            if key in index:
                i = index[key]
                if tr["prob"] > events[i]["prob"]:
                    events[i]["prob"] = tr["prob"]
            else:
                index[key] = len(events)
                events.append(dict(tr))
        return RunResult(events=events, states=states)

class _DecoderState:
    """Per-stream decoder state: body/arm beliefs, feature window and tracking (Swift twin)."""

    def __init__(self, host: "HsmmDecoder"):
        self.host = host
        self.body = _expand(_PRIOR)
        self.arm = list(_ARM_PRIOR)
        self.window = FeatureWindow()
        self.last_ts: Optional[int] = None
        # tracking (DecoderTracking)
        self.moving = False
        self.running = False
        self.last_moving_ts: Optional[int] = None
        self.stationary_since_ts: Optional[int] = None
        self.active_postural: Optional[dict] = None
        self.events: List[Dict[str, object]] = []
        self.last_agreement = 1.0
        self.last_evidence: Optional[dict] = None
        self.last_window_fill = 0
        self.last_intensity: Optional[float] = None
        self.last_sleep = "unknown"
        self.last_in_bed = False
        self.last_wear = "unknown"
        self.last_has_motion = False
        self.last_publish_ts: Optional[int] = None
        self.arm_display: Optional[List[float]] = None

    # -- belief updates -------------------------------------------------------

    def _reset_belief(self) -> None:
        self.body = _expand(_PRIOR)
        self.arm = list(_ARM_PRIOR)
        self.window.reset()
        self.moving = False
        self.running = False
        self.stationary_since_ts = None
        self.active_postural = None
        self.last_window_fill = 0
        self.arm_display = None

    def _predict_body(self, shift: float) -> None:
        layout = _LAYOUT
        next_b = [0.0] * layout["total"]
        exit_table = layout["exits_awake"] if self.last_sleep == "awake" else \
            (layout["exits"] if self.last_sleep == "asleep" else layout["exits_unknown"])
        for m in range(_BODY_COUNT):
            start = layout["start"][m]
            k = layout["phases"][m]
            p = layout["advance"][m]
            for j in range(k):
                a = self.body[start + j]
                if a == 0:
                    continue
                moved = a * p
                next_b[start + j] += a - moved
                if j < k - 1:
                    next_b[start + j + 1] += moved
                else:
                    for (to, w) in exit_table[m]:
                        next_b[layout["start"][to]] += moved * w

        # A clear posture-shift burst raises the hazard of the matching transition: diverts a slice
        # of the stationary mass into the transition mode (direction from where the mass is).
        if shift > 0.05:
            h = SHIFT_HAZARD * shift

            def divert(frm, to, weight):
                fraction = min(0.5, h * weight)
                s0 = layout["start"][frm]
                moved = 0.0
                for j in range(layout["phases"][frm]):
                    d = next_b[s0 + j] * fraction
                    next_b[s0 + j] -= d
                    moved += d
                next_b[layout["start"][to]] += moved

            divert(SEATED, SIT_TO_STAND, 1.0)
            divert(UPRIGHT, STAND_TO_SIT, 1.0)
            divert(SEATED, LYING_DOWN, 0.25)
            divert(UPRIGHT, LYING_DOWN, 0.15)
            divert(BED_REST, GETTING_UP, 0.35 if self.last_sleep == "asleep" else 1.0)
        self.body = next_b

    def _apply_body(self, logL: List[float], dis: List[float]) -> None:
        mx = max(logL)
        total = 0.0
        layout = _LAYOUT
        for m in range(_BODY_COUNT):
            l = math.exp(logL[m] - mx)
            start = layout["start"][m]
            for j in range(layout["phases"][m]):
                self.body[start + j] *= l
                total += self.body[start + j]
        if not (total > 1e-300) or not math.isfinite(total):
            self.body = _expand(_PRIOR)
            return
        prior = _expand(_PRIOR)
        eps = LEAK
        for s in range(len(self.body)):
            self.body[s] = (1 - eps) * (self.body[s] / total) + eps * prior[s]

    def _body_posterior(self) -> List[float]:
        b = [0.0] * _BODY_COUNT
        layout = _LAYOUT
        for m in range(_BODY_COUNT):
            start = layout["start"][m]
            for j in range(layout["phases"][m]):
                b[m] += self.body[start + j]
        return b

    def _predict_arm(self) -> None:
        a = len(ARM_CLASSES)
        ctx = _arm_context(self._body_posterior())
        next_arm = [0.0] * a
        for i in range(a):
            stay = _ARM_STAY[i]
            next_arm[i] += self.arm[i] * stay
            out = self.arm[i] * (1 - stay)
            denom = 0.0
            for j in range(a):
                if j != i:
                    denom += ctx[j]
            for j in range(a):
                if j != i:
                    next_arm[j] += out * ctx[j] / denom
        self.arm = next_arm

    def _apply_arm(self, f: dict) -> None:
        q = _arm_pattern(f)
        tau = 0.5  # armTemperature
        total = 0.0
        for i in range(len(ARM_CLASSES)):
            self.arm[i] *= math.pow(max(1e-6, q[i]), tau)
            total += self.arm[i]
        if not (total > 1e-300) or not math.isfinite(total):
            self.arm = list(_ARM_PRIOR)
            return
        prior = _ARM_PRIOR
        for i in range(len(ARM_CLASSES)):
            self.arm[i] = (1 - LEAK) * (self.arm[i] / total) + LEAK * prior[i]

    def _smooth_arm_for_display(self) -> None:
        alpha = 1.0 / max(1, 45)
        e = self.arm_display
        if e is not None and len(e) == len(ARM_CLASSES):
            for i in range(len(ARM_CLASSES)):
                e[i] += alpha * (self.arm[i] - e[i])
            self.arm_display = e
        else:
            self.arm_display = list(self.arm)

    # -- tracking / events ----------------------------------------------------

    def _record(self, kind: str, p: float, ts: int) -> None:
        self.events.append({"kind": kind, "probability": _clamp01(p), "ts": ts})
        if len(self.events) > EVENT_CAP:
            self.events = self.events[len(self.events) - EVENT_CAP:]

    def _update_tracking(self, post: List[float], ts: int) -> None:
        p_moving = post[WALK] + post[BRISK_WALK] + post[RUN] + post[STAIRS]
        p_run = post[RUN]
        p_stationary = post[BED_REST] + post[SEATED] + post[UPRIGHT]

        if p_moving >= 0.5:
            self.last_moving_ts = ts

        if not self.moving and p_moving >= 0.6:
            self.moving = True
            self._record(WALK_START, p_moving, ts)
        elif self.moving and p_moving <= 0.3:
            self.moving = False
            self._record(WALK_STOP, 1 - p_moving, ts)
        if not self.running and p_run >= 0.55:
            self.running = True
            self._record(RUN_START, p_run, ts)
        elif self.running and p_run <= 0.25:
            self.running = False
            self._record(RUN_STOP, 1 - p_run, ts)

        if p_stationary >= 0.6:
            if self.stationary_since_ts is None:
                self.stationary_since_ts = ts
        elif p_stationary <= 0.4:
            self.stationary_since_ts = None

        # Posture-change events: one event per excursion of a transition mode above the floor.
        if self.active_postural is not None:
            mass = post[self.active_postural["mode"]]
            if mass > self.active_postural["prob"]:
                self.active_postural["prob"] = mass
                for i in range(len(self.events) - 1, -1, -1):
                    if (self.events[i]["kind"] == self.active_postural["kind"]
                            and self.events[i]["ts"] == self.active_postural["ts"]):
                        self.events[i]["probability"] = mass
                        break
            if mass < CLEAR_FLOOR:
                self.active_postural = None
        else:
            best = None
            for (mode, kind) in POSTURAL_EVENT_KINDS:
                p = post[mode]
                if best is None or p > best[2]:
                    best = (mode, kind, p)
            if best is not None and best[2] >= POSTURAL_EVENT_FLOOR:
                self.active_postural = {"kind": best[1], "mode": best[0], "ts": ts, "prob": best[2]}
                self._record(best[1], best[2], ts)

        cutoff = ts - self.host.history_window_s
        self.events = [e for e in self.events if e["ts"] >= cutoff]

    # -- publishing -----------------------------------------------------------

    def _publish_if_due(self, ts: int) -> Optional[Dict[str, object]]:
        interval = self.host.publish_interval_s
        if self.last_publish_ts is not None:
            due = (ts - self.last_publish_ts >= interval and ts % interval == 0) \
                or ts - self.last_publish_ts >= 2 * interval
        else:
            due = ts % interval == 0
        if not due:
            return None
        self.last_publish_ts = ts
        return self._build_state(ts)

    def _build_state(self, ts: int) -> Dict[str, object]:
        post = self._body_posterior()
        posture: Dict[int, float] = {c: 0.0 for c in range(len(POSTURE_CLASSES))}
        loco: Dict[int, float] = {c: 0.0 for c in range(len(LOCOMOTION_CLASSES))}
        for m in range(_BODY_COUNT):
            if post[m] > 0:
                p = _PROFILES[m]
                for (c, w) in p["posture"].items():
                    posture[c] += post[m] * w
                for (c, w) in p["locomotion"].items():
                    loco[c] += post[m] * w
        arm_dist: Dict[int, float] = {i: self.arm[i] for i in range(len(ARM_CLASSES))}

        posture_head = _normalize_head(posture, POSTURE_CLASSES)
        loco_head = _normalize_head(loco, LOCOMOTION_CLASSES)
        arm_head = _normalize_head(arm_dist, ARM_CLASSES)

        unknown_mass = post[UNKNOWN]
        h = 0.0
        for p in post:
            if p > 0:
                h -= p * math.log(p)
        entropy = min(1.0, h / math.log(float(_BODY_COUNT)))
        coverage = self.last_evidence["coverage"] if self.last_evidence is not None else 0.0
        warm = min(1.0, self.last_window_fill / 10)
        confidence = (1 - unknown_mass) * (1 - 0.5 * entropy) * self.last_agreement
        confidence *= 0.45 + 0.55 * coverage
        confidence *= 0.5 + 0.5 * warm
        if not self.last_has_motion:
            confidence *= 0.5
        if self.last_wear == "unknown":
            confidence *= 0.95
        confidence = _clamp01(confidence)
        uncertainty = _clamp01(0.5 * entropy + 0.5 * min(1.0, unknown_mass
                                                         + (1 - self.last_agreement) * 0.5))

        fresh = None
        for e in self.events:
            if e["ts"] <= ts and ts - e["ts"] <= self.host.event_hold_s:
                fresh = {"kind": e["kind"], "prob": e["probability"], "ts": e["ts"]}

        return dict(
            ts=ts,
            posture={k: v for k, v in posture_head.items()},
            locomotion={k: v for k, v in loco_head.items()},
            arm_behavior={k: v for k, v in arm_head.items()},
            intensity=self.last_intensity,
            overall_confidence=confidence,
            overall_uncertainty=uncertainty,
            transition=fresh,
        )

    def ingest(self, obs: dict, w_transition: float = 0.0) -> Optional[Dict[str, object]]:
        """Feed one second of evidence; returns a published state when one is due (Swift ingest)."""
        if self.last_ts is not None and obs["ts"] <= self.last_ts:
            return None

        first_ever = self.last_ts is None
        if self.last_ts is not None:
            gap = obs["ts"] - self.last_ts
            if gap > self.host.gap_reset_s:
                self._reset_belief()
            elif gap > 1:
                for _ in range(1, gap):
                    self._predict_body(0.0)
                    self._predict_arm()

        self.last_sleep = obs["sleep"]
        self.last_in_bed = obs["in_bed"]
        self.last_wear = obs["wear"]

        if obs["wear"] == "off_wrist":
            # Off-wrist suspends inference (never reached in the IMU-only subset; ported for parity).
            self.last_ts = obs["ts"]
            return self._publish_if_due(obs["ts"])

        f = self.window.push(obs)

        if not first_ever:
            self._predict_body(_shift_strength(f))
            self._predict_arm()
        logL, dis, has_motion, _channels = _score(f, self.host.temperature,
                                                  w_transition=w_transition)
        self._apply_body(logL, dis)
        self._apply_arm(f)
        self._smooth_arm_for_display()

        post = self._body_posterior()
        agreement = 0.0
        for m in range(_BODY_COUNT):
            agreement += post[m] * math.exp(dis[m])
        self.last_agreement = _clamp01(agreement)
        self.last_evidence = f["evidence"]
        self.last_window_fill = f["window_fill"]
        self.last_has_motion = has_motion
        self.last_intensity = f["m10"]
        self._update_tracking(post, obs["ts"])
        self.last_ts = obs["ts"]
        return self._publish_if_due(obs["ts"])
