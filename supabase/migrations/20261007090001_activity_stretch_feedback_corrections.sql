-- Extend the stretch-feedback correction vocabulary to the activity ontology's finer classes
-- (spec 9.1): brisk_walking, stairs, desk_work, typing and fidgeting join the existing twelve.
--
-- The original table (20261004171000) declared the corrected_label CHECK inline on the column, so
-- it carries an auto-generated name that cannot be referenced statically. This additive migration
-- finds that check in a DO block (the only table check whose definition contains a
-- `corrected_label = ANY (...)` list; the verdict-coupling check is excluded) and drops it, then
-- adds a named constraint with the extended vocabulary. Idempotent: re-running it drops the named
-- constraint it added and re-creates it.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $$
declare
  v_name text;
begin
  select conname into v_name
  from pg_constraint
  where conrelid = 'public.activity_stretch_feedback'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%corrected_label = ANY%';
  if v_name is not null then
    execute format('alter table public.activity_stretch_feedback drop constraint %I', v_name);
  end if;
end;
$$;

alter table public.activity_stretch_feedback
  add constraint activity_stretch_feedback_corrected_label_check
  check (corrected_label is null or corrected_label in (
    'sitting', 'standing', 'lying_down', 'asleep', 'walking', 'brisk_walking', 'running', 'stairs',
    'cycling', 'in_vehicle', 'desk_work', 'typing', 'fidgeting', 'exercise', 'other_movement',
    'not_wearing', 'other'));

comment on constraint activity_stretch_feedback_corrected_label_check
  on public.activity_stretch_feedback is
  'Accepted corrected_label vocabulary; extended by 20261007090001 with brisk_walking, stairs, desk_work, typing and fidgeting (spec 9.1).';

commit;
