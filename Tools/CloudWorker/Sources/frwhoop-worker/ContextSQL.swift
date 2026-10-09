import Foundation
import WhoopProtocol

/// Every SQL statement the physiology-context lane runs, in one place (the pattern of `PhysiologyCandidateSQL`).
///
/// Rules the statements follow:
///  - Parameters are text and cast in SQL (`$1::uuid`); a SQL NULL comes back as "" and an optional parameter
///    is sent as "" and turned into NULL with `nullif`.
///  - Every raw-stream read is scoped by `user_id` AND `device_id`, bounded by the read window, and ORDERED BY
///    the table's full identity, so two loads of the same rows produce the same arrays (determinism).
///  - Availability is `ceil(extract(epoch from ingested_at))`: the first whole second at which the row is
///    known to have been stored. Rounding up keeps a causal cutoff conservative (a row ingested at 100.4 s is not
///    treated as available to a decision taken at 100 s).
///  - The lane only reads raw streams, published products and its own tables, and only writes through the
///    fenced `*_physiology_context_v1` RPCs. Nothing here writes a `noop_*`, `sessions`, scoring or series
///    table, or calls `scoring_dirty_span` / `enqueue_scoring_v2`.
enum ContextSQL {

    // MARK: - Presence guard (deploy order: the worker may run before the migration)

    /// Whether the lane's queue and RPCs exist. The heartbeat's queue-age entry and the lane both use it.
    static let tablesPresent = """
        select (to_regclass('public.physiology_context_jobs') is not null
                and to_regclass('public.physiology_context_days') is not null
                and to_regprocedure('public.claim_physiology_context_v1(text,integer)') is not null
                and to_regprocedure('public.publish_physiology_context_v1(uuid,bigint,jsonb)') is not null)::text
               as present
        """

    // MARK: - Queue RPCs (contracts §6)

    static let enqueue = "select public.enqueue_physiology_context_days_v1($1::integer)::text"

    /// The claim (`claim_physiology_context_v1(p_worker, p_lease_seconds)`), plus the database clock at the
    /// claim (the job's causal cutoff and `generatedAt`). The clock is the database's so it is on the same
    /// timeline as `ingested_at`. `day_start`/`day_end` are the queue's own local-day bounds (checked against the
    /// worker's).
    static let claim = """
        select c.user_id::text as user_id, c.device_id::text as device_id, c.day::text as day,
               c.mode::text as mode, c.input_revision::text as input_revision,
               c.lease_token::text as lease_token, coalesce(c.timezone_id::text, '') as timezone_id,
               coalesce(c.day_start::text, '') as day_start, coalesce(c.day_end::text, '') as day_end,
               coalesce(c.cutoff_override::text, '') as cutoff_override,
               coalesce(array_to_string(c.reasons, ','), '') as reasons,
               floor(extract(epoch from clock_timestamp()))::bigint::text as claimed_at
          from public.claim_physiology_context_v1($1::text, $2::integer) c
        """

    static let renew = "select public.renew_physiology_context_v1($1::uuid, $2::integer)::text"
    /// Returns `{status: failed|released|lease_lost|lease_expired, ...}`.
    static let fail = "select public.fail_physiology_context_v1($1::uuid, $2::bigint, $3::text)::text"
    /// Returns `{applied, context_revision, reason: published|unchanged|lease_lost|lease_expired|stale_revision|
    /// owner_retired, cascaded_days, ...}`; a malformed payload raises 22023 `invalid_physiology_context_*`.
    static let publish = "select public.publish_physiology_context_v1($1::uuid, $2::bigint, $3::jsonb)::text"

    /// Heartbeat queue-age entry (appended only when `tablesPresent`; a static reference to a missing table fails
    /// the whole heartbeat query at parse time). Same gates as the claim.
    static let queueAgeEntry = """
          union all
          select 'context', count(*), min(j.not_before)
            from public.physiology_context_jobs j
           where j.completed_revision < j.input_revision and not j.dead_letter
             and j.not_before <= now() and (j.lease_until is null or j.lease_until <= now())
        """

    // MARK: - Raw streams over the read window [$3, $4)

    static let heartRate = """
        select ts::text as ts, bpm::text as bpm,
               ceil(extract(epoch from ingested_at))::bigint::text as at
          from public.noop_hr_samples
         where user_id = $1::uuid and device_id = $2::uuid and ts >= $3::bigint and ts < $4::bigint
         order by ts
        """

