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

Only the tools in `tools.py`, all bound by the host to one owner, one metric and one anchor night (no tool
accepts a user, device or date):

| tool | source |
| --- | --- |
| `get_metric_series`, `get_metric_summary`, `get_related_metrics`, `get_sleep_context`, `get_data_quality` | `server_daily_scores` (RLS as the owner) + the context document |
| `get_workout_context`, `get_activity_context` | `physiology_context_days` (RLS as the owner) |
| `get_recent_events` | `exposure_events` (RLS as the owner) + the document's unrecorded categories |
| `get_user_context` | `coach_memory_items` (service-only table, explicit owner filter) |
| `get_previous_insight` | `metric_insights` (RLS as the owner) |
| `search_literature` | curated, PubMed-verified corpus (`data/literature_seed.json`); PubMed / Europe PMC only if `NARA_LITERATURE_REMOTE` is set |

Every owner read is a READ ONLY transaction as `authenticated` with the owner's JWT claims, after asserting
`auth.uid()`; RLS decides which rows exist. The windows match the fingerprint
(`internal.metric_insight_inputs`), so the cache key covers exactly what an analysis reads.

The numbers come from `evidence.py` (deterministic). The context layer's own judgments are used first, chosen
with the app's rules (`MeasurementContextSelection.headlineReference` / `.episode`); while that layer has no
ready reference (new accounts), a labelled personal-range fallback is used.

Adding a source (labs, medications, EHR, genomics, conversation memory) = a loader in `sources.py` + a tool in
`tools.py` (and the table in the fingerprint). The prompt contract, the validator and Prime do not change.

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
it: no network except the job's LLM proxy, no writes outside the run directory, no reads of secrets, an
environment without secrets. Linux uses bubblewrap (`apt install bubblewrap`; every namespace unshared, a
forwarder turns the proxy's Unix socket into the loopback port Prime calls); macOS uses `sandbox-exec`.
`nara-metric-insight self-test` proves it on the host and runs as `ExecStartPre`. `NARA_SANDBOX=none` exists
only for protocol tests and must be set explicitly.

## Configuration

See `deploy/metric-insight.env.example` (names only). Secrets come from files / systemd credentials, never the
environment: `db_url` (a direct Postgres URL; the role must be able to `SET ROLE authenticated` and
`service_role`) and `llm_api_key`.

## Tests

```
uv sync
uv run pytest                       # unit tests (+ PostgreSQL tests when initdb is available)
NARA_TEST_PRIME_BIN=... NARA_TEST_KERNEL_PYTHON=... uv run pytest -m prime   # end to end with Prime Agent
```

The PostgreSQL tests build a throwaway cluster from the full migration chain (`/opt/homebrew/bin` or
`NARA_TEST_PG_BIN`). The end-to-end test drives a real `prime-agent` against a scripted OpenAI-compatible stub
(`tests/stub_llm.py`), so it needs no API key and sends nothing anywhere.
