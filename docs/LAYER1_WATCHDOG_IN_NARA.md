# Watchdog and Baseline in Nara

This note is for review of branch `nara-baseline-watchdog` on `csdudi/Nara-App`. It describes what was added on top of the current Nara app, where a wearer sees it, and what was left alone.

Watchdog and Baseline answer different questions from Charge. They share the strap’s samples. They do not share usuals, ranges, or trust, and they are never averaged together.

| | Question | What the wearer sees |
|---|---|---|
| Charge | How recovered is this night? | The homepage ring labeled Baseline still shows Charge. The number was not changed. |
| Baseline (Layer 1) | What is usual over days and nights? | Day-and-night usuals: this week, and a longer copy. |
| Watchdog | What does the last half-hour look like for this person? | Six live graphs: heart rate, resting heart rate, HRV, skin temperature, breathing, and SpO₂. |

A drug is never named. The only treatment that restarts the long usual is one the wearer logs. There is no on-device training. Wrist-off stays unavailable. The model files in the app are the existing students (`units-ad-coreml-v3` and `timesfm3-student-v3`). Official UniTS and TimesFM 3.0 weights are not shipped.

## Where it shows up

- Homepage **Baseline** ring or word: only the day-and-night usuals. Not Watchdog, and not the trends.
- Homepage **Watchdog** ring or word: only the last-30-minute graphs. The ring number is still heart-rate reserve.
- **Monitor** tab: Watchdog, then Baseline, then the existing trends. That page is unchanged by the homepage taps.
- Settings → **Day & night usuals**: the Monitor page (all three sections).
- Settings → **Logged treatment start**: the only control that restarts the long usual.
- macOS uses the same Settings links. Baseline and treatment open in a sheet.

Recovery on the homepage is unchanged.

## What was fitted to this version of the app

The engines were brought onto the current Nara tree (activity classification, sleep screens, ElderNet, and the rest of that update). Those screens and their scoring were not rewritten. Watchdog and Baseline read signals that tree already stores.

- **Heart rate and resting heart rate.** If the model line is flat, the corridor follows this half-hour, the same way HRV and skin temperature already do. Still minutes move the rest center. A walk does not. The lift above that center still comes from the IMU label (still, walk, run, cycle-like, lifting, artifact) and from how hard the wrist is moving. Chair-still thresholds were not changed. A walking minute does not enter resting heart rate.
- **IMU.** Stored 1 Hz gravity is still the motion lane. A missing dynamic-acceleration value, or a second that exists only in the 100 Hz capture, is filled from that capture. The 100 Hz files are not scored as raw tensors, and the capture path was not rewritten. A logged bicep or other placement still drops the wrist IMU. The phone activity caption is a caption only. It is not an IMU label and it is not used in the Off check.
- **Breathing.** A strap with a respiration waveform still uses it. A 5.0/MG has no waveform, so Watchdog uses the same heartbeat-rhythm estimate the day chart already draws.
- **SpO₂.** A percent already stored on the optical row is used. A 5.0/MG writes its own percent in the history byte while the wearer is asleep and still. Watchdog reads that byte. A daytime strip can still be empty, because the strap does not write that percent while the wearer is awake.
- **Sleep.** The strap’s asleep code is merged into the sleep intervals Watchdog already had, so an open night is not trained as awake rest. Sleep staging itself is unchanged.
- **Live heart rate.** A packet advances Watchdog freshness even when the bpm does not change. A contact-not-detected packet does not.

`Watchdog.evaluate` does not write the 7-day or 60-day Baseline snapshots.

## What was not changed

Charge, the hosted night score, and the worker path that publishes it. The 100 Hz IMU capture. The new activity, sleep, and ElderNet screens. The homepage ring numbers (Charge, heart-rate reserve, Recovery).

## How to look

1. Open Today. Tap **Baseline**. The page is the usuals only.
2. Go back. Tap **Watchdog**. The page is the six live graphs only.
3. Open the Monitor tab. Watchdog, Baseline, and trends are on one page.
4. Settings → Logged treatment start is the treatment log, separate from both graphs.