    /// Same exclusions as scoring (`DayScorer.loadRR`): the Oura SpO2 beat train and rows whose timestamp the
    /// receiver flagged. Transport selection (`DayScorer.oneTransportPerHour`) runs in Swift afterwards.
    static let beatIntervals = """
        select ts::text as ts, "rrMs"::text as rr, seq::text as seq, coalesce(ord::text, '') as ord,
               coalesce("srcChannel"::text, '') as ch,
               ceil(extract(epoch from ingested_at))::bigint::text as at
          from public.noop_rr_intervals
         where user_id = $1::uuid and device_id = $2::uuid and ts >= $3::bigint and ts < $4::bigint
           and ("srcChannel" is null or "srcChannel" <> \(RRSourceChannel.spo2Ibi.rawValue))
           and ("tsSuspect" is null or "tsSuspect" <> 1)
         order by ts, seq, "rrMs"
        """

    static let gravity = """
        select ts::text as ts, x::text as x, y::text as y, z::text as z,
               coalesce("dynAccel"::text, '') as dyn,
               ceil(extract(epoch from ingested_at))::bigint::text as at
          from public.noop_gravity_samples
         where user_id = $1::uuid and device_id = $2::uuid and ts >= $3::bigint and ts < $4::bigint
         order by ts
        """

    static let steps = """
        select ts::text as ts, counter::text as counter, coalesce("activityClass"::text, '') as ac,
               ceil(extract(epoch from ingested_at))::bigint::text as at
          from public.noop_step_samples
         where user_id = $1::uuid and device_id = $2::uuid and ts >= $3::bigint and ts < $4::bigint
         order by ts
        """

    static let skinTemperature = """
        select ts::text as ts, raw::text as raw,
               ceil(extract(epoch from ingested_at))::bigint::text as at
          from public.noop_skin_temp_samples
         where user_id = $1::uuid and device_id = $2::uuid and ts >= $3::bigint and ts < $4::bigint
         order by ts
        """

    static let wearEvents = """
        select ts::text as ts, kind,
               ceil(extract(epoch from ingested_at))::bigint::text as at
          from public.noop_events
         where user_id = $1::uuid and device_id = $2::uuid and ts >= $3::bigint and ts < $4::bigint
           and (left(kind, 9) = 'WRIST_OFF' or left(kind, 8) = 'WRIST_ON')
         order by ts, kind
        """

    static let bandSleepState = """
        select ts::text as ts, state::text as state,
               ceil(extract(epoch from ingested_at))::bigint::text as at
          from public.noop_sleep_state_samples
         where user_id = $1::uuid and device_id = $2::uuid and ts >= $3::bigint and ts < $4::bigint
         order by ts
        """

    // MARK: - Published products

    /// The latest snapshot of the day published by `$5` (unix seconds; `cutoff`). A causal replay passes its
    /// cutoff so a snapshot published after it is never read; a retrospective or live job passes the claim time.
    static let latestSnapshot = """
        select s.result_revision::text as result_revision, s.input_revision::text as input_revision,
               ceil(extract(epoch from s.computed_at))::bigint::text as at, s.payload::text as payload
          from public.scoring_snapshots_v2 s
         where s.user_id = $1::uuid and s.device_id = $2::uuid and s.day = $3::date
           and s.algorithm_version = $4::text and s.computed_at <= to_timestamp($5::bigint)
         order by s.result_revision desc
         limit 1
        """

    /// The sleep sessions (with `dataThrough` and `timezone`) of the newest snapshot of each OTHER day in `[$3, $4]`
    /// published by `$6`, `$7` excluded
    /// (it is read in full above). The newest revision per day is picked from the read index first, so only those
    /// payloads are read (a busy day holds hundreds of revisions; the pattern of `ActivityLane.loadPublishedNights`).
    static let snapshotSleepRange = """
        with newest as (
          select s.day, max(s.result_revision) as rr
            from public.scoring_snapshots_v2 s
           where s.user_id = $1::uuid and s.device_id = $2::uuid and s.day >= $3::date and s.day <= $4::date
             and s.day <> $7::date and s.algorithm_version = $5::text and s.computed_at <= to_timestamp($6::bigint)
           group by s.day
        )
        select snap.day::text as day, snap.result_revision::text as result_revision,
               ceil(extract(epoch from snap.computed_at))::bigint::text as at,
               case when jsonb_typeof(snap.payload -> 'sleep') = 'array' then (snap.payload -> 'sleep')::text
                    else '[]' end as sleep,
               coalesce(snap.payload ->> 'dataThrough', '') as data_through,
               coalesce(snap.payload ->> 'timezone', '') as timezone
          from newest join public.scoring_snapshots_v2 snap on snap.result_revision = newest.rr
         order by snap.day
        """

