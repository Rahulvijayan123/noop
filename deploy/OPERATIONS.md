# frwhoop-worker operations runbook

Live deployment: droplet `frwhoop-worker-2` (sfo3, 4 vCPU/8 GB, 143.198.62.4),
systemd unit `frwhoop-worker.service`, runs as user `frwhoop`, code at
`/opt/noop` (branch `cloud-worker`), private SQLite at `/opt/sqlite`,
secrets in `/etc/frwhoop/worker.env` (0600, root-owned).

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
