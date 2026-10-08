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

- `ActivityExpertSelection.Decision` is also `Decodable` (it already was `Codable`; unchanged).
- `ActivityExpertAuthority` (new, StrandAnalytics): the `authority` block a producer stores with a row and the
  route returns, `Codable`, with `gaitSource(track:releaseMode:day:)`/`motionSource(track:mode:day:)` helpers
  that build the policy's sources from it. See "Row authority block" below.

How the phone uses it: build one `GaitQualitySource` per `/gait-windows` row (below), the HART windows'
input revision per UTC day from `/activity-windows` (`input_revision`), call `select`, and decode with
`canonical(...)`. Anything else (a candidate arm) is a preview and must be kept separate from the canonical
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

(The remaining sections are filled in below as the work lands.)
