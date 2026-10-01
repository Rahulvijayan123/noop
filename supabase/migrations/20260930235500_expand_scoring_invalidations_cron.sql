-- Scoring claims skip any day inside a pending scoring_invalidations_v2 range, and nothing in the
-- deployment ever expanded those ranges: a profile save (or a history correction) queued a range over
-- the owner's whole history and scoring for that device then stopped until someone ran the expander
-- by hand. Run it every minute so a range is turned into dirty jobs almost immediately.
begin;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'frwhoop-expand-scoring-invalidations') then
    perform cron.unschedule('frwhoop-expand-scoring-invalidations');
  end if;
  perform cron.schedule('frwhoop-expand-scoring-invalidations', '* * * * *',
    'select public.expand_scoring_invalidations_v2(500)');
end $$;

commit;
