# Personal event detection: implementation and cloud handoff

This PR replaces PR #3 and includes its logger, custom icons, favorites, duration presets, retained archive and account-owned sync. It adds detection settings, review feedback, real event timelines and physiology charts, and the personal model-selection service.

**No live cloud infrastructure was changed.** The migration, API and worker files are prepared for maintainer deployment. The app retains local choices and shows that cloud detection is not deployed when the route is unavailable.

## Rahul's deployment work

@Rahulvijayan123, please complete the cloud setup below before enabling automatic detection. The app and worker cannot use the new routes until this is done.

1. Review the current deployed `scores` function, source ownership tables, sensor schemas and VPS capacity against this branch. Preserve the existing upload, scoring and account contracts.
2. Back up the database and use the manual SQL migration procedure in [BACKEND.md](BACKEND.md). Apply the logger migration `20261008090000_manual_events.sql` if missing, then `20261009090000_personal_event_detection.sql` and `20261009100000_phenotype_signatures.sql`. Record applied versions with the repository's migration-repair procedure. **Do not run production `supabase db push`.**
3. Deploy the updated `scores` function. Test `/manual-events`, `/event-detection`, `/event-detection/physiology` and `/event-detection/signature` with two separate test accounts. Confirm another account cannot read events, reviews, charts or models.
4. Install the isolated Python runtime described in [the worker README](../Tools/PersonalEventDetection/README.md). Supply the database connection privately, with certificate verification. Confirm its role can read the owner-scoped sensor tables and write the new worker tables. Keep all service credentials off the app.
5. Review and supply the optional pinned encoder source/weights. Missing dependencies and checkpoints are recorded as skipped candidates. Do not treat them as tested model results.
6. Review CPU, RAM, disk and database load on the actual VPS. Use the two `.service.example` templates as starting limits. Keep the training service at low priority so it cannot consume all ingestion/scoring capacity. Prepare a private `/var/lib/nara-events` directory. Install the services only after these checks; no existing deploy script enables them.
7. Run fixture or test-account jobs first. Verify train → save → reload → infer → review, switch-off during an in-flight job, late uploads, repeated jobs, and model replacement. Measure actual upload-to-display delay. Then enable `NARA_EVENT_DETECTION_ENABLED=1` for the reviewed rollout.
8. Keep a prior model version for rollback. To roll back a label, stop/fence its inference job and atomically set its `active_model_id` to an earlier artifact for the **same owner and type**. Never copy a model between accounts. The app can disable the label while this is done.
9. Confirm the whole-account deletion path removes the new database rows through `auth.users` cascades and removes the owner's private cache directory through the worker's hourly cleanup. Event-level archive remains retained; it is separate from deleting an entire account.

## Signature phase (docs/PHENOTYPE_SIGNATURES.md)

The detector grid is replaced by the signature engine, and **no detection alerts are produced in this
phase**. The Events tab section is "Learn event signatures"; each type's toggle is "Learn this event's
signature" (the same `setting` command). The type's page (and "What Nara has learned about ..." on a
logged event's page) shows the signature card from `GET /scores/event-detection/signature?typeId=<uuid>`:
`{report, identity}`, where `report` is the newest `event_detector_runs.report` of the caller and type
with `version = 'signature-report-1'`, or null. The service role reads the runs table (owner and type
from the credential and query, rows filtered again in the route); clients keep no grant on it.
The card shows the status (Learning / Individual context / Emerging / Established / No reliable
signature yet, with the reason: too few days, not consistent or not replicated), the findings with their
change, interval and "7 of 8 events", the event-locked profile of the top channel (−30 to +30 min, mean
with its 95% range, onset marked), the evidence counts, data-quality notes and limitations, and whether
it is "Promising" or "Not reliable enough for alerts yet" (expected recall at 1 false alert a day), always
with "Alerts are off". `EventDetectionCenter` caches the report per owner. `--demo-screen eventsignature`
and `eventsignaturenone` show an emerging signature and one with none yet (sample data).

## App behavior

- Event categories use a permanent UUID; renames change the display label while retaining history, presets, settings and model ownership. Occurrences use separate IDs. Similar-event comparisons use type and owner IDs.
- Favorites and automatic detection are separate controls. A pending toggle shows “Waiting to sync”; it is not presented as server-confirmed. A disabled or archived type cannot publish a result from an older job revision.
- The main Events page shows logging controls, per-type detector status, a possible-event review queue, retained reviewed detections and a real timeline. Confirming a detection links a matching manual event instead of adding another occurrence.
- Reviews can confirm, reject, mark unsure, change type or adjust time. Event types and detector details also support explicitly reviewed negative time. Unlabelled time and unconfirmed model output are not training truth.
- HR, HRV and movement details use authenticated cloud data for the event's wearable. Phase means use observed support duration. Curves use the existing shape-preserving interpolation and retain missing-data gaps. HRV is shown at its measured window width, and movement is the existing `accel_rms_g` signal. No example recovery score is substituted for missing results.
- Cloud inference runs after data arrives. The app refreshes while the Events page is visible. This PR does not add push notifications or claim that the phone can detect an event while offline.

## Worker contracts

Weekly jobs select a personal detector by estimated user time saved, subject to event recall, false-alert, delay and resource gates. Each candidate is tested under the same causal alert policy for a label. Reports retain selection, later evaluation, costs, skips and dependencies. Current models remain active unless a new candidate passes the later-data comparison. No model is activated when there is insufficient evidence.

Jobs have leases, retries and settings-revision fences. Sensor upload and correction statements invalidate affected device-days. Ordinary uploads advance stored cursors; late data uses bounded replay. Publication checks the current input revision. Replays use durable detected-episode IDs and retain review state, including through a model swap. A delayed upload is historical; this code sends no stale live notifications.

Source-bound training currently uses the research suite's heart-rate and raw-temperature inputs. Movement is available in the UI from the separate existing activity lane. A future movement-trained personal candidate can be added explicitly to the versioned registry; it must not silently replace one of the research suite's input definitions.

## Validation record

See [the local validation record and sample screenshots](PERSONAL_EVENT_DETECTION_VALIDATION.md). Local fixture tests are distinct from a full Supabase deployment test, VPS capacity validation, and physical-phone review. None of those production checks is implied by a passing synthetic detector test.

The small `CoachChatViewModel.merge` expression is split into typed intermediate values to allow the current main branch to compile; its sort and merge behavior is unchanged.
