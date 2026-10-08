# Model preparation, runtime identity and releases (Spec 01 §1)

Area: Deployment and release. Branch `spec01/deploy-20261007`. Shared contract:
[README.md](README.md) ("Runtime identity"). Operator steps: [deploy/README.md](../../deploy/README.md),
read-only checklist: [deploy/OPERATIONS.md](../../deploy/OPERATIONS.md#runtime-identity-checklist).

## What changed and why

| Defect at the audited base | Fix |
| --- | --- |
| `provision.sh` parsed top-level `artifacts`/`models`; the manifest has `entries[].artifacts[]`, so it saw 0 of 11 entries / 18 artifacts. SleepECG's two required artifacts have prose in `url` (bundled in the wheel / extracted from a zip). | The shell no longer reads the manifest. Its model section calls `Tools/InferenceWorker/scripts/materialize_model_root.py stage` with the sidecar venv, which plans with `artifacts.plan_manifest` and verifies with `artifacts.verify_manifest` (the sidecar's own startup check). Every artifact declares a machine-readable `source`. |
| Artifacts were written straight into the live root; a failure left a half-written cache selected. | A complete revision is staged beside `revisions/`, verified, probed, sealed read-only, renamed to a content id and selected by an atomic symlink replace. A rejected revision leaves `current` alone. |
| `provision.sh` did `cd /opt` / `cd /opt/sqlite` before computing `REPO_ROOT`; the documented relative invocation lost its path. | `SCRIPT_DIR`/`REPO_ROOT`/`MANIFEST`/`MATERIALIZER` are resolved on the first lines, before any `cd`; `--models-only --models-root DIR` runs the same model code path unprivileged. |
| `FRWHOOP_SOURCE_REVISION` was the only statement of what runs. | Worker and sidecar measure themselves (executable digest; source tree, lock, manifest, revision and artifact digests) and report the env value only as `claimed_source_revision`. |
| The release tarball omitted `Packages/` and was extracted over `/opt/noop`, so old analytics code could survive. | `deploy/package-release.sh` packages ONE git revision with the local package closure derived from the `Package.swift` files; `deploy/release-host.sh` installs into a fresh `/opt/noop/releases/<commit>`, builds and tests there, seals it and switches `/opt/noop/current` atomically. |

Kept from the first round (no concrete defect found): the materializer/verifier split, the content
revision id, the stamp/build-record pair and the `--print-identity` entry point. Added in round 2: a
test that drives one `/healthz` answer through the real HTTP server and checks every §1 field
together, and a worker-reported loaded identity (`worker_loaded_identity`, below).

## Manifest schema extension (`models/manifest.json`, `manifest_version` 1.1.0)

Additive only; every existing field and reader is unchanged (`load_manifest`, `verify_manifest`,
`manifest_summary`, ParaDigMa's and rhythm's `artifact_state`).

`entries[].artifacts[].source` (`artifacts.SOURCE_KINDS`):

