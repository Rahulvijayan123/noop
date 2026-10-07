# Watchdog / Layer 1 — 4 Oct leftover close-out

Plans in `docs/baselines/` and the 1 Oct log stay. Charge is not rewritten. The two Layer 1 usuals are never averaged. `t0` is never inferred from HR. A drug is never named. There is no on-device training. Watchdog `evaluate` never writes 7-day / 60-day snapshots.

This is the **single** 4 Oct note. Numbering is the original 1 Oct list (1–12). Do not create a second 4 Oct file. Leftover walks and patches for today live here. Phone bugs after leftovers, G1–G9, graph paint, and the physiology page are at **After-bug closeout** at the end. Do not copy those onto `RAHUL_HANDOFF.md`.

Walk each leftover the same four ways:

1. What we understand the request to mean
2. Evidence that this failure exists (file, function, why it happens)
3. How we will implement it
4. Why that is a full fix, and what it must not hinder

---

## Original list (status on 4 Oct)

| # | Original request | 4 Oct |
|---|---|---|
| 1 | Fix HRV units. Transform once and rebuild any affected saved records. | Closed Friday. Re-audited 4 Oct — no leftover engine work. |
| 2 | Fix sample counting. Fixed minute buckets and measurement identities. | Leftover patched today, then wrap-up closed the last wall-clock leak (band / sessionAbs / tape active minutes). |
| 3 | Share context and learning gates. Sleep ≠ awake-rest; learn off / detect on; yesterday only in overlapping sleep. | Leftover (yesterday leak + tape/IMU during confound/alert) — patched today. |
| 4 | Initialize each metric independently. Own seed, count, readiness, anchor. Missing temp must not start at 0 or inherit HR ready. | Leftover (corridor + sidecar blend from 0) — patched today. |
| 5 | Correct readiness and staleness. Eligible observations; context-matched history; illness must not refresh last OK. | Leftover (habit lastOK + week lastUpdate) — patched today. |
| 6 | Keep an independent personal-change check. Hat-follow must not hide a Layer 1 off. Hold adaptation. | Leftover (7-day walk + note-only) — patched today. |
| 7 | Make high/low checks independent of the model window. | Leftover (minute mean / HRV filter / duration reset) — patched today. |
| 8 | Fix episode transitions and notifications. | Leftover (tick persist / quiet-on-unavailable / escalate cooldown) — patched today. |
| 9 | Make the displayed bands and confidence consistent. | Leftover (row Off from painted band ≠ engine) — patched today. |
| 10 | Correct the model integration. Students not “official.” Convert deferred. | Student UniTS I/O + mask + horizon match shipped. TimesFM remains a student. Official convert still deferred. Names and tick wiring: evening **Reference** (student models). |
| 11 | Finish source isolation. | Walked and patched today. |
| 12 | Persist episodes and delivery status properly. | Walked and patched today. |
| Add-on | Event recovery (F04), symptom feedback (F08), clinician export (F09). | **Shipped** as sidecars (engine + UI + pins). |

---

# Send packet — what is implemented (4 Oct night)

This section is for handing the log to Rahul. Everything that was **this week’s planned work** is in the first table. Items below that were **never** this week’s ship list.

## Planned this week — implemented

| Item | Where | Proof |
|---|---|---|
| Leftovers **1–9, 11–12** | Engine + V40 | `WatchdogV40CloseoutTests` (38) green |
| Leftover **10** student path | UniTS I/O, mask, 5-min horizon, student names | Students labeled `units-ad-coreml-v3` / `timesfm3-student-v3`. **Official Harvard convert is not a leftover to finish** — it cannot ship on device (see leftover 10). |
| **F04** event recovery | `WatchdogEventRecovery.swift`, `BaselineStore`, live card line | Pins `testEventRecovery*`; UI on Watchdog card |
| **F08** episode note | `WatchdogEpisodeAnnotation.swift`, `WatchdogEpisodeNoteSheet` | Pins `testAnnotation*`; sheet after **sent** page only |
| **F09** clinician pack | `WatchdogEpisodeLedger.swift`, `WatchdogClinicianExport.swift` | Pins `testExport*` / `testLedger*`; Baseline toolbar ShareLink |
| Phone: hide-all long card | `preferReadySeries` | After-bug table |
| Phone: live line before 14 | `WatchdogView` | After-bug table |
| **G1** presentMinutes / lastBandKey | Display | Pre-handoff pin |
| **G5** personal-off uses shown 60-day | Existing contract | Documented |
| **G6** stale-mask then display window | `evaluate` | Temp TRUST flicker |
| **G7** always Range; In/Off still 14+TRUST≥35 | `WatchdogView` | |
| **G8** personal skin setpoint, 1.0 °C | `UniTSRuntime.reconstructTemp` | Not core temp |
| **G9** chair still 0.32 / 0.22 | `WatchdogConfig` / activity | |
| Paint / companion width | `paintRanges` | Display only; never narrower than Off σ |
| Physiology extreme page | `WatchdogPhysiology.swift` | 8 `WatchdogPhysiologyAlertTests`; six graphs stay separate |

## Planned in the Sep 08 / ADDONS list — shipped as sidecars

F04 / F08 / F09 match `docs/baselines/ADDONS.md`. They do **not** vote on Off, notify, or Layer 1 usuals. `WatchdogAddonSidecarTests` covers the contract pins.

## Documented, **agreed not to code** (not missing)

| Item | Why it is not a hole |
|---|---|
| **G2–G4** | Quality / freshness / empty WHOOP 5 resp+SpO₂. Chinmay: document only, do not invent a decoder or a new usual. |
| Empty breathing / SpO₂ on WHOOP 5 | Ingest / v18 channels, not Layer 1 or Watchdog. |
| Official UniTS / TimesFM 2.5 convert | Leftover 10: convert script fails; students stay. TimesFM 3.0 must not ship. |
| F02 caregiver portal, F05 med comparison, clinical V07–V08 | Explicitly **not** these add-ons (`ADDONS.md` “What this is not”). |
| Charge / Effort / Rest rewrite | Out of scope all week. |
| Nara-App port | Next repo. Brief is `docs/PORT_LAYER1_WATCHDOG.md`. Not a leftover. |

Branch: `nara-baseline-watchdog` (not `main`).

---

# 1. Fix HRV units

**Original:** The daytime tape currently logs RMSSD and then passes it as milliseconds, causing rejection or a second log transformation. Transform once and rebuild any affected saved records.

## Plain explanation

Layer 1 HRV math is **ln(RMSSD)**. The tape and the range check are **milliseconds**. If the tape stores `log(44)` (~3.7) and then `evaluate` logs again, the day is rejected (3.7 is not in 5…250 ms) or trained as double-ln. Sleep nights from `DailyMetric.avgHrv` were already ms. Only the Watchdog day tape was wrong.

## 1. What we understand

Store native RMSSD ms on the tape. `toMath` is the one ln. Rebuild persisted buckets that already stored ln.

## 2. Evidence — where and why

`LBDayTape.ingest` used to `log` then pass the mean as if it were ms. `LongitudinalBaseline.observation` range-checks (5, 250). `ln(40) ≈ 3.69` → `.lowQuality`. If it slipped through, `toMath` did `log(log(ms))`.

## 3. How we implemented it

Tape stores ms. Persist key `noop.baseline.daytape.v2`. `migrateHrvFromLnIfNeeded` lifts means in (0, 5) with `exp` once. Pins: `testDayTapeHRVIsMillisecondsNotLn`, `testMigrateLnHRVBucket`.

## 4. Why full / what not to hinder

Sleep HRV nights and Charge untouched. Two Layer 1 copies still never averaged.

**Review:** Wrong unit on the daytime tape only. Seen in Layer 1 awake-rest HRV observations. Fixed Friday (ms + migrate). Reliable. **No further 4 Oct engine work.**

---

# 2. Fix sample counting

**Original:** Use fixed minute buckets and actual measurement identities. Re-reading overlapping windows or the same sparse reading must not increase coverage, sample counts, or baseline readiness.

## 1. What we understand

Identity is **`(channel, civilMinute)` of the measurement**, not “evaluate ran in a new wall minute.”

- Same 30-minute window again → tape / IMU / sidecar / band `n` unchanged.
- Hold one temp pair for eight minutes while HR ticks → temp `nPresent` stays 1.
- HR-only new minutes may still advance **global** band `n`. They must not increment temp `nPresent`.

## 2. Evidence — where and why

**Closed Friday (still true)**

- `LBDayTape.addUnique`: civil minute of last fresh sample. Pin: `testOverlappingWindowDoesNotRaiseHRVCount`.
- IMU: `ts > lastTs`; coverage = unique `ts/60`.
- Sidecar native counts: `lastFiniteMinuteUnix` must be `> lastNativeMinute[k]`.

**Still open on 4 Oct (before this patch)**

`WatchdogBand.update` used `shouldCountMinute(nowUnix, lastUnix)` — the **tick’s** civil minute — then incremented **every** `present` channel.

A sparse temp sample stays present and fresh for ~8 minutes. Each 20 s tick in a **new** wall minute did `n += 1` and `nPresent[temp] += 1`. Fourteen ticks made temp **ready** from one reading.

Sidecar `sessionN` / `sessionKeyTicks` used the same wall-minute gate.

## 3. How we implemented it

1. `WatchdogBandState.lastMinute[k]` = last counted civil minute (`unix / 60`) for that channel.
2. Production update gets `lastFiniteMinuteUnix` per channel.
3. If no present channel has a newer measurement civil minute, return without touching `n` or `nPresent`.
4. If HR is new and temp is the same pair: `n += 1`, `nPresent[HR] += 1`, temp `nPresent` unchanged.
5. `sessionN` / `sessionNativeN` / `sessionKeyTicks` increment only when at least one `lastNativeMinute[k]` advanced.
6. Wrap-up: `WatchdogBand.update` no longer early-returns on the **tick** civil minute when `sampleMinute` is present — a new temp in the same wall minute still counts. `sessionAbs` blends only channels whose native minute advanced (held sparse temp does not). Tape `activeMinutes` keys on the last fresh HR measurement minute, not `nowUnix`.

Pins: `testBandDoesNotMatureTempFromHeldSparseSample`, `testBandCountsNewChannelInSameWallMinute`.

## 4. Why full / what not to hinder

Sparse temp still *holds* TRUST between samples. It must not *mature* the green band. Does not change J, Layer 1 copies, or Charge. IMU `sampleCount` can still rise on two timestamps in the same minute; coverage is unique minutes.

**Review:** Counts were keyed on “we looked again.” Seen on tape `n`, band `nPresent`, sidecar `sessionN`. Tape + IMU unique-minute; band/sidecar use per-channel last measurement minute; wrap-up removed the leftover wall-clock gate. Reliable for those doors.

---

# 3. Share context and learning gates

**Original:** Scoring and baseline ingestion should use the same sleep/activity context. Sleep must not enter awake-rest baselines. Poor-quality, confounded, and active-alert periods should stop adaptive learning while preserving valid measurements for detection. Yesterday’s confounder should only carry over during overlapping sleep.

## Plain explanation

There are two jobs on the same half-hour:

1. **Detection** — “Does this stretch look unlike you *right now*?” Keep the raw minutes even if you logged illness or an alert is open.
2. **Learning** — “Add this minute to usual.” Must not run on sleep, thin/off-wrist data, a confounder day, or an open alert.

Two words also got mixed. Live scoring calls a still tail **“rest”** including asleep. Layer 1 **awake-rest** means still **and not asleep**. Sleep minutes in `restHR` train overnight values into daytime usual.

Calendar yesterday: illness yesterday applies only while last night’s sleep is still open. `today ?? yesterday` attached yesterday after wake.

After `evaluate`, any successful window could still ingest tape and IMU, including quality-fail and open alerts.

Illness still **caps Watchdog severity at candidate** (29 Sep product). That is “no page,” not “no detection.” Learning is a different door.

## 1. What we understand

| Rule | Meaning |
|---|---|
| Same context | Sleep / effort / still for a minute is one bit (col-19 or open interval + occupancy), used by LiveTail and the tape. |
| Sleep ≠ awake-rest | Sleep may update sleep SpO₂ nadir. Never `restHR` / `restHRV`. |
| Learn off, detect on | Confound, quality-unavailable, candidate/active/severe: band + sidecar + tape + IMU do not train. `evaluate` still runs. |
| Yesterday confounder | Only if `sleepOpen` and yesterday `confoundsUsual`. Never `today ?? yesterday` after wake. |

