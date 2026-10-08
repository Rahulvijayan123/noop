"""Immutable identity and contracts of the wav2sleep PPG-only shadow adapter.

Every value here is a declaration the adapter is held to (Spec 03, "Each adapter needs"):
artifact/source identity, native and model sampling contracts, required channels, preprocessing
revision, trained class meanings, supported-window and quality gates, release mode and the
named downstream consumer. Nothing in this module imports torch, so importing the package never
pulls in the model runtime.
"""

from __future__ import annotations

from typing import Any

# --------------------------------------------------------------------------------------------
# Provider identity
# --------------------------------------------------------------------------------------------

PROVIDER_ID = "wav2sleep.ppg-only.v1"
METRIC = "sleep_stage"
#: Temporal mode, the same vocabulary as the sibling sleep_stage candidate: the model is
#: non-causal (bidirectional over the whole run), so it is retrospective only.
MODE = "retrospective"
#: Release mode. Never raised downstream (docs/model-integration/README.md, "Release modes").
RELEASE_MODE = "shadow"
ADAPTER_VERSION = "wav2sleep.ppg-only.v1/1.0.0"
#: Bumped whenever run assembly, the epoch grid, resampling or normalization changes.
PREPROCESSING_REVISION = "wav2sleep-ppg-preprocessing/1.0.0"
CONFIG_VERSION = "wav2sleep-ppg-gates/1.0.0"
ACCURACY_STATUS = "unverified_accuracy"

#: Off by default; exactly "1" enables (the same rule as the rhythm shadow lanes).
ENABLE_FLAG = "FRWHOOP_WAV2SLEEP_SHADOW_ENABLED"
#: Intra-op thread cap for the forward pass (default 1, clamped to [1, MAX_THREADS]).
THREADS_ENV = "FRWHOOP_WAV2SLEEP_THREADS"
DEFAULT_THREADS = 1
MAX_THREADS = 4

# --------------------------------------------------------------------------------------------
# Source and artifact identity (separate fields on purpose: code commit, weights revision and
# artifact digests are different facts; docs/sleep-analytics/spec.md section 9)
# --------------------------------------------------------------------------------------------

CODE_REPOSITORY = "https://github.com/joncarter1/wav2sleep"
#: Code commit vendored in ../wav2sleep_vendored (2026-07-16, "Update README"). Every vendored
#: file has the same git blob id here as at CODE_CONTENT_SINCE.
CODE_COMMIT = "278e30463c8149c4e6899b8784da492fec695bd9"
CODE_COMMIT_DATE = "2026-07-16"
CODE_CONTENT_SINCE = "8b2a7b1ca5caab4fe7efcf75faa0a125f5ea24c4"
CODE_CONTENT_SINCE_DATE = "2026-02-02"
CODE_LICENSE = "MIT"

WEIGHTS_REPOSITORY = "https://huggingface.co/joncarter/wav2sleep"
#: First Hugging Face commit that carries these exact bytes (2026-02-02T13:11:06Z). The current
#: HEAD (8b6e46ab..., a README-only change) serves identical bytes. The manifest's earlier
#: ``revision`` value 278e3046 is the CODE commit; it is not a Hugging Face revision (its
#: resolve URL returns 404).
WEIGHTS_REVISION = "18fc32f095f10c1f7a91a56298e7598d02c58529"
WEIGHTS_REVISION_DATE = "2026-02-02"
WEIGHTS_LICENSE = "MIT"

#: Relative paths under the artifact root. Kept identical to the existing manifest entry's
#: paths; the directory name is a storage key only - identity is the sha256.
ARTIFACT_DIR = "wav2sleep/278e3046"
ARTIFACTS: dict[str, dict[str, Any]] = {
    "state_dict.pth": {
        "relpath": f"{ARTIFACT_DIR}/state_dict.pth",
        "size_bytes": 9_666_562,
        "sha256": "ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc",
        "url": f"{WEIGHTS_REPOSITORY}/resolve/{WEIGHTS_REVISION}/state_dict.pth",
    },
    "config.yaml": {
        "relpath": f"{ARTIFACT_DIR}/config.yaml",
        "size_bytes": 749,
        "sha256": "b92f4e26f3290f5207b53be343d82a4e338968b54782718f13429e800f114509",
        "url": f"{WEIGHTS_REPOSITORY}/resolve/{WEIGHTS_REVISION}/config.yaml",
        # git blob id of the Hugging Face file at WEIGHTS_REVISION; the same blob is
        # checkpoints/wav2sleep/config.yaml in the code repository at CODE_CONTENT_SINCE.
        "git_blob": "f5a5bcc1eaca8c35f36eccc3f7913f9e1b801353",
    },
}
#: Measured from the strict load: 177 tensors, 2,391,172 float32 parameters (all four
#: encoders are loaded; only the PPG encoder is ever called).
STATE_DICT_KEYS = 177
STATE_DICT_PARAMETERS = 2_391_172

