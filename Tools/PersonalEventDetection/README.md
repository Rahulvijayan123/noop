# Personal event detection worker

This directory contains the two VPS worker lanes for account-owned event detection. It is disabled by default. No deployment is performed by this PR. See [the maintainer handoff](../../docs/PERSONAL_EVENT_DETECTION.md).

Install with Python 3.12 in a separate virtual environment:

```sh
python3.12 -m venv .venv
.venv/bin/pip install '.[matrix]'
```

The base package supports statistical features and the scikit-learn heads. The `matrix` extra adds CPU neural heads, MiniRocket, catch24, XGBoost and CatBoost. NormWear and NormWear-2 also require approved local checkpoints and their upstream runtime dependencies. There are no automatic model downloads, random pretrained substitutes, or remote code downloads.

`NARA_EVENT_ENCODERS` is an optional path to a maintainer-owned JSON file. Each frozen encoder key (`normwear`, `normwear2`) has `source` (where needed), `checkpoint`, and `provenance_sha256`. The digest is SHA-256 of the sorted JSON `FrozenEncoder.provenance` object. Pin and review those local source/weight files before use. A missing or changed checkpoint causes its candidates to be skipped with a recorded reason.

Set these values in a private worker environment file:

```text
NARA_EVENT_DETECTION_ENABLED=1
NARA_EVENT_DATABASE_URL=<private Postgres connection with TLS verification>
NARA_EVENT_CACHE=/var/lib/nara-events
NARA_EVENT_ENCODERS=/etc/frwhoop/event-encoders.json
OMP_NUM_THREADS=1
OPENBLAS_NUM_THREADS=1
```

Run each lane in a separate supervised process:

```sh
nara-event-worker --lane train
nara-event-worker --lane infer
```

`--once` claims at most one due job for local validation. Importing this package, applying the migration, or installing the app does not start either lane. The prepared systemd templates are not enabled by any existing deployment script.

## Data and selection

- Identity is `(owner, event type UUID)`. Names are metadata. Occurrences have separate UUIDs.
- A model selects one wearable source based on completed, source-bound examples. It does not pool different owners or straps.
- Windows use 32 seconds of uploaded heart rate and raw strap temperature, with two 16-second steps and an 8-second stride. Raw temperature is explicitly in strap units. No conversion into degrees is claimed.
- Unknown intervals are not negative examples. Users add negative intervals in detector details or reject a detection. Archived manual labels are excluded. Confirmed detections produce retained manual revisions; possible detections do not train the model.
- Training/selection/test are split by UTC day with purges around boundaries and whole crossing episodes removed. At least five reviewed days are required. Every evaluation gate also requires three complete events and one hour of observed reviewed negative exposure. These configurable research defaults are not clinical validation.
- All 25 input combinations and 18 heads are registered. Every cell receives an evaluated, skipped, or failed record. Each candidate runs in a separate process with a three-minute limit. Runs have a three-hour budget and resume completed cells from a cache. Frozen features and fitted training encoders are reused for the same data and version.
- A common policy scores candidates in event units. User time saved is `(20 - 2) × unique detected events - 10 × false alerts`, normalized by observed reviewed days. These action-time assumptions are estimates. Scores are not presented as calibrated confidence.
- Promotion needs useful later held-out results and improvement over the existing model. Previously used protected test time is excluded from later promotion tests. No winner means no automatic detector. Models are not replaced merely because a week passed.
- Artifacts and model reports are private database rows; only server code can read executable model artifacts. Model loading is only from these trusted server-generated rows, never an upload endpoint.
- Training is bounded to 90 days and one million rows per sensor. Jobs that need a larger budget stop with a reason, rather than silently sample or drop records.
- New upload inserts invalidate device-days. Inference replays each changed day causally and retains episode IDs across repeated runs, late uploads and model changes. Existing reviewed episodes retain their review. Historical detections are labelled; there is no push-notification sender in this feature.
- UI switches increment a settings revision. Both job claims and result commits check it. Archiving a type stops its jobs. Account deletion cascades database rows, including artifacts; cache cleanup is described in the handoff.

## Local validation

```sh
PYTHONPATH=. python -m unittest discover -s tests -v
```

Database tests require the explicit `NARA_EVENT_TEST_DSN` pointing to localhost. Create a **disposable** PostgreSQL database; apply `tests/database_fixture.sql`, then migrations `20261008090000_manual_events.sql` and `20261009090000_personal_event_detection.sql`. Never apply the fixture to Supabase. The fixture provides the existing table interfaces needed by these tests; the full Supabase test environment is a separate integration check.

```sh
NARA_EVENT_TEST_DSN=postgresql://127.0.0.1:55439/nara_personal_test \
  PYTHONPATH=. python -m unittest discover -s tests -v
```

The synthetic tests prove pipeline behavior, persistence and isolation. They do not establish real-user detection accuracy or VPS capacity.