## 2. Evidence — where and why

**Closed earlier (still true)**

- Col-19 / interval on the last fresh minute (`LBDayTape.sleepAt`). Pins: `testSleepMinuteDoesNotEnterAwakeRest`, `testSleepIntervalBlocksAwakeRestEvenIfLastRowIsAwake`.
- Band / sidecar `bandLearn` false on confound, recovery, personal-off, candidate/active/severe.
- Rest tape skips 20 min post-workout.
- LiveTail sleep → period `.rest` is scoring still, not Layer 1 awake-rest.

**Still open on 4 Oct (before this patch)**

1. `WatchdogService`: `return todayLog ?? yesterdayLog` — after wake, yesterday `feltIll` still entered `evaluate`.
2. After `evaluate`, any `.success` window called `ingestWatchdogTape` / `ingestImu`.

## 3. How we implemented it

1. `Watchdog.liveDayLog` — today if today confounds; yesterday only if sleep is open and yesterday confounds; else today (may be nil).
2. `Watchdog.shouldTrainUsual` — false if unavailable, data-unavailable, candidate/active/severe, or `dayLog.confoundsUsual`.
3. Service ingests IMU / day tape only when that is true.
4. `LBDayTape.ingest(..., trainUsual: false)` no-ops.

Pins: `testYesterdayConfounderOnlyWhileSleepOpen`, `testTapeDoesNotTrainWhenTrainUsualIsFalse`, `testShouldTrainUsualStopsOnQualityAndAlert`.

## 4. Why full / what not to hinder

Detection still sees the window. Sleep HR stays on `DailyMetric` nights. Charge workouts are not this gate. LiveTail `.rest` including sleep is kept for “still now.”

**Review:** Sleep could train daytime rest; learning ran when only detection should; yesterday stuck after wake. Seen on `awakeRest*`, green band, `dayLog`, service ingest. Fixed Friday (sleep bit) + today (liveDayLog / shouldTrainUsual). Reliable for those doors. **No further engine work for request 3 unless a pin fails.**

---

# 4. Initialize each metric independently

**Original:** Each channel needs its own first-value seed, count, readiness, and band anchor. Missing temperature or other metrics must not start from zero or inherit readiness from HR.

## Plain explanation

The strap does not write every vital every minute. If “the band” is one object: 14 HR minutes mark **everything** ready; empty temperature is treated as residual 0; the first real 33 °C can blend from stored 0 and become ~5 °C.

Each channel keeps its own first-value seed, `nPresent[k]`, ready when **that** count ≥ 14, and its own anchor.

## 1. What we understand

Six channels: HR, RHR, HRV, temp, resp, SpO₂. Missing = `present[k] == false`. Residual 0 in an empty slot is not a measurement. Sidecar `writeDay` must seed a channel the first day it is present. Shared session `n` must not set another channel’s α, ready, or corridor.

## 2. Evidence — where and why

**Already closed (still true)**

- Band `present` mask skips missing vitals.
- First present residual seeds `q[k]`.
- Sparse temp does not mature from a held civil minute (request 2).
- TRUST C for temp/resp/SpO₂ is that series’ fill, not HR fill.

**Still open on 4 Oct (before this patch)**

1. `Watchdog.evaluate` — if `bandState.ready` (any channel ≥ 14), all six corridors were scaled. `sessionAbs[k]` starts at 0, so missing temp was nudged as `|r| = 0`.
2. `WatchdogBand.update` used one `alpha(n)` for every channel.
3. `writeDay` stored `center[2] = 0` when HRV was missing; the first later HRV day did `0.85×0 + 0.15×46` and treated the jump from 0 as MAD.

## 3. How we implemented it

1. `WatchdogBand.channelReady` — `nPresent[k] ≥ 14`.
2. Corridor apply + sessionAbs tweak only when **that** channel is ready.
3. EMA α from `nPresent[k] + 1`, not session `n`.
4. Sidecar: first present day copies `dayMedian[i]`; MAD stays 0 until there is a previous **nonzero** center.

Pins: `testMissingTempDoesNotInheritHRBandReady`, `testTempFirstValueSeedsIndependentlyAfterHRReady`, `testWriteDayFirstHRVDoesNotBlendFromZero`.

## 4. Why full / what not to hinder

A key can still be `ready` when HR matured (legacy `bandReady` / `sigmaAdaptive`). Paint and scale stay per channel. Detection still uses a present temp residual. The `nowUnix == 0` band helper still uses a throwaway `nPresent`; live carry uses `WatchdogBandState`.

**Review:** Missing channels were treated as 0 and as ready once HR was ready. Seen on green corridor width and sidecar usuals. Fixed today. Reliable for band + sidecar doors. **No further engine work for request 4 unless a pin fails.**

---

# 5. Correct readiness and staleness

**Original:** Use genuinely eligible observations and consistent coverage units. Recalculate readiness after selecting context-matched history. Illness days should not make an old baseline look freshly learned.

## Plain explanation

Layer 1 has two usuals: a 7-day copy and a 60-day copy. “Ready” means there are enough **clean** nights of the **same kind of day** (rest vs trained). “Stale” means the last **eligible** night of that kind is more than 14 days ago.

An illness day can still have a heart-rate number. If that number is allowed to stamp “last OK,” a held 60-day median looks freshly learned. It is not — that night was dropped from the usual.

A second leak: after the engine picks **only rest nights** (or only trained nights) for the usual, it still used *any* recent clean night for freshness. Twenty trained days after the last rest day made a rest usual look up to date.

Coverage for readiness is **nights in the window** (`n / 53`, `n / 7`). Observation coverage is **minutes** (still / moving) or **SpO₂ slots**. Those units stay separate. Nil coverage is low-quality, not a free pass.

## 1. What we understand

- Eligible = quality-ok + in range + `nightIsClean` (no usual-confounder).
- After habit match, `nLong`, `establishedLong`, `showLong`, TRUST, `lastOK`, and `stale` all use the matched nights.
- Illness / confound must not refresh `lastQualityOKEpoch`.
- Held long copy: stale from the held window’s last update, not an illness today.

## 2. Evidence — where and why

**Closed Friday (still true)**

- `lastQualityOKEpoch` requires `nightIsClean`. Pin: `testIllnessNightDoesNotRefreshLastQualityOK`.
- `establishedLong` / `showLong` after habit remap of `nLong`.
- Held copy remaps stale from `lastLongUpdate`.

**Still open on 4 Oct (before this patch)**

1. After habit match, `lastOK` was still the last clean night of **any** habit. A rest usual could look fresh because yesterday was trained.
2. `lastUpdate` for the week copy used the last trainable night even if that night was ill, so the 7-day snapshot’s `lastUpdate` looked new while the center skipped that night.
3. `nLongLowQ` stayed on the unfiltered long window after habit remapped `nLong`.

## 3. How we implemented it

1. `lastQualityOKEpoch(..., habit:)` when the long copy is habit-matched.
2. Remap `stale`, `lastLongUpdate`, and `nLongLowQ` from matching-habit long nights.
3. `lastUpdate` requires `nightIsClean`.

Pins: `testHabitMatchedStaleUsesLastMatchingNightNotOtherHabit`, `testWeekLastUpdateSkipsIllnessNight` (plus the Friday illness pin).

## 4. Why full / what not to hinder

Skip-and-hold of the center stays. Charge untouched. Watchdog still read-only on shown copies. 7-day center still uses recent clean nights (not habit-filtered); only its `lastUpdate` stamp skips confounders. Observation coverage stays minutes/slots; copy coverage stays night-slots.

**Review:** Illness and the wrong habit could stamp last OK. Seen on Layer 1 `stale`, TRUST freshness, `copy7.lastUpdate`. Fixed Friday (illness) + today (habit lastOK + clean lastUpdate). Reliable for those doors. **No further engine work for request 5 unless a pin fails.**

---

# Usual freeze (logged felt ill only) — 4 Oct product

Not one of the original 12 numbers. A logged felt-ill should lock a when-well snapshot for Watchdog personal-off. Treatment freeze stays the only path that restarts Layer 1’s long usual.

## 1. What we understand

- **Logged felt ill** → snapshot the last clean 7-day and 60-day copies (`logged_ill`). Illness nights still do not train (skip-and-hold). **Do not** wipe `centerLong` / `nLong`.
- **No adaptive freeze.** A quiet 7-day vs 60-day split does not invent a new version.
- **Treatment start** (logged) still freezes the pre-start path and opens a new long epoch. No inferred `t0`.

## 2. Evidence

The first cut opened a new long epoch on felt-ill (same wipe as treatment) and also froze on a 3-day week-vs-long split. That changed Layer 1 core scoring without a treatment log.

## 3. How we implemented it

`LBUsualFreeze` is attached only from `firstFeltIllOnset`. Replay epoch wipe uses **`trialEpoch` only**. Week-off streak / `week_off_long` removed.

Pins: `testFeltIllFreezesPreIllnessUsualWithoutResettingLong`, `testWeekShiftDoesNotFreezeWithoutLoggedIll`.

## 4. Why full / what not to hinder

Watchdog personal-off can still use the snapshot. Layer 1 z / CUSUM / habit / stale stay skip-and-hold. Charge untouched. Treatment trial tests stay the source of truth for epoch reset.

## Isolation vs the rest of 4 Oct

| # | Why freeze does not rewrite it |
|---|---|
| 2 | Band / tape counts are measurement civil minutes. No freeze read. |
| 3 | `liveDayLog` / `shouldTrainUsual` use the day log, not `usualFreeze`. |
| 4 | Per-channel seed / `channelReady` never see Layer 1 freeze. |
| 5 | `lastOK` / `lastUpdate` still use `nightIsClean`. Felt-ill no longer wipes `nLong`, so staleness is not reset. |
| 6 | Personal-off still prefers a freeze **when a log created one**, else the 60-day copy. Week-split no longer invents that freeze. |
| 7 | `safetyHit` is last still-rest extrema on the window. Severity: safety → severe before personal-off / freeze. Pin: `testSafetyHighLowIgnoresLoggedIllFreeze`. |

---

# 6. Independent personal-change check

**Original:** Compare current measurements against the established matching baseline, even when the short-term model follows the new level. A sustained HRV decline should remain detectable rather than gradually becoming “normal.” Keep a stable reference and hold adaptation during an open deviation.

## Plain explanation

UniTS draws a dotted “expected” line that can **follow** a new HRV level. If that were the only ruler, a week of low HRV would look explained — “normal” for this half-hour. Layer 1’s when-well usual is a **different** ruler: what this person looked like over days.

Personal-off means: this minute’s **native** HR or HRV vs that stable usual, not vs the hat.

## 1. What we understand

- Matching usual = **logged felt-ill snapshot** or the 60-day copy, not the walking 7-day. No adaptive week-split freeze.
- Hat residuals stay for J / workout names. They must not clear personal-off.
- Band / sidecar do not train while personal-off or an episode is open.
- Sustained personal-off (persist minutes) is **candidate**, even if recon J is quiet.

## 2. Evidence

**Closed Friday:** `personalNativeOff` vs shown HRV long copy; `bandLearn` false on personalOff; live prompt `asOf` is calendar yesterday.

**Still open on 4 Oct (before this patch)**

1. Fallback `copyLong ?? copy7` — a walked week copy could hide the decline.
2. Only HRV was compared. Live HR vs sleep RHR / awake-rest HR was missing.
3. Severity treated personal-off as **note** only. Quiet hat + persist never became candidate.

## 3. How we implemented it

1. `personalReference` = `usualFreeze` long, else established / shown long. Never the 7-day.
2. Native HR and HRV both compared.
3. `personalOff && persist` → candidate.

Pins: `testPersonalNativeOffIndependentOfHat`, `testPersonalOffUsesFrozenLongNotWalkedWeek`, `testPersonalNativeOffHRAgainstSleepRHR`, `testSustainedPersonalOffIsCandidateEvenIfHatIsQuiet`.

## 4. Why full / what not to hinder

Not Charge. Not a named illness. Confounded days still cap at candidate. Treatment freeze stays the trial path.

**Review:** Hat-follow could hide a real Layer 1 off; week walk could too. Seen on Watchdog severity / green band. Fixed Friday (HRV vs long) + today (freeze/HR/candidate). Reliable for those doors. **No further engine work for request 6 unless a pin fails.**

---

# 7. High/low checks independent of the model window