    /// Logged and detected workouts of this device overlapping the read window. Availability is the last write.
    static let workouts = """
        select id::text as id, kind, extract(epoch from start_at)::bigint::text as s,
               extract(epoch from end_at)::bigint::text as e,
               coalesce(summary ->> 'type', summary ->> 'kind', '') as label,
               ceil(extract(epoch from greatest(created_at, updated_at)))::bigint::text as at
          from public.sessions
         where user_id = $1::uuid and device_id = $2::uuid and kind in ('workout', 'manual_workout')
           and start_at < to_timestamp($4::bigint) and end_at > to_timestamp($3::bigint)
         order by start_at, end_at, id
        """

    /// v1 HART epochs overlapping the read window, from ONE revision per UTC epoch day: the newest published
    /// revision of each day (`$5`…`$6`), or in a causal job (`$7` = cutoff, unix seconds) the newest one published
    /// at or before the cutoff — what a reader at the cutoff would have read. Older lineages are never merged in:
    /// the publish keeps every fingerprint's rows, and an older lineage would fill seconds the newest one dropped
    /// (D3-02). This is per UTC day, never one revision across the whole read window (each day is its own publish).
    /// The per-day probe walks `activity_context_epochs_day_revision_rows` (20261008100100) when it exists; without
    /// that index the query is still correct, only slower. Reading one revision instead of every lineage removes
    /// the ~85x row amplification measured in production.
    static let activityEpochs = """
        with days as (
          select g::date as day from generate_series($5::date, $6::date, interval '1 day') g
        ), latest as (
          select days.day,
                 (select e.result_revision from public.activity_context_epochs e
                   where e.user_id = $1::uuid and e.device_id = $2::uuid and e.day = days.day
                     and (nullif($7, '') is null or e.computed_at <= to_timestamp(nullif($7, '')::bigint))
                   order by e.result_revision desc limit 1) as rr
            from days
        )
        select e.start_ts::text as s, e.end_ts::text as e, e.motion_label, e.posture, e.exercise_session,
               e.sleep_state, e.exertion_context, e.wear_state, coalesce(e.wear_signal, '') as wear_signal,
               e.confidence::text as confidence, e.observed_s::text as observed_s, e.valid_s::text as valid_s,
               e.model_version, e.preprocessing_version, e.result_revision::text as revision,
               ceil(extract(epoch from e.computed_at))::bigint::text as at
          from latest l
          join public.activity_context_epochs e on e.day = l.day and e.result_revision = l.rr
         where user_id = $1::uuid and device_id = $2::uuid and e.start_ts < $4::bigint and e.end_ts > $3::bigint
         order by e.start_ts, e.result_revision, e.fingerprint
        """

    /// The ONE v2 decoder document per UTC day `$5`…`$6` the lane reads (D5-04), ranked:
    ///  1. decoded by the worker's current decoder (`$7`, `ActivityContextVersions.decoder`) before another one;
    ///  2. the newer decoder (`hsmm-X.Y` compared numerically, so 1.10 is after 1.9; unparseable last), so an
    ///     older-decoder document never wins on a few seconds of `data_through` when neither is current;
    ///  3. data through later (a document rebuilt from newer uploads first; unknown last);
    ///  4. raw-IMU (HART, `source_rank` 1) before measurement-stream documents;
    ///  5. computed later, then the higher result revision.
    /// `says_in_bed`: the document's runs carry `in_bed` (written only when true, by decoder hsmm-1.3 and later,
    /// ccd5f0dca). On an older document a run without it is "not said", never "not in bed".
    /// A causal job (`$8` = cutoff) ranks only documents computed at or before its cutoff (documents are updated
    /// in place, so a later one never stands in for what the decision could see). Runs and transition events are
    /// read from the same chosen document, so they never disagree.
    static let chosenActivityDocuments = """
        with chosen as (
          select distinct on (d.day) d.day, d.algorithm_version, d.decoder_version, d.result_revision,
                 d.computed_at, d.document,
                 (coalesce((regexp_match(d.decoder_version, '^hsmm-([0-9]+)[.]([0-9]+)$'))::int[] >= array[1, 3],
                           false)
                  or jsonb_path_exists(d.document, '$.runs[*].in_bed')) as says_in_bed
            from public.activity_context_days d
           where d.user_id = $1::uuid and d.device_id = $2::uuid and d.day >= $5::date and d.day <= $6::date
             and (nullif($8, '') is null or d.computed_at <= to_timestamp(nullif($8, '')::bigint))
           order by d.day, (d.decoder_version = $7::text) desc,
                    (regexp_match(d.decoder_version, '^hsmm-([0-9]+)[.]([0-9]+)$'))::int[] desc nulls last,
                    d.data_through desc nulls last,
                    (case d.algorithm_version when 'hart-activity-1' then 1 else 2 end),
                    d.computed_at desc, d.result_revision desc
        )
        """

