# Integration fragment: ActiNet Walmsley classifier as a shadow activity-intensity channel

For Spec 01's owners. Written 2026-10-08 against Spec 01 `feat/spec01-model-integration-20261007` @ `783ac84da`,
in particular `docs/model-integration/activity-authority.md` "Extension points for Specs 02/03". Spec 03 changes
none of the files below. Everything here is a proposal for Spec 01 to apply, in Spec 01's own style.

Contract of the adapter itself: [../ACTINET_CLASSIFIER.md](../ACTINET_CLASSIFIER.md).

## 0. What is already done on the Spec 03 side

- **Producer.** `python -m activity_context.actinet_classifier.serve`, a standalone stdin/stdout JSON-lines child
  modelled on `eldernet.serve`: ops `ping` / `infer` / `shutdown`, wire schema `actinet-classifier-1`, release mode
  fixed at `shadow`, consumer `activity_intensity_shadow`.
- **Loaded identity.** `ping` returns Spec 01's `loaded` map (`activity-loaded-1`, built with `base_loaded`) and
  `loaded_digest`; every `infer` repeats `loaded_digest`. Keys beyond the base: `weights_sha256`, `hmm_sha256`,
  `artifact_digest`, `preprocessing_digest`, `model_version`, `release_mode`, `grid`, `max_batch`. All values are
  strings, as `ActivityPythonService.parsePing` requires. The import is guarded: before Spec 01 merges, `ping` omits
  `loaded` and the worker gives the child no cache identity. Verified on a local merge of both branches
  (§8).
- **Merge.** `git merge-tree` of the two branches is clean; no file is touched by both (Spec 03 only adds files).
  The merge changes `loaded.code_sha256` for every activity child once, because that digest covers every `.py` and
  `.json` file in `activity_context/`.

## 1. Admission category

A **genuinely new channel** (activity-authority.md, extension point 2). The output is a 4-class label per 30 s
epoch plus class probabilities. That is not a motion-head bundle (Nara label space, 5 s hop, `inertia-prep-1`) and
not gait quality, so it cannot go in `activity_motion_heads_days` or `activity_gait_windows_days`. Do not widen the
`encoder_kind` check for it. The Inertia lane's `encoder_kind actinet` is a different thing: the harnet30 encoder
under Nara's heads. Use the channel name `activity_intensity` and model id `actinet-walmsley` so the two cannot be
confused.

## 2. Worker stage (Swift, `Tools/CloudWorker/Sources/frwhoop-worker/`)

A new `ActiNetIntensityStage` beside `ElderNetStage` (`ActivityGaitQuality.swift`), off unless configured:

| Setting | Meaning | Default |
|---|---|---|
| `FRWHOOP_ACTINET_CLASSIFIER_ENABLED` | 1/true/yes/on starts the child | off |
| `FRWHOOP_ACTINET_CLASSIFIER_DIR` | converted artifact directory (`--artifact-dir`) | none: the stage stays off |
| `FRWHOOP_ACTINET_CLASSIFIER_ARTIFACT_DIGEST` | the deployment pin; a ping whose `loaded.artifact_digest` differs keeps the stage off | none: the stage stays off |
| `FRWHOOP_ACTINET_CLASSIFIER_THREADS` | `--threads` | 1 |
| `FRWHOOP_ACTINET_CLASSIFIER_TIMEOUT_SECONDS` | per request; clamped to a third of the job lease, as Inertia does | 60 |
| `FRWHOOP_ACTINET_CLASSIFIER_JOB_BUDGET_SECONDS` | per job | as Inertia |
| `FRWHOOP_ACTINET_CLASSIFIER_PYTHON` | interpreter | the activity Python |

- **There is no mode setting.** The only mode is `shadow`. Any configured mode other than `shadow` is a
  configuration error, not a lowering. Promotion would be a separate change (§6).
- **The deployment pin** is `5d4d749a61d1b848d6930a66ee4c1d6aac9b236aeb6d2a3aeb9a8eb15864c941`
  (`weights.DEPLOYMENT_ARTIFACT_DIGEST`: the source joblib, converted weights and HMM file by role).
- **Request.** One `infer` per job-day carrying that day's raw-IMU runs, in time order: the same run objects the
  HART child gets (`start_ts`, `end_ts`, `sample_rate_hz` 100, `channels_order`, `units`, `columns_b64`;
  `head_b64`/`tail_b64` are accepted and ignored). One request per day matters: upstream's HMM runs over one
  recording, and the adapter runs one Viterbi pass per request. Bounds: at most 2,880 epochs, 4,000 runs and 86,400
  input seconds per request, and a 12 MiB response line. Split a longer request at a gap, never inside a run.
