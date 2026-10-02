# frwhoop-worker operations runbook

Live deployment: droplet `frwhoop-worker-2` (sfo3, 4 vCPU/8 GB, 143.198.62.4),
systemd unit `frwhoop-worker.service`, runs as user `frwhoop`, code at
`/opt/noop` (this repository's `Tools/CloudWorker`, `contracts` and `deploy`; the deployed revision
is in `FRWHOOP_SOURCE_REVISION`), private SQLite at `/opt/sqlite`,
secrets in `/etc/frwhoop/worker.env` (0600, root-owned).

Production runs with the projection lane off
(`/etc/systemd/system/frwhoop-worker.service.d/no-projection-replay.conf`). See
[docs/BACKEND.md](../docs/BACKEND.md) for why, and for the health-check queries.

## Queue contracts the worker drains

| Lane | Queue | Claim -> Publish |
| --- | --- | --- |
| projection | `noop_projection_debt` | `noop_claim_projection_debt` -> download + verify + `noop_commit_push_projection` (server re-verify first when `sha256_source != 'server_verified'`) |
| scoring (fleet) | `physiology_work_items` | `scoring_legacy_claim_one` -> REPEATABLE READ tx: load inputs -> `scoring_legacy_seal_snapshot` -> `engine_publish_legacy_fenced` -> `scoring_legacy_finish_work` |
| scoring v2 | `scoring_jobs_v2` | `claim_scoring_v2` -> `publish_scoring_snapshot_v2` |
| archive (v2) | `scoring_archive_jobs_v2` | `claim_scoring_archive_v2` -> B2 upload -> `complete_scoring_archive_v2` |
| archive (legacy) | `physiology_archive_outbox` | leased row -> zstd + B2 upload -> derived manifest insert |
| heartbeat | `scoring_service_heartbeats` | upsert every 15 s |

## Monitoring

```bash
systemctl status frwhoop-worker
journalctl -u frwhoop-worker -f          # lane errors print inline
psql "$FRWHOOP_DB_URL" -c "select * from scoring_service_heartbeats;"
psql "$FRWHOOP_DB_URL" -c "select state,count(*) from noop_projection_debt group by 1;"
psql "$FRWHOOP_DB_URL" -c "select status,count(*) from scoring_work_items group by 1;"
psql "$FRWHOOP_DB_URL" -c "select count(*) from scoring_snapshots_v2;"
psql "$FRWHOOP_DB_URL" -c "select status,count(*) from physiology_archive_outbox group by 1;"
```

## Known bounded residuals (DB design, not worker defects)

- ~285 projection-debt rows are replay duplicates from a legacy re-index path
  (NULL `batch_id`): `noop_commit_push_projection` structurally rejects them;
  the worker records bounded hourly failures exactly like the deployed worker did.
- ~63 rows are research archive kinds (`physiology`, `frames`, `imu_raw`):
  no projection target exists; bounded failures.
- Data already projected is never double-counted (upsert by natural key).

## Failure recovery

- Kill/restart at any time: every claim is a leased transaction; leases expire
  (2-10 min) and redeliver. SIGTERM finishes the current claim then exits.
- Worker state is disposable: inputs live in verified B2 objects + Postgres.
- Rollback: `git checkout <sha> && swift build -c release ... && systemctl restart frwhoop-worker`.

## Physiology inference sidecar (loopback only)

Second service on the same Droplet: `frwhoop-inference.service`, user
`frwhoop-inf`, config `/etc/frwhoop/inference.env`, code `/opt/frwhoop-inference`
(pinned venv), model cache `/opt/frwhoop-models/current` (read-only to the service
user). It binds `127.0.0.1` only and opens no public port, so no Cloud Firewall or
ufw rule is required. The worker keeps scoring when the sidecar is down.

```bash
systemctl status frwhoop-inference
journalctl -u frwhoop-inference -f
curl -s http://127.0.0.1:8787/healthz | head      # readiness + per-provider status
curl -s http://127.0.0.1:8787/v1/providers | head # capability manifest
ss -ltnp | grep 8787                              # must show 127.0.0.1, never 0.0.0.0
systemctl show frwhoop-inference -p MemoryCurrent -p MemoryPeak
```

The worker reports sidecar readiness and candidate counters in the EXISTING
heartbeat payload (`scoring_service_heartbeats.meta -> inference`), so no new
monitoring surface is needed:

```bash
psql "$FRWHOOP_DB_URL" -c "select meta->'inference' from scoring_service_heartbeats where id = 1;"
psql "$FRWHOOP_DB_URL" -c "select meta->'lanes' from scoring_service_heartbeats where id = 1;"
```

### Failure mapping (candidate lane)

Every sidecar failure settles as a WITHHELD candidate with a machine-readable
reason and never blocks the canonical publish:

| Condition | Withheld reason | Retried in the same drain |
| --- | --- | --- |
| connection refused / unreachable | `provider_error` | once (max 2 attempts) |
| deadline elapsed (`FRWHOOP_INFERENCE_TIMEOUT_MS`) | `timeout` | once (max 2 attempts) |
| HTTP 503 (provider not ready) | `not_ready` | once (max 2 attempts) |
| any other non-200 | `provider_error` | no |
| undecodable / invalid body | `provider_error` | no |

Candidate skips are counted in the heartbeat: `skipped_stale_debt` (new input
arrived after the claim was sealed), `skipped_deleted_user`, `skipped_no_input`,
`skipped_budget`, and `skipped_off` (metric mode is `off`).

### Rollback

1. Disable the candidate lane without touching the sidecar: comment out
   `FRWHOOP_INFERENCE_URL` in `/etc/frwhoop/worker.env`, then
   `systemctl restart frwhoop-worker`. Scoring returns to the legacy path exactly.
2. Set the affected metric back to `off` in `physiology_provider_defaults` — the
   worker stops computing candidates for it on the next drain.
3. Stop the sidecar: `systemctl disable --now frwhoop-inference`. The worker keeps
   running; candidates settle as withheld `provider_error`.
4. Roll the model cache back by repointing `current`:
   `ln -sfn /opt/frwhoop-models/revisions/<previous> /opt/frwhoop-models/current`.