    /// v2 decoder runs overlapping the read window `[$3, $4)`, from the chosen document of each UTC day.
    static let activityRuns = chosenActivityDocuments + """
        select (r.value ->> 's')::bigint::text as s, (r.value ->> 'e')::bigint::text as e,
               coalesce(r.value ->> 'activity_class', 'unknown') as class,
               coalesce((r.value ->> 'class_confidence')::real, (r.value ->> 'overall_confidence')::real, 0)::text
                 as confidence,
               coalesce(r.value ->> 'sleep', '') as sleep, coalesce(r.value ->> 'wear', '') as wear,
               case when c.says_in_bed then coalesce(r.value ->> 'in_bed', 'false') else '' end as in_bed,
               case when r.value ->> 'activity_detail' = 'in_vehicle'
                      or coalesce(case when jsonb_typeof(r.value -> 'locomotion') = 'object'
                                       then (r.value -> 'locomotion' ->> 'vehicle_motion')::real end, 0) >= 0.5
                    then 'vehicle_motion' else '' end as locomotion,
               c.algorithm_version, c.decoder_version, c.day::text as doc_day,
               c.result_revision::text as revision,
               ceil(extract(epoch from c.computed_at))::bigint::text as at
          from chosen c
         cross join lateral jsonb_array_elements(case when jsonb_typeof(c.document -> 'runs') = 'array'
                                                      then c.document -> 'runs' else '[]'::jsonb end) as r(value)
         where (r.value ->> 's')::bigint < $4::bigint and (r.value ->> 'e')::bigint > $3::bigint
         order by (r.value ->> 's')::bigint, (r.value ->> 'e')::bigint, c.result_revision
        """

    /// Decoder transition events (`document.events`) flagged in the read window `[$3, $4)`, from the same chosen
    /// document of each UTC day as `activityRuns` (the `activity_context_transitions` view reads every document).
    /// `onset_ts` (the decoder's causal back-date) and `source` are "" on documents decoded before they existed.
    static let activityTransitions = chosenActivityDocuments + """
        select (x.value ->> 'ts')::bigint::text as ts, coalesce(x.value ->> 'kind', '') as kind,
               coalesce(x.value ->> 'probability', '') as probability,
               coalesce(x.value ->> 'onset_ts', '') as onset_ts, coalesce(x.value ->> 'source', '') as source,
               c.algorithm_version, c.decoder_version, c.result_revision::text as revision,
               ceil(extract(epoch from c.computed_at))::bigint::text as at
          from chosen c
         cross join lateral jsonb_array_elements(case when jsonb_typeof(c.document -> 'events') = 'array'
                                                      then c.document -> 'events' else '[]'::jsonb end) as x(value)
         where (x.value ->> 'ts')::bigint >= $3::bigint and (x.value ->> 'ts')::bigint < $4::bigint
         order by (x.value ->> 'ts')::bigint, coalesce(x.value ->> 'kind', ''), c.result_revision
        """

    /// Placement records in effect anywhere in the read window: the device's own and the owner's device-less
    /// (user-level) declarations. Nothing before the first record is invented.
    static let placements = """
        select extract(epoch from effective_start)::bigint::text as s,
               coalesce(extract(epoch from effective_end)::bigint::text, '') as e,
               placement, source, revision::text as revision,
               ceil(extract(epoch from recorded_at))::bigint::text as at,
               (device_id is null)::text as user_level
          from public.placement_intervals
         where owner = $1::uuid and (device_id = $2::uuid or device_id is null)
           and effective_start < to_timestamp($4::bigint)
           and (effective_end is null or effective_end > to_timestamp($3::bigint))
         order by effective_start, (device_id is null) desc, revision, recorded_at, id
        """

    static let device = """
        select coalesce(device_family, '') as family, coalesce(firmware, '') as firmware,
               coalesce(source_kind, '') as source_kind
          from public.devices
         where id = $1::uuid and user_id = $2::uuid
        """

