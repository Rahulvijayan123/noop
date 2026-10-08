# Activity authority and fusion (Spec 01 §2)

Status: worker, database and route side (branch `spec01/activity-20261007`). The phone side
(`Strand/**`) is on `spec01/activity-phone-20261007` and is documented by its implementer; this
document owns the shared StrandAnalytics policy and every server interface the phone reads.

## API for the phone side

Read this section first; it is kept current on every commit.

### Shared policy (StrandAnalytics, `ActivityContextAuthority.swift`)

Public API, stable since `5c238bc0b` (only additive changes; each one is listed here):

- `ActivityReleaseMode` (`shadow < candidate < production`), `init(recorded:)` (missing or unknown text reads
  as `shadow`), `lowered(to:)`.
- `ElderNetRoute` (`standalone`, `hart_embedded`).
- `GaitQualitySource(track:releaseMode:route:expectedModelVersion:expectedWeightsDigest:gaitPrior:inputRevision:day:)`
- `MotionHeadsSource(track:mode:expectedBundleSHA256:inputRevision:day:)`
- `EmbeddedGaitSource(windows:releaseMode:)` (default `shadow`).
- `ActivityExpertSelection.select(revisions:gaitQuality:motionHeads:embeddedGait:)`, then
  `canonical(_:base:)` for the published decode, `decode(_:base:channels:)` / `candidateArms` / `jointArm`
  for candidate arms, `decisions`, `digest`, `use(of:)`, `canonicalChannels`, `candidateChannels`,
  `ActivityExpertSelection.policy` (`"expert-authority-1"`).

Additive in round 2:

- `ActivityExpertAuthority` (new, `09790adab`): the `authority` block a producer stores with a row and the
  route returns. `Codable` (lenient decode: an unknown release, or one above the block's own `mode`, reads
  lower, never higher). `init(decision:mode:pinnedModelVersion:pinnedWeightsDigest:gaitPrior:pinnedBundleSHA256:)`.
  Helpers that rebuild the policy's source from a stored row:
  `ActivityExpertAuthority.gaitSource(_ authority: Self?, track:recordedRelease:inputRevision:day:) -> GaitQualitySource`
  and `ActivityExpertAuthority.motionSource(_ authority: Self?, track:recordedRelease:inputRevision:day:) -> MotionHeadsSource`
  (pass the row's `release_mode` as `recordedRelease`, its `input_revision`, its UTC `day`; pass `nil` for a row
  whose `authority` is null: it then has no pins and the policy reads it as shadow).
- `ActivityExpertSelection.decision(for:) -> Decision?` (new): the decision for one channel.

How the phone uses it: build one `GaitQualitySource` per `/gait-windows` row with
`ActivityExpertAuthority.gaitSource(...)` (the row's `windows` decode into the `GaitQualityTrackInput` as
today), the HART windows' input revision per UTC day from `/activity-windows` (`input_revision`) as the
`revisions` map, pass `/activity-windows`' embedded `g_*` windows as `EmbeddedGaitSource(windows:)`, call
`select`, and decode with `canonical(...)`. Anything else (a candidate arm) is a preview and must be kept separate from the canonical
state. While no expert row is production (today: none can be, see "Release-mode vocabulary") `canonical`
removes every expert channel, so the phone's decode equals HART alone.

### `GET /scores/gait-windows?days=…[&known=…]` (additive fields)

Unchanged: query, `known` rule, one row per day (newest `computed_at`), `day, mode, model_version, hop_s,
window_s, gait_threshold, n_windows, n_gait, n_prefiltered, result_revision, computed_at, unchanged?, model,
summary, windows`.

New on every row (also on `unchanged: true` rows):

| Field | Type | Meaning |
|---|---|---|
| `release_mode` | `"shadow"` \| `"candidate"` | The row's release after every producer-side lowering (`coalesce(release_mode, mode)`; the route clamps anything else to `"shadow"`). Never `"production"`. Use it as `GaitQualitySource.releaseMode`. |
| `input_revision` | string (int64) | The raw-IMU input revision the windows were computed from (`GaitQualitySource.inputRevision`). |

New on full rows (with `windows`):