**Original:** A valid fresh breach should still be evaluated during startup or incomplete model coverage. Preserve unusual-but-valid readings and their duration; averaging or filtering must not erase the values that the rules are supposed to detect.

## Plain explanation

High/low safety is a **ruler on the last still-rest reading**: rest HR above 120 or below 35, skin temp / breathing / RMSSD outside the same engineering bounds. It does not ask UniTS “does this half-hour look explained?”

The 30-minute model window can be thin at startup. Friday already ran safety on that thin window.

Leftover: the **number** the rule saw was not always the real extreme, and the **clock** of how long it had been extreme was wiped when coverage was incomplete.

## 1. What we understand

- Still, on-wrist, **fresh** last minute.
- HR high/low uses that minute’s **max / min samples**, not the minute mean.
- An RMSSD that is already past the safety bound stays on the grid; the 3-tap median must not replace it with neighbors.
- First-seen unix of the open extreme is held across thin / UniTS-fail ticks. Wrist-off / empty window clears it.
- Wrist-off stays unavailable. Forecast still cannot severe.

## 2. Evidence

**Closed Friday:** quality-fail (not wrist-off) calls `safetyCap`; `safetyDuringQualityFail` is severe without UniTS. Pin: `testThinWindowRestHR135IsSafetySevere`.

**Still open on 4 Oct (before this patch)**

1. `safetyCap` used `tail.last(window.hr)` — the **minute mean**. Twenty seconds at 135 mixed with 70 bpm can average under 120.
2. `rmssdGrid` dropped RMSSD outside 8…250 **before** the safety rule could see it. `median3` then replaced a 6 ms sample with 40 ms neighbors.
3. Quality-fail **zeroed** `consecutiveMismatchTicks` before the safety door. UniTS `catch` returned unavailable with no safety check. No first-seen unix, so duration did not survive the next thin tick.

## 3. How we implemented it

1. `safetyHit` — HR from last fresh `hrMax` / `hrMin`; temp / resp / HRV last fresh native.
2. `rmssdGrid` keeps a positive RMSSD even if it is out of band. `median3` returns a safety-bound sample unchanged.
3. Quality-fail and UniTS-fail call safety **before** clearing persist. `rememberSafety` stores channel, extreme, first unix. Episode line can show `held Ns`.

Pins: `testHrMinuteMeanDoesNotHideFreshHigh`, `testMedian3KeepsSafetyBoundRMSSD`, `testSafetyDurationSurvivesThinWindowTicks`, `testSafetyHighLowIgnoresLoggedIllFreeze` (plus Friday thin-window 135).

## 4. Why full / what not to hinder

Does not invent missing temp to fill coverage. Effort minutes still do not count as rest-HR extrema. Charge / Layer 1 usuals untouched. SpO₂ has no safety bound in `WatchdogConfig` — not added.

**Review:** Thin coverage already paged Friday. Mean / filter / duration could still hide the same extreme. Seen on Watchdog safety, not Charge. Fixed today. Reliable for those doors. **No further engine work for request 7 unless a pin fails.**

---

# 8. Episode transitions and notifications

**Original:** A gradual candidate → active → severe episode must send its first severe notification once. Count new valid observations and elapsed time rather than repeated ticks. Missing data should pause recovery, and duplicate notifications need a clear cooldown/rearming policy.

## Plain explanation

An episode is one stretch that climbs note → candidate → active → severe. The phone should **page once** when it first becomes severe. Three 20-second looks at the same minute are not three new facts. If the strap drops, that stretch is **paused**, not “all better.” After things are quiet for a while, a **new** episode may page again.

## 1. What we understand

- First severe of this `episodeId` pages once (`notifiedSevereEpisodeId`).
- Persist / recovery advance on a **new measurement civil minute**, not every tick and not a held last pair in a new wall minute.
- Unavailable zeros quiet and does **not** resolve or drop the id.
- Escalate (same episode, bigger jump) needs 30 minutes since the last page. Rearm after 15 in-range minutes.

## 2. Evidence

**Closed Friday:** `WatchdogNotifyPolicy` first-severe; `lastPersistMinute` so 20 s ticks in the same minute do not add persist. Pin: `testFirstSevereNotifiesOnce`.

**Still open on 4 Oct (before this patch)**

1. A new **wall** minute with the **same** last sample still incremented persist / in-range (same leak as request 2).
2. `nextState` added a quiet tick on every evaluate. Two 20 s quiet looks could **resolve**. Unavailable paused quiet but two later ticks could still close the episode too fast.
3. `notifyCooldownSeconds` was 0. Escalate could re-page in 40 s. Safety rising-edge paged even after this episode already had its first severe.

## 3. How we implemented it

1. Persist / in-range increment only when `persistMinute` is new **and** `latestValidObsMinute` is newer than `lastPersistObsMinute`.
2. Recovery uses `consecutiveInRangeTicks >= 2` (two valid quiet minutes). Unavailable keeps the id and the in-range count.
3. First severe (or first safety) of an id still pages. Escalate needs `escalateDelta` **and** 30 minutes since `lastNotifiedAt`. A **new** safety rising edge during a stable episode still pages (request 7). Same-minute held samples do not count as persist.

Pins: `testEscalateRespectsCooldown`, `testRecoveryNeedsTwoValidQuietMinutesNotTicks`, `testUnavailablePausesRecoveryWithoutResolving`, `testPersistDoesNotAdvanceOnHeldObservationNewWallMinute`.

## 4. Why full / what not to hinder

Workouts / Early / note still do not page. Request 7 safety first page of an episode still fires. Delivery queued/sent/failed is request 12, not this door. Charge / Layer 1 untouched.

**Review:** Gradual climb could miss the page (Friday) or count ticks / re-page (today). Seen on Watchdog notify / episode state. Reliable for those doors. **No further engine work for request 8 unless a pin fails.**

---

# 9. Displayed bands and confidence

**Original:** One fresh sparse reading should not count as 100% coverage. The displayed “Off” status and watchdog decision should have clearly consistent meanings. Keep starting thresholds configurable and labelled internally as engineering defaults until calibrated.

## Plain explanation

The green band is “where the dotted line thinks this minute should sit.” TRUST is “how filled and fresh this vital is.” **Off** on the card must mean the same thing Watchdog already decided — not “this last point sits a bit outside a painted width.”

One temp sample in 30 minutes is a few percent of that strip, not 100%.

## 1. What we understand

- Sparse C = fresh finite minutes / strip length. Never 1.0 from one pair.
- Live **Off** = `severity ≥ candidate` **or** safety **or** personal-off. Not Layer 1 HOW OFF. Not “outside painted band” alone.
- A row says Off only when that live-off door is true **and** this channel is hot / personal-off / outside the band.
- `tNote` / `tActive` / `tSevere` stay `prior-untuned` engineering defaults.

## 2. Evidence

**Closed Friday:** `sparseCoverage` is fresh/length. Pin: `testSparseCoverageIsNotOneFromASinglePair`. Config header already says engineering defaults.

**Still open on 4 Oct (before this patch)**

The card set **Off** from `abs(obs − hat) > painted width`. Watchdog could be within limits (or only a note) while a row said Off, or personal-off / candidate while a widened learning band said In range. Quality line said “Coverage %” from **HR fill**, which could be read as temp confidence.

## 3. How we implemented it

1. `Watchdog.liveOff` + `WatchdogResult.liveOff` / `personalOff`.
2. Watchdog rows: Off only if `liveOff && (outsideBand || channelHot)`.
3. Quality line says **HR fill**, not generic Coverage.

Pins: `testLiveOffMatchesSeveritySafetyAndPersonalOff` (plus Friday sparse C).

## 4. Why full / what not to hinder

No wearer-facing “confidence %.” Charge / Layer 1 HOW OFF unchanged. Thresholds not wearer-fit. Request 7/8 notify doors unchanged.

**Review:** One pair is not 100% (Friday). Off now matches the engine. Reliable for those doors. **No further engine work for request 9 unless a pin fails.**

---

# 10. Correct the model integration

**Original:** The bundled models are students, so their outputs must not be labelled “official.” The official export is unfinished. Either finish that integration or explicitly defer it and keep predictive Early warnings in shadow mode. Wire missingness masks into actual inference and match forecasts to their future target timestamps.

## Plain explanation

The phone ships **student** graphs (UniTS_AD and TimesFM3_Student). Those are practice models. They must not be sold as the official TimesFM 2.5-200m path. Until that convert exists, a “this is about to go off” Early page stays **shadow**: we still compute the cube, we do not page the wearer for looking ahead.

A forecast is five **future** minutes: now+1 through now+5. When we hold that cube for the rest of this minute, those five clocks stay put. When a minute arrives, we score **that** minute against **that** column — not “whatever five heart-rate samples we happen to have at the end of the strip.”

Empty minutes are empty. The student graphs now take `present_mask` (1 = measured) as a required input. Holes are prompt-filled; the mixer zeros those residuals. TimesFM student is trained on the **next** five minutes (`extra_future=HORIZON`), not a copy of now.

## 1. What we understand

- `forecastSource` is `student` | `hold` | `inject`. `official` is unused until convert pins exist.
- Wearer Early is false for student / hold.
- Official Harvard UniTS and TimesFM 2.5 **cannot be implemented on the phone today** (reasons below). TimesFM 3.0 must not ship.
- Missingness: `maskStaleChannels` before models; `packPresentMask` (1 = measured); occupancy + prompt fill **and** required `present_mask` on `units-ad-coreml-v3` / `timesfm3-student-v3`.
- Forecast columns belong to `now+60…now+300` at emit. Holds must not slide those unix times. Backcast matches observations at those times.

## 2. Evidence

**Closed Friday:** student label, Early shadow, `horizonUnix` helper, convert download-only, TimesFM 3.0 banned. Pins: `testStudentForecastIsNotWearerEarly`, `testHoldForecastCannotEarly`.

**Still open on 4 Oct (before this patch)**

`WatchdogForecastRuntime.step` scored the last five **present** observations against the 6×5 **future** cube. A hold recomputed `horizonUnix(nowUnix)`, so the labels walked while the numbers stayed. Carry stored `lastForecastUnix` (emit wall time) but not the five target seconds. `packPresentMask` existed for tests and was not passed into Core ML.

## 3. How we implemented it

1. `WatchdogCarry.lastForecastHorizonUnix` — persist the five target seconds with the cube.
2. `WatchdogForecastStep.persistHorizon` — holds reuse those seconds (or rebuild from `lastForecastUnix` on old carry).
3. `WatchdogForecastRuntime.backcastEnergy` — column `i` vs the sample at `horizons[i]`. Missing that minute is skip, not a last-present stand-in.
4. UniTS / TimesFM `predict` always attach `present_mask` (all-ones if the caller omitted it). Students were retrained with random holes; forecast loss is the true future 5-min cube.
5. Students stay labelled `student`. Wearer Early stays shadow for student / hold. Official convert latch (`officialConvertReady` / `publishedSource`) was removed — it did not change the student.

Pins: `testHoldForecastKeepsEmitHorizon`, `testBackcastMatchesHorizonNotLastPresent`, `testPresentMaskMarksMissingMinutes` (plus Friday Early / source pins).

## 4. Why full / what not to hinder

This is the leftover on **labels, Early, timestamps, and student missingness**. Official graphs are **not** on the phone. Do not invent an official path by renaming students. Charge / Layer 1 / safety / notify doors unchanged. Reconstruct still uses occupancy; we do not mix the measurement mask into motion occupancy.

**Review:** Student UniTS reconstruct + mask + timestamps are complete on-device. Official Harvard UniTS is **not** (Core ML convert fails). TimesFM is the TimesFM3 student, not 2.5-200m. Early is shadow. Held cubes keep their clocks. Do not rename either graph official.

## Why official models cannot be implemented today

Not a latch. Not a student rename. These are the exact blockers.

### Official UniTS (Harvard `units_x32_pretrain`, MIT)

Watchdog needs one frozen Core ML graph: inputs occupancy + prompt + personal_scale + observed + `present_mask`, outputs hat + σ, shape **(1, 6, 30)**.

The public checkpoint is a **different machine**:

| Fact | What we saw 4 Oct |
|---|---|
| File | `units_x32_pretrain_checkpoint.pth` ~18 MB |
| Keys | `student`, `optimizer`, `epoch`, `args`, `ibot_loss` — that `student` is UniTS’s iBOT pretrain copy, **not** our Watchdog mixer |
| Geometry | `d_model=32`, `patch_len=16`, `seq_len=96`, `pred_len=96` — **96**, not 30 |
| Prompts | Per **benchmark dataset** (ETTh1, Weather, Traffic, ECG5000, …). **No** 30×6 Watchdog vital prompt |
| Load | Requires Harvard’s `UniTS.Model` Python class (`vendor/UniTS.py`) |

