-- The verification lane's arrival scan reads only the objects still waiting for a receipt.
--
-- WHY
-- VerificationLane.candidateSQL pages through raw, ready objects whose durability receipt is not
-- 'verified_indexed', oldest first. No index matches that filter or order, so every call scans
-- object_manifests in full. The lane makes two such calls a cycle (the cursor page, then the head page
-- after the cursor wraps), so on 10-09 these two statements had read about 1.75 billion blocks since
-- Postgres started on 09-30, about 82% of all block reads in the database, at up to 95 s a call. That
-- read load starves every other reader of the 2 GB instance (scoring, uploads, context lanes).
--
-- WHAT CHANGES
-- A partial index on created_at over exactly the rows that scan can return. It holds only objects
-- awaiting verification, so both pages become a short ordered index read.
--
-- The predicate must stay identical to candidateSQL's receipt, failure and class/status clauses, or the
-- planner cannot prove the query implies it and falls back to the full scan.
-- On a large table, build it first with CREATE INDEX CONCURRENTLY (outside a transaction) under the
-- same name; this statement is then a no-op. Undo: drop index concurrently
-- public.object_manifests_verify_pending_idx. No table or data changes.
create index if not exists object_manifests_verify_pending_idx
  on public.object_manifests (created_at)
  where object_class = 'raw'
    and status = 'ready'
    and (durability_receipt is null or durability_receipt->>'state' is distinct from 'verified_indexed')
    and verification_failure_code is null;
