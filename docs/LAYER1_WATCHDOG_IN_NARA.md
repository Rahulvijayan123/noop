# Watchdog and Baseline in Nara

This note is for review of branch `nara-baseline-watchdog` on `csdudi/Nara-App`, pull request https://github.com/Rahulvijayan123/Nara-App/pull/2.

It has two parts. The first explains how Watchdog and Baseline were fitted into the current Nara app, including the features that app already had. The second explains the scoring logic of each engine.

## Part 1. How this sits in the current app

Nara already had three ideas that use similar words. This work does not replace them.

| Already in the app | What it is | What this work did |
|---|---|---|
| Charge | Night recovery score. The homepage ring labeled Baseline still shows this number. | Left the score, the ring number, and the hosted worker alone. |
| Heart-rate reserve | The homepage ring labeled Watchdog. It is how much of the gap from resting heart rate to max heart rate the latest heart rate is using. | Left the number alone. Tapping the ring or the word now opens the live Watchdog graphs. |
| Activity, sleep, and gait work already in this version | Activity classification, the day timeline, ElderNet gait, the sleep tab, and Sentry. | Not rewritten. Watchdog and Baseline read streams those features already store. |

Watchdog and Baseline are two more engines. They read the same strap samples. They do not share a usual, a green range, or a trust number with Charge or with each other, and they are never averaged.

| Engine | Question | Where the wearer sees it |
|---|---|---|
| Baseline (Layer 1) | What is usual for this person over days and nights? | Day-and-night usuals: a 7-day copy and a longer copy. |
| Watchdog | Does the last half-hour look like this person? | Six live graphs: heart rate, resting heart rate, HRV, skin temperature, breathing, and SpO₂. |

### Where a tap goes

- Homepage **Baseline** ring or word: only the day-and-night usuals.
- Homepage **Watchdog** ring or word: only the last-30-minute graphs.
- **Monitor** tab: Watchdog, then Baseline, then the trends that were already on that tab.
- Settings → **Day & night usuals**: the Monitor page.
- Settings → **Logged treatment start**: the only control that restarts the long Baseline usual. A drug is never named. The app does not infer that a treatment started.
- macOS uses the same Settings links. Baseline and treatment open in a sheet.

Recovery on the homepage is unchanged.

### Signals this version of the app already had

The tick runs on the phone about every 20 seconds after the repository has loaded. It reads the active strap. It does not start a new capture.

- **Heart rate.** Stored samples, plus the live packet. A packet advances freshness even when the bpm does not change. A contact-not-detected packet does not.
- **R–R intervals.** These are the beats behind HRV, and behind breathing when the strap has no respiration waveform.
- **Skin temperature.** The same family-aware conversion the day chart uses (centidegrees on a 5.0/MG).
- **SpO₂.** A percent already stored on the optical row is used. A 5.0/MG writes its own percent in a history byte while the wearer is asleep and still. Watchdog reads that byte, the same source the day chart uses. A daytime strip can be empty because the strap does not write that percent while the wearer is awake. The nightly SpO₂ average is not a usual and is not a reason to notify.
- **Breathing.** If the strap stored a respiration waveform, Watchdog uses it. A 5.0/MG does not. Watchdog then uses the same heartbeat-rhythm estimate the day chart already draws (`SleepStager.rollingRespRate`).
- **Steps.** The strap’s own class on each step sample: still, walk, or run.
- **IMU.** The motion lane is the stored 1 Hz gravity sample (x, y, z, and dynamic acceleration when the strap sent it). If dynamic acceleration is missing, or a second exists only in the 100 Hz capture file, that second is filled from the file: one sample per second, not the raw 100 Hz tensor. The 100 Hz writer was not changed. A logged bicep or other placement drops the wrist IMU. Wrist and unknown placement keep it.
- **Sleep.** Scored sleep sessions, plus the strap’s own asleep code (state 2). A gap longer than 90 seconds starts a new interval. Those minutes are not trained as awake rest. Sleep staging and the sleep tab were not changed.
- **Phone activity context.** The heart-rate page already saves a day document of posture and locomotion. Watchdog may show that label as a caption. The caption is not an input to the Off check and it is not a Baseline series.
- **Placement.** The placement the wearer already logged in Settings.

HART, the worker’s activity checkpoint, is not used. It does not set Off, a notification, or a Baseline center.

### What a tick does, and what it refuses to do

`AppModel` owns a `BaselineStore` and a `WatchdogService`. After the first data refresh, the service starts. Each tick builds a 30-minute window, calls `Watchdog.evaluate`, and updates the card. If the minute is allowed to train, the same window is ingested into the on-device day tape that Baseline reads later. `evaluate` itself never writes the 7-day or 60-day snapshots.

A background refresh on iOS can run the same tick. It may skip the forecast model. It still runs the reconstruction and the safety check. It stops if iOS expires the task.

There is no on-device training. The model files in the app are the existing students: `units-ad-coreml-v3` and `timesfm3-student-v3`. Official UniTS weights and TimesFM 3.0 weights are not shipped.

Wrist-off stays unavailable. It is not guessed back from a quiet IMU.

## Part 2. The logic

### Baseline (Layer 1)

Baseline answers one question: given the days this person has already lived, what is usual, and how wide is that usual.

Parameter set `v1.review`. Changing a constant would be a new parameter set. Old snapshots are not edited in place.

Each series is a day-level number, not a minute. The main ones that already have a column on the daily row are sleep resting heart rate, sleep HRV, sleep wrist temperature, sleep respiration, sleep SpO₂ mean, and waking steps. Awake rest, awake active, and all-day heart rate and HRV are built from the minute tape (still minutes versus moving minutes). Waking IMU energy is the movement of the wrist, in unique minutes, and that day trains only when coverage is at least 60 minutes. Charge is not a series.