| Field | Type | Meaning |
|---|---|---|
| `identity` | object | `model_id, model_version, weights_digest, upstream_commit, preprocessing_version` (the row's model identity; `weights_digest` is recomputed by the publish function from the per-head digests). |
| `authority` | object \| null | The producer's authority block (below), or `null` for a row written before `20261008100000` or by an older worker. `null` means: no pins and no prior, so the policy reads the row as shadow (`model_not_pinned`). |

### `GET /scores/activity-windows?days=…[&known=…]` (additive fields)

New on every row: `input_revision` (string int64; the HART windows' raw-IMU input revision, the key of the
policy's `revisions` map), `release_mode: "production"` (HART is the production producer), and
`embedded_gait_release_mode: "shadow"` (the HART-embedded ElderNet `g_*` windows in `hart-windows-1` have no
release of their own; pass them as `EmbeddedGaitSource(windows:)` with the default shadow release, never as
evidence).

### Motion heads

No route. Motion-head rows (`activity_motion_heads_days`) are shadow/candidate only and the canonical decode
cannot use them, so the phone needs no motion-head store (Spec §2: "add motion-head readback only if the
chosen authority design needs it"). A future production promotion adds a route with the same fields as
`/gait-windows` (`release_mode`, `input_revision`, `identity`, `authority`).

### Row authority block (`authority`, schema `expert-authority-1`)

Stored by the worker inside the row's `summary.authority` and copied by a trigger into the `authority`
column (so an old database simply keeps it in `summary`). Keys (sorted on the wire):

| Key | Type | Gait | Motion |
|---|---|---|---|
| `policy` | string | `"expert-authority-1"` | same |
| `channel` | string | `"gait_quality"` | `"motion_heads"` |
| `route` | string | `"standalone"` | `"standalone"` |
| `mode` | string | worker mode (`shadow`/`candidate`) | same |
| `release_mode` | string | release after the policy's lowering | same |
| `use` | string | `none`/`candidate`/`canonical`: what the producer's own job let the row shape | same |
| `reason` | string \| null | why `use` is below `release_mode` (e.g. `model_not_pinned`) | same |
| `input_revision` | string (int64) | the job's input revision | same |
| `pinned_model_version` | string \| null | `FRWHOOP_ELDERNET_MODEL_VERSION` | — |
| `pinned_weights_digest` | string \| null | `FRWHOOP_ELDERNET_WEIGHTS_SHA256` | — |
| `gait_prior` | number \| null | `FRWHOOP_ELDERNET_GAIT_PRIOR` | — |
| `pinned_bundle_sha256` | string \| null | — | `FRWHOOP_INERTIA_BUNDLE_SHA256` |

`use`/`reason` are informational (the producer's view). A consumer always re-runs the policy itself; the
policy only lowers.

### Older phones (the `authority` capability)

A phone built before this policy (for example the installed build from `dab2124f3`) cannot be trusted with
expert rows below production: it builds a PRODUCTION gait config from hard-coded `GaitWindowStore.Pins` for any
`/gait-windows` row whose `model` digest checks out, ignoring `mode` and `release_mode`, and it adds the
`hart-windows-1` `g_*` columns to its decoder input. Spec §2.1 forbids that upgrade, and the server is the only
lever for builds already installed. So both window routes take a capability parameter:

- `authority=<n>` (this build sends `authority=1`, `ServerScoreRepository.windowsAuthorityCapability`): the caller
  applies `ActivityExpertSelection` itself. Response as documented above. Any other non-numeric value is
  `400 invalid_authority`.
- No `authority` (every older build): `/gait-windows` rows keep `day, mode, model_version, hop_s, window_s,
  gait_threshold, n_*, release_mode, input_revision, result_revision, computed_at, summary, windows, unchanged`
  but carry no `model`, `identity` or `authority` (no row is production, so this is every full row). The old
  build's parser then yields `model == nil`, its `syncGaitWindows` stores nothing for its decoder, its
  `latestModel` gets no new day, and it decodes those days on HART alone; its walking card (`GaitWindowsCache`,
  which reads only `windows`) is unchanged. `/activity-windows` bodies leave out the `g_*` columns (HART's own
  windows, features, fine labels and transition columns are unchanged), so the old decoder gets no embedded gait.

Residual cost, not fixable from the server: a day an older phone stored before the server change (with its
`model`) stays in that phone's on-disk `GaitWindowStore` and keeps feeding its decode of that day until the phone
is updated or the store is cleared. Result revisions are the same in both shapes, so an older phone that already
holds a day at revision R keeps its stored copy (`unchanged`); after updating, the new build re-reads any day it
does not hold in its own store with the capability. Proven by `gait_windows_route_test.ts` ("a phone without the
authority capability…"), `activity_windows_route_test.ts` ("the embedded gait columns go only to…"), the
full-chain `activity_authority_sql_test.ts`, and `ActivityPhoneAuthorityTests.testTheWindowRoutesDeclareTheAuthorityCapability`.

Compatibility otherwise: every field above is additive; nothing an older phone needs for display is removed.
Deploy order: apply `20261008100000` before deploying the `scores` function (the route selects the new
columns).

## Authority design

One rule, one place: `ActivityExpertSelection` (StrandAnalytics, used by the worker and the phone) decides,
per expert source of one decode, the highest decode it may shape. Releases are only ever lowered (missing
pins, a stand-in encoder, a bundle tier below the mode, an input revision that is not the HART windows'),
never raised, by every layer: producer (worker stage mode), storage (`release_mode` column, at or below the
row's `mode`), route (clamps to shadow/candidate), policy (lowers by pins/tier/revision), decoder
(`releaseRefusal`: a production config accepts only production windows, no config accepts shadow windows).

| Decode | Who makes it | Channels | Stored in |
|---|---|---|---|
| Canonical (published) | worker, `selection.canonical` | production sources only (none exist) | `activity_context_days` (v2), `activity_context_epochs` (v1, HART fold, no experts) |
| Stream day | worker, `buildStreamDay` | same policy over the stored HART set | `activity_context_days` (streams lineage) |
| Single-expert candidate | worker, `selection.decode(channels: [x])` | one candidate channel | the expert row's `candidate_document` |
| Joint candidate + ablations | worker, `ActivityCandidateDays` | every admitted candidate channel | `activity_candidate_days` |
| Phone decode | phone, `selection.canonical` from the routes' rows | production sources only | phone cache |

The server owns the published canonical document. The phone recomputes only from the same selected evidence
(the HART windows plus whatever the policy admits canonically, today nothing) with the default config, so
its decode equals the server's inputs. Candidate arms are never published, never read by scoring, never
returned by a route.

Concrete defect fixed (round-1 finding, kept): the worker's published v2 decode and its stream-day decode
added the HART-embedded ElderNet windows (`gaitWindows`) to the decoder input unconditionally, so an
experimental in-process expert with no release could shape published output. Both now go through
`canonical`, which removes them (they are shadow). In production the embedded expert is not enabled
(`ACTIVITY_GAIT_EXPERT` is not set in `deploy/`, and the worker now clears it for the HART child), so the
published bytes do not change; the replay test proves it.

## Release-mode vocabulary per producer

| Producer | Mode set by | Stored release | Can be production? |
|---|---|---|---|
| HART (`activity_context.serve`) | it is the production lane | — (`/activity-windows` says `production`) | yes (it is the baseline) |
| ElderNet standalone (`eldernet.serve`) | `FRWHOOP_ELDERNET_MODE` shadow/candidate (production refused by config) | `activity_gait_windows_days.release_mode`; candidate needs both pins and π, else shadow | no: needs a code change, a migration widening the checks, and an owner decision |
| ElderNet embedded in HART (`--gait-expert eldernet`) | none recorded | always shadow; superseded when a standalone source exists | no |
| Motion heads (Inertia-1 / ActiNet encoders + Nara head bundle) | `FRWHOOP_INERTIA_MODE` shadow/candidate | `activity_motion_heads_days.release_mode`; stand-in encoder or shadow-tier bundle → shadow; candidate needs the bundle pin | no (as above) |
| Transition expert (inside HART's service) | ships with the HART child | rides `hart-windows-1`; part of the HART lineage | as HART; see "Provider-to-consumer rows" |

## Selection policy and where it lives

`Packages/StrandAnalytics/Sources/StrandAnalytics/ActivityContextAuthority.swift`, policy
`expert-authority-1`. Per (day, device, input revision): `revisions` maps each UTC day to the HART windows'
input revision; a row from another revision is `input_revision_mismatch`. One ElderNet model and one motion
bundle per decode (canonical sources first, then the newest day; others `model_differs_within_decode`).
`digest` (sha256 over the policy and the sorted decisions) identifies a selection; the worker reports the
last one in the heartbeat and stores it with the candidate row.

Worker wiring (`ActivityLane.process`, step 5b): `ActivityCandidateDays.selection(...)` builds the job's
selection from its own results (each stage's windows with the release its mode allows, the pins and π it
enforced, the job's input revision and day, the HART-embedded windows as their own route). Every decode of
the job reads that one selection: the published v2 decode (`buildContextDayAndInput` → `canonical`), each
single-expert candidate (`ActivityMotionHeadsDays.candidate` / `ActivityGaitWindowsDays.candidate`, which
keep their earlier refusal reasons and then decode with `selection.decode(channels: [x])`), and the joint
candidate. Each expert row's summary carries the selection's decision as its authority block.

## Joint candidate and ablation storage

`Tools/CloudWorker/Sources/frwhoop-worker/ActivityCandidateDays.swift`. Arms: `hart` (no expert),
`hart+<channel>` per admitted channel, `joint` (all admitted channels in one decode: the decoder's own
tempered channels, correlation discounts and shared accelerometer budget; never an average of output
vectors). With one admitted channel, `joint` is that ablation (`same_as`). Each arm stores its channels, the
expert stamps that really shaped it, `document_sha256` (equal digests = byte-identical documents), a
final-output summary and a comparison against HART alone (`ActivityOutputComparison`: changed seconds,
coverage), and the expert track reports. Nothing is decoded twice: the HART arm reuses the published
document while no channel is canonical, and the single-expert arms reuse the expert rows' candidate
documents (the replay test proves reuse and fresh decodes give the same bytes).

Stored only while some expert runs in candidate mode (`ActivityLane.storesCandidateDays`), through
`publish_activity_candidate_day` under its own savepoint before the v1 publish (same lease/revision fence as
the other activity publishes; a rejection never blocks a publish). Retention 30 days
(`prune_activity_candidate_days`, every 6 h while candidate mode is on). Table is service-role only.

## ElderNet route selection

One route per windows/model revision: the worker's standalone ElderNet service. The worker starts the HART
child with `ACTIVITY_GAIT_EXPERT` cleared (`Config.hartChild`), so the embedded copy does not run on the
worker at all; and should a stored HART set carry embedded windows (an older worker, a hand-run serve), the
policy reads them as shadow and drops them whenever a standalone source exists
(`superseded_by_standalone_route`). The decoder's existing duplicate-vote suppression
(`ActivityContextEvidence.swift`: the in-process gait expert stands down on seconds where the gait-quality
channel speaks) is unchanged.

## Cache identity fields

`ActivityLocalCache.inferenceKey(request:identity:versions:)`: sha256 over the key schema, every entry of
the child's measured `loaded` map (artifact sha256s read from the bytes it loaded, the package code digest,
thread settings), the version labels, and the request. A child whose ping carries no `loaded` map (or whose
`loaded_digest` does not check out) gets no cache key, so nothing is cached. The ElderNet stage's in-memory
response cache uses the same key. HART `loaded` keys: `schema, code_sha256, manifest_sha256,
checkpoint_sha256, config_sha256, threads, env.*` (+ transition and gait artifacts when loaded); ElderNet:
`weights_digest, upstream_digest, calibration_sha256`; Inertia/ActiNet: `bundle_sha256,
encoder_config_sha256, checkpoint_sha256`.

Heartbeat: `meta.lanes[activity].identity` = `expert_policy`, `selection_digest` (last job),
`<child>.<loaded key>` and `<child>.loaded_digest` for `hart`, `inertia`, `eldernet`, and `<stage>.mode`.

## Migration notes (`20261008100000_activity_release_authority.sql`)

- `activity_gait_windows_days` and `activity_motion_heads_days`: `release_mode text` (null on old rows; check:
  null, `shadow`, or equal to `mode`) and `authority jsonb` (object or null). A `before insert or update`
  trigger copies `summary.authority` into `authority` and sets `release_mode`
  (`internal.activity_expert_release`: shadow unless mode is candidate and the block, if any, says candidate or
  production; motion rows with a stand-in encoder or a shadow-tier bundle are shadow). The publish functions
  are not replaced. No backfill: a null `release_mode` reads as the recorded mode (route `coalesce`).
- `activity_candidate_days` (PK owner, device, UTC day), `publish_activity_candidate_day(uuid, bigint, jsonb)`
  (fence: lease alive, revision current, payload `day` and `input_revision` equal the job's; raises
  `invalid_candidate_day_*` on a malformed payload), `prune_activity_candidate_days(integer, integer)`. RLS on,
  service role only (no `authenticated` select).
- Idempotent (`if not exists`, `drop … if exists`, `create or replace`); proven by applying it twice in the
  full-chain test.
- Rollback: leave candidate mode off; columns, trigger and table can stay.

## Interfaces changed (old vs new)

| Interface | Change | Compatibility |
|---|---|---|
| `/scores/gait-windows` | + `release_mode`, `input_revision`, `identity`, `authority`; + `authority` query capability | with the capability: additive. Without it: no `model`/`identity`/`authority` (older phones keep the walking card, lose the evidence they must not have) |
| `/scores/activity-windows` | + `input_revision`, `release_mode`, `embedded_gait_release_mode`; + `authority` capability | without the capability the `g_*` columns are left out |
| Expert row payloads | + `summary.authority` | old functions store it verbatim; new trigger copies it |
| New RPCs | `publish_activity_candidate_day`, `prune_activity_candidate_days` | an older DB rejects the call; the worker's savepoint absorbs it (counted `candidate_day_failures`) |
| Env | `FRWHOOP_ACTIVITY_THREADS` (HART child threads, 1…16, default 1); `ACTIVITY_GAIT_EXPERT` now cleared for the HART child | new |
| Heartbeat | activity lane `identity`; counters `expert_selections`, `expert_canonical_shaped` (with an expert on), `candidate_*` (in candidate mode) | additive |
| Swift (worker) | `ContextDayBuild.selection/inputRevision`, `Built.document`, `*Row` variants returning the candidate, `candidate(…, selection:)` | internal |
| Swift (StrandAnalytics) | `ActivityExpertAuthority`, `ActivityExpertSelection.decision(for:)` | additive |

Old workers: write no authority block and no candidate rows; their rows read as their recorded mode. Old
rows: likewise, never production.

## Extension points for Specs 02/03

A new optional activity checkpoint or head bundle plugs in without becoming production:

1. Producer: run it as a motion-heads encoder (`activity_context/inertia`, a new `encoder_kind` beside
   `inertia1`/`actinet`) with a Nara head bundle whose manifest carries `evidence_tier_max`, or as a new
   standalone serve process modelled on `eldernet.serve`. It must answer `ping` with a `loaded` map
   (`activity_context/loaded.py`) so cache keys and the heartbeat name its bytes.
2. Storage: rows in the existing expert tables (a new `encoder_kind` needs the kind check widened) with
   `summary.authority` built by `ActivityExpertAuthority(decision:…)`; a genuinely new channel adds a
   `Channel` case to `ActivityExpertSelection` (additive) and its own table with the same `release_mode` /
   `authority` / fence pattern.
3. Release: the stage mode stays shadow/candidate. Nothing reaches the canonical decode until a source is
   recorded as `production`, which today no table, setting or route allows; promotion is a separate change
   (widen the `mode` checks, a production mode in the stage settings, an owner decision and evaluation on
   final activity outputs via the joint candidate's ablations).
4. Evaluation: candidate mode stores the joint candidate and its ablations automatically; compare arms by
   `document_sha256` and `comparison` (final outputs and coverage), never by standalone classifier accuracy.
   A stand-in encoder or an encoder without matching trained heads is refused (`encoder_kind_standin`,
   `evidence_tier_shadow`) and never qualifies a bundle.

## Provider-to-consumer rows

| Provider | Input contract | Release mode | Storage | API | App consumer |
|---|---|---|---|---|---|
| HART (`activity_context.serve`, `hart-wisdm-v0` manifest/checkpoint) | raw IMU 20 Hz `RunRequest` chunks | production | `activity_encoder_windows` (`hart-windows-1`), `activity_context_epochs`, `activity_context_days` | `/scores/activity-windows` (+ `release_mode: production`) | phone decoder (canonical) |
| ElderNet standalone (`eldernet.serve`) | same chunks, 30 Hz resample, 10 s / 5 s hop | shadow / candidate | `activity_gait_windows_days` (+ `release_mode`, `authority`) | `/scores/gait-windows` | phone walking card; decoder only via the policy (canonical: never today) |
| ElderNet embedded in HART (`--gait-expert eldernet`) | HART's chunks | shadow (no release) | `g_*` in `hart-windows-1` | `/scores/activity-windows` (`embedded_gait_release_mode: shadow`) | none (policy drops it) |
| Motion heads, Inertia-1 encoder | 30 s @ 20 Hz windows | shadow (no public weights; stand-ins sealed at shadow) | `activity_motion_heads_days` | none | none |
| Motion heads, ActiNet/HARNet30 encoder | 30 s @ 20 Hz windows | unavailable for labels (no trained Nara head bundle) → shadow at most | `activity_motion_heads_days` | none | none |
| Transition expert (inside HART's service) | HART's windows | HART lineage (stamped per window) | `transition` in `hart-windows-1` | `/scores/activity-windows` | phone decoder (as today; not changed here) |
| Joint candidate (worker) | the job's selection | candidate, never published | `activity_candidate_days` | none (service role only) | none |

## Read-only runtime checklist (droplet)

```sh
# Heartbeat identity and counters of the activity lane
psql "$RO_URL" -Atc "select jsonb_pretty(l) from scoring_service_heartbeats h,
  jsonb_array_elements(h.meta->'lanes') l where l->>'name'='activity' order by h.last_poll_at desc limit 1"
# Expert rows of a day: release, identity, input revision, producer decision
psql "$RO_URL" -Atc "select day, mode, release_mode, model_version, weights_digest, input_revision,
  authority->>'use', authority->>'reason' from activity_gait_windows_days
  where user_id='<owner>' order by computed_at desc limit 5"
psql "$RO_URL" -Atc "select day, bundle_id, mode, release_mode, encoder_kind, evidence_tier_max, bundle_sha256,
  checkpoint_sha256, input_revision from activity_motion_heads_days where user_id='<owner>'
  order by computed_at desc limit 5"
# Nothing expert-shaped is production
psql "$RO_URL" -Atc "select count(*) from activity_gait_windows_days where release_mode not in ('shadow','candidate')"
# Joint candidates (candidate mode only)
psql "$RO_URL" -Atc "select day, policy, selection_digest, input_revision, withheld_reason,
  jsonb_object_keys(arms) from activity_candidate_days where user_id='<owner>' order by computed_at desc limit 8"
# Route responses (owner credential)
curl -s -H "authorization: Bearer $INSTALL_TOKEN" "$SUPABASE_URL/functions/v1/scores/gait-windows?days=<day>&authority=1" \
  | jq '.days[] | {day, mode, release_mode, input_revision, identity, authority}'
curl -s -H "authorization: Bearer $INSTALL_TOKEN" "$SUPABASE_URL/functions/v1/scores/activity-windows?days=<day>&authority=1" \
  | jq '.days[] | {day, input_revision, release_mode, embedded_gait_release_mode}'
# Child processes, their threads and RSS (one per enabled stage; no ACTIVITY_GAIT_EXPERT on HART)
ps -o pid,rss,nlwp,args -C python3 | grep activity_context
cat /proc/<hart pid>/environ | tr '\0' '\n' | grep -E 'ACTIVITY_|_NUM_THREADS'
```

## Phone side

### What changed and why

Two defects at the base:

1. `GaitWindowStore.evidenceConfig(model:)` built a `mode: .production` ElderNet config whatever the stored row's
   `mode` was, and `Repository.activityBaseDecoderConfig` installed it whenever its own hard-coded pins matched. A
   shadow or candidate `/gait-windows` row could therefore shape the phone's own decode (after round 1 the decoder
   refused the unrecorded windows, but the config, its cache tag and the decision were still the phone's, not the
   policy's).
2. `AppModel.syncGaitWindows` ran inside the success path of the HART (`/activity-windows`) fetch, so any HART
   failure (404 on an older server, a timeout) skipped the gait sync.

Now:

- The phone never builds an expert evidence config. `GaitWindowStore.Pins` and `evidenceConfig(model:)` are gone,
  and `activityBaseDecoderConfig` carries no expert entries. Every decode the wearer sees goes through
  `ActivityPhoneEvidence.canonical(...)` (`Strand/Data/Repository+ActivityContext.swift`), which builds the shared
  policy's sources from the stored rows, calls `ActivityExpertSelection.select(...)` and decodes with
  `.canonical(...)`.
- HART and gait windows are fetched by one pass object, `ActivityWindowsSync` (`Strand/Data/ActivityWindowsSync.swift`),
  which runs each fetch on its own and allows one pass at a time.

### How the phone uses the shared policy

`ActivityPhoneEvidence.canonical(input, base:, encoders:, gait:)` for a decode span `[dayStart, dayEnd)`:

| Policy argument | Built from |
|---|---|
| `revisions` | `ActivityEncoderWindowStore.inputRevisions(from:to:)`: each stored HART UTC day's `input_revision` (days that do not record one are absent, which the policy does not treat as a mismatch). |
| `gaitQuality` | `GaitWindowStore.sources(from:to:)`: one `GaitQualitySource` per stored UTC day with windows ending in the span; `releaseMode` = the record's `recordedRelease` (below), `route: .standalone`, pins / prior / input revision / day from the record. |
| `motionHeads` | always `[]` (no phone readback; see "Motion heads"). |
| `embeddedGait` | `EmbeddedGaitSource(windows: input.gaitWindows, releaseMode: ActivityEncoderWindowStore.embeddedGaitRelease(...))`: the HART-embedded ElderNet windows stored in `hart-windows-1`, at the weakest release the overlapping HART days record (`embedded_gait_release_mode`; missing = shadow). |

`selection.canonical(input, base:)` then installs only production channels and strips every other expert entry from
both the input and the config. The cache key (`"<reads>@<config.cacheTag>"`) uses that canonical config, so the
on-disk ActivityContext of a day is keyed by what actually shaped it; `cachedActivityContext(dayStart:)` computes
the same config for its instant draw.

Effect with today's server rows (all `shadow`/`candidate`, no pins in the route): no ElderNet, motion-head or
embedded-gait evidence reaches the phone's decode, i.e. it equals HART alone plus the strap's streams. This is a
visible change only on days whose stored `hart-windows-1` still carries HART-embedded `g_*` windows (the worker
disabled that route in round 1, `ActivityPythonService.Config.hartChild`); those windows used to shape the decode
unconditionally and now read as shadow, as the policy says. The worker's published stream day makes the same
change on `spec01/activity-20261007` (`ActivityContextDays.buildStreamDay` decodes with
`select(embeddedGait:).canonical(...)`, commit `3a685526e`), so phone and server still decode the same evidence.

There is no experimental preview on the phone (no UI decodes a candidate arm), so none was added. The walking card
(`GaitWindowsCache`, `WalkingInsightsSection`, `DayActivityDetailViews`) shows ElderNet gait quality from the
route's newest row; it is quality reporting, not activity decoding, and is unchanged (see "Requests to parent").

`Repository+ActivityPersonalProfile.swift` (not owned here) still gates gait windows on
`activityBaseDecoderConfig.gaitQuality`, which is now always nil, so the personal-profile fit runs without ElderNet
(as it effectively did at the base, where the decoder refused the unrecorded windows).

### Stored fields and migration

All new fields are optional Swift properties with nil defaults, so the synthesized `Decodable` reads records written
before them (missing keys decode as nil). Nothing is rewritten on upgrade; a day is replaced the next time the route
sends it at a new revision.

`GaitWindowStore.DayRecord` (`OpenWhoop/GaitWindows/<owner>/<device>/<day>.json`):

| Field | From the route | Old record |
|---|---|---|
| `mode` (existing) | `mode` | as stored |
| `releaseMode` | weaker of `release_mode` and `authority.release_mode` | nil |
| `inputRevision` | `input_revision` (else `authority.input_revision`) | nil |
| `pinnedModelVersion`, `pinnedWeightsDigest`, `gaitPrior` | `authority.pinned_model_version`, `.pinned_weights_digest`, `.gait_prior` | nil |
| `producerUse`, `producerReason` | `authority.use`, `.reason` (informational; the policy is re-run) | nil |
| `identity` | `identity` (must name the same `model_version` / `weights_digest` as `model`, else the day is not stored) | nil |

`recordedRelease` = `ActivityReleaseMode(recorded: mode)` lowered to `ActivityReleaseMode(recorded: releaseMode)` when
present: missing or unknown text is shadow, and a `release_mode` above `mode` cannot raise it. An old record (mode
`candidate`, no pins, no prior) therefore reads as candidate and the policy lowers it to shadow (`model_not_pinned`);
it is never production. A day the route answers `unchanged` with a lower `release_mode` than stored is lowered in place
(`GaitWindowStore.lowerRelease`), never raised. `save` compares every field except the windows' JSON text, so a demoted
or newly pinned row at the same revision is stored.

`ActivityEncoderWindowStore.DayRecord` (`OpenWhoop/ActivityWindows/...`): new `inputRevision` (`input_revision`),
`releaseMode` (`release_mode`, kept for inspection; HART is the production producer and is not gated here) and
`embeddedGaitReleaseMode` (`embedded_gait_release_mode`). Old records: nil, nil, nil (embedded gait reads as shadow).

`ServerScoreRepository.ActivityWindowsDay` / `GaitWindowsDay` carry the same fields (all optional, nil from a server
without them). `revisionNumber` accepts the int64-as-string the route sends (or a number; booleans and fractions
rejected).

### Fetch independence

`AppModel.syncActivityWindows` keeps its guards (cloud scoring authoritative, owner of the strap data, a read
candidate) and then calls `ActivityWindowsSync.run(hart:gait:)`:

- `hart` and `gait` each run inside their own `do/catch`; a throw is recorded in the outcome (`hartFailed`,
  `gaitFailed`) and the other still runs. Order: HART, then gait (sequential, so at most one request of each per pass).
- One pass at a time: a call while a pass is in flight returns nil (dropped, not queued); a new pass starts only
  `activityWindowsRefreshSeconds` (300 s) after the last one started. Sign-out calls `reset()` (the old
  `activityWindowsSyncedAt = nil`); an in-flight pass then finishes and its results are dropped by the per-fetch
  account checks.
- Materialization and the personal-profile refit are requested when either store changed.

### Motion heads

No phone store or route method: motion-head rows are shadow/candidate only, so the canonical decode could not use
them, and the worker side added no route (its doc, "Motion heads"). `ActivityPhoneEvidence` passes
`motionHeads: []`. When a production promotion adds a route with the `/gait-windows` fields, the extension point is a
`MotionHeadsWindowStore` beside `GaitWindowStore` whose `sources(from:to:)` feeds `motionHeads:` the same way.

### Compatibility

| Server | Phone behaviour |
|---|---|
| Today's (no release fields) | Gait rows stored with `mode` only; policy reads them as shadow (`model_not_pinned`); canonical decode = HART alone. HART days stored without revision; embedded gait shadow. |
| Release-authority route (`20261008100000` + new `serverScores.ts`) | Fields stored; rows are at most candidate (`release_mode` never production), so canonical decode is still HART alone; a candidate arm would be admitted by the policy but nothing on the phone decodes one. |
| A future production row | Admitted to the canonical decode only with pins, a prior and a matching input revision (`testAProductionRowWithItsPinsShapesTheCanonicalDecode`). |
| Old phone against the new route | Ignores the new fields; its own base defect remains on that build (it is fixed only by shipping this one). |

### Tests

New `StrandTests/ActivityPhoneAuthorityTests.swift` (macOS):

- `testShadowAndCandidateGaitRowsCannotChangeThePhonesDecode`: replay through the real stores
  (`ActivityEncoderWindowStore` with HART windows, `GaitWindowStore`) → `ActivityPhoneEvidence.canonical` →
  `ActivityContextDayBuilder.update`; the sorted-key JSON of the document and the cache tag are identical with no
  gait rows, shadow and candidate rows from today's server, pinned shadow/candidate rows from the new route, and a
  candidate row whose `release_mode` claims production. Sensitivity check: the pinned candidate row decoded as a
  candidate arm does change the document.
- `testAProductionRowWithItsPinsShapesTheCanonicalDecode`: positive control; and a row from another input
  revision is not combined.
- `testEmbeddedGaitWindowsInHartRecordsStayOutOfTheCanonicalDecode`: HART-embedded windows at nil / shadow /
  candidate / unknown release decode identically to a HART day without them.
- `testRecordsStoredBeforeTheReleaseFieldsReadAsTheirRecordedModeNeverProduction`,
  `testHartRecordsStoredBeforeTheFieldsReadWithoutRevisionAndShadowEmbeddedGait`: old on-disk JSON layouts.
- `testAnUnchangedDayCanOnlyBeLoweredInPlace`.
- `testGaitRouteParsingOldAndNewServer`, `testActivityWindowsRouteParsingCarriesRevisionAndReleases`.
- `testGaitFetchRunsWhenHartFetchFails`, `testOnePassAtATime`.

### Test results

All with `DEVELOPER_DIR="/Volumes/External SSD/Xcode.app/Contents/Developer"`, after `xcodegen generate`,
derived data under `_build-scratch/spec01/activity-phone/`:

- `xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath …/dd-mac
  -only-testing:StrandTests/ActivityPhoneAuthorityTests -only-testing:StrandTests/ActivityImuCaptureTests
  -only-testing:StrandTests/ActivityPersonalProfileStoreTests`: 25 tests, 0 failures (10 + 9 + 6).
- Same with `-only-testing:StrandTests`: 3216 tests, 13 skipped, 11 assertion failures in 3 test cases:
  `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets` (known time-zone failure) and
  `ActivityCalibrationSessionTests.testBeginWithAnEmptyProtocolEndsCleanly` /
  `.testStepsChainBackToBackAndEveryActivityEndsWithDone`. The two calibration tests are not in COMMON.md's known
  list but fail identically (22 tests, 10 failures) with every file of this branch reset to `49bb94039`, so they
  were already failing at the base and are not caused by this branch (they touch none of its code). The other two known
  time-zone tests passed in this run.
- iOS: `xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug -destination generic/platform=iOS
  -derivedDataPath …/dd-ios CODE_SIGNING_ALLOWED=NO build`: `** BUILD SUCCEEDED **`.

Not verified: a real device against the deployed or the new route (no deploy, by rule); the worker's route
fields were read from its committed `serverScores.ts`/doc at its final `e25dc3fb0` (route unchanged since `3a685526e`) and are matched by the parsing tests
here, not by an end-to-end request.

### Phone-side requests to parent

1. Fold this section into `activity-authority.md` (worker side owns that file).
2. `Strand/Data/Repository+ActivityPersonalProfile.swift` (not owned here) still reads gait windows through
   `activityBaseDecoderConfig.gaitQuality` + `GaitWindowStore.trackInput`. The config no longer carries an ElderNet
   entry, so the personal-profile fit now runs without ElderNet (at the base the decoder already refused those
   unrecorded windows). If a production gait row should ever reach the fit, route that input through
   `ActivityPhoneEvidence.canonical(...)` there (a few lines; no change needed for today's rows).
3. Owner decision: the walking card (`GaitWindowsCache`, `WalkingInsightsSection`, `DayActivityDetailViews`) shows
   ElderNet gait quality from the newest row of any mode. That is quality reporting, not activity decoding, and is
   unchanged here; say if it should be limited to candidate or production rows.
4. After the worker branch merges, the hand-written parsing of the `authority` block in
   `ServerScoreRepository.gaitWindowsDays` can be replaced by `ActivityExpertAuthority` (added on
   `spec01/activity-20261007` in `09790adab`, not in this tree, so not used here); field names and semantics already
   match its final doc (`e25dc3fb0`).
5. `ActivityCalibrationSessionTests` (2 tests) fail at `49bb94039` with no change of this branch involved; please
   assign to whoever owns `Strand/Collect/ActivityCalibrationSession.swift`.

## Resources

Every activity child is a separate Python process in the worker's systemd cgroup. Each now caps its numerical
threads: the worker sets `OMP/OPENBLAS/MKL/VECLIB/NUMEXPR_NUM_THREADS` for every child (`numericalThreads`),
torch intra-op threads are capped by the serve process (`--threads`, inter-op 1), the HART child takes
`FRWHOOP_ACTIVITY_THREADS` (default 1), ElderNet `FRWHOOP_ELDERNET_THREADS` (default 1), Inertia
`FRWHOOP_INERTIA_THREADS` (default 1). Each child reports its thread settings in its `loaded` map.

Measured on 2026-10-08 with `python -m activity_context.resources` (Darwin arm64, Python 3.10.20, one synthetic
hour per child, `Tools/ActivityContext/.venv`; outputs in `_build-scratch/spec01/activity/rss-r2/`). The host
was heavily loaded by other sessions (load average up to ~800), so latencies are not representative; the first
HART runs timed out (60 s) and were repeated when the load fell (`*-b.json`, used below).

| Child | Artifact (sha256) | Peak RSS | RSS after load | OS threads |
|---|---|---|---|---|
| HART v0, capped (1) | `hart-wisdm-v0` checkpoint `39dc12e0…3b2f`, manifest `d6a7def3…baf` | 454,112 KiB | 375,280 KiB | 2 |
| HART v0, uncapped (before this change) | same | 417,856 KiB | 325,856 KiB | 17 |
| ElderNet standalone, capped (1) | `research/eldernet-upstream` weights digest `01b2f982…4ca6`, upstream `f7639763…8bb7` | 302,112 KiB | 204,128 KiB | 1 |
| Inertia serve, stand-in tiny fixture (shadow) | `fixtures/inertia/encoder_tiny.ckpt` `7a1677c8…7dad`, bundle `03eb56f2…` | 234,624 KiB | 180,752 KiB | 1 |
| ActiNet HARNet30 encoder alone, 720 windows, 1 thread | `research/actinet-artifacts/actinet-harnet30-c24-mw-20260128.pt` `46732ff2…7ba5` | 361,472 KiB | 210,608 KiB | — |

Not measured: a real Inertia-1 checkpoint (no public weights; none on disk) and a trained Nara head bundle
for ActiNet (none exists; the encoder alone is measured, which is what such a bundle would add). Totals with
every stage on: HART + ElderNet + one motion-heads child ≈ 454 + 302 + 361 MiB ≈ 1.1 GiB of child RSS on top
of the worker itself, with at most 2 + 1 + 1 OS threads of numerical work (previously HART alone used 17).

## Tests run (this round)

| Command | Result |
|---|---|
| `cd Packages/StrandAnalytics && xcrun swift test --skip LongitudinalBaselineTests --filter ActivityContext` | 295 tests, 0 failures |
| worker `xcrun swift test --filter "ActivityElderNetStageTests\|ActivityInertiaStageTests\|ActivityLocalCacheTests"` | 58 tests, 0 failures |
| worker `xcrun swift test --filter ActivityAuthorityReplayTests` | 7 tests, 0 failures |
| worker `FRWHOOP_TEST_DB_URL=<throwaway full-chain cluster> xcrun swift test --filter "Activity.*DatabaseTests"` | 36 tests, 0 failures, 0 skipped |
| worker full `xcrun swift test` (no `FRWHOOP_TEST_DB_URL`) | 696 tests, 67 skipped (the database suites), 0 failures |

An earlier filtered run under host load average ~800 failed four timing-sensitive tests (ElderNet NaN/internal,
Inertia time budget, two `ActivityPythonServiceTests` timeout/restart cases: a 5 s ping timed out); none touches
the code changed here, and all passed in the full run above.
| `Tools/ActivityContext/.venv/bin/python -m pytest tests -q` | 639 passed, 44 skipped, 3 failed (the three `test_inertia_golden.py` checks, an `ood_score` drift in the 4th decimal; they fail identically at the round-1 base, `logs/pytest-base-full.log`) |
| `deno test … tests/activity_windows_route_test.ts tests/gait_windows_route_test.ts` (+ auth, ground-truth, enrolled-scores, physiology-context route tests) | 72 passed, 0 failed |
| `EDGE_TEST_ARTIFACTS=<scratch> deno test … tests/activity_authority_sql_test.ts` (full migration chain; runs the activity context, encoder windows, gait windows, motion heads and release-authority contracts, re-applies the migration, reads the routes through PostgREST) | 1 test, 7 steps, 0 failed |

## Requests to parent

1. **Unit limits** (`deploy/`, not edited here): give the worker unit a memory ceiling that covers the worker plus
   the measured child total, for example `MemoryHigh=` worker RSS + 1.2 GiB and `MemoryMax=` that + 25 %, and
   `TasksMax=` large enough for the worker's threads plus ~8 child threads. Set `FRWHOOP_ACTIVITY_THREADS=1`,
   `FRWHOOP_ELDERNET_THREADS=1` explicitly in the env template so the caps are visible to an operator, and do not
   set `ACTIVITY_GAIT_EXPERT` (the worker clears it for the HART child anyway).
2. **Deploy order**: apply `20261008100000_activity_release_authority.sql` before deploying the `scores` function
   (the route selects `release_mode`, `input_revision`, `authority`).
3. **Shared README**: list `activity_candidate_days` as service-role-only and the activity lane's heartbeat
   `identity` keys (`expert_policy`, `selection_digest`, `<child>.<loaded key>`, `<child>.loaded_digest`).
4. `docs/ARCHITECTURE.md` §7: one paragraph that the published activity decode reads
   `ActivityExpertSelection.canonical` and that the HART-embedded ElderNet route no longer runs on the worker.