- **Cache.** `ActivityLocalCache.inferenceKey(request:identity:versions:)` (`ActivityLocalCache.swift:72` at
  `783ac84da`) takes a single `ActivityPythonService.RunRequest`, but this request carries a day of runs. Add an
  overload, for example `inferenceKey(runs: [RunRequest], identity:versions:)`, under a new key schema
  `activity-infer-multi-1`: the sha256 of each run's existing key material in time order, plus the child's
  `cacheIdentity`. Return nil without an identity, as the single-run key does. The response's own
  `cache_key = sha256(input_digest, artifact_digest, preprocessing_digest)` is stored with the row (§3) for audit.
  It does not replace the worker key, which also covers code and threads.
- **Failure.** A child error, timeout or `model_available: false` stores nothing and touches no other lane. Count it
  in the heartbeat as Inertia does (`*_failures`, `*_unavailable`).
- **Heartbeat.** Add `actinet_classifier.loaded_digest` to the hard-coded child list in `ActivityLane.identity`
  (`ActivityLane.swift:357-368`), plus counters `actinet_jobs`, `actinet_epochs`, `actinet_valid_epochs`,
  `actinet_failures`, `actinet_unavailable` and `actinet_rows_stored`.
- **Resources.** One more resident Python child. On this Mac: about 340 MB RSS after load, peaking at 1.0–1.2 GB on
  a full-day request, and about 4.4 CPU-s for a 480-burst duty-cycled day at 1 thread
  ([../ACTINET_CLASSIFIER.md](../ACTINET_CLASSIFIER.md) §9). **Not measured on the Droplet**, which needs the
  owner's approval. The child shares the scoring worker's cgroup, so set
  `Config.numericalThreads` / `FRWHOOP_ACTINET_CLASSIFIER_THREADS` to 1.

## 3. Storage (`supabase/migrations`, new)

`activity_intensity_shadow_days`, in the pattern of `20261005170000_activity_motion_heads.sql` plus
`20261008100600_activity_release_authority.sql`: `user_id` and `device_id` with the composite key to `devices`, a
job fingerprint and input revision, a result-revision sequence, worker-written rows, and a fenced publish function
with the same lease and revision fence as `publish_activity_motion_heads_day`. Sketch (column checks abbreviated
where they copy the motion-heads table verbatim):

```sql
create table public.activity_intensity_shadow_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  model_id text not null check (model_id = 'actinet-walmsley'),
  model_version text not null check (model_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  mode text not null check (mode = 'shadow'),
  release_mode text not null default 'shadow' check (release_mode = 'shadow'),
  authority jsonb check (authority is null or jsonb_typeof(authority) = 'object'),
  wire_schema text not null check (wire_schema = 'actinet-classifier-1'),
  artifact_digest text not null check (artifact_digest ~ '^[0-9a-f]{64}$'),
  preprocessing_version text not null, temporal_version text not null,
  preprocessing_digest text not null check (preprocessing_digest ~ '^[0-9a-f]{64}$'),
  input_digest text not null check (input_digest ~ '^[0-9a-f]{64}$'),
  cache_key text not null check (cache_key ~ '^[0-9a-f]{64}$'),
  loaded_digest text not null check (loaded_digest ~ '^[0-9a-f]{64}$'),
  job_fingerprint text not null check (job_fingerprint ~ '^[0-9a-f]{64}$'),
  input_revision bigint not null check (input_revision >= 1),
  n_epochs integer not null check (n_epochs between 0 and 2880),
  n_valid integer not null check (n_valid between 0 and n_epochs),
  withheld_reason text check (withheld_reason is null or length(withheld_reason) between 1 and 240),
  summary jsonb not null check (jsonb_typeof(summary) = 'object'),
  -- columnar `ai-col-1`: epoch start deltas, valid/reason codes, probabilities in per-mille x4, logits x4 (3 dp),
  -- hmm label index, after_gap, contiguous_epochs; null when over the worker's size cap (summary says so)
  epochs jsonb check (epochs is null or (jsonb_typeof(epochs) = 'object'
                                         and (epochs ->> 'format') is not distinct from 'ai-col-1')),
  result_revision bigint not null,
  created_at timestamptz not null default clock_timestamp(),
  computed_at timestamptz not null,
  primary key (user_id, device_id, day, model_version, mode),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create sequence if not exists public.activity_intensity_shadow_days_result_revision_seq;
alter table public.activity_intensity_shadow_days enable row level security;
revoke all on public.activity_intensity_shadow_days from public, anon, authenticated;
grant all on public.activity_intensity_shadow_days to service_role;
create policy activity_intensity_shadow_days_service on public.activity_intensity_shadow_days
  for all to service_role using (true) with check (true);
-- publish_activity_intensity_shadow_day(...): copy of publish_activity_motion_heads_day's lease + revision fence.
-- prune_activity_intensity_shadow_days(): 30-day retention, as prune_activity_motion_heads_days.
```