# --------------------------------------------------------------------------------------------
# Sampling contracts
# --------------------------------------------------------------------------------------------

EPOCH_SECONDS = 30
#: The native rate is whatever the request declares (Spec 01 docs/model-integration/README.md,
#: "PPG segments", pinned at 0fd8b94d3): ``ppg.native_rate_hz`` must be one of these AND equal
#: every segment's ``clock.samples_per_second``. Nothing below assumes either value.
#:
#: * 25 - anchored v26 records as Spec 01 now sends them: the anchor plus 24 cumulative deltas,
#:        25 distinct samples per 1-second record; the next record's anchor is the 26th point
#:        (it belongs to the next second);
#: * 24 - the earlier CONTRACTS section 4 convention (points 0..23 of 25 per second).
SUPPORTED_NATIVE_RATES_HZ = (24, 25)
ANCHORED_V26_NATIVE_RATE_HZ = 25


def native_samples_per_epoch(rate_hz: int) -> int:
    """Native samples in one 30-s epoch at the declared rate (720 at 24 Hz, 750 at 25 Hz)."""
    return int(rate_hz) * EPOCH_SECONDS


#: settings.COLS_TO_SAMPLES_PER_EPOCH['PPG'] in the pinned code: 1024 per 30 s = 34.1333 Hz.
MODEL_SAMPLES_PER_EPOCH = 1024
MODEL_RATE_HZ = MODEL_SAMPLES_PER_EPOCH / EPOCH_SECONDS
#: settings.TRAINING_LENGTH_HOURS in the pinned code; the official max sequence is 1200 epochs.
TRAINING_LENGTH_HOURS = 10
MAX_EPOCHS = TRAINING_LENGTH_HOURS * 3600 // EPOCH_SECONDS  # 1200
MAX_WINDOW_SECONDS = TRAINING_LENGTH_HOURS * 3600  # 36000
#: Signed 20-bit optical ADC domain (Whoop5RawOptical.sampleMin/sampleMax).
ADC_SAMPLE_MIN = -524_288
ADC_SAMPLE_MAX = 524_287
#: A reconstructed absolute run whose every sample fits the i16 delta range AND whose median
#: magnitude is this small looks like un-anchored deltas, not absolute counts.
LEGACY_DELTA_ABS_LIMIT = 32_768
LEGACY_DELTA_MEDIAN_LIMIT = 2_048

SAMPLING_CONTRACT: dict[str, Any] = {
    "native": {
        "signal": "WHOOP optical PPG (absolute ADC counts, anchor + cumulative deltas)",
        "rate_hz": "declared by the request (ppg.native_rate_hz == clock.samples_per_second); "
                   f"supported {list(SUPPORTED_NATIVE_RATES_HZ)}; anchored v26 = "
                   f"{ANCHORED_V26_NATIVE_RATE_HZ}",
        "units": "adc_counts",
        "sample_time": "start_unix + j/rate (float64 j/float(rate) relative to the run's epoch "
                       "origin)",
        "endpoint_ownership": "at 25 Hz each record carries its anchor + 24 deltas and the next "
                              "record's anchor is the 26th point; at 24 Hz each second emits points "
                              "0..23 of 25; either way the next second owns the endpoint",
    },
    "model": {
        "signal": "PPG",
        "samples_per_epoch": MODEL_SAMPLES_PER_EPOCH,
        "rate_hz": MODEL_RATE_HZ,
        "grid": "k * 30/1024 s for k = 1..1024*n relative to the epoch origin "
                "(the pinned process_waveform_dataframe grid, which starts one step after 0)",
        "max_epochs": MAX_EPOCHS,
    },
    "resampling": "linear interpolation in time between native samples (the pinned "
                  "interpolate_index(method='index') path), float32 cast; it is tensor "
                  "compatibility only, never accuracy evidence and never added bandwidth",
}

