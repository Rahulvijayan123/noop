"""The ``sensor.biomarkers.v1`` request envelope exactly as the Swift worker writes it.

A port of ``SensorBiomarkerInputs.buildRequests`` / ``writeJSON`` / ``segmentJSON`` and
``SensorBiomarkerLane.inferenceBody`` (Tools/CloudWorker/Sources/frwhoop-worker), byte for byte
where the Swift writer is byte-defined: sorted metadata keys, JSONSerialization's escaped solidus
(``deg\\/s``), the spliced segment arrays, the IMU 100 Hz scales, the 20 s seam alignment and the
<= 300 s segment cap. It decodes the committed worker fixtures
(``Tools/CloudWorker/Tests/frwhoop-workerTests/Resources/sensor_biomarkers/``), so the sidecar is
tested against what the worker actually sends rather than a hand-built dict.

Two PPG encodings:

* ``legacy``: today's worker. Each anchored v26 record emits its first 24 reconstructed points
  (``native_rate_hz: 24``) and every segment carries ``config: {"stable": true}`` only.
* ``run_aware``: the members of docs/model-integration/README.md ("PPG segments"): all 25 points
  of a record on a uniform 25 Hz grid, ``run_id`` ``ppg-<start_unix>``, ``config.identity
  "unknown"`` / ``config.known false`` (v26 carries no gain, drive or channel), ``config.stable``
  and a ``clock`` object. The PPG transport branch commits the real builder's golden envelope
  (``sensor_biomarkers_request_envelope.json``); ``golden_envelope()`` returns it when present.
"""

from __future__ import annotations

import hashlib
import json
import struct
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[4]
FIXTURE_DIR = (REPO_ROOT / "Tools" / "CloudWorker" / "Tests" / "frwhoop-workerTests" / "Resources"
               / "sensor_biomarkers")
GOLDEN_ENVELOPE = FIXTURE_DIR / "sensor_biomarkers_request_envelope.json"

ACCEL_SCALE = 1.0 / 4096.0
GYRO_SCALE = 2000.0 / 32768.0
IMU_RATE = 100
MAX_SEGMENT_SECONDS = 300
SEAM_ALIGNMENT_SECONDS = 20
ANALYSIS_VERSION = "sensor-biomarkers/1.0.0"
PROVIDER_ID = "sensor.biomarkers.v1"
USER_ID = "11111111-1111-4111-8111-111111111111"
DEVICE_ID = "22222222-2222-4222-8222-222222222222"
ALL_FAMILIES = sorted(["movement", "oscillation", "ppg_quality", "pulse_shape",
                       "perfusion_research", "tremor", "arm_swing", "rhythm_shadow"])

#: The worker never knows placement today (SensorBiomarkerLane passes "unknown").
UNKNOWN_PLACEMENT = {"watch_side": "unknown", "device_orientation": "unknown"}

#: The clock the run-aware transport states for an anchored v26 record.
RUN_AWARE_CLOCK = {
    "source": "record_unix_second",
    "grid": "start_unix + k/25",
    "endpoint": "next_record_anchor",
    "grid_evidence": "offline v26 packet corpus: 25 distinct samples per record",
    "samples_per_second": 25,
    "packet_timing_verified": False,
}


def load_fixture(name: str) -> dict[str, Any]:
    return json.loads((FIXTURE_DIR / name).read_text())


def golden_envelope() -> bytes | None:
    """The envelope the real Swift builder wrote, once the transport branch commits it."""
    if not GOLDEN_ENVELOPE.is_file():
        return None
    data = json.loads(GOLDEN_ENVELOPE.read_text())
    if isinstance(data, dict) and "body" in data:
        body = data["body"]
        return body.encode("utf-8") if isinstance(body, str) else json.dumps(body).encode("utf-8")
    return GOLDEN_ENVELOPE.read_bytes()


# ---------------------------------------------------------------------------
# Swift JSON spellings
# ---------------------------------------------------------------------------

def _json_value(value: Any) -> str:
    """JSONSerialization / JSONEncoder output for metadata: compact, sorted, escaped solidus."""
    return json.dumps(value, sort_keys=True, separators=(",", ":")).replace("/", "\\/")