- **One deliberate departure from the motion-heads table:** no `select` grant or policy for `authenticated`. The
  motion-heads rows are owner-readable. Shadow intensity has no app reader and must not get one by accident.
- `authority` follows the row authority block (`expert-authority-1`) with `channel: "activity_intensity"`,
  `route: "standalone"`, `mode: "shadow"`, `release_mode: "shadow"`, `use: "none"` and
  `pinned_artifact_digest: <pin>`. This needs one additive key in `ActivityExpertAuthority`.
- Probabilities, the HMM label and the raw argmax stay separate columns. They are never merged with motion-head
  probabilities (different label space) or with any sleep output.

## 4. Authority and correlated evidence (`ActivityContextAuthority.swift`, additive)

- Add `Channel.activityIntensity` to `ActivityExpertSelection` with `use(of:) == .none` for every release mode
  that exists today. It never reaches `canonical(_:base:)` or a candidate arm.
- **Correlated evidence.** The Walmsley network is harnet30, fine-tuned from the same ssl-wearables UK Biobank
  pretraining as the `actukb` encoder. It sees the same accelerometer seconds, and its ActiNet c24 sibling is the
  `actc24` encoder. If it ever enters a joint decode it must share the accelerometer evidence budget with the
  motion heads and gait quality. It is not an independent vote, and it must never be averaged with
  `movement_intensity`.
- **Sleep label.** Its `sleep` class is HR-independent motion context. It must never feed canonical sleep staging,
  in-bed / asleep detection or a sleep metric. The consumer below maps it only for comparison.

## 5. Consumer `activity_intensity_shadow`

An offline comparison, not a route:

- per day and account, minutes per class (HMM and raw), coverage (`valid` / recorded seconds, `after_gap`
  fraction), and agreement with the `actukb` `movement_intensity` head cut at 1.5 / 3 MET on the same 30 s epochs;
- on reference sets: the external head-to-head ([../ACTINET_CLASSIFIER.md](../ACTINET_CLASSIFIER.md) §10) and,
  when they exist, WHOOP intensity labels.

No API, no app rendering, no canonical metric. Promotion is not on the table (§6).

## 6. What would have to be true before anything beyond shadow

1. The owner's licence decision ([licence-corrections.md](licence-corrections.md)): a service on beta testers'
   data is likely outside clause 1.1(b).
2. A named product use for 4-class intensity that `movement_intensity` cannot serve.
3. Evidence on final outputs, not standalone accuracy (activity-authority.md, extension point 4). The external
   head-to-head shows no significant difference from `actukb` (§10 of the contract).
4. Continuous capture, if the HMM is to mean anything: with 60 s in 180 s, about half of all epochs follow a gap,
   so the HMM label is mostly the raw label.
5. A Droplet resource measurement, with approval.

## 7. Tests Spec 01 should add with the wiring

- The stage refuses any mode but `shadow`, and a ping whose `loaded.artifact_digest` differs from the pin.
- `ActivityExpertSelection` gives `activityIntensity` `use == .none`, and the canonical decode is byte-identical
  with and without an intensity row (the `document_sha256` of the published decode does not change).
- No `authenticated` select on the new table; no route returns it.
- The worker cache key changes when the child's `loaded_digest` changes.
- `tests/actinet_classifier/test_actinet_classifier_isolation.py` (Spec 03) fails as soon as a production path names
  the classifier. Update it in the same change that wires it.

## 8. Checked locally against Spec 01 (2026-10-08)

On a throwaway local merge of `feat/spec01-model-integration-20261007` @ `654f93afc` into this branch at `a94bf8701` (a separate
worktree, never pushed; the Spec 01 worktree untouched), the ActivityContext suite was run with the converted
artifact. The ActiNet tests pass there, including `test_loaded_identity_follows_spec01_when_present` (the map is
all strings and `loaded_digest` equals Spec 01's `loaded_digest()` in ping and infer). The full path
input → preprocessing → inference → shadow response was exercised through `serve.handle_line` with the real
artifact. Persistence and inspection could not be exercised: the store in §3 does not exist on either branch.
Results: [../STATUS.md](../STATUS.md).
