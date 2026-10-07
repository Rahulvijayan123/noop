# Metric insight worker

Writes the explanation card on a key metric's detail screen (resting heart rate first; HRV is supported by the
same code). It drains `public.metric_insight_jobs` (`supabase/migrations/20261008000000_metric_insights.sql`)
and publishes into `public.metric_insights`, which the scores function serves at `POST /scores/insights`.

```
app ──POST /scores/insights {metric}──▶ scores edge function ──metric_insight_request_v1──▶ Postgres
   ◀── {status: ready | pending | unavailable, insight} ──┘        │ unchanged inputs: cached insight, no work
                                                                    │ changed inputs: job queued, stale insight served
this worker ──claim──▶ job (owner, metric, anchor night, fingerprint)
   ├─ deterministic gate: < 3 measured nights → fixed "not enough data" text, no model call
   ├─ Prime Agent (one sandboxed `prime-agent --mode rpc` per job)
   │     model-written Python ──mcp `nara`──▶ shim ──Unix socket──▶ tool broker ──▶ owner-scoped reads
   │     Prime host ──HTTP──▶ per-job LLM proxy (key, model, budget) ──▶ provider
   ├─ validator: shape, wording, numbers/dates grounded in tool results, estimates labelled, citations retrieved
   └─ publish (fenced by lease + revision) or fail (backoff, dead letter at 3)
```

## What the agent can see

The root agent's data is a fixed set of Python variables (`tools.VARIABLES`). The prompt's first cell loads every
one of them for every analysis, then prints a small digest of their key computed facts; the validator refuses an
answer until all of them were loaded and the literature was searched. Every tool is bound by the host to one
owner, one metric and one analysis night (no tool accepts a user, device or date).

| variable | source | what it holds |
| --- | --- | --- |
| `manifest` | — | every source, whether it is connected |
| `metric_summary` | `server_daily_scores` + context document | latest night, previous night, the person's usual (below), the assessment |
| `metric_series` | `server_daily_scores` | the nightly values, missing nights as null |
| `state_breakdown` | scores, context documents, hosted snapshots | the metric during sleep, at calm awake rest and around movement, by time of day, each against its own usual; HRV through the night's two days by activity (15-minute slots) |
| `movement_patterns` | `activity_context_runs`, context bouts | movement the day and evening before the night and on the day, minutes by kind, how long before sleep the last one ended |
| `related_metrics` | scores + context availability | HRV / resting HR / breathing / skin temperature / sleep against their usual, marked measured or estimated |
| `sleep_context`, `workout_context`, `activity_context` | scores, context documents | sleep timing and duration, exertion windows, daily activity |
| `recent_events` | `exposure_events` | what the person logged (medications are never named) |
| `data_quality` | scores + context | tracked, measured and missing nights |
| `user_context` | `coach_memory_items` (explicit owner filter) | notes the person gave the coach |
| `chat_history` | placeholder | not connected (coach transcripts exist in `coach_messages`; connecting them is a product decision) |
| `health_records` | placeholder | not connected (no EHR, conditions or labs on the server) |
| `previous_insight` | `metric_insights` | the previous explanation's headline |
| `research_evidence` | `search_literature` | peer-reviewed findings: the curated, PubMed-verified corpus first, then PubMed / Europe PMC journal articles (no preprints, no retractions) |

Every owner read is a READ ONLY transaction as `authenticated` with the owner's JWT claims, after asserting
`auth.uid()`; RLS decides which rows exist (the hosted snapshots come through the owner's own
`get_server_score_snapshot_v2`). The inputs fingerprint (`internal.metric_insight_inputs`) covers everything these
read, so an unchanged night is served from the cache and a changed one is re-analysed.

**The person's usual** follows the phone Baseline's Layer 1 rules (`LongitudinalBaseline`, v1.review), applied to
the server's nightly values: the 60-day copy (median of nights T-60..T-8, spread floor 2 bpm / 0.08 ln, outliers
trimmed, band k spreads wide with k fitted to the person once 14 nights are in, shown at 4 nights) and the 7-night
weighted copy. Layer 1's own snapshots stay on the phone by design (docs/PORT_LAYER1_WATCHDOG.md §7), so the two can
differ slightly. The context layer's change detection (episodes, |z| >= 2.5) is used when its reference is ready.

