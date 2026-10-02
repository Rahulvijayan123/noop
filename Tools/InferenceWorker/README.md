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

Withholding is explicit and machine-readable (`insufficient_coverage`,
`artifact_fraction`, ...) with a finer `diagnostics.withheld_detail`.

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
  `ready: false` with a reason when a required artifact is missing or mismatched.
* Every loop and retry is bounded; a provider that exceeds the per-request
  wall-clock budget yields `withheld` + `timeout`, never a hung request.
* Bad input never crashes the server: 400 with a JSON error body, 404 for an
  unknown metric, 503 when a provider is not ready.

See `docs/server-physiology-migration/` for the migration-level documentation.
