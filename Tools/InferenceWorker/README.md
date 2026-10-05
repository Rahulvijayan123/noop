# FRWHOOP inference sidecar (`Tools/InferenceWorker`)

Loopback-only Python sidecar that serves versioned physiology providers to the
FRWHOOP Swift worker. Nothing in this package is reachable from a public port:
it binds `127.0.0.1` only and refuses to start on any other host unless
`--allow-non-loopback` is passed explicitly (tests only).

## What is here

| Path | Purpose |
| --- | --- |
| `src/frwhoop_inference/contract.py` | Frozen request/response contract: version constants, withheld-reason enum, bounds/label-space/finiteness/timestamp/identity validation, independent valid-pair RMSSD reference |
| `src/frwhoop_inference/server.py` | stdlib `ThreadingHTTPServer`: `GET /healthz`, `GET /v1/providers`, `POST /v1/infer` |
| `src/frwhoop_inference/artifacts.py` | Manifest loading + sha256 verification of cached artifacts at startup |
| `src/frwhoop_inference/providers/hrv.py` | `production.runs.v1` (authoritative) and `neurokit2.shadow.v1` (gated comparison) |
| `models/manifest.json` | Pinned model/dependency manifest: revision, URL, size, sha256, license, rights verdict, input contract, status |
| `tests/` | Synthetic, seeded fixtures + server contract tests |

## Providers

### `production.runs.v1` (authoritative, metric `hrv`)

A faithful port of the shipped engine
(`Packages/StrandAnalytics/.../HRVAnalyzer.swift`,
`Tools/CloudWorker/.../IntradaySeries.swift`,
`Packages/StrandAnalytics/.../SleepStager.swift`):

1. dedup retransmission by **observation identity** (never by RR value alone),
2. range filter 300-2000 ms,
3. Malik ectopic rejection, 0.20 deviation, radius-2 centred window,
4. gap-aware adjacency: a pair counts only when the two beats were adjacent in
   the original series *and* the wall clock did not run ahead of the interval by
   more than `splice_tolerance_s` (default 3.0 s),
5. 5-minute tumbling windows, the final window closed on `end`,
6. window floor of 20 clean intervals,
7. pooled `sum(d^2)` / pair counts across runs (never an average of segment
   RMSSDs),
8. session value = plain mean over usable windows, plus the over-count gate;
   day value = duration-weighted mean of session means,
9. valid pairs and coverage reported **separately** from the beat floor.

**Input aggregation** (`input.aggregation`, mirrored from `input.config.aggregation`
when the top-level key is absent - the pre-repair worker stated its intent only in
`config`):

* `mean_over_windows` (the spelling `DayScoring.hrvConfig()` emits) and its legacy
  alias `session` score the **plain mean over the session's USABLE windows**, so a
  window the 20-interval floor refuses - *including the first one* - does not
  withhold the night; a session with no usable window left withholds, naming its
  reason.
* `window` scores **one** window. With `input.windows` the contract requires exactly
  one; with no `input.windows` it means the FIRST window the provider derives from
  the context interval and ignores the rest. That back-compat path is retained for
  an explicit caller, and it is exactly why the worker states `mean_over_windows`.
* `day` is the duration-weighted mean of session means.
* An unknown spelling is refused (400 `invalid_input`), never silently downgraded.

Withholding is explicit and machine-readable (`insufficient_coverage`,
`artifact_fraction`, ...) with a finer `diagnostics.withheld_detail`. Two caveats,
recorded rather than implied: `low_coverage` and `high_rejected_fraction` fire only
when a caller tunes `min_coverage` / `max_rejected_fraction` away from their shipped
defaults (`0.0` / `None`), and the shipped engine has no nightly artifact gate, so
`artifact_fraction` is reachable today only through the over-count path.

### Spec section 5 vs the shipped code

Spec section 5 lists provisional thresholds "subject to current-code verification".
Four of them are **not** in the shipped Swift code, and this port is faithful to the
shipped code. The divergences are recorded here so no reader assumes the spec's
numbers are in force:

| Spec section 5 (provisional) | Shipped code / this port | Evidence |
| --- | --- | --- |
| minimum 30 clean intervals | `min_clean_beats = 20` | `HRVAnalyzer.swift:33` (`minBeats = 20`) |
| maximum 20 % artifact fraction | no nightly artifact gate (`max_rejected_fraction = None`, `min_coverage = 0.0`); the gate exists but is off unless tuned | `HRVAnalyzer.swift` exposes no such constant |
| minimum 3 usable windows | no such floor; a session with one usable window is scored | `SleepStager.swift:2958-2973` |
| median-window aggregation | plain mean over windows | `SleepStager.sessionAvgHRV` (`:2958-2973`) |

A stricter gate for the candidate lane is a deliberate divergence and must be set in
that lane's tuning and recorded as such.

### `neurokit2.shadow.v1` (comparison only, never publishable)

Calls `neurokit2==0.2.13` `hrv_time` on the **same cleaned interval series** the
production path used, with `RRI_Time` reconstructed as interval **END** times by
RR accumulation inside whole-second buckets (ordered by `seq`/`ord`). It is
labelled `unverified_accuracy`, is never canonical, and withholds with
`unresolved_adjacency` when the bucket reconstruction cannot be trusted (missing
`seq`/`ord`, or a bucket holding more beat-time than its wall clock allows).

## Running

```bash
cd Tools/InferenceWorker
uv sync                      # creates .venv from the committed uv.lock
uv run pytest -q             # test suite
uv run python -m frwhoop_inference.server --host 127.0.0.1 --port 8787
```

Environment: `FRWHOOP_MANIFEST`, `FRWHOOP_MODEL_ROOT`,
`FRWHOOP_REQUEST_TIMEOUT_MS`, `FRWHOOP_HOST`, `FRWHOOP_PORT`.

## Operational rules

* No network access at inference time. Weights are cached and sha256-verified at
  deploy-prep; the sidecar verifies the manifest at startup and reports
  `ready: false` with a reason when a required artifact is missing, mismatched, or
  **has no published `sha256`** (a `verify_at_startup` entry with no digest fails
  closed - audit DD-4). Only `verify_at_startup: false` entries are skipped by
  design, as the non-blocking `not_verified` status.
* Every loop and retry is bounded; a provider that exceeds the per-request
  wall-clock budget yields `withheld` + `timeout`, never a hung request.
* Bad input never crashes the server: 400 with a JSON error body, 404 for an
  unknown metric, 503 when a provider is not ready.

See `docs/server-physiology-migration/` for the migration-level documentation.