| `kind` | Members | Provisioner action |
| --- | --- | --- |
| `url` | (uses the artifact's `url`) | HTTPS fetch (plain http refused), body capped at `size_bytes`, installed only after sha256 and size match; or copied from `--mirror DIR` |
| `wheel_resource` | `package`, `version?`, `resource` | copied from the installed distribution (SleepECG `classifiers/wrn-gru-mesa.zip`) |
| `zip_member` | `artifact`, `member` | extracted from another artifact of the same entry (`classifier.keras`) |
| `installed_package` | `package`, `version` | `check_installed`: the version from `uv.lock` is confirmed, nothing is copied |
| `none` | `reason` | recorded only |

A manifest without `source` still reads: an `https://` `url` is a `url` source, anything else is
`none` (`artifacts.artifact_source`). Plan actions (`artifacts.PLAN_ACTIONS`): `stage`,
`check_installed`, `record` (not verified at startup, or no fetchable source), `skip` (entry status
not in `eligible`/`shadow_eligible`, or `wired: false`). Required providers
(`artifacts.required_providers`) are the providers of wired entries with
`required_for_readiness: true`; today only `sleepecg.wrn-gru-mesa.v1`.

## Revision layout and `revision.json`

```
/opt/frwhoop-models/
  revisions/<rev-id>/        read-only; <rev-id> = "rev-" + sha256(schema, manifest sha256,
      manifest.json          sorted (path, sha256, size) of every verified artifact)[:16]
      revision.json
      <artifact paths>       the manifest's relative paths
  revisions/.staging-*       in progress; removed on rejection or by the next run
  current -> revisions/<rev-id>   replaced by symlink-to-temp + os.replace
  .provision.lock            flock; a second provisioner exits 3
```

`revision.json` (schema `frwhoop-model-revision/1`): `revision_id`, `created_at_utc`,
`manifest {sha256, manifest_version, entries, artifacts}`, `staged_by {commit, dirty, source
(release_stamp | git | unknown), materializer_sha256, python}`, `artifacts[]` (plan action, reason,
source, outcome per artifact), `verification {ok, reason, checks[]}`, `required_providers`,
`withheld[] {entry_id, provider_id, required, artifacts, reason}`, and `probe {ok, process_ready,
providers{pid: {ready, reason, version}}}`. Materializer exit status: 0 selected or unchanged,
1 rejected, 2 usage, 3 lock held. CLI: `stage`, `plan`, `list`, `select <rev-id>` (rollback), and
the original flat `<dest-root>` form (tests, end-to-end scripts).

The sidecar pins its root once: `artifacts.pin_model_root(os.environ)` at the top of
`server.main()` resolves `FRWHOOP_MODEL_ROOT` (`/opt/frwhoop-models/current`) and
`FRWHOOP_MANIFEST` to real paths and writes them back, so every provider (including the optional
ones that read the variables themselves) stays on one revision for the process lifetime.

## Identity fields

### Worker: `scoring_service_heartbeats.meta.identity` and `frwhoop-worker --print-identity`

`RuntimeIdentity.swift`, schema `worker-identity/1`. Measured once at startup; failures go to
`error` and never block startup or the heartbeat. `--print-identity` prints the same JSON and
exits before any configuration or connection.

| Field | Meaning |
| --- | --- |
| `executable {path, sha256}` | sha256 of `/proc/self/exe` on Linux (the file actually running, even if its path was replaced), else the bundle executable |
| `release {stamp_path, stamp_sha256, release_id, git_commit, git_tree, dirty, created_at_utc, files_sha256, package_resolved_sha256, build{…}}` | `RELEASE.json` found via `FRWHOOP_RELEASE_STAMP` or up to 6 levels above the executable; `build` is `BUILD.json` beside it (`executable_sha256`, `release_stamp_sha256`, `built_at_utc`, `swift_version`, `platform`, `tests`) |
| `matches_release` | true only when the measured executable digest equals the build record's and the build record names this stamp's digest |
| `claimed_source_revision`, `claimed_revision_matches_release` | `FRWHOOP_SOURCE_REVISION` as a claim, and whether it equals the stamp's commit |
| `measured_at`, `error?` | |

Lanes may add their own measured identities in `meta.lanes[].identity` (string map, shared
contract).

### Sidecar: `identity` in `GET /healthz` and `GET /v1/providers`

`identity.py`, schema `runtime-identity/1`. Digests are cached by (path, size, mtime); the package
source digest is computed once at import, so a request costs a few `stat` calls.

| Field | Meaning |
| --- | --- |
| `code_revision {commit, dirty, source_matches_release, uv_lock_matches_release}` | commit from the release stamp, confirmed by the measured source tree and lock; null without a stamp (a claim is never promoted) |
| `source {path, sha256, files, measured_at_utc, error?}` | digest over the imported `frwhoop_inference` package (bytecode ignored) |
| `uv_lock_sha256` | the lock beside the package |
| `release` | stamp summary (`RELEASE.json` beside the code or `FRWHOOP_RELEASE_STAMP`), or `{error}` |
| `manifest {path, sha256, manifest_version, verified_at_utc, model_root, model_root_resolved, configured_model_root, revision, matches_release, matches_revision}` | the manifest bytes this process verified against and the pinned root |
| `model_revision` | the selected revision's `revision.json` summary: `revision_id`, `sha256`, `manifest_sha256`, `staged_by`, `withheld`, `probe_process_ready` |
| `artifacts[] {entry_id, name, status, sha256}` | startup verification verdict; `sha256` only when `verified` |
| `providers {pid: {ready, reason, loaded?, loaded_source?}}` | readiness; `loaded` is what the provider reports through `loaded_identity()` |
| `claimed_source_revision`, `package_version`, `contract_version` | |

`loaded` and `loaded_source`: checkpoints load in the warm infer worker process (runtime area,
`execution.py`), not in the HTTP process. `identity.py` therefore prefers
`app.worker_loaded_identity[pid]` (`loaded_source: "worker"`) when the server publishes it, and
falls back to calling `loaded_identity()` on the HTTP process's provider copy
(`loaded_source: "process"`), which is right only for providers that can name their bytes without
loading them. Nothing fills `worker_loaded_identity` yet (request 1 below); until then the verified
`artifacts[]` digests are the checkpoint digests in use, because a provider's readiness is gated on
exactly those checks.

## Packaging and deploy steps

`deploy/package-release.sh --out DIR [--rev REV] [--allow-dirty] [--dry-run]` (stdlib python):
`git archive` of `Tools/CloudWorker`, the local packages reached from its `Package.swift`
(StrandAnalytics, WhoopProtocol, WhoopStore and, through WhoopStore, OuraProtocol), the repository
files those packages' tests read by path, `contracts`, `deploy`, `Tools/ActivityContext`,
`Tools/InferenceWorker` and the licence files. A dirty tree is refused unless `--allow-dirty`
(then id `<commit>-dirty-<tree>`, `dirty: true`). Inside: `RELEASE.files` (sha256sum format) and
`RELEASE.json` (schema `nara-release-stamp/1`: `release_id`, `git_commit`, `git_tree`, `dirty`,
`created_at_utc`, `package_resolved_sha256`, `uv_lock_sha256`, `manifest_sha256`,
`included_paths`, `local_packages`, `test_fixture_paths`, `files {name, count, sha256}`,
`trees {path: sha256}`, `tool`). `verify RELEASE_DIR` re-checks an extracted tree.

`deploy/release-host.sh [--root /opt/noop] install|build|switch|rollback|status`: `install` checks
the tarball's `.sha256` and every stamped file and refuses an existing `releases/<id>`; `build` runs
`swift build -c release` and `swift test` there against `/opt/sqlite`, writes `BUILD.json`, runs
`--print-identity` and refuses unless `matches_release` is true and the digest matches, prunes the
test build and seals the tree; `switch` refuses a release without `BUILD.json` or whose binary
changed, and replaces `current` atomically (old target becomes `previous`); `rollback` switches to
`previous`. The worker unit runs `/opt/noop/current/Tools/CloudWorker/.build/release/frwhoop-worker`
with `ReadWritePaths=/var/lib/frwhoop` only. The sidecar venv is per release
(`/opt/frwhoop-inference/venvs/<id>`, outside the read-only release tree) and
`/opt/frwhoop-inference/venv` points at it.

## Rollback

- Worker code: `/opt/noop/current/deploy/release-host.sh rollback && systemctl restart frwhoop-worker`.
  Releases are never deleted by the scripts.
- Sidecar code: re-run the previous release's `provision.sh --sidecar-only` (its venv still exists,
  the link is switched back) and restart `frwhoop-inference`.