PyTorch probe **works**: wrap `anomaly_detection`, pad 30→32, slice ETTh1 prompt tokens to 6 channels, `hat` shape `(1,6,30)`.

`coremltools` **does not**. Three hard stops on the official forward, in order:

1. **`DynamicLinear` → `aten::Int`.** Layers pick width at runtime. Baking seven of them to fixed `Linear` was not enough.
2. **`unfold` not implemented** in the Core ML PyTorch frontend (patch tokenize). A reshape workaround for 2×16 patches still left later failures.
3. **Remaining `aten::Int`** in Seq/Var attention (`B, N, C = x.shape`) and `prepare_prompt` repeats.

Until someone rewrites that official forward in Core ML–legal ops (fixed shapes, no `unfold`, no dynamic `Int` ranks) and pins a new hash, Harvard UniTS **cannot** replace `UniTS_AD.mlpackage`. Relabeling the D=32 student does not count.

### Official TimesFM 2.5-200m (Apache-2.0)

This is the legal on-device TimesFM we would convert — **not** 3.0.

| Fact | Why it is not on the phone |
|---|---|
| Weights | Hugging Face `model.safetensors` **~925 MB** / 0.2B params |
| Public Apple ports | ~463 MB fp16 **univariate** (context 2048, horizon 128, host RevIN/RoPE/pad) |
| Watchdog job | **6 channels × 5 future minutes**, occupancy + `present_mask`, not 2048-univariate |
| Status | No traced `TimesFM3_Student`-shaped official graph exists. Convert was not finished. |

A 925 MB univariate decoder is not a drop-in for the 6×5 student. Shipping it as-is would also blow the app budget and still miss mask / occupancy I/O.

### TimesFM 3.0 (cannot ship at all)

`google/timesfm-3.0-pytorch` / ~330M weights use `timesfm-non-commercial-license-v1.0` for self-hosted use. Production use is Google Cloud only. **Downloading and converting 3.0 for the app is the same as shipping banned weights.** Cloud 3.0 would be a scoring API (data leaves the phone). That is a different product, not this on-device Watchdog.

### What we ship instead

`UniTS_AD.mlpackage` and `TimesFM3_Student.mlpackage` from `train_export.py` (~100 KB / ~43 KB, `present_mask`, true +1…+5 min forecast). `forecastSource` stays `student` / `hold` / test `inject`. Wearer Early stays shadow. `export_official_coreml.py` may probe into `.official-ckpts/` only — it does **not** overwrite the student packages.

---

# 11. Finish source isolation

**Original:** Use the active strap for every channel, including IMU. Switch or clear live buffers and learned state when the source changes. Selecting a historical date in the UI must not change the live baseline prompt.

## Plain explanation

The live card is “what is this strap doing **right now**.” If you pair a second WHOOP, or swipe the Baseline calendar back to June, that must not mix last month’s nights or the other strap’s IMU into this half-hour.

Two jobs share a store:

1. **Dashboard / Layer 1** may union history (active strap + old imports) so nights are not orphaned.
2. **Live Watchdog** must read **one** `deviceId`: HR, RR, temp, resp, SpO₂, steps, events, **and IMU/gravity**.

When you tap a different strap, the 20-second live rings and the learned band / episode (carry) must belong to **that** strap. They must not keep walking with the old one.

When you swipe a historical date, Layer 1 HOW OFF can change. The UniTS **prompt** for the live card must stay “last completed night,” not that swipe.

## 1. What exactly was going wrong?

**Closed earlier (still true)**

- `Repository.watchdogSourceIds()` is `[deviceId]`.
- IMU / gravity already queried `model.deviceId`.
- Live HR/RR rings clear when `deviceId` changes; carry is keyed `noop.watchdog.carry.v2.{deviceId}`.
- `BaselineStore.livePromptAsOf` uses the newest scored night **before calendar today**, not `store.asOf`.

**Still open on 4 Oct (before this patch)**

1. **Window still looped `ids`.** Even though the list was one id, HR/temp/resp/SpO₂/steps/events were written as a merge. Widening `watchdogSourceIds` later would have mixed straps again. IMU was the only channel that looked like a single id.
2. **Sleep intervals were the dashboard union.** `sleepSessions` reads every registered WHOOP. Live “sleep open” and “yesterday’s confounder only while sleep is open” could follow **another** strap’s night.
3. **v1 carry cloned onto every new device.** First tick on a new `deviceId` copied `noop.watchdog.carry.v1` (episode, persist, band `n`, forecast cube) onto that strap. Switching sources did **not** start learned state clean.

The calendar swipe was already isolated for the prompt. It needed a pin so a later `evaluate(asOf: store.asOf)` could not sneak back in.

## 2. Where is this effect seen?

| Leak | File | What the wearer would see |
|---|---|---|
| Multi-id window loop | `WatchdogService.loadWindow` | Other strap’s temp/HR in this 30 minutes if ids ever grew |
| Sleep union | `Repository.sleepSessions` used from `tick` | Sleep-open / yesterday illness from a parked WHOOP |
| v1 carry clone | `WatchdogService.loadCarry` | New strap inherits the old episode and green-band counts |
| Calendar swipe | `BaselineStore.watchdogPromptEvaluations` vs `asOf` | (Already correct) live dotted line must not jump when you tap June |

## 3. How we fixed it

1. Live window reads **only** `model.deviceId` for HR, RR, temp, resp, SpO₂, events, steps, **IMU/gravity**.
2. `Repository.watchdogSleepSessions` — this strap + its `-noop` sibling only. `tick` uses that, not the dashboard union.
3. v1 carry migrates **once** (`noop.watchdog.carry.v1.migratedTo`). Later deviceIds start empty. Live rings still clear on switch; v2 carry still loads per id.
4. Prompt stays `livePromptAsOf`. Pin: swiping `asOf` does not change `watchdogPromptEvaluations` `.asOf`.

Pins: `testWatchdogLiveReadsStayOnActiveStrap`, `testLiveWatchdogPromptIgnoresCalendarSwipe`.

## 4. Is this fix reliable? Further work?

Reliable for the **live card** doors: one strap’s samples (including IMU), new strap does not inherit v1 episode/band, calendar swipe does not retarget the UniTS prompt.

**No new leftover document for request 11.** Not remaining on this door:

- Layer 1 **day-tape IMU energy** is still one accumulator per civil day (not per device). That is Layer 1 history, not the live 30-minute window.
- Dashboard sleep / Full Day timelines still union registered WHOOPs on purpose.
- `selectedWhoopModel` still picks WHOOP 4 vs 5 freshness; that is family, not source id.

# 12. Persist episodes and delivery status

**Original:** Persist episodes and delivery status properly. Keep episode evidence across restart and distinguish queued, sent, and failed notifications. Permission denial or scheduling failure should remain visible and retryable. Cancel background work on expiration, and ensure backfill cannot create new live alerts.

## Plain explanation

An episode is one stretch that goes off. The phone must remember **which stretch** and **whether we already paged** if the app restarts. “We tried to page” is not the same as “the banner actually arrived.”

Three delivery words:

- **queued** — we decided to page; the system is still sending.
- **sent** — it left the phone.
- **denied** — notifications are off. **failed** — the system rejected the request.

Denied / failed must stay on the card and must be allowed to try again (after a cooldown), not be treated as “already notified.”

A background tick that iOS kills must **stop** — it must not finish a page after expiration. History backfill must never open a new live alert.

## 1. What exactly was going wrong?

**Closed earlier (still true)**

- Episode id, persist, lastNotifiedAt live on `WatchdogCarry` in `noop.watchdog.carry.v2.{deviceId}` (survives restart).
- Evaluate sets `notifyDelivery = queued` when it decides to page.
- `WatchdogNotifier` already called back sent / failed.
- BG `expirationHandler` cancels the in-flight Task (`WatchdogBackgroundScheduler`).
- `liveAlerts: false` during backfill (and inject pin `testBackfillInjectDoesNotNotify`).

**Still open on 4 Oct (before this patch)**

1. **Queued counted as notified.** `notifiedSevereEpisodeId` was stamped when we queued. Permission off → callback `failed` → the episode would never retry.
2. **Denied and failed were the same word.** Both were `failed`. The card did not show either.
3. **Delivery callback did not refresh the live card** — only UserDefaults carry.
4. **`tick` ignored cancellation** after `await` loadWindow / sleep. Expiration could still persist and post.
5. Backfill already silent; needed a pin that it also does not set `queued`.

## 2. Where is this effect seen?

| Leak | File | What you would see |
|---|---|---|
| Stamp notified on queue | `Watchdog.evaluate` / `safetyDuringQualityFail` | Notifications off → one silent “page,” never again |
| Denied = failed | `WatchdogNotifier` | Cannot tell permission vs send error |
| Card not updated | `WatchdogService.tick` | Carry said failed; Baseline still looked fine |
| Tick after expire | `WatchdogService.tick` | Page after iOS cancelled the BG task |
| Backfill | `liveAlerts = !backfilling` | History replay must not badge |

## 3. How we fixed it

1. `notifiedSevereEpisodeId` is set only when delivery is **sent**.
2. `queued` is **in-flight** — no second page this episode until sent / denied / failed.
3. `denied` vs `failed`. Denied / failed stay on the card (`certaintyCaption`) and **retry** after `notifyCooldownSeconds`.
4. Delivery callback writes carry **and** `applyWatchdog` so the card updates.
5. `tick` returns on `Task.isCancelled` (including after window / sleep / evaluate) and does not post if cancelled.
6. Backfill still `liveAlerts: false` and must not write `queued`.

Pins: `testQueuedNotifyDoesNotDoublePage`, `testDeniedNotifyIsRetryableAfterCooldown`, `testEvaluateDoesNotStampNotifiedUntilSent`, `testBackfillInjectDoesNotNotify`.

## 4. Is this fix reliable? Further work?

Reliable for persist-across-restart, queued / sent / denied / failed, retry after deny, BG cancel, and no backfill pages.

**No new leftover document for request 12.** Not remaining on this door:

- We do not add a wearer “Retry now” button (cooldown retry is the door).
- Mac has no BGAppRefresh; iOS scheduler was already registered.
- Test-centre `WatchdogNotifier.post(..., test: true)` is still a debug page, not a live episode.

---

# Add-on plan (not implemented): Event recovery — Sep 08 F04

**Status on 4 Oct:** plan only. Do not ship until Chinmay asks. Charge / leftover 1–12 stay closed.

**Original contract (F04 · Event recovery, P1):** Measure time back to the pre-event baseline and remaining deviations after a logged episode. Recovery stays unknown during missing data.

This is an **adjacent record**. It reuses Watchdog episode ids and Layer 1 freeze / 60-day copies. It is **not** a third engine and it must not change live Off, notify, or Layer 1 snapshot writes.

## Why this does not rewrite the current loop

Watchdog already answers: “Did *this* half-hour look unlike the reconstruction?”

Layer 1 already answers: “What is usual across *days*?”

Personal-off already answers: “Is the last fresh native HR/HRV off the **stable** usual *right now*?”

F04 answers a **fourth** question, after an episode has already opened:

> After episode `wd-…` started, how long until this vital sat inside the **pre-event** usual again, and what is still off? If the strap is off, say unknown — do not call that recovered.

Those are different clocks. Mixing them is what would break the current code.

| Clock | Who owns it today | F04 may |
|---|---|---|
| `severity` / `liveOff` / `shouldNotify` | `Watchdog.evaluate` | **Read only.** Never write. |
| `episodeState` recovering / resolved (2 quiet reconstruct minutes) | `Watchdog.nextState` | **Leave as-is.** Watchdog can resolve while F04 still says “not back to usual.” |
| `shouldTrainUsual` | evaluate + tape ingest | Unchanged. Open Off still freezes learning. |
| Layer 1 7-day / 60-day snapshots | `LongitudinalBaseline.evaluate` | **Never write.** F04 only **copies** `personalReference` at episode open. |
| Charge / Recovery | `Baselines.swift` | Untouched. |
| Student UniTS / TimesFM / Early | forecast runtime | Untouched. Early stays shadow. |
| Notify queued / sent / denied / failed | request 12 | Acknowledgement is **not** F04. A sent page does not mean recovered. |