    /// Same columns and defaults as `DayScorer.loadProfile`.
    static let profile = """
        select coalesce(height_cm::text, '') as h, coalesce(weight_kg::text, '') as w,
               coalesce(date_of_birth::text, '') as dob, coalesce(sex_model, 'nonbinary') as sex
          from public.profiles where id = $1::uuid
        """

    // MARK: - Exposures and history (contracts §6 tables)

    /// Every revision of the owner's exposure events whose occurrence overlaps `[$2, $3)` (unix seconds). All
    /// revisions are read: the engine picks the latest available one at the cutoff and keeps the history.
    static let exposureRevisions = """
        select r.event_id::text as event_id, r.revision::text as revision, r.kind, r.label,
               r.occurred_start::text as s, r.occurred_end::text as e, r.time_precision,
               r.recorded_at::text as recorded_at, r.received_at::text as received_at,
               r.source, r.confirmation,
               coalesce(r.dose_amount::text, '') as dose_amount, coalesce(r.dose_unit, '') as dose_unit,
               coalesce(r.dose_provenance, '') as dose_provenance
          from public.exposure_event_revisions r
         where r.owner = $1::uuid and r.occurred_start < $3::bigint and r.occurred_end > $2::bigint
         order by r.event_id, r.revision
        """

    /// Earlier days' daily values of the same device and mode, `[$4, $5]`, as the `DailyValue` JSON the worker
    /// published (`payload`). `$6` (unix seconds, or "" for none) is a causal cutoff: only values whose
    /// publication is at or before it are read (a replay never sees history published after its decision).
    static let historyDailyValues = """
        select v.payload::text as value
          from public.physiology_context_daily_values v
         where v.user_id = $1::uuid and v.device_id = $2::uuid and v.mode = $3::text
           and v.day >= $4::date and v.day <= $5::date
           and (nullif($6, '') is null or exists (
                 select 1 from public.physiology_context_days d
                  where d.context_revision = v.context_revision
                    and d.published_at <= to_timestamp(nullif($6, '')::bigint)))
         order by v.day, v.series_key collate "C", v.regime_key collate "C"
        """

    /// Earlier days' bouts of the same device and mode, `[$4, $5]` (`ExertionBout` JSON); `$6` as above.
    static let historyBouts = """
        select b.payload::text as bout
          from public.physiology_context_bouts b
         where b.user_id = $1::uuid and b.device_id = $2::uuid and b.mode = $3::text
           and b.day >= $4::date and b.day <= $5::date
           and (nullif($6, '') is null or exists (
                 select 1 from public.physiology_context_days d
                  where d.context_revision = b.context_revision
                    and d.published_at <= to_timestamp(nullif($6, '')::bigint)))
         order by b.day, b.start_ts, b.bout_id collate "C"
        """

    /// Telemetry for a causal job (reviews P5 / RC-18): how many history rows of the read ranges are NOT read
    /// because their current publication is after the cutoff (`$6`, unix seconds): daily values `[$4, $5]`, bouts
    /// `[$7, $5]`. History tables keep only the current version of a day, so after a later republish a replay
    /// cannot see the version the live decision saw; this counts what it lost (or what did not exist yet — the two
    /// cannot be told apart). Never in the document: it describes rows the decision could not have had.
    static let historyAfterCutoff = """
        select ((select count(*) from public.physiology_context_daily_values v
                  where v.user_id = $1::uuid and v.device_id = $2::uuid and v.mode = $3::text
                    and v.day >= $4::date and v.day <= $5::date
                    and not exists (select 1 from public.physiology_context_days d
                                     where d.context_revision = v.context_revision
                                       and d.published_at <= to_timestamp($6::bigint)))
              + (select count(*) from public.physiology_context_bouts b
                  where b.user_id = $1::uuid and b.device_id = $2::uuid and b.mode = $3::text
                    and b.day >= $7::date and b.day <= $5::date
                    and not exists (select 1 from public.physiology_context_days d
                                     where d.context_revision = b.context_revision
                                       and d.published_at <= to_timestamp($6::bigint))))::text as n
        """

    /// Every frozen reference registered for the device (`FrozenReference` JSON); `$3` as `$6` above, against
    /// the registration time. A retrospective job passes "" and so reads every registered reference.
    static let frozenReferences = """
        select f.payload::text as reference
          from public.physiology_context_frozen_references f
         where f.user_id = $1::uuid and f.device_id = $2::uuid
           and (nullif($3, '') is null or f.registered_at <= to_timestamp(nullif($3, '')::bigint))
         order by f.series_key collate "C", f.regime_key collate "C", f.version, f.reference_id collate "C"
        """
}