Adding a source (labs, medications, EHR, genomics, conversation memory) = a loader in `sources.py`, a tool and a
variable in `tools.py`, and its table in the fingerprint. The prompt contract, the validator and Prime do not change.

## Memory and isolation

* Health history: the application database only.
* Per-user context: `coach_memory_items` and the user's own previous insight, read per job for that owner.
* Agent learning: Prime's Continual Harness, but only a curated, user-free file (`NARA_CURATED_HARNESS`,
  built by `scripts/build_curated_harness.py` from `data/curated_harness.json`) copied into each job.
  `--no-session` keeps no transcript; each job's agent directory (including anything the model writes to its
  harness) is deleted when the job ends, so nothing learned from one person reaches another.
* Each job gets its own run directory, capability token, LLM token, broker socket and Prime process.

## Sandbox

The whole Prime process tree is confined (`sandbox.py`), because model code can ask the Prime host to act for
it: no network except the job's LLM proxy, no writes outside the run directory (and none to the job's settings,
provider config, auth file, curated harness or cwd), no reads of secrets, an environment without secrets. The
provider key never enters the tree: Prime gets a per-job token for the loopback LLM proxy, which pins the model,
caps tokens and requests, and forwards an allowlist of request fields only. After each job the whole process tree
is killed and the run directory deleted; leftovers from a crash are purged at start.

- Linux (production): bubblewrap (`apt install bubblewrap`), every namespace unshared, `--cap-drop ALL`, its own
  PID namespace that dies with the job; a forwarder turns the proxy's Unix socket into the loopback port Prime
  calls. Nothing of the host (sockets, /run, other processes, the worker's state) is visible inside.
- macOS (development only, `NARA_SANDBOX=macos` must be set explicitly): `sandbox-exec`. It cannot hide other
  processes' launch environments or filter Unix-domain sockets reliably; never run it with real users' data.
- `nara-metric-insight self-test` proves the confinement on the host (internet, the real credentials directory,
  the worker's state dir, writes outside, the environment) and runs as `ExecStartPre`.
- `NARA_SANDBOX=none` exists only for protocol tests and must be set explicitly.

## What is published

`validate.py` is the gate: every variable loaded; a fixed shape; at least one peer-reviewed citation retrieved in the
job that backs an interpretation sentence; "because" only when hedged ("likely because"); NFKC text with no invisible or non-Latin characters; none of the app's
forbidden terms (kept identical to `PhysiologyContextWording.forbiddenTerms`, inflections included) and no causal,
diagnostic or certainty wording; absolute dates only; every number checked by unit against the tool results the
model received (a value "on Oct 6" must be Oct 6's value, a direction word must match the sign of the change, zero
is never a measurement, number words and clock times count); "estimated" wherever a person's estimated signal is
stated; citations only from this job's retrieval, each backing an interpretation of something present. One retry
with the reasons, then the job fails (backoff, dead letter at 3). The app re-checks wording before rendering.

## Changing the analysis

Cached analyses are keyed by their inputs, not by this code. When the prompt, the tools, the evidence or the
validator change what would be published, bump `internal.metric_insight_version()` in a new migration: every
cached analysis then counts as changed and is redone on the next visit (within the daily bound).

## Configuration

See `deploy/metric-insight.env.example` (names only). Secrets come from files / systemd credentials, never the
environment: `db_url` (a direct Postgres URL; the role must be able to `SET ROLE authenticated` and
`service_role`) and `llm_api_key`.

## Tests

```
uv sync
uv run pytest                       # unit, plumbing, PostgreSQL and end-to-end tests (34)
NARA_TEST_PRIME_BIN=... NARA_TEST_KERNEL_PYTHON=... uv run pytest -m prime   # end to end with Prime Agent
```

The PostgreSQL tests build a throwaway cluster from the full migration chain (`/opt/homebrew/bin` or
`NARA_TEST_PG_BIN`). The end-to-end test drives a real, sandboxed `prime-agent` against a scripted
OpenAI-compatible stub (`tests/stub_llm.py`), so it needs no API key and sends nothing anywhere; its first tool
cell also probes isolation from inside the kernel (cross-user call refused, no internet, no secret in the
environment, the global harness read-only). `scripts/smoke_real_model.py` runs one analysis with a real provider
on invented data.