Hard locks stay: two Layer 1 copies never averaged; no `t0` from HR; never name a drug; no on-device training; wrist-off is unavailable; backfill cannot create live alerts.

---

## 1. What we understand (the product)

### Open

The first tick that creates `carry.episodeId` (`wd-{unix}` or `wd-safety-{unix}`) **snapshots** the same ruler personal-off already uses:

`Watchdog.personalReference(ev)` = logged felt-ill `LBUsualFreeze.centerLong/spreadLong` if present, else the shown 60-day copy. **Never** the walking 7-day. **Never** the UniTS hat.

One snapshot per **(episodeId, series, deviceId)**. HR and HRV (and later temp/resp/SpO₂ only if that series already has a shown long copy). Sleep vs awake-rest stay on their own series — same list as `BaselineStore.watchdogPromptEvaluations`.

If there is **no** freeze and **no** established long copy, F04 does **not** invent a band. Status = `no_reference`. That is not recovered and not a new Layer 1 seed.

### Score

Each later **eligible** observation is compared to **that frozen copy**, not to tonight’s walking week:

```
z = (toMath(native) − freeze.center) / freeze.spread
in_band = |z| ≤ k   // same k as personal-off / isOffUsual
```

Eligible means the same gates as Layer 1 last-OK / Watchdog personal-off: matching context, quality ok, not a carried-forward minute, not wrist-off. Illness nights do not refresh the freeze (they also do not refresh last-OK).

### Clocks

| Field | Meaning |
|---|---|
| `openedUnix` / `openedCivilDay` | First candidate/active/severe (or safety) for this episode id. |
| `lastEligibleUnix` | Last observation that was allowed to move the F04 clocks. |
| `inBandSinceUnix` | First eligible minute that was in-band, if still in-band now. |
| `returnedUnix` | Set only after **two eligible in-band observations** (nights for Layer 1 series, or two distinct civil minutes for a live native) — **not** two 20 s ticks, **not** two reconstruct-quiet minutes. |
| `hoursToReturn` | `(returnedUnix − openedUnix) / 3600`, only when `returnedUnix` is set. |
| `remainingZ` | Last eligible z vs the freeze. Shown in native units on the card (bpm / ms), not as a disease probability. |
| `status` | `open` · `returning` · `returned` · `unknown` · `no_reference` |

`returning` = last eligible is in-band but `returnedUnix` is not set yet.
`open` = last eligible is still off the freeze, even if Watchdog `episodeState` is already `.resolved`.

### Missing data

Wrist-off, coverage fail, or no new eligible observation:

- Do **not** increment `inBandSinceUnix`.
- Do **not** set `returnedUnix`.
- `status = unknown` while unavailable (same door as Watchdog `dataUnavailable`).
- When data resume, keep the same freeze and the same `openedUnix`. A gap does not reset the episode and does not count as time-in-band.

### What the wearer sees (later; not this plan’s engine)

One line under the live card or the long-term card, keyed by the last episode id:

- “Not back to your pre-event usual yet · HR +8 bpm vs the frozen night.”
- “Unknown — strap off since 14:02.”
- “Back to usual after 11 hours.”

Watchdog copy “Recovering · waiting for two quiet minutes” stays. That sentence is reconstruct-quiet, not F04.

No diagnosis. No drug name. No caregiver ack. No new push when F04 returns (notify policy stays request 12).

---

## 2. Evidence — where a naive hook would break things

| Wrong hook | File | What would break |
|---|---|---|
| Drive `nextState` from Layer 1 z | `Watchdog.nextState` | Half-hour resolve waits on nights. Leftover 8 undone. |
| Drive `severity` / `liveOff` from F04 | `WatchdogScores.severity`, `liveOff` | A lingering 60-day off keeps paging after the strip is quiet. Request 9 Off meaning changes. |
| Hold `shouldTrainUsual` until F04 returned | `shouldTrainUsual` | Band/tape freeze for days after Watchdog resolved. Learning door changes. |
| Write Layer 1 centers from F04 | `LongitudinalBaseline` | Watchdog writes usuals — hard lock. |
| Store F04 **only** on `WatchdogCarry` and clear it when `episodeId` nils | `nextState` rearm (`rearmTicks`) | Time-to-return disappears 15 quiet minutes after Watchdog resolves — exactly when F04 still matters. |
| Use walking 7-day as the freeze | `personalReference` | Request 6 undone. Hat-follow / sick-week walk hides the change. |
| Count 20 s ticks as recovery minutes | persist leftover | Request 2 / 8 again. |
| Score backfill as live F04 open | `liveAlerts: false` | History creates a fake “open recovery.” Same rule as no live alerts. |
| Ask UniTS hat “are we back?” | reconstruct | F04 is personal usual, not the green corridor. |

---

## 3. How we will implement it (when asked)

### New types (StrandAnalytics)

`WatchdogEventRecovery.swift` — no edits to `severity`, `fused`, `NotifyPolicy`, `shouldTrainUsual`.

```
WatchdogEventRecoveryStatus: open | returning | returned | unknown | no_reference

WatchdogEventRecoveryChannel:
  series: LBSeries
  center, spread, k          // math space; copied at open
  remainingZ: Double?
  nativeRemaining: Double?   // display units
  lastEligibleUnix: Int
  inBandSinceUnix: Int?
  returnedUnix: Int?

WatchdogEventRecovery:
  episodeId: String
  deviceId: String
  openedUnix, openedCivilDay
  status
  channels: [WatchdogEventRecoveryChannel]
  lastUnavailable: Bool
```

Pure functions:

1. `openIfNeeded(episodeId, deviceId, nowUnix, evaluations, existing) -> WatchdogEventRecovery`
   - If `existing.episodeId == episodeId`, return existing (do not refresh centers).
   - Else snapshot `personalReference` per series. Empty refs → `no_reference`.
2. `step(record, natives, nowUnix, unavailable, evaluations) -> WatchdogEventRecovery`
   - `natives` = last fresh HR bpm / HRV ms already computed in `combine` (`lastHR?.obs`, `lastHRV?.obs`).
   - If `unavailable`: set `unknown`, return (freeze kept).
   - If no new **measurement civil minute** vs `lastEligibleUnix`: return unchanged (request 2).
   - Else update z / remaining / returning / returned.
3. `hoursToReturn` / `headline` — display only.

`step` must **not** take reconstruct residuals or `forecastSource`.

### Persist (outside live carry)

Key: `noop.watchdog.eventRecovery.v1.{deviceId}` (UserDefaults, same namespace style as `noop.watchdog.carry.v2.{deviceId}`).

- Survives restart.
- **Survives** `carry.episodeId = nil` at rearm.
- Switching `deviceId` loads that strap’s record only (request 11). Do not clone v1 blobs.
- Keep the **last** closed (`returned` / `no_reference`) record plus the current `open`/`unknown` one — not an unbounded history in this first cut. A 7-day export (F09) is a later add-on.

Do **not** put the freeze centers on `WatchdogCarry`. Carry already clears on rearm.

### Call site (after evaluate, not inside it)

`WatchdogService.tick` already has `result`, `evaluations`, `deviceId`, `nowUnix`, `unavailable`.

```
evaluate(...) -> result          // unchanged
applyWatchdog(result)            // unchanged
if !backfilling {
  recovery = openIfNeeded(...)
  recovery = step(...)
  persist recovery
}
applyRecovery(recovery)          // BaselineStore field only
```

`Watchdog.evaluate` signature stays. No new argument on `combine`. Safety-during-quality-fail still opens `wd-safety-…`; F04 may open `no_reference` if there is no long copy — that is correct (thin / wrist-off safety is not a Layer 1 recovery story).

Backfill / `liveAlerts == false`: do **not** open a new F04 record. May **step** an already-open record only if we later want history reconstruction; first cut is **live ticks only** so backfill cannot invent a recovery clock.

### Layer 1 night step (same record, same freeze)

Once per completed civil day, after Layer 1 `evaluate` for the live prompt `asOf` (not the calendar swipe):

- If an F04 record is `open` / `returning` / `unknown`, take tonight’s **clean, habit-matched** native for the matching series.
- `step` with that night as one eligible observation.
- Illness / extra-med night: skip (do not move clocks; do not refresh freeze).

This is how “time back to usual” can finish overnight after the live card already said Watchdog resolved. Still no snapshot write.

### UI (minimal, after engine pins)

- `BaselineStore.eventRecovery: WatchdogEventRecovery?`
- One caption on `WatchdogPlaceholderView` or under “Long-term baseline”:
  - unknown / no_reference / remaining native / hoursToReturn
- Do **not** change `liveOff`, row Off, or HOW OFF.
- Do **not** change “Recovering · two quiet minutes.”

### Pins (new suite, do not weaken V40)

| Pin | Must hold |
|---|---|
| `testEventRecoveryDoesNotChangeSeverityOrNotify` | Same window → same `severity`, `shouldNotify`, `episodeState` with or without a recovery record. |
| `testEventRecoveryFreezeIgnoresWalkingWeek` | Week walks after open; remaining z uses the snapshotted long/freeze. |
| `testEventRecoveryDoesNotWriteLayer1` | Usual hashes / `nLong` unchanged. |
| `testEventRecoveryUnknownOnUnavailable` | Wrist-off / coverage → `unknown`; `returnedUnix` stays nil. |
| `testEventRecoveryIgnoresHeldMinute` | Same civil minute, new wall tick → clocks unchanged. |
| `testEventRecoverySurvivesWatchdogRearm` | After `episodeId` nils, record still `open` until Layer 1 in-band. |
| `testEventRecoveryNoOpenOnBackfill` | `liveAlerts: false` does not create a record. |
| `testEventRecoveryNoReferenceWithoutLongCopy` | No freeze and no `showLong` → `no_reference`, not a population 60 bpm usual. |
| `testEventRecoveryTwoEligibleMinutesToReturn` | One in-band minute is `returning`, not `returned`. |

V40 / statistics / Layer 1 biometric pins stay green with **zero** edits to their assertions.

### File touch list (when implementing)

| File | Change |
|---|---|
| `WatchdogEventRecovery.swift` | **New.** Types + `openIfNeeded` + `step`. |
| `WatchdogService.swift` | After evaluate: open/step/persist if live. |
| `BaselineStore.swift` | Hold last recovery for the card. |
| `WatchdogView.swift` / `BaselineMonitorView.swift` | One caption. |
| `WatchdogEventRecoveryTests.swift` | **New** pins above. |
| `docs/baselines/WATCHDOG.md` + `LAYER1.md` | One paragraph: F04 is a sidecar; Watchdog resolve ≠ usual-return. |
| `Watchdog.swift` / `WatchdogV2.swift` / `LongitudinalBaseline.swift` | **No logic change.** |

---

## 4. Why this is a full F04 / what it must not hinder

Full for the contract sentence: time back to **pre-event** usual, remaining deviation, unknown while missing. F08 / F09 are sibling sidecars (plans below), not part of F04.

Must not hinder:

- Leftover 1–12 (especially 2, 6, 8, 9, 11, 12).
- Charge / Recovery.
- Official convert still deferred; students still not official.
- Treatment trial freeze (`LongitudinalBaselineTrial`) — F04 copies `personalReference`; it does not open a treatment epoch or name a dose.

**Implementation order when asked:** (1) types + pins with no UI, (2) persist + `WatchdogService` hook, (3) night step, (4) one caption, (5) baseline-doc sentence. Stop after (1) if any V40 pin moves.

---

# Add-on plan (not implemented): Symptom feedback — Sep 08 F08

**Status on 4 Oct:** plan only. Usability sidecar. Must not change `confoundsUsual`, severity, notify, or Charge.

**GitHub-facing spec:** [`docs/baselines/ADDONS.md`](baselines/ADDONS.md) (F08 + F09 + F04 locks, persist keys, pins, file lists). Keep this walk and that file in sync.

**Original contract (F08 · Symptom feedback, P1):** Request symptoms, exertion, stress, illness or sensor context **after alerts**. Preserve **event time**, **entry time**, and **reporter**. Missing responses are **not** negative labels.

## Yes — it can be added without changing the engine

The daily log already exists (`LBDayLog` on Baseline). That form is a **civil-day** checklist. Saving it **does** change scoring: `feltIll` / travel / extra med / alcohol / off-typical sleep or diet set `confoundsUsual`, which stops Watchdog learning and drops the Layer 1 night.