def _double(value: float) -> str:
    """Swift ``Double.description`` for the finite values the worker writes."""
    text = repr(float(value))
    return text if ("e" in text or "." in text or "inf" in text or "nan" in text) else text + ".0"


def iso_utc(ts: int) -> str:
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def segment_end(start: int, run_end: int, max_duration: int = MAX_SEGMENT_SECONDS) -> int:
    limit = start + max_duration
    aligned = limit - ((limit % SEAM_ALIGNMENT_SECONDS) + SEAM_ALIGNMENT_SECONDS) % SEAM_ALIGNMENT_SECONDS
    return min(aligned if aligned > start else limit, run_end)


def input_revision(digests: Iterable[str]) -> str:
    canonical = "\n".join(sorted(digests))
    return "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# IMU (NPB1 rawImuSession)
# ---------------------------------------------------------------------------

def decode_npb1_imu(decoded: bytes) -> list[tuple[int, np.ndarray]]:
    """``Npb1ImuDecoder.decode``: [(ts, 600 i16 axis-major columns)]."""
    assert decoded[:4] == b"NPB1" and decoded[4] == 1 and decoded[5] == 4
    count = struct.unpack_from("<I", decoded, 6)[0]
    offset = 10
    records = []
    for _ in range(count):
        _row_id, ts, length = struct.unpack_from("<qqI", decoded, offset)
        offset += 20
        columns = np.frombuffer(decoded, dtype="<i2", count=length // 2, offset=offset).astype(int)
        offset += length
        records.append((int(ts), columns))
    assert offset == len(decoded)
    return records


def imu_records_from_fixture() -> tuple[list[tuple[int, np.ndarray]], str]:
    fixture = load_fixture("sensor_biomarkers_imu.json")
    decoded = bytes.fromhex(fixture["decoded_hex"])
    digest = hashlib.sha256(decoded).hexdigest()
    assert digest == fixture["decoded_sha256"], "IMU fixture digest mismatch"
    return decode_npb1_imu(decoded), digest


def synthetic_imu_records(start: int, seconds: int, *, seed: int = 5,
                          gyro_hz: float | None = None) -> list[tuple[int, np.ndarray]]:
    """Worn, nearly still strap: ~1 g on z plus sensor noise, as i16 counts."""
    rng = np.random.default_rng(seed)
    records = []
    for s in range(seconds):
        t = (s * IMU_RATE + np.arange(IMU_RATE)) / IMU_RATE
        ax = rng.normal(0, 0.01, IMU_RATE)
        ay = rng.normal(0, 0.01, IMU_RATE)
        az = 1.0 + rng.normal(0, 0.01, IMU_RATE)
        gyro = rng.normal(0, 0.5, (3, IMU_RATE))
        if gyro_hz is not None:
            gyro[0] += 20.0 * np.sin(2 * np.pi * gyro_hz * t)
        columns = np.concatenate([
            np.round(ax / ACCEL_SCALE), np.round(ay / ACCEL_SCALE), np.round(az / ACCEL_SCALE),
            np.round(gyro[0] / GYRO_SCALE), np.round(gyro[1] / GYRO_SCALE),
            np.round(gyro[2] / GYRO_SCALE)]).astype(int)
        records.append((start + s, columns))
    return records


def _split_runs(seconds: Sequence[int]) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    if not seconds:
        return runs
    run_start = prev = seconds[0]
    for s in seconds[1:]:
        if s - prev > 1 or s <= prev:
            runs.append((run_start, prev + 1))
            run_start = s
        prev = s
    runs.append((run_start, prev + 1))
    return runs


def imu_segments(records: Sequence[tuple[int, np.ndarray]]) -> list[dict[str, Any]]:
    timeline = {ts: cols for ts, cols in records}
    segments = []
    for run_start, run_end in _split_runs(sorted(timeline)):
        start = run_start
        while start < run_end:
            end = segment_end(start, run_end)
            accel, gyro = [], []
            for t in range(start, end):
                c = timeline[t]
                for i in range(IMU_RATE):
                    accel.append([c[i] * ACCEL_SCALE, c[IMU_RATE + i] * ACCEL_SCALE,
                                  c[2 * IMU_RATE + i] * ACCEL_SCALE])
                    gyro.append([c[3 * IMU_RATE + i] * GYRO_SCALE, c[4 * IMU_RATE + i] * GYRO_SCALE,
                                 c[5 * IMU_RATE + i] * GYRO_SCALE])
            segments.append({"start_unix": start, "duration_s": end - start,
                             "accel_g": accel, "gyro_dps": gyro})
            start = end
    return segments


def _rows_json(rows: Sequence[Sequence[float]]) -> str:
    return "[" + ",".join("[" + ",".join(_double(v) for v in row) + "]" for row in rows) + "]"


def imu_segment_json(segment: dict[str, Any]) -> str:
    return ("{\"accel_g\":" + _rows_json(segment["accel_g"])
            + f",\"duration_s\":{segment['duration_s']},\"gyro_dps\":"
            + _rows_json(segment["gyro_dps"]) + f",\"start_unix\":{segment['start_unix']}}}")


# ---------------------------------------------------------------------------
# PPG (anchored v26 records)
# ---------------------------------------------------------------------------

def ppg_records_from_fixture(ts_offset: int = 0) -> list[dict[str, Any]]:
    """``sensor_biomarkers_ppg_records.json`` (anchor + 24 deltas per record), shifted in time."""
    fixture = load_fixture("sensor_biomarkers_ppg_records.json")
    return [{**record, "ts": record["ts"] + ts_offset} for record in fixture["records"]]


def records_from_wave(wave: np.ndarray, start: int, *, burst_index: int = 1) -> list[dict[str, Any]]:
    """Anchored v26 records for a 25 Hz wave: record s holds x[25s] and the next 24 deltas."""
    assert wave.size % 25 == 0
    records = []
    for s in range(wave.size // 25):
        points = np.round(wave[25 * s:25 * s + 25]).astype(int)
        deltas = np.diff(points)
        assert np.all(np.abs(deltas) < 32767), "synthetic wave exceeds the i16 delta range"
        records.append({"ts": start + s, "rowId": start + s, "burstIndex": burst_index,
                        "baseCode": int(points[0]), "samples": deltas.tolist()})
    return records


def _reconstruct(record: dict[str, Any]) -> list[int] | None:
    """``reconstructSecond``: the 25 absolute points, or None for a withheld second."""
    deltas = record.get("samples") or []
    if len(deltas) != 24 or record.get("baseCode") is None:
        return None
    config = record.get("config") or {}
    if config and ((config.get("driveA") or 0) == 0 or (config.get("driveB") or 0) == 0):
        return None
    if any(d in (-32768, 32767) for d in deltas):
        return None
    points = [int(record["baseCode"])]
    for d in deltas:
        points.append(points[-1] + int(d))
    if any(p < -524288 or p > 524287 for p in points):
        return None
    return points


def ppg_segments(records: Sequence[dict[str, Any]], *, encoding: str) -> list[dict[str, Any]]:
    """Runs over emitted seconds (split at a missing second or a burst change), then segments."""
    emitted = []
    for record in sorted(records, key=lambda r: r["ts"]):
        points = _reconstruct(record)
        if points is not None:
            emitted.append((int(record["ts"]), record.get("burstIndex"), points))
    runs: list[list[tuple[int, Any, list[int]]]] = []
    for second in emitted:
        if runs and second[0] == runs[-1][-1][0] + 1 and second[1] == runs[-1][-1][1]:
            runs[-1].append(second)
        else:
            runs.append([second])
    per_second = 24 if encoding == "legacy" else 25
    segments = []
    for run in runs:
        by_ts = {ts: points for ts, _, points in run}
        run_start, run_end, burst = run[0][0], run[-1][0] + 1, run[0][1]
        start = run_start
        while start < run_end:
            end = segment_end(start, run_end)
            samples: list[int] = []
            for t in range(start, end):
                samples.extend(by_ts[t][:per_second])
            segment: dict[str, Any] = {"start_unix": start, "duration_s": end - start,
                                       "samples": samples, "sample_count_per_second": per_second,
                                       "config": {"stable": True}}
            if encoding == "run_aware":
                segment["run_id"] = f"ppg-{run_start}"
                segment["config"] = {"stable": True, "identity": "unknown", "known": False,
                                     "burst_index": burst}
                segment["clock"] = dict(RUN_AWARE_CLOCK)
            segments.append(segment)
            start = end
    return segments


def ppg_segment_json(segment: dict[str, Any]) -> str:
    """``segmentJSON(_ PpgSegment)``; the run-aware members are written in the same sorted order."""
    parts = []
    if "clock" in segment:
        parts.append("\"clock\":" + _json_value(segment["clock"]))
    parts.append("\"config\":" + _json_value(segment["config"]))
    parts.append(f"\"duration_s\":{segment['duration_s']}")
    if "run_id" in segment:
        parts.append("\"run_id\":" + _json_value(segment["run_id"]))
    parts.append(f"\"sample_count_per_second\":{segment['sample_count_per_second']}")
    parts.append("\"samples\":[" + ",".join(str(int(v)) for v in segment["samples"]) + "]")
    parts.append(f"\"start_unix\":{segment['start_unix']}")
    return "{" + ",".join(parts) + "}"


# ---------------------------------------------------------------------------
# The envelope
# ---------------------------------------------------------------------------

def build_body(*, imu: Sequence[dict[str, Any]], ppg: Sequence[dict[str, Any]],
               families: Sequence[str], revision: str, day: str,
               ppg_rate: int | None = None, placement: dict[str, str] | None = None,
               user_id: str = USER_ID, device_id: str = DEVICE_ID) -> bytes:
    """``SensorBiomarkerInputs.writeJSON`` + ``SensorBiomarkerLane.inferenceBody``."""
    placement = placement or UNKNOWN_PLACEMENT
    metadata = {
        "schema_version": 1,
        "device": {"id": device_id, "family": "whoop5"},
        "input_revision": revision,
        "day_utc": day,
        "watch_side": placement["watch_side"],
        "device_orientation": placement["device_orientation"],
        "families": list(families),
    }
    out = _json_value(metadata)[:-1]
    if imu:
        out += (",\"imu\":{\"sampling_rate_hz\":100,\"units\":"
                + _json_value({"accel": "g", "gyro": "deg/s"}) + ",\"segments\":["
                + ",".join(imu_segment_json(s) for s in imu) + "]}")
    if ppg:
        rate = ppg_rate or ppg[0]["sample_count_per_second"]
        out += (f",\"ppg\":{{\"native_rate_hz\":{rate},\"units\":\"adc_counts\",\"segments\":["
                + ",".join(ppg_segment_json(s) for s in ppg) + "]}")
    out += "}"
    starts = [s["start_unix"] for s in (*imu, *ppg)]
    ends = [s["start_unix"] + s["duration_s"] for s in (*imu, *ppg)]
    context = {
        "user_id": user_id, "device_id": device_id,
        "interval_start_utc": iso_utc(min(starts)), "interval_end_utc": iso_utc(max(ends)),
        "iana_timezone": "UTC", "profile_version": "none",
        "config_version": ANALYSIS_VERSION, "corrections_version": "none",
    }
    body = ("{\"context\":" + _json_value(context) + ",\"input\":" + out
            + ",\"metric\":\"sensor_biomarkers\",\"provider\":"
            + _json_value({"provider_id": PROVIDER_ID}) + "}")
    return body.encode("utf-8")


def legacy_fixture_body(families: Sequence[str] = ALL_FAMILIES) -> bytes:
    """Today's worker, over the committed fixtures: the IMU object plus the anchored PPG records
    moved into the IMU object's hour (the lane sends one UTC hour per request)."""
    imu_records, imu_digest = imu_records_from_fixture()
    base = imu_records[0][0]
    records = ppg_records_from_fixture(ts_offset=base + 10 - 1000)
    ppg_digest = hashlib.sha256((FIXTURE_DIR / "sensor_biomarkers_ppg_records.json").read_bytes()).hexdigest()
    return build_body(imu=imu_segments(imu_records), ppg=ppg_segments(records, encoding="legacy"),
                      families=families, revision=input_revision([imu_digest, ppg_digest]),
                      day=iso_utc(base)[:10], ppg_rate=24)
