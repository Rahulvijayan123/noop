# Upstream contract pin — hosted Whoop-Nara Supabase

This directory is a **byte-identical pin** of the hosted Whoop-Nara (upstream) Supabase
contract that the fork's worker/phone talk to. It is evidence for the port: the exact
sources we must mirror, at one exact upstream revision.

## 1. Pinned revision

- **Revision (full SHA):** `9abbcf22fa5ea34febc548b835cdd60454991609`
- **Short:** `9abbcf22`
- **Pin date:** 2026-09-28 (commit timestamp `2026-09-28T12:15:03-07:00`)
- **Subject:** `Pack quarantined history into bounded uploads and hold history on capacity`
- **Source repo:** `/Volumes/External SSD/Nara Whoop App V2/Whoop-Nara` (branch tip at pin time)
- **Purpose:** freeze the hosted edge-function sources + the SQL migrations that define
  the RPCs we port, so the fork port can be diffed against a stable reference and the
  porting work is reproducible.

Verification of the pin (run from anywhere):

```sh
git -C '/Volumes/External SSD/Nara Whoop App V2/Whoop-Nara' rev-parse HEAD
# 9abbcf22fa5ea34febc548b835cdd60454991609
```

## 2. What is pinned

Under `supabase/`, preserving upstream relative paths:

1. **Edge-function contract sources** — `functions/_shared/*` and the four entrypoints
   the worker/phone talk to: `push`, `ingest-verify`, `reconcile`, `scores`.
   The `_shared` set is the **transitive local import closure** of those entrypoints plus
   `registry.ts`, and includes the contract-semantics modules the port must mirror:
   `registry.ts`, `structuredSync.ts`, `keys.ts`, `scalarProvenance.ts`,
   `appendProjection.ts`, `workerAuth.ts`, `intakeAdmission.ts`, `retention.ts`,
   `installationLifecycle.ts`, `serverScores.ts`, and (per port scope) `historyRecovery.ts`,
   `boundedRecovery.ts`, `serverScoring.ts`.
2. **`functions/DURABILITY_RECEIPT.md`** and **`functions/deno.lock`** — the receipt
   contract doc and the exact dependency lock the deployed functions use.
3. **`config.toml`** — supabase project config (functions/verify settings).
4. **`migrations/`** — a **bounded, justified subset** of the 147 migrations: the files
   that define (or last redefine) the pinned RPCs, plus the projection-target-table
   migrations and helper-function definitions those RPCs call. See `MIGRATIONS_INDEX.md`
   for the per-RPC mapping and selection rationale (49 files of 147).
5. **`functions/tests/`** — only the three unit tests that assert registry/projection
   mapping semantics: `registry_test.ts`, `append_projection_test.ts`,
   `auxiliary_identity_test.ts`. Identified-but-not-copied tests are listed in
   `MANIFEST.md` (they exercise the same mapping only indirectly and drag in the
   local-Postgres/S3 harness).

`MANIFEST.md` lists every copied file with `sha256`, git blob SHA at the pinned revision,
and byte size. `fetch.sh` re-creates the snapshot from any upstream revision.

## 3. What is deliberately NOT pinned, and why

- **The other 98 `migrations/*.sql`** — frwhoop base schema, settings/integrations, sleep
  storage, day-completeness, physiology calibration/revisions, RR measurement identity,
  fleet-scheduler internals beyond the listed RPCs, history-clock durability,
  bounded-recovery archive, and unrelated scoring support. We pin the **contract surface**,
  not the full schema history; the fork already has its own DB and only needs the RPC
  contract to mirror.
- **`supabase/history/*`** — pre-migration-rename history snapshots; superseded by the
  `migrations/` set.
- **`supabase/tests/*`** — SQL review fixtures for the whole repo, outside the pinned
  RPC surface.
- **The full `functions/tests/` harness** — only mapping-semantics unit tests are copied;
  integration tests that need a live local Postgres/S3 harness are excluded.
- **Everything outside `supabase/`** — iOS/Android/watch clients, docs, tools. The fork
  ports the server contract, not the whole upstream tree.

## 4. Reproducible fetch process

`contracts/upstream/fetch.sh` re-creates this snapshot from any upstream repo + revision.
It reads the path list embedded in the script (generated from `MANIFEST.md`) and writes
the files under the current directory, preserving `supabase/...` relative paths.

Manual, exact commands a future agent runs to re-create this snapshot from scratch:

```sh
UP='/Volumes/External SSD/Nara Whoop App V2/Whoop-Nara'
REV=9abbcf22fa5ea34febc548b835cdd60454991609
DEST='/Volumes/External SSD/Nara Whoop App V2/noop/contracts/upstream'

# 0. verify the pinned revision is present
git -C "$UP" cat-file -e "$REV^{commit}"

# 1. re-fetch every manifest path (paths are listed in MANIFEST.md / fetch.sh)
#    example for one file — the script loops over all of them:
git -C "$UP" show "$REV:supabase/functions/_shared/registry.ts" > "$DEST/supabase/functions/_shared/registry.ts"

# 2. verify byte-identity for every copied file
while read -r p; do
  git -C "$UP" show "$REV:$p" | diff -q - "$DEST/$p" || echo "MISMATCH $p"
done < <(git -C "$UP" ls-tree -r --name-only "$REV" | grep -F -f "$DEST/manifest-paths.txt")

# 3. verify hashes
shasum -a 256 "$DEST"/supabase/functions/_shared/*.ts "$DEST"/supabase/migrations/*.sql
```

The canonical path list is `contracts/upstream/manifest-paths.txt` (same order as
`MANIFEST.md`); `fetch.sh` uses exactly that list.

## 5. Deployed-vs-pinned edge-function revision skew (evidence)

The **deployed** edge functions were last updated **2026-09-21** (per the Supabase
management API). The pinned tip `9abbcf22` is dated **2026-09-28** — i.e. the pinned
sources are **newer** than the deployed edge functions, so the pinned TS is a
**superset** of what is deployed. The **live DB is the authority for the RPC contract**
(another agent diffs the deployed DB separately, see `contracts/deployed/`).

Evidence (recorded 2026-09-28):

```sh
git -C '/Volumes/External SSD/Nara Whoop App V2/Whoop-Nara' log --format='%h %ad %s' --date=short -8 -- supabase/functions/
# d5a1ee17 2026-09-27 fix(intake): classify recovery authority from structured errors
# 3435a188 2026-09-26 Add same-owner canonical selected score RPC with route parity proof
# 5722b7cf 2026-09-25 Index RR measurement identity lookup without changing projection semantics
# 1ccd289f 2026-09-24 Use indexed equality for validated append identity lookups
# b58c5cc9 2026-09-24 Make derived hold regression fixture self-contained
# 9ab89b4d 2026-09-24 Keep source-less derived outputs in retained identity hold
# 4f2e0527 2026-09-24 Preserve retained legacy device identity during enrollment sync
# 9f853e8b 2026-09-24 Compare retained observations with faithful nullable transport fixtures

git -C '/Volumes/External SSD/Nara Whoop App V2/Whoop-Nara' rev-list -1 --before=2026-09-22 HEAD
# 7c83261502fba7d61c038d8d8bcbb55e26ca049f

git -C '/Volumes/External SSD/Nara Whoop App V2/Whoop-Nara' show -s --format='%h %ad %s' --date=short 43cadf4d 7c832615
# 43cadf4d 2026-09-21 Prove canonical persisted mobile selection from actual Edge results
# 7c832615 2026-09-22 Merge branch 'feat/sensor-algorithms' into release/integration
```

The nearest edge-function revisions to the deploy date are **`43cadf4d` (2026-09-21)** and
**`7c832615` (2026-09-22)**. The pinned tip includes ~7 days of edge-function changes
after the last deploy.

### Correction to an earlier parent claim (protocol versions)

The pinned checkout documents **protocol 1.3/1.2/1.1/1.0**, not only 1.0/1.1. Evidence:

- `supabase/functions/_shared/registry.ts:12`
  `export const PUSH_PROTOCOL_VERSIONS = ['1.3', '1.2', '1.1', '1.0'];`
- `supabase/functions/push/index.ts:124`
  `return json({ type: 'error', protocolVersion: '1.2', code: 'unauthorized' }, err.status || 401);`
  — matches the live deployed unauthorized response (protocolVersion `1.2`).

## 6. Files in this directory

- `README.md` — this file.
- `MIGRATIONS_INDEX.md` — RPC -> defining migration(s) mapping with file:line.
- `MANIFEST.md` — every copied file: path, sha256, git blob SHA, byte size.
- `manifest-paths.txt` — newline-separated upstream paths (input to `fetch.sh`).
- `fetch.sh` — re-fetch script (POSIX sh).
- `supabase/...` — the pinned sources.