F08 is a **different object**: an optional note **on one episode**, after a page. Filling it, skipping it, or saying “I felt fine” must **not** flip today’s `LBDayLog.feltIll` and must **not** open or close an Off.

If we “enhanced the daily log” by auto-checking Felt ill after a severe page, that would **rewrite** leftover 3 / 5 / 6. That is the one implementation that is forbidden.

| Already shipped | F08 add-on |
|---|---|
| Evening reminder at 21:00 (`DayLogReminder`) — “how was the day?” | Prompt after a **sent** severe / safety page — “what was going on just then?” |
| One `LBDayLog` per civil day | One `WatchdogEpisodeAnnotation` per `episodeId` (optional) |
| Missing day log = unmarked = **clean** for usuals (locked) | Missing annotation = `skipped` / nil fields = **not** “no symptoms” |
| Felt ill **does** confound usuals | Annotation illness chip is **display + export only** |

Wearer can still fill the daily log as today. F08 never writes `setDayLog`.

---

## 1. What we understand

After `notifyDelivery` becomes **sent** (request 12 — not on queue, not on deny), the app may show a local **survey** sheet (or a second notification category, not the Watchdog extreme page):

Optional chips / short fields, all `Optional`:

- symptoms (free text or a small fixed list: none / unwell / pain / other — **none is explicit**, not default)
- exertion (rest / light / hard)
- stress (low / high)
- illness (felt off / not) — **annotation only**
- sensor context (loose / charging / just put on / other)

Always stored:

| Field | Source |
|---|---|
| `episodeId` | `carry.episodeId` at the page |
| `eventUnix` | Episode open unix (`wd-{unix}` / first candidate), **not** when they tapped Save |
| `enteredUnix` | When they saved the sheet |
| `reporter` | `wearer` for this cut (caregiver reporter is F02, not this add-on) |
| `deviceId` | Active strap |
| `status` | `pending` · `entered` · `skipped` · `expired` |

**Missing ≠ negative:** `pending` and `skipped` and nil chips must never become `feltIll=false`, `symptoms=none`, or a training label. Replay / future model work must drop rows that are not `entered`.

Expiry: if they do not answer within **24 hours**, `expired`. Do not nag into the next episode. Do not page again.

This is **not** acknowledgement (F02). Saving or skipping does not resolve the episode and does not stamp `notifiedSevereEpisodeId`.

---

## 2. Where a naive hook would break things

| Wrong hook | What breaks |
|---|---|
| `setDayLog(feltIll: true)` when they tap “felt off” | Learning freeze + Layer 1 skip from a **survey**, not the morning log. |
| Prompt on `shouldNotify` / `queued` | Sheet appears when the banner never sent (denied). |
| Use `WatchdogNotifier` extreme path | A survey looks like a second clinical page. Request 8 / 12. |
| Treat skip as “no symptoms” in export | F08 contract broken; false negative labels. |
| Drive `severity` from “I feel fine” | Wearer text clears Off. Request 9. |
| Auto-open daily-log sheet after severe | Mixes civil-day confounders with episode time. |

---

## 3. How we will implement it (when asked)

### New type

`WatchdogEpisodeAnnotation.swift` — Codable, no import of scoring.

Persist: `noop.watchdog.annotations.v1.{deviceId}` — last ~30 annotations, not unbounded.

`WatchdogService` after **sent** callback (same place request 12 stamps `notifiedSevereEpisodeId`):

- if no annotation for this `episodeId`, insert `pending` with `eventUnix` = episode open.
- do **not** insert on backfill / `liveAlerts == false`.

UI: sheet from Baseline / live card when `pending` for current episode. Save → `entered`. Not now → `skipped`. No change to `Watchdog.swift` evaluate.

Notification: optional `UNNotificationCategory` `watchdog-episode-note` (separate from `baseline-day-log` and from the severe banner). Tapping opens the sheet. This is not `shouldNotify`.

### Pins

| Pin | Must hold |
|---|---|
| `testAnnotationDoesNotSetConfoundsUsual` | Entered illness chip; today’s `LBDayLog.confoundsUsual` unchanged unless the wearer saved the daily log separately. |
| `testAnnotationDoesNotChangeSeverity` | Same evaluate before/after annotation. |
| `testSkippedIsNotNegativeLabel` | `skipped` / nil symptoms ≠ `none`. |
| `testEventTimeIsEpisodeOpenNotSave` | `enteredUnix > eventUnix`; event time stays open unix. |
| `testNoAnnotationOnQueuedOrBackfill` | Queue / `liveAlerts false` do not insert `pending`. |
| `testSurveyNotifyIsNotWatchdogPage` | Survey category ≠ extreme notify reason. |

`LBDayLog` **gains no required fields**. Optional future: a link “this day had episode notes” on the daily log **read** view only.

### Files

| File | Change |
|---|---|
| `WatchdogEpisodeAnnotation.swift` | **New** |
| `WatchdogService` / `WatchdogNotifier` sent callback | Insert `pending` after **sent** only |
| `BaselineStore` + small sheet | Enter / skip |
| `Watchdog.swift` / `LBDayLog.confoundsUsual` / `LongitudinalBaseline` | **No logic change** |

---

## 4. Why this is a full F08 / what it must not hinder

Full for: ask after alerts, keep event vs entry vs reporter, missing is not a negative label. Enhances the **story** around the daily log (episode notes + civil-day log) without making the daily log the alert form.

Must not hinder leftover 3 (yesterday confounder), 5 (illness last-OK), 6 (personal-off freeze from **logged** felt-ill only), 8 / 12 (one severe page), Charge, students.

Not F02: no caregiver ack, no quiet hours, no “ack does not resolve” portal.

---

# Add-on plan (not implemented): Clinician export — Sep 08 F09

**Status on 4 Oct:** plan only. Read-only 7-day pack for a physician. Not a caregiver product (F02). Not a new detector.

**GitHub-facing spec:** [`docs/baselines/ADDONS.md`](baselines/ADDONS.md). Ledger fields and export blocks there are the implementation contract.

**Original contract (F09 · Clinician export, P1):** Summarize **seven days** of episodes, deviation burden, baseline comparisons, annotations, and monitored time, with source evidence and algorithm versions.

## Yes — it can be added without changing the engine

Today there is no Watchdog/Layer 1 7-day physician pack. Settings backup (`DataBackup`) is a raw SQLite ZIP. `WeeklyDigestView` is Charge/Today, not this.

F09 **reads** what leftover 1–12 and the F04/F08 sidecars already persist. It must **not** call `evaluate` with `liveAlerts: true`, must **not** write Layer 1 snapshots, and must **not** invent official model names.

The missing piece is a small **episode ledger**. Live `WatchdogCarry` is the **current** episode only and **clears** `episodeId` on rearm. A 7-day export cannot be “whatever is in carry right now.”

---

## 1. What we understand

One wearer-triggered share (Files / Mail / share sheet). Window = last **7 completed civil days** + today so far, on the **active `deviceId`**.

Pack contents (JSON + a one-page human summary; same numbers):

| Block | Source (read) | What it is |
|---|---|---|
| Header | `WatchdogConfig.configVersion`, `units-ad-coreml-v3`, `timesfm3-student-v3`, Layer 1 `param_set`, app build | Versions. Students stay labelled **student**. `forecastSource` never printed as official. |
| Source | Active `deviceId`, family | Request 11. No WHOOP∪Apple mix. |
| Episodes | **New ledger** (below) | Id, open/close unix, max severity, safety?, personal-off?, notify delivery, live vs backfill |
| Deviation burden | Ledger + Layer 1 `LBEvaluation` for those 7 nights | Count of candidate/active/severe minutes (eligible observation minutes, not 20 s ticks). Nights HOW OFF / TRUST **per copy**, never averaged. |
| Baseline comparison | `copy7` vs `copyLong` + freeze if any | Centers, n, last-OK, held? Same units as the card (HR bpm, HRV ms). |
| Annotations | F08 records in window | Event time, entry time, reporter, chips; `pending`/`skipped` shown as missing, not “no” |
| Event recovery | F04 records in window | hoursToReturn / unknown / no_reference |
| Daily logs | `dayLogsByDay` | Civil-day confounders as the wearer logged them |
| Monitored time | Quality gates already on each tick | Minutes with coverage ok and not wrist-off, per day. Unavailable minutes listed, not “recovered.” |
| Evidence pointers | Window start/end, episode ids, `calibrationSource` | Not raw PPG. Not a diagnosis. Banner: not a medical device. |

**Burden** is counted on **measurement civil minutes** that were Off (request 2). Re-reads and held temp do not add minutes.

---

## 2. Where a naive hook would break things

| Wrong hook | What breaks |
|---|---|
| Replay 7 days through `evaluate(liveAlerts: true)` to rebuild the pack | Backfill creates live alerts (request 12). |
| Relabel students “official” on the PDF | Request 10. |
| Average 7-day and 60-day in one “usual” column | Layer 1 hard lock. |
| Count ticks or HR fill as monitored time for temp | Request 9. |
| Export every other strap’s carry | Request 11. |
| Write Layer 1 while generating the pack | Watchdog writes usuals. |
| Treat skipped F08 as symptom-negative in the physician table | F08 contract. |

---

## 3. How we will implement it (when asked)

### Episode ledger (append-only, live only)

`WatchdogEpisodeLedger.swift`

On live tick, when `episodeId` is first created **or** when severity steps candidate→active→severe, **upsert** a row:

`episodeId, deviceId, openedUnix, lastUnix, maxSeverity, safety, personalOff, notifyDelivery, liveAlerts`.

When Watchdog resolves / rearms, set `closedUnix` if still nil. **Do not delete** the row when carry clears.

Cap: 21 days of rows, prune older. Persist `noop.watchdog.episodeLedger.v1.{deviceId}`.

`liveAlerts == false` → **no insert**. History stays history.

This ledger does not change `nextState`. It is a journal of what evaluate already decided.

### Builder

`WatchdogClinicianExport.build(asOf:deviceId:ledger:evaluations:dayLogs:annotations:recovery:monitoredByDay) -> WatchdogClinicianExport`

Pure. No BLE. No notify. No Layer 1 write.

Share from Baseline toolbar: “7-day summary for a clinician.” JSON + short text. Wearer holds the file (F02 portal not in scope).

### Pins

| Pin | Must hold |
|---|---|
| `testExportDoesNotCallLiveAlerts` | Builder does not set `shouldNotify` / `queued`. |
| `testExportDoesNotWriteLayer1` | Usual hashes unchanged. |
| `testExportBurdenUsesEligibleMinutes` | Two ticks, one civil minute → one burden minute. |
| `testExportKeepsTwoCopies` | Week and long printed separately. |
| `testExportMarksStudents` | Version line contains `student`, not `official`. |
| `testExportSkippedAnnotationIsMissing` | Skipped F08 ≠ “no symptoms.” |
| `testExportActiveStrapOnly` | Other `deviceId` ledger rows omitted. |
| `testLedgerIgnoresBackfill` | `liveAlerts false` does not append. |

### Files

| File | Change |
|---|---|
| `WatchdogEpisodeLedger.swift` | **New** journal |
| `WatchdogClinicianExport.swift` | **New** builder |
| `WatchdogService.tick` | Upsert ledger after evaluate (live only) |
| Baseline toolbar share | UI |
| `Watchdog.swift` scoring / `LongitudinalBaseline` | **No logic change** |

Ledger upsert is the only live-loop touch besides F04’s after-evaluate hook. It must be fail-soft (journal error cannot skip persist carry / notify).

---

## 4. Why this is a full F09 / what it must not hinder

Full for a **7-day, versioned, two-copy, annotated** pack a physician can read. Not a hosted caregiver inbox. Not clinical activation (V07–V08 still FALSE).

Must not hinder leftover 1–12, Charge, F04 clocks, F08 missing≠negative.

---

# How the three add-ons sit together (still not implemented)

```
evaluate / Layer 1 / Charge     ← unchanged
        │
        ├─ F04  event recovery     after evaluate; own persist
        ├─ F08  episode annotation after notify **sent**; own persist; never writes LBDayLog
        └─ F09  episode ledger     after evaluate (live); export is read-only share
```

Daily log stays the **civil-day** honesty form. F08 is the **alert-time** note. F09 is the **7-day packet** that includes both plus Watchdog/Layer 1 numbers you already compute.