- Models: `materialize_model_root.py select --models-root /opt/frwhoop-models <rev-id>` and restart
  the sidecar.
- A host on the pre-release layout keeps `/opt/noop/{Tools,contracts,deploy}` untouched as the
  rollback target of the first move (deploy/README.md, "Moving an existing host to releases").

## Evidence (runs on this branch)

Sidecar, macOS (`cd Tools/InferenceWorker`):

- `uv run --frozen pytest -q -o addopts="" tests/test_provisioning.py tests/test_identity.py tests/test_release_packaging.py tests/test_manifest.py`
  at the integration merge 49bb94039: **63 passed** (218 s). After the round-2 identity changes,
  `tests/test_identity.py`: **9 passed**. Final counts: see "Final runs" below.
- What the provisioning fixture proves (`tests/test_provisioning.py`, real manifest, no network):
  the plan enumerates every entry and nested artifact with counts read from the file and a reason
  for each (`stage`/`check_installed`/`record`/`skip`); blocked and unwired entries are never
  fetched; a revision is staged from the real SleepECG wheel bytes plus optional bytes from a stub
  fetcher, verified, probed and selected; re-staging is idempotent; a corrupted or missing required
  artifact and a not-ready required provider reject and keep the previous `current`; an existing
  revision directory with other bytes is never reused; a missing optional artifact withholds only
  its provider; `provision.sh --models-only` runs by relative path from another cwd, unprivileged,
  idempotently, and exits non-zero on rejection; `provision.sh` resolves its paths before any `cd`;
  `select` rolls back and refuses unknown ids; the lock refuses a second provisioner; interrupted
  staging is cleaned; a real directory at `current` is never replaced; unsafe paths, plain http and
  oversized bodies are refused; fetched bytes are verified before install.