# --------------------------------------------------------------------------------------------
# Channels and classes
# --------------------------------------------------------------------------------------------

#: The only modality admitted. ECG, ABD and THX are ABSENT from the model input (the pinned
#: ``predict_on_folder(signals=['PPG'])`` route: the signal is simply not in the input dict).
REQUIRED_SIGNALS = ("ppg_waveform",)
MODEL_SIGNAL = "PPG"
NOT_ADMITTED_SIGNALS = ("ECG", "ABD", "THX")
#: Keys that would carry a non-PPG modality in a request. Any of them is refused.
FORBIDDEN_INPUT_KEYS = ("ecg", "abd", "thx", "resp", "respiration", "rsa", "effort",
                        "chest", "abdomen", "thorax")

#: Class order of the 4-class checkpoint (settings.INTEGER_LABEL_MAPS[4]: W->0, N1->1, N2->1,
#: N3->2, REM->3; data/utils.convert_int_stage maps N4 to N3).
CLASS_ORDER = ("wake", "light", "deep", "rem")
CLASS_MEANINGS = {
    "wake": "W",
    "light": "N1 + N2",
    "deep": "N3 (legacy N4 scored as N3)",
    "rem": "REM",
}
#: Namespaced so it can never be mistaken for the canonical four-stage display contract or
#: merged with SleepECG's ``wake/rem/nrem`` space.
LABEL_SPACE = "wav2sleep/wake-light-deep-rem"
OUTPUT_TYPES = {
    "probabilities": "class_probabilities (softmax of the model logits; uncalibrated)",
    "logits": "model logits exactly as returned by Wav2Sleep.forward",
    "labels": "argmax label (a different output type; never a probability)",
}

#: The samples reach the model with the sign they arrived with. The released checkpoint is
#: polarity-sensitive (on the synthetic 8-h night a sign flip changed 353/960 argmax epochs at 24 Hz
#: and 316/960 at 25 Hz, max probability change 0.97 / 0.99) and WHOOP's raw optical polarity relative to the PSG oximeter pleth
#: it was trained on is unverified - so nothing is inverted, rectified or auto-corrected here;
#: settling the polarity is an activation gate.
POLARITY = "as_received"

#: Spec 01's counter for a run_id violation (gap or config change inside one run_id): the run is
#: split there, never joined.
RUN_ID_DISCONTINUITY = "ppg_run_id_discontinuity"

#: What must be true before the shadow lane may be activated (WAV2SLEEP.md section 11).
ACTIVATION_GATES = (
    "spec01_anchored_ppg_transport_deployed",
    "overnight_contiguous_ppg_capture",
    "whoop_optical_polarity_and_domain_characterised",
    "sleep_stage_evaluation_set",
    "droplet_cpu_memory_measured",
    "shadow_comparison_consumer_built",
)

# --------------------------------------------------------------------------------------------
# Gates (provisional, not tuned: there is no WHOOP evaluation set)
# --------------------------------------------------------------------------------------------

DEFAULT_CONFIG: dict[str, Any] = {
    # A run shorter than this is not staged (its epochs are masked ``run_too_short``). Two
    # hours ~ the sequence mixer's two-sided receptive field (2 blocks x +/-62 epochs = 249).
    "min_run_epochs": 240,
    # Scored epochs required for the night (4 h) ...
    "min_valid_epochs": 480,
    # ... and as a fraction of the window's whole 30-s epochs.
    "min_coverage_fraction": 0.75,
    # The official max sequence (TRAINING_LENGTH_HOURS = 10). Longer windows are withheld
    # ``night_too_long``; nothing is silently truncated.
    "max_window_seconds": MAX_WINDOW_SECONDS,
    # Bounded parsing work: 10 h of 15-s pieces.
    "max_segments": 2400,
}
#: Bounds a request override must respect (overrides are recorded and enter the cache key).
CONFIG_BOUNDS: dict[str, tuple[float, float]] = {
    "min_run_epochs": (1, MAX_EPOCHS),
    "min_valid_epochs": (1, MAX_EPOCHS),
    "min_coverage_fraction": (0.0, 1.0),
    "max_window_seconds": (EPOCH_SECONDS, MAX_WINDOW_SECONDS),
    "max_segments": (1, 2400),
}