Suggested build order when asked: **F08 types+pins** (smallest, improves the log story) → **F09 ledger+builder+pins** (physician pack; ledger also helps F04 history) → **F04** (uses ledger episode open time). Any V40 movement stops the cut.

Do not implement until asked.

---

# Display gaps G1–G4 (4 Oct evening)

This write-up lives **only in this daily log**. Do not copy it onto `docs/baselines/RAHUL_HANDOFF.md`.

Chinmay approved: fix **G1** in the display helper. **G2–G4 are not engine bugs** — they are the existing leftover-2 / Layer 1 gates. Changing them would rewrite scoring. `evaluate`, Off, notify, Layer 1 copies, Charge stay as they were.

## G1 — still’s green must not paint a junk key (CODE FIX)

**Logic that stayed:** each phase×activity key has its own `nPresent`. Still 14 minutes stay on still. Artifact does not train still. Walk does not write still.

**What was wrong:** `presentMinutes` used `max(all keys)` when the current `lastBandKey` had no state. After a non-learnable minute, `evaluate` sets `lastBandKey` without writing a band. The card borrowed still’s 14 and kept a green HR band.

**Worked minute:** 9:00–9:15 sit → still HR 14, green. 9:16 artifact → other has 0. Card showed green (bug). After fix: 9:16 Live, no green. 9:17 sit again → still’s 14, green.

**Fix:** if `lastBandKey` is set and missing → **0**. If `lastBandKey` is empty (reopen before first tick) → stored max so we do not reset. File: `WatchdogCarry.presentMinutes`. Does not change `evaluate`.

## G2 — old carry has no per-vital list (NOT a code change)

**This is not “reopen starts at 0.”** Current `v2.{deviceId}` already saves `nPresent`. Force-quit after 14 minutes reloads 14.

**What people notice:** only a **one-time upgrade** from the old single `bandN` flag. New card needs `nPresent[HR]`, `nPresent[temp]`, …. Migrate copies the old lump and leaves the list at zeros, so the first launch after upgrade is Live until 14 new minutes.

**Why we do not write code:** inventing “HR = 14” from a single `bandN` would guess which vitals were ready and could paint a green temp/SpO₂ band that never existed. Safer to stay Live. Next reopen on this build is fine.

## G3 — 30 bins on screen, one stamp toward green (NOT a code change)

**This is leftover 2 working.** The live line may draw all 30 observed minutes on the first tick. The green-band counter stamps only the **last finite civil minute** in that window. Re-reading the same minute does not add 30.

**Worked case:** wear 7:00–7:30, open at 7:30. Line = 30 HR points. Band count = 1. Green after 13 more **new** eligible minutes.

**Why we do not write code:** crediting all 30 bins would break leftover 2 (duplicate counts), let backfill mature a band on launch, and treat walk / wrist-off tail inside the window as still.

## G4 — plot vs judge (NOT a code change)

**This is two Layer 1 gates that already exist.** Week/long **show** = 4 nights (`n7Show` / `nLongShow`). Long **established** (may judge) = 14, or 21 for steps / active minutes / IMU. Chips use show so a ready vital can plot. HOW OFF / alerts still need established + TRUST ≥ 35.

**Worked case:** night 4 sleep HR → week ribbon, chip on, no HOW OFF. Night 14 → long may judge.

**Why we do not write code:** moving “ready” to 14/21 would hide week plots we already promised at 4. Averaging show with established would mix the two copies. The Oct 4 chip bug (hide everyone if one is thin) is already fixed in the store; G4 is just naming the two locks.

Probes: `WatchdogBaselineGapProbeTests`. Re-run 4 Oct evening: 152 selected Watchdog/Layer 1 pins green.

---

# Pre-handoff sweep (4 Oct, later)

New file `WatchdogPreHandoffSweepTests` (15 cases). G1 helper, reopen, leftover-2 ticks, Layer 1 two copies, sleep≠awake-rest, felt-ill, wrist-off, Off doors, notify-once, students, F08/F09 backfill.

**G5 (found, not patched):** `Watchdog.personalReference` treats a long **show** (4 nights in T−60…T−8) as a personal-off ruler (`establishedLong || showLong`). A 90 bpm vs a 60 bpm 8-night median is already personal-off / can become candidate. Layer 1 **judge** lock is 14. Week copy is still ignored (that pin passed).

Worked case: 8 long-window nights at 60, not established. Live still HR 90 → personal-off true today. After 14+ nights the same door is the intended one.

**If we changed it:** `personalReference` would require `establishedLong` (or freeze). That **would** change live Off on thin long copies. Do not do this unless Chinmay wants personal-off to wait for 14. Not on the Rahul handoff page.

No other new engine gaps in this sweep.

---

# Phone: temp graph flicker (G6, 4 Oct)

**What you see:** Temp (and TRUST %) appear, then vanish, then come back. Same tick can look like a new reading.

**Cause (display, not scoring):** `maskStaleChannels` wipes **every** temp bin when the last finite minute is older than 8 minutes (WHOOP temp clock). `evaluate` then called `combine` on that wiped copy. The card’s `horizonTemp` went empty → graph gone. `holdSparseTrust.stillInWindow` also used the wiped tape → TRUST reset even though the sample was still inside the 30-minute strip. Published rule: hold TRUST until that observation **leaves the 30-minute window**.

**What stayed the same:** UniTS / residuals / last-pairs / Off still use the masked window. Fresh last-pair still requires the 8-minute clock. Wrist-off / quality fail still wipe.

**Fix:** `evaluate` keeps the unmasked lookback window for display + sticky TRUST (`stillInWindow`, `horizon*`, observed value). `combine` scores on the masked copy.

Worked case: last temp at minute −10, still in the 30-bin strip. Model mask is empty. Card still draws the last °C and holds the last TRUST until that minute slides off the left of the strip.

Pin: `testStaleTempStillPaintsUntilItLeavesTheWindow` in `WatchdogPreHandoffSweepTests`.

Secondary (not patched): Settings strap model 4 vs 5 can decode temp on different families and also blink. Match the strap you are wearing.

---

# Phone: no painted range after 30–40 min (G7, 4 Oct)

**What you see:** Live HR line + TRUST 65–73, status **Live**, no `Range lo–hi`, no corridor. Caption still asks for more still minutes.

**Cause (display):** `WatchdogView` drew `AreaMark` / range copy only when `callReady` = 14 stamped minutes on the **current** key **and** TRUST ≥ 35. Unknown activity (no IMU / no steps) never stamps. TRUST 65–73 already clears 35. The model already had \(\hat{x} \pm \sigma\); the card hid it.

**What stayed the same:** `evaluate`, `nPresent`, Off, green styling, In range / Off still need 14 + TRUST ≥ 35. Walk still does not train still.

**Fix:** Paint the model corridor and `Range` label whenever there is a hat (or prompt usual) and a width. Gray until the key is ready; green after 14. File: `WatchdogView` only.

Evening UI curves the corridor (smoothstep + Catmull-Rom) so lo/hi follow each minute’s \(\hat{x} \pm \sigma\). After the “yellow in-range is misleading” bug, the **band stays green**; the **live line and every past point** take warning/critical only when that minute is outside **that** band. Scoring unchanged.

---

# Reference: TRUST, ranges / 14 minutes, student models (4 Oct evening)

This is a card-and-engine map for phone testing. It is **not** a scoring change. Do not copy G1–G7 onto `RAHUL_HANDOFF.md`. Leftover 10 (students ≠ official) stays true.

## Student models — names and where they sit

Watchdog ships **two frozen Core ML students**. They are distilled stand-ins, not the Harvard / Google official weights. The card, export banner, and `WatchdogConfig` must keep saying **student**. Relabeling them “official” is leftover 10 failing.

| Role on the phone | Config string | Bundle | What it is | What it is not |
|---|---|---|---|---|
| **Reconstructor** | `WatchdogConfig.modelVersion` = **`units-ad-coreml-v3`** | `UniTS_AD.mlpackage` | Student UniTS-AD. One inference → \(\hat{x}_t\) and \(\sigma_t\) for the 30×6 window. | Official Harvard UniTS. Convert of that checkpoint is still blocked (`aten::Int` / unfold). |
| **Reconstructor fallback** | `fallbackModelVersion` = **`units-ad-recon-v4`** | Swift prior in `UniTSRuntime.priorResidual` | Rest prompt + occupancy lift if Core ML does not load. Same units, no student weights. | Not a third trained model. |
| **Forecast student** | `forecastModelVersion` = **`timesfm3-student-v3`** | `TimesFM3_Student.mlpackage` | Student TimesFM cube: horizons `now+60…now+300`. Source `student` or `hold` (same cube until clocks roll). | Official TimesFM **2.5-200m** (Apache-2.0, convert not shipped). **TimesFM 3.0 must not ship** (license). The bundle name “TimesFM3_Student” is the **student**, not 3.0 weights. |

`present_mask` is a required Core ML input (1 = measured minute). Stale channels are wiped **before** UniTS / TimesFM (`maskStaleChannels`). Missing is nil, not 0.

**Official is unused.** `forecastSource` is `student` | `hold` | `inject`. The `official` token exists so convert pins can land later. Wearer Early stays **shadow** unless source is `official` or `inject`. Students do not page on Early.

No on-device training. `evaluate` never writes Layer 1 7-day / 60-day snapshots. Charge is a different engine.

### How they enter one Watchdog tick

```
quality gate (coverage / freshness / wrist-off)
        │
        ▼
mask stale series ──► UniTS student reconstruct ──► hat + σ  (or Swift prior)
        │                         │
        │                         ├─ last fresh pair per channel
        │                         ├─ residual energy / joint J  → severity, Off, notify
        │                         ├─ TRUST  (U from hat, E from energy)
        │                         └─ painted corridor  hat ± σ  (card)
        │
        └─ TimesFM student (optional) ──► next 1–5 min cube
                  forecastSource = student | hold
                  backcast vs those horizon minutes
                  Wearer Early = shadow on students
```

The **live range on the graph is UniTS (or the prior), not TimesFM.** TimesFM looks ahead; it does not replace \(\hat{x}\) on the 30-minute strip. Layer 1 usuals may tighten the **prompt** into UniTS. They are not the green corridor and are never averaged (week vs long).

---

## TRUST (per vital)

TRUST is “how much to believe this vital’s in-range / off call.” It is **not** health, not a diagnosis, not “how ready the 14-minute band is.”

\[
50U + 35C + 15E
\]

| Term | What it is on the phone |
|---|---|
| **U** (50) | Short-term first. A finite **student (or prior) hat** → \(U = 0.55\). A **shown** Layer 1 usual **replaces** that with that copy’s TRUST 0…1 (awake HR ≠ sleep RHR; copies never averaged). Caps **18 / 28** only when there is no hat and no shown usual. |
| **C** (35) | Fill. HR / RHR / HRV: 30-minute HR coverage, **or** fill of the current rest tail once still has started after effort. Temp / breathing / SpO₂: that series’ **fresh** minutes / 30 — not HR fill, not 1.0 from one held pair. |
| **E** (15) | Evidence vs the reconstruction: \(1 - \text{energy}/\tau\) in range; persist × magnitude if that channel is hot. Energy is vs the **student hat**, not vs Layer 1. |

Floor for calling Off / painting the **green** personal width: **TRUST ≥ 35** (`LongitudinalBaseline.trustHideThreshold`). 65 and 73 are both already above that. An 8-point walk (73 → 65) is usually **C**: sit after a walk and C switches from the full 30-minute window to a short rest tail.

**Sticky sparse TRUST.** Temp, breathing, SpO₂ keep the last computed percent until **that vital’s last observation changes** or it **leaves the 30-minute window** (G6). Occupancy and HR fill must not walk those numbers between samples.

TRUST does **not** increment `nPresent`. It does not unlock TimesFM. It does not write Layer 1.

---

## Ranges and the 14-minute rule

### What the range is

Each minute on the card is

\[
\hat{x}_t \pm \sigma_t
\]

- \(\hat{x}_t\) = student UniTS reconstruction for that minute (or Swift prior). Motion / occupancy **lifts** the hat (walk HR is not judged against sitting HR).
- \(\sigma_t\) = that inference’s half-width (floors in `WatchdogConfig`: HR ~5 bpm scale, etc.), then a small **band scale** after the key is ready.

This is **not** the 14 still minutes averaged into a usual. It is **not** Layer 1 week / 60-day \(k \times\) MAD. It is **not** the TimesFM cube.

### Two paints (G7)