- `tests/test_identity.py::test_healthz_reports_code_lock_manifest_loaded_digests_and_readiness_together`:
  one `/healthz` over a real `InferenceServer` socket, with a revision staged by the real
  materializer, a release stamp and a provider gated by the real SleepECG entry, returns the stamp's
  commit with `source_matches_release`/`uv_lock_matches_release` true, the measured `uv.lock` and
  manifest digests, `matches_release`/`matches_revision` true, both SleepECG artifacts `verified`
  with digests, the provider's loaded checkpoint digest equal to the verified one, and readiness
  equal to the route's own provider map.
- Unprivileged smoke against the real manifest (macOS, offline):
  `deploy/provision.sh --models-only --models-root _build-scratch/spec01/deploy/smoke-models-r2 --offline`
  from `/tmp`: exit 0, `SELECTED rev-a784abfae6243237`, manifest sha256 `bfa5e1de…20fe08a`
  (11 entries, 18 artifacts), `required_providers: [sleepecg.wrn-gru-mesa.v1]`, probe
  `process_ready: true`; ParaDigMa (3 files), DeepBeat and SiamAF recorded as withheld (optional,
  missing offline); the revision directory is `r-x`.

Linux release build: see "Linux release build" below.

## Read-only runtime checklist (droplet)

The full command list is in [deploy/OPERATIONS.md](../../deploy/OPERATIONS.md#runtime-identity-checklist).
Summary: `readlink /opt/noop/current`, `release-host.sh status`, `sha256sum -c RELEASE.files`;
`sha256sum /proc/<worker pid>/exe` equals heartbeat `meta.identity.executable.sha256` and
`BUILD.json` `executables["frwhoop-worker"].sha256`, `matches_release: true`,
`release.git_commit` is the shipped commit; `curl -s 127.0.0.1:8787/healthz | jq .identity`:
`code_revision.commit` equals `RELEASE.json`, `source_matches_release`, `uv_lock_matches_release`,
`manifest.matches_release`, `manifest.matches_revision` true, `manifest.revision` equals
`readlink /opt/frwhoop-models/current`, required artifacts `verified`, withheld providers listed;
`sha256sum /opt/frwhoop-models/current/revision.json` equals `model_revision.sha256`;
`systemctl show … -p MemoryCurrent -p MemoryPeak -p TasksCurrent` for resource use. No droplet
session was available to this area: deployment is **not verified** on the droplet.

## Compatibility

- Manifest: additive `source`; old manifests (no `source`) read as before; `verify_manifest`,
  `manifest_summary` (now also exposes `source`), `artifact_state` readers unchanged.
- Model root: the default stays `/opt/frwhoop-models`; a host whose root is a plain directory keeps
  working (no revision is reported). The materializer never replaces a real directory at `current`.
- Sidecar HTTP: `identity` is a new member of `/healthz` and `/v1/providers`; no field was removed
  or renamed. Old workers ignore it.
- Heartbeat: `meta.identity` and `meta.lanes[].identity` are new members of the existing jsonb;
  nothing reads them in the app or edge functions. No migration.
- `FRWHOOP_SOURCE_REVISION` is still read and reported (as a claim). New optional env:
  `FRWHOOP_RELEASE_STAMP` (worker and sidecar; default: search above the executable / package).
- Worker unit: `ExecStart`/`WorkingDirectory` moved to `/opt/noop/current/...`; resource limits
  unchanged. A pre-release host must follow "Moving an existing host to releases" before installing
  the new unit; until then its old unit keeps working.
- Releases built on arm64 (the Linux check below) and on the x86_64 droplet have different binary
  digests; identity compares a process with its own host's build record only.

## Extension points for Specs 02/03

Adding a new optional checkpoint (for example a Spec 03 head) so that it is staged and verified but
never becomes required:

1. Add (or extend) an entry in `models/manifest.json` with the real licence verdict, `status`
   `shadow_eligible` (or `eligible`), `wired: true` only once a provider reads it, the provider's
   `provider_id`, and per artifact: `path` (relative, under its own versioned directory),
   `sha256` and `size_bytes` of the real bytes, `verify_at_startup: true`,
   `required_for_readiness: false` on the artifact AND the entry, and a `source` (`url` for a pinned
   HTTPS download; `wheel_resource`/`zip_member`/`installed_package` when the bytes ship in a pinned
   dependency). Never add an artifact without a real digest; `sha256: null` with
   `verify_at_startup: true` is a check failure (`no_sha256`).
2. `materialize_model_root.py plan` must show the new artifacts as `stage`; `tests/test_manifest.py`
   (`test_every_artifact_declares_a_machine_readable_source`,
   `test_every_staged_artifact_can_be_produced_and_verified`) and `tests/test_provisioning.py`
   cover it once the stub fetcher in `tests/provision_support.py` knows the bytes (tests never use
   the network).
3. The provider reads `FRWHOOP_MODEL_ROOT`/`FRWHOOP_MANIFEST` (already pinned) or the manifest
   check results, and withholds its own outputs when its artifact is missing; it must not raise
   process readiness failures for an optional artifact. A missing optional artifact then appears in
   `revision.json` `withheld` and in `/healthz` `artifacts[]` as `missing`, and nothing else changes.
4. Implement `loaded_identity()` on the provider returning `{name: sha256}` of the bytes it loaded
   (bounded: 32 keys, 200 chars per value) so `/healthz` reports them per provider.
5. A worker lane that loads its own checkpoint reports it in `LaneSnapshot.identity` (string map).
6. Making an artifact required is a deliberate manifest change (`required_for_readiness: true` on
   the entry): from then on a revision without it is rejected and the previous one stays selected.
7. New Swift package dependencies of the worker are picked up by `package_release.py` from the
   `Package.swift` files; a test that reads a repository file by path outside the closure must be
   added to its fixture list (`test_fixture_paths`), or the packaged `swift test` fails.

## Linux release build

(filled in below)

## Requests to parent

1. **Runtime area (`execution.py`, `server.py`): report what the warm worker loaded.** In the infer
   worker's hello (`execution.py`, next to `readiness = jobs.warm(...)`), add
   `"loaded": {pid: provider.loaded_identity()}` for providers that implement it (exceptions caught,
   values stringified), and in `InferenceServer._on_infer_hello` set
   `self.app.worker_loaded_identity = hello.get("loaded") or {}`. `identity.py` already prefers it
   (`loaded_source: "worker"`). Without it, `/healthz` `providers[].loaded` reflects the HTTP
   process's unloaded provider copies.
2. **Providers / sensor biomarkers: implement `loaded_identity()`** where a checkpoint is loaded
   (SleepECG: the two verified digests; ParaDigMa: `artifact_state()`'s `{asset: sha256}`; rhythm:
   DeepBeat/SiamAF digests when loaded). Not done here: those files belong to other areas.
3. **Shared README "Runtime identity"**: mention `providers[].loaded_source` and
   `worker_loaded_identity` (additive).