HRV is stored as the natural log of RMSSD. The card shows milliseconds.

Two copies are kept, and they are not averaged:

- **7-day copy.** A finite exponential average of the last 7 completed days. The smoothing weight is `2 / (7 + 1) = 0.25`. It is shown after 4 nights in the week. Trust is hidden under 35. The 7-day copy is never the comparison Watchdog uses for personal-off.
- **Long copy.** The median and MAD of days from 60 days ago through 8 days ago (a 7-day gap, so the newest week is not inside the long copy). The band is 2 MAD, with the usual MAD scale 1.4826. It is shown after 14 days for the sleep series, and after 21 days for steps, active minutes, and IMU energy. A copy older than 14 days without a new update is stale.

A felt-ill mark freezes a “when well” snapshot. Watchdog may compare against that frozen copy for personal-off. Felt-ill does not restart the long epoch. The only event that restarts the long epoch is a logged treatment start, with a 7-day wash-in. The app never names the drug.

`Watchdog.evaluate` does not write either copy. The day tape is ingested only after evaluate, and only when that minute is allowed to train (not while the window is confounded, not from a walking minute into a still series, and not across an open sleep interval into awake rest).

### Watchdog

Watchdog answers a different question: in the last 30 one-minute bins, is this minute inside the range that was expected for this person, in this context.

The window is 30 minutes. Empty minutes stay empty. A missing sample is not filled with zero. The present-mask tells the model which minutes were actually measured.

Six channels, each with its own graph:

1. Heart rate
2. Resting heart rate (still minutes only)
3. HRV (RMSSD)
4. Wrist skin temperature
5. Breathing
6. SpO₂, when a percent is present

#### What “Off” means

The card says Off when any one of these is true:

- The joint residual is severe (the reconstruction and, when it runs, the forecast agree that several minutes are far from the expected line, and that has persisted).
- A safety bound fires.
- Personal-off fires: native heart rate or HRV is outside the frozen felt-ill copy, or outside the shown 60-day copy. Never the 7-day copy. Never the model’s own hat.

A separate physiology page can open only when safety fires, or when at least 3 vitals are outside and at least 2 of those are at the active threshold. That page does not rename the event as a diagnosis, and it does not name a drug.

The painted corridor on the graph is not the same thing as Off. A point can sit outside the gray band before the personal green width exists. The green personal width for a channel waits for 14 good still minutes of that channel, and the status word Off waits for the band to be ready and for trust of at least 35. Before that, a live trace is labeled Live.

#### IMU labels

Each minute gets one label from the wrist IMU and the strap step class. The phone activity caption is not this label.

The label is one of: still, standing, walk, run, cycle-like, lifting, motion artifact, or unknown.

- No IMU and no steps: unknown. Unknown is not rest.
- Strap step class walk or run, when enough step samples exist: walk or run.
- Chair-still: not a step sport, occupancy under 0.32, dynamic acceleration under 0.22 g, and the variation of that acceleration stays low. Those two constants were not changed.
- Otherwise the amount and the pattern of motion choose walk, run, cycle-like, lifting, or artifact.

Occupancy is dynamic acceleration divided by 0.4 g when that value exists, otherwise how far the gravity vector is from 1 g. A walk keeps gravity near 1 g, so the dynamic value is what makes the walk visible. That is why a missing dynamic value is filled from the 100 Hz file.

A walking, running, cycle, lifting, or artifact minute does not enter resting heart rate. A minute with heart rate but no motion sample does not enter it either. Missing motion is not treated as sitting still.

#### Heart rate and resting heart rate

HRV and skin temperature already replace a flat model line with a short-term center from this half-hour. Heart rate and resting heart rate now use that same door.

- The rest center follows still minutes in this window. A shown Baseline usual only seeds it. Effort minutes do not pull it up.
- If the student model’s heart-rate line barely moves (less than 4 bpm across the strip), the graph uses this short-term center instead of the flat line.
- On top of that center, the expected heart rate rises with the IMU label. Still and standing add nothing. Walk, run, cycle, and lifting have a floor (0.32, 0.85, 0.55, 0.42). If the measured motion is stronger than that floor, the expected line uses the measured motion. At full effort the lift is about half of this person’s rest heart rate. The painted width widens with the same motion. The floor of the width is ±5 bpm.
- Resting heart rate is only the still minutes. Its center follows those minutes. It is not a flat overnight number drawn across a walk.

#### The other four channels

- **HRV.** A slow center of this half-hour’s RMSSD, then a drop when the minute is effort. A sleep usual may seed the first minutes. It is not a flat line for the whole strip.
- **Skin temperature.** This person’s wrist setpoint, updated by this window. Activity lowers the expected skin temperature. It is wrist skin, not core temperature.
- **Breathing.** This person’s rest rate, plus a rise with occupancy. The samples are the waveform when the strap has one, otherwise the heartbeat-rhythm estimate.
- **SpO₂.** The expected line is this person’s usual, or the population prior until a copy exists. Motion is not treated as a predicted desaturation. The points are percents only.

#### Students

UniTS-AD reconstructs the six channels and a scale for each. TimesFM is the forecast sidecar. Both are the student checkpoints already in the package. If the UniTS line for HRV or temperature barely moves, the short-term prior above is what the card draws. The same replacement now applies to heart rate and resting heart rate. The forecast may be skipped on a background tick. Safety and the reconstruction still run.

### What was deliberately left out

Charge and the hosted night score. The 100 Hz capture path. The activity, sleep, and ElderNet screens and their own scores. Raw PPG waveforms. The nightly SpO₂ candidate average. On-wrist bits inside the sleep-state byte. Collector “user confirmed” intervals. Official TimesFM 3.0 and official UniTS weights. HART as a voter.