| Paint | When | Meaning |
|---|---|---|
| **Gray / model corridor** | Live tape + a hat (or prompt usual) + a width | Student (or prior) \(\hat{x} \pm \sigma\) for this half-hour. Shown even if the 14-minute counter is 0. |
| **Green / personal width** | 14 **good** minutes on the **current** phase×activity key **and** TRUST ≥ 35 | Still’s typical error \(q\) has an anchor; scale may step ±0.02, clamp 0.75…1.40. Status may say In range / Off. |

`WatchdogView` (G7) always draws the model corridor. Green styling and **In range / Off** still wait for 14 + TRUST ≥ 35. Live **Off** in the engine is still `severity ≥ candidate` or safety or personal-off — not “last point outside the painted band” alone.

### What “14 good minutes” are

On one **phase × family** key (example: afternoon × still):

- Stamp at most **one civil minute** per channel per evaluate (leftover 2). Re-reading the same minute does not add 13.
- Only **learnable** families: still, sleep, held walk/run/cycle/lift. Artifact, unknown, post-workout, felt-ill, personal-off, candidate+ **do not stamp**.
- **Unknown** (no IMU and no steps) never becomes still. That is why 30–40 minutes of wear can show TRUST 65–73 and no green band.
- Each vital has its own `nPresent`. Missing temp is not 0 and does not inherit HR’s 14.
- Those 14 minutes **seed still’s width only**. They do not become the hour’s HR. Walk has its own counter. The live tape is always the last 30 minutes of **whatever was measured**.
- No recency expiry while `v2.{deviceId}` carry is kept. Same civil minute cannot stamp twice. `nCap` only slows the EMA.

After still is ready, **any** minute still goes into UniTS + residual + Off. Only more **still** minutes keep nudging still’s \(\sigma\).

### Still (device class)

Not a medical rest state. WHOOP step class + IMU + occupancy → `WatchdogActivityRuntime.pick`. After G9: occupancy &lt; **0.32** and IMU dyn &lt; **0.22** stay still/stand (chair fidget). LiveTail rest until occ ≥ 0.32. Quiet unknown + learnable still/sleep uses family **still**. Walk with steps or occ ≥ 0.32 is still walk.

### Phone color (evening, after the misleading-color bugs)

1. First pass colored the **live line** by in/out — looked like the band was yellow while in range. Reverted.
2. Next pass grayed the corridor — “ranges don’t display the color at all.” Restored a **green** fill.
3. Final: **green band = model corridor only.** Width = residual σ, or occupancy / \|hat\| prior when student σ is a flat rail (`liveAdaptiveScale` via `paintRanges`). Companion hats can widen **paint only** while occupancy is up (HRV drop → HR, HR lift → HRV/resp/temp). Sitting still does not borrow width. Paint is **never narrower** than Off σ.
4. Live line + **all history points** stay on the strip. A point is warning/critical only vs **that minute’s** \(\hat{x}\pm\sigma\).

Off / persist / learning still use residual σ. TimesFM is not this line.

---

# Temp: personal-setpoint skin, not fake core (G8, 4 Oct)

Chinmay asked the live temp baseline to follow **body-temp logic** rather than a wrist-vs-33 rail.

**Cannot do:** convert WHOOP wrist °C to core / “body temp” (no +4 °C, no fever scale). That would be a different quantity and a medical lie.

**What changed (scoring + card, still wrist °C):**

- Center is a **personal setpoint**: Layer 1 sleep temp seeds if shown; else the **first finite skin sample is the center**. This half-hour then updates it (`tempCenterAlpha = 0.28`). Occupancy still **lowers** expected skin.
- Width floor **1.0 °C** (was 0.35). First 32.2 vs population 33 is inside the rail.
- Student UniTS hat that is stuck on the prompt (`span < 0.15 °C`) is replaced by this prior — same pattern as live HRV.
- Card caption: “Wrist skin · personal usual.” Not renamed Body temp.

Files: `WatchdogConfig`, `UniTSRuntime.reconstructTemp` / `liveTempHat`, `WATCHDOG.md` temp row, `WatchdogView` caption.

Pin: `testTempHatIsPersonalSkinNotPopulation33`.

---

# 14-minute lock — exact definition (4 Oct evening)

A minute counts toward green **only if every line below is true**. There is no “looks still enough.” Wall-clock wear does not count.

**One sentence:** a **new civil minute** of **that vital**, on a **learnable still/sleep/held-workout** tick, with **IMU or steps** so the class is not unknown, while the half-hour is **quiet** (not Off, not felt-ill, not post-workout).

## Must all be true (AND)

1. **Quality window passed** — evaluate is live, not Waiting / wrist-off.
2. **Activity class is still, stand, walk, run, cycle, or lift** from IMU and/or WHOOP steps. **No IMU and no steps → `unknown` → family `.other` → stamp is skipped.** Sitting on the couch without those streams never increments.
3. **Event label is one of:** `normal_still_awake`, `normal_sleep`, `workout_walk`, `workout_run`, `workout_cycle`, `workout_lift`. Artifact, mixed, abnormal, forecast-only, post-workout, safety — no.
4. **Family is not `.other`.** Unknown and artifact map to `.other`.
5. **Not safety, not felt-ill confound, not personal-off, not candidate/active/severe.**
6. **Not inside 20 minutes after a workout end.**
7. **Reconstruction is quiet:** joint residual `reconJ < 1.0` (`tNote`). **HR energy also &lt; 1.0** — a slightly off HR blocks the stamp for *every* vital that tick.
8. **No channel’s |r| ≥ 2.5** (`residualCap`).
9. **That vital has a fresh last pair** (`present[k]`). No new temp sample → temp does not get +1 even if HR does.
10. **New civil minute** for that vital vs `lastMinute[k]`. Same 10:14 read again at 10:14:40 → 0.

## Counters (why 40 minutes can still be 0)

| Split | Effect |
|---|---|
| **Per vital** | HR 14 ≠ temp 14. Caption “N more for heart rate” is HR only. |
| **Per phase × family** | `morning×still` ≠ `midday×still` ≠ `morning×walk`. Clock hour: late &lt;5, morning &lt;12, midday &lt;17, evening, or sleep. Crossing noon **starts a new 14**. |
| **Green reads `lastBandKey`** | Sit 14, then unknown/walk → card reads the new key (often 0). Still’s 14 are still stored; they are not shown. |

## What you can do on the phone that *does* count

Sit or lie still **and** the strap is sending **steps class 0 and/or IMU**, quality CURRENT, no felt-ill, no workout in the last 20 min, HR looking like the hat (not a walk residual). Then **one** new clock-minute of HR (or of temp if a temp row arrived) adds 1 to that key.

If IMU/steps are missing, **zero minutes will ever lock.** That is the current definition, not a vague “good minute.” It is why 30–40 minutes of wear never turns the band green.

---

# Chair still never stamped (G9, 4 Oct)

Chinmay sat still ~1 hour; `nPresent` stayed 0. IMU/occupancy at **0.15–0.22** (typing, breathing, chair shift) was **walk** or **effort**, or no IMU → **unknown → `.other`** so the 14-minute lock never moved.

**What changed (lock only, Off/severity unchanged):**

- Desk occupancy **&lt; 0.32** and IMU dyn **&lt; 0.22** → still/stand, not walk (`chairStillOccupancy`).
- Still/stand tail stays **rest** until occupancy **0.32** (was 0.15).
- Quiet **unknown** (no IMU, or unlabeled rest) with a learnable still/sleep label uses band family **still**, not `.other`.

Walk with steps or occ ≥ 0.32 is still walk. Crossing noon is still a new key.

Pin: `testChairFidgetIsStillAndUnknownRestCountsForTheBand`.

---

# Multivariate students vs Off (4 Oct evening)

Students **are** 6×30 tensors. Off does **not** call UniTS/TimesFM “is this severe?” It scores last-minute \((obs-\hat{x})/\sigma\) per vital, then `severityJoint` (sum, cap 1, RHR out). TimesFM student **cannot** severe-notify.

A first pass put companion width into residual σ (would move Off). **Reverted.** Companion / occupancy prior widen the **card corridor only** (`paintRanges`). Off, persist, learning, personal-off stay residual σ. Paint never narrower than that score.

Tried “model Off needs two vitals” **inside** `severity`. That merged the six Watchdogs. **Reverted.** Holistic page is a **sidecar** (`WatchdogPhysiologyAlert`), not a new Off number.

Pins: `testCompanionWidthUsesOtherHatsOnlyWithMotion`, `testPaintRangeNeverNarrowerThanScoreScale`.

---

# Physiology alert is not a per-vital Watchdog (4 Oct)

Each graph / hat / σ stays its own Watchdog. Row Off = **that** vital vs **that** band (after 14 + TRUST 35). One yellow HR does not rewrite the other five.

`WatchdogPhysiologyAlert` only **reads** those in/out labels (`|r|` vs residual σ, RHR out). `evaluate` then ANDs `shouldNotify` with `physiologyOff` (or safety).

**Page (extreme only):**

| Pages | Does not page |
|---|---|
| Still-wrist safety extrema | One vital, even if loud |
| Three vitals outside **and** two of those at `tActive` (1.6) | Two vitals (even both loud) |
| First severe of an episode, after sent (leftover 8) | Three mild `tNote` outsides |
| | Personal-off alone |
| | Quiet rest, backfill, `liveAlerts: false` |
| | TimesFM student / looking ahead |

File: `WatchdogPhysiology.swift`. Pins: `WatchdogPhysiologyAlertTests` (8), Statistics contract one-vs-two-vs-safety.

Leftovers 1–10: V40 + Prime handover live + Statistics still green after this sidecar.

---

# After-bug closeout (4 Oct night)

Phone bugs after leftover 1–12, then what shipped. **Do not copy G1–G9 or this page onto `RAHUL_HANDOFF.md`.** Prime reads `docs/baselines/PRIME_HANDOVER.md` (updated tonight) + `WATCHDOG.md`.

## Bugs → fixes

| Seen on the phone | Code | Status |
|---|---|---|
| Long-term card hid every vital when the selected series was not ready | `BaselineStore.preferReadySeries` except explicit `selectSeries` | Shipped (morning commit) |
| No live graph until green at 14 | Live line as soon as a finite sample; green after 14 | Shipped |
| 20–30 min, no live baseline; empty breathing / SpO₂ | Quality 80% + freshness, or WHOOP 5 v18 has no `resp_rate_raw` / scored SpO₂ % | Ingest / quality, not a new usual |
| Temp graph flicker TRUST 73↔65 | G6: mask stale for models; paint/TRUST from unmasked 30 until the sample leaves | Shipped |
| No Range after 30–40 min | G7: always paint corridor + Range label; In range/Off still 14+TRUST 35 | Shipped |
| Yellow in-range / then gray corridor | Band green only; history points colored vs that minute’s band | Shipped |
| First temp outside 33±0.35 | G8: personal skin setpoint, 1.0 °C, not core | Shipped |
| Chair hour, 0/14 | G9: chair still 0.32 / 0.22; unknown rest can stamp still | Shipped |
| Flat HR/temp rails vs moving HRV | Paint uses occupancy / \|hat\| when student σ is flat; HRV was already this | Shipped (display) |
| Wanted multivariate Off on one graph | Six Watchdogs stay separate; `WatchdogPhysiologyAlert` pages only extreme clusters | Shipped |

## G-list (this file only)

| Id | What | Scoring? |
|---|---|---|
| G1 | `presentMinutes` on `lastBandKey`; empty key → max stored | Display |
| G2–G4 | Documented, not patched | — |
| G5 | Personal-off on `showLong` (documented, optional) | Existing |
| G6 | Stale-mask models; display until leave window | TRUST paint |
| G7 | Always show model Range | Display |
| G8 | Personal skin temp hat | Hat + card |
| G9 | Chair-still lock | Lock only |
| Paint | `paintRanges` / companion / `liveAdaptiveScale` | Display only |
| Phys | Extreme multi-vital page sidecar | Notify AND only |

## Leftovers 1–12 after the evening

Re-ran `WatchdogV40CloseoutTests` (38), `WatchdogPrimeHandoverLiveTests`, `WatchdogStatisticsContractTests`. Green. 11–12 (hold forecast clocks, `present_mask` / held minute) stay in V40.

## Branch

`nara-baseline-watchdog` pushed (not `main`). Daily log stays gitignored. Prime tonight: `PRIME_HANDOVER.md` §2 “4 Oct evening” + `WatchdogPhysiologyAlertTests`.