#: Measured, not assumed (docs/pretrained-models/WAV2SLEEP.md, "Resources"): one 10-h PPG-only
#: night (1199 scored epochs), fresh process, Apple M4 Max, torch 2.14.1, under concurrent load.
#: NOT measured on the 4 vCPU / 8 GB Droplet.
MEASURED_RESOURCES: dict[str, Any] = {
    "host": "Apple M4 Max (arm64), macOS, torch 2.14.1, numpy 2.5.3; not the Droplet",
    "model_load_s": [0.046, 0.093],
    "night_10h": {
        "threads_1": {"wall_s": [0.74, 0.93], "cpu_s": [0.78, 0.83]},
        "threads_2": {"wall_s": [0.49, 0.69], "cpu_s": [0.83, 0.98]},
    },
    "peak_rss_mb": [1284, 1302],
    "forward_activation_peak_mb": [890, 900],
    "request_json_bytes_10h": 6_964_300,
    "response_json_bytes_10h": 159_333,
}

# --------------------------------------------------------------------------------------------
# Consumer
# --------------------------------------------------------------------------------------------

DOWNSTREAM_CONSUMER: dict[str, Any] = {
    "name": "sleep_stage_shadow_comparison",
    "status": "proposed (docs/pretrained-models/integration/wav2sleep.md); wired after Spec 01",
    "description": "per-night shadow comparison of these epochs against the canonical stager's "
                   "epochs for the same night and input revision; agreement is monitoring, not "
                   "accuracy evidence",
    "never": ["canonical sleep stages", "apnea events", "user-facing display", "health scores"],
}

# --------------------------------------------------------------------------------------------
# Withheld reasons: detail code -> sidecar WithheldReason (contract.py) value
# --------------------------------------------------------------------------------------------

WIRE_REASON: dict[str, str] = {
    "lane_disabled": "not_ready",
    "artifact_missing": "blocked_artifact",
    "artifact_size_mismatch": "blocked_artifact",
    "artifact_sha256_mismatch": "blocked_artifact",
    "state_dict_mismatch": "blocked_artifact",
    "config_mismatch": "blocked_artifact",
    "invalid_input": "blocked_input",
    "invalid_window": "blocked_input",
    "night_too_long": "blocked_input",
    "channel_not_admitted": "blocked_input",
    "derived_respiration_refused": "blocked_input",
    "no_ppg_segments": "blocked_input",
    "missing_ppg_anchor": "blocked_input",
    "legacy_deltas_suspected": "blocked_input",
    "unsupported_native_rate": "blocked_input",
    "clock_rate_mismatch": "blocked_input",
    "invalid_segment": "blocked_input",
    "nonfinite_samples": "blocked_input",
    "non_integer_samples": "blocked_input",
    "saturated_samples": "blocked_input",
    "too_many_segments": "blocked_input",
    "unverified_sample_clock": "unverified",
    "optical_config_identity_missing": "blocked_input",
    "optical_config_unidentified": "unverified",
    "optical_config_changed": "blocked_input",
    "missing_run_id": "blocked_input",
    "unsorted_segments": "blocked_input",
    "overlapping_segments": "blocked_input",
    "no_stageable_run": "insufficient_coverage",
    "insufficient_overnight_coverage": "insufficient_coverage",
    "nonfinite_model_output": "provider_error",
    "unknown_config": "blocked_input",
    "provider_id_mismatch": "blocked_input",
}

#: Per-epoch mask reasons (an epoch is scored only when its reason is None).
EPOCH_MASK_REASONS = (
    "no_ppg",                    # no admitted native sample covers the epoch (a gap)
    "run_edge_partial_epoch",    # the run starts/ends inside the epoch, or the epoch's end
                                 # sample (owned by the next second) is not in the run
    "run_too_short",             # the run is shorter than min_run_epochs
    "flat_signal",               # the run's native std < 0.001 (the pinned ingest's
                                 # MIN_SIGNAL_STD flat-PPG rule, applied per run)
    "nonfinite_model_output",    # the model returned a non-finite value for this run
)
#: preprocessing/1_ingest.py MIN_SIGNAL_STD in the pinned code (flat/dead PPG is dropped).
MIN_SIGNAL_STD = 0.001
