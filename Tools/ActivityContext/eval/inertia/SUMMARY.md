# Inertia-1 heads — evaluation summary

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

Status: real Inertia-1 evaluation **BLOCKED** (no public checkpoint; `pipeline_cli embed --encoder inertia-1/ar_transformer-small/30s@20hz` fails with `model_missing: blocked: no checkpoint`). The bundles below use stand-in encoders (`standin:handcrafted-stats-v1` = engineered baseline, `standin:nara-imu-feat-1-accel` = what the decoder already sees, `standin:inertia-arch-random-init/ar_transformer-small/seed0` = negative control). All are `evidence_tier_max = shadow`.

## Experiments

| experiment | role | encoder | window | training datasets | bundle | evaluated sha256 | sealed sha256 | git commit | evaluated |
|---|---|---|---|---|---|---|---|---|---|
| ood-hc | ood_bench | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-ood-hc` | `811ef6e2a28314d4` | `1a5110336832634b` | `a424d207e1c4` | yes (n=3) |
| ood-nf | ood_bench | nf | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-ood-nf` | `bb828ffb3235147e` | `5916b911e7d06282` | `a424d207e1c4` | yes (n=3) |
| ood-art | ood_bench | art | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-ood-art` | `3784c9c5bdcc7085` | `9ff173b2a3eac8be` | `a424d207e1c4` | yes (n=3) |
| primary-hc | primary | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-primary-hc` | `f03f85acf7e06e9b` | `3fb1ae3e75c8b993` | `a424d207e1c4` | yes (n=3) |
| primary-nf | primary | nf | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-primary-nf` | `e8a34e919d5d19b5` | `736eb93e440fa5da` | `a424d207e1c4` | yes (n=3) |
| primary-art | primary | art | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-primary-art` | `c0eb1a045f749df3` | `1b8fadcc1521709a` | `a424d207e1c4` | yes (n=2) |
| linear-hc | arch | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-linear-hc` | `6dac0eddb1f9875c` | `55ec82170e80c93c` | `a424d207e1c4` | yes (n=3) |
| mlp-hc | arch | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-mlp-hc` | `97115d4109c57015` | `30e84df65b21ab31` | `a424d207e1c4` | yes (n=3) |
| linear-art | arch | art | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-linear-art` | `f0a839da6c42f169` | `20fe1b0a40e86883` | `a424d207e1c4` | yes (n=2) |
| mlp-art | arch | art | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-mlp-art` | `8df3f9f10866715e` | `813cf70ad14be481` | `a424d207e1c4` | yes (n=2) |
| linear-nf | arch | nf | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-linear-nf` | `ac609c4fd7435a28` | `1f001e014c71bb3c` | `a424d207e1c4` | yes (n=3) |
| w10-hc | window | hc | w10 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-w10-hc` | `1cd36c60fda273ab` | `e57e9f8a7c661bf2` | `a424d207e1c4` | yes (n=3) |
| lodo-noc24-hc | lodo | hc | w30 | wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-lodo-noc24-hc` | `62b9566ced026d1e` | `af46646f8e6721dc` | `a424d207e1c4` | yes (n=3) |
| lodo-c24only-hc | lodo | hc | w30 | capture24 | `shadow-lodo-c24only-hc` | `0af9f28cbb271e4e` | `59970578b019ff8e` | `a424d207e1c4` | yes (n=3) |
| lodo-nohhar-hc | lodo | hc | w30 | capture24, wisdm2019_watch, pamap2, mhealth, opportunity | `shadow-lodo-nohhar-hc` | `cb2cd3200eaace91` | `2bfa1d9f339a156a` | `a424d207e1c4` | yes (n=3) |
| seed1-hc | seed | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-seed1-hc` | `1141f03851e3f4e0` | `f91941703727b82d` | `a424d207e1c4` | yes (n=3) |
| seed2-hc | seed | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-seed2-hc` | `796029c9cb29261c` | `9128922bb4810dd7` | `a424d207e1c4` | yes (n=3) |
| primary-inertia1 | primary | inertia1 | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-primary-inertia1` | `` | `–` | `–` | blocked |

Every evaluated bundle is SEALED: `test_gate.json` (per class val status, pooled + per-dataset test gates, final status, recomputed merges) is listed in the bundle's manifest, so the served artifact carries the one-shot gate; `load_bundle` refuses a gate that promotes or was made for another bundle.

## Headline (pooled test, subject-cluster bootstrap 95% CI)

| experiment | head | n | macro-F1 [95% CI] | macro-F1 present-only (legacy) | balanced acc [95% CI] | NLL | Brier | ECE-15 | majority macro-F1 | predicted while absent |
|---|---|---|---|---|---|---|---|---|---|---|
| primary-hc | posture | 74,475 | 0.657 [0.638, 0.676] | 0.657 [0.638, 0.676] | 0.645 [0.629, 0.661] | 0.389 | 0.216 | 0.024 | 0.250 | – |
| primary-hc | locomotion | 91,653 | 0.678 [0.642, 0.706] | 0.678 [0.642, 0.706] | 0.640 [0.595, 0.685] | 0.375 | 0.180 | 0.022 | 0.127 | – |
| primary-hc | arm_behavior | 20,972 | 0.422 [0.375, 0.486] | 0.422 [0.375, 0.486] | 0.434 [0.392, 0.546] | 0.705 | 0.461 | 0.072 | 0.262 | – |
| primary-nf | posture | 74,475 | 0.598 [0.583, 0.611] | 0.598 [0.583, 0.611] | 0.596 [0.582, 0.609] | 0.484 | 0.262 | 0.027 | 0.250 | – |
| primary-nf | locomotion | 91,653 | 0.417 [0.380, 0.439] | 0.417 [0.380, 0.439] | 0.422 [0.397, 0.447] | 0.475 | 0.229 | 0.015 | 0.127 | – |
| primary-nf | arm_behavior | 20,972 | 0.353 [0.307, 0.422] | 0.353 [0.307, 0.422] | 0.395 [0.362, 0.493] | 0.738 | 0.478 | 0.068 | 0.262 | – |
| primary-art | posture | 74,475 | 0.460 [0.436, 0.488] | 0.460 [0.436, 0.488] | 0.473 [0.448, 0.502] | 0.704 | 0.432 | 0.108 | 0.250 | – |
| primary-art | locomotion | 91,653 | 0.254 [0.219, 0.277] | 0.254 [0.219, 0.277] | 0.253 [0.212, 0.288] | 0.657 | 0.310 | 0.052 | 0.127 | – |
| primary-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.740 | 0.470 | 0.056 | 0.262 | – |
| linear-hc | posture | 74,475 | 0.618 [0.605, 0.628] | 0.618 [0.605, 0.628] | 0.617 [0.605, 0.627] | 0.413 | 0.231 | 0.014 | 0.250 | – |
| linear-hc | locomotion | 91,653 | 0.620 [0.572, 0.658] | 0.620 [0.572, 0.658] | 0.564 [0.506, 0.616] | 0.424 | 0.198 | 0.037 | 0.127 | – |
| linear-hc | arm_behavior | 20,972 | 0.422 [0.375, 0.486] | 0.422 [0.375, 0.486] | 0.434 [0.392, 0.546] | 0.705 | 0.461 | 0.072 | 0.262 | – |
| mlp-hc | posture | 74,475 | 0.657 [0.638, 0.676] | 0.657 [0.638, 0.676] | 0.645 [0.629, 0.661] | 0.389 | 0.216 | 0.024 | 0.250 | – |
| mlp-hc | locomotion | 91,653 | 0.678 [0.642, 0.706] | 0.678 [0.642, 0.706] | 0.640 [0.595, 0.685] | 0.375 | 0.180 | 0.022 | 0.127 | – |
| mlp-hc | arm_behavior | 20,972 | 0.416 [0.372, 0.462] | 0.416 [0.372, 0.462] | 0.471 [0.427, 0.566] | 0.665 | 0.441 | 0.066 | 0.262 | – |
| linear-art | posture | 74,475 | 0.432 [0.411, 0.455] | 0.432 [0.411, 0.455] | 0.445 [0.422, 0.472] | 0.742 | 0.464 | 0.072 | 0.250 | – |
| linear-art | locomotion | 91,653 | 0.232 [0.193, 0.258] | 0.232 [0.193, 0.258] | 0.235 [0.193, 0.273] | 0.690 | 0.318 | 0.040 | 0.127 | – |
| linear-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.727 | 0.462 | 0.085 | 0.262 | – |
| mlp-art | posture | 74,475 | 0.460 [0.436, 0.488] | 0.460 [0.436, 0.488] | 0.473 [0.448, 0.502] | 0.704 | 0.432 | 0.108 | 0.250 | – |
| mlp-art | locomotion | 91,653 | 0.254 [0.219, 0.277] | 0.254 [0.219, 0.277] | 0.253 [0.212, 0.288] | 0.657 | 0.310 | 0.052 | 0.127 | – |
| mlp-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.740 | 0.470 | 0.056 | 0.262 | – |
| linear-nf | posture | 74,475 | 0.567 [0.554, 0.582] | 0.567 [0.554, 0.582] | 0.574 [0.562, 0.587] | 0.552 | 0.290 | 0.087 | 0.250 | – |
| linear-nf | locomotion | 91,653 | 0.393 [0.366, 0.414] | 0.393 [0.366, 0.414] | 0.375 [0.351, 0.394] | 0.507 | 0.234 | 0.044 | 0.127 | – |
| linear-nf | arm_behavior | 20,972 | 0.353 [0.307, 0.422] | 0.353 [0.307, 0.422] | 0.395 [0.362, 0.493] | 0.738 | 0.478 | 0.068 | 0.262 | – |
| w10-hc | posture | 227,293 | 0.618 [0.601, 0.634] | 0.618 [0.601, 0.634] | 0.613 [0.600, 0.625] | 0.454 | 0.255 | 0.043 | 0.212 | – |
| w10-hc | locomotion | 282,152 | 0.616 [0.583, 0.641] | 0.616 [0.583, 0.641] | 0.589 [0.560, 0.619] | 0.434 | 0.205 | 0.021 | 0.127 | – |
| w10-hc | arm_behavior | 64,906 | 0.430 [0.379, 0.498] | 0.430 [0.379, 0.498] | 0.443 [0.404, 0.552] | 0.708 | 0.466 | 0.069 | 0.260 | – |

macro-F1 = sklearn convention (union of true and predicted classes); 'present-only' = the earlier number over classes with test support only. † = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

## Per-class test F1 (precision/recall) — primary bundles

Final status = min(VAL status, pooled test gate, every wrist dataset with >= 30 accepted windows): strong needs precision >= .95 (pooled also CP95 >= .90, recall >= .05), weak needs precision >= .80; demotions only. P single-label = precision on windows whose truth is exactly one class.

#### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| class | primary-hc F1 (P/R) | primary-nf F1 (P/R) | primary-art F1 (P/R) | linear-hc F1 (P/R) | mlp-hc F1 (P/R) | primary-hc P single-label (n) | test support | status val→final (primary-hc) | demotion reasons |
|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.91 (0.91/0.92) | 0.89 (0.85/0.94) | 0.75 (0.72/0.77) | 0.91 (0.89/0.93) | 0.91 (0.91/0.92) | 0.90 (35,939) | 38,480 | weak→weak | – |
| seated_likely | 0.84 (0.81/0.87) | 0.80 (0.81/0.79) | 0.63 (0.61/0.65) | 0.83 (0.81/0.85) | 0.84 (0.81/0.87) | 0.77 (25,686) | 31,775 | weak→abstain | pamap2 test: precision 0.629 at n_acc 89 -> abstain |
| upright_stationary | 0.22 (0.47/0.14) | 0.10 (0.33/0.06) | 0.00 (0.00/0.00) | 0.11 (0.29/0.07) | 0.22 (0.47/0.14) | 0.53 (4,220) | 4,220 | abstain→abstain | – |
| postural_transition | unsupported | unsupported | unsupported | unsupported | unsupported | – | 0 | unsupported→– | – |

#### locomotion

| class | primary-hc F1 (P/R) | primary-nf F1 (P/R) | primary-art F1 (P/R) | linear-hc F1 (P/R) | mlp-hc F1 (P/R) | primary-hc P single-label (n) | test support | status val→final (primary-hc) | demotion reasons |
|---|---|---|---|---|---|---|---|---|---|
| stationary | 0.94 (0.91/0.97) | 0.92 (0.86/0.98) | 0.89 (0.81/1.00) | 0.93 (0.89/0.98) | 0.94 (0.91/0.97) | 0.91 (72,964) | 73,196 | strong→strong | – |
| walking | 0.66 (0.80/0.56) | 0.57 (0.72/0.48) | 0.15 (0.79/0.08) | 0.63 (0.82/0.51) | 0.66 (0.80/0.56) | 0.79 (8,306) | 8,527 | strong→strong | – |
| brisk_walking | unsupported | unsupported | unsupported | unsupported | unsupported | – | 0 | unsupported→– | – |
| running | 0.88 (0.91/0.85) | 0.80 (0.69/0.95) | 0.72 (0.75/0.68) | 0.78 (0.95/0.67) | 0.88 (0.91/0.85) | 0.91 (203) | 203 | strong→weak | pooled test: precision 0.941 at n_acc 152 -> weak |
| stairs | 0.73 (0.72/0.74) | 0.00 (0.00/0.00) | 0.00 (0.00/0.00) | 0.72 (0.69/0.76) | 0.73 (0.72/0.74) | 0.72 (152) | 152 | weak→weak | – |
| cycling | 0.67 (0.72/0.63) | 0.46 (0.49/0.43) | 0.00 (0.00/0.00) | 0.62 (0.71/0.55) | 0.67 (0.72/0.63) | 0.72 (808) | 808 | weak→abstain | pooled test: precision 0.721 at n_acc 703 -> abstain |
| vehicle_motion | 0.50 (0.71/0.38) | 0.00 (0.31/0.00) | 0.00 (0.00/0.00) | 0.37 (0.76/0.25) | 0.50 (0.71/0.38) | 0.71 (3,518) | 3,518 | weak→weak | – |
| other | 0.37 (0.40/0.35) | 0.17 (0.27/0.12) | 0.02 (0.22/0.01) | 0.28 (0.34/0.24) | 0.37 (0.40/0.35) | 0.40 (5,249) | 5,249 | abstain→abstain | – |

#### arm_behavior

| class | primary-hc F1 (P/R) | primary-nf F1 (P/R) | primary-art F1 (P/R) | linear-hc F1 (P/R) | mlp-hc F1 (P/R) | primary-hc P single-label (n) | test support | status val→final (primary-hc) | demotion reasons |
|---|---|---|---|---|---|---|---|---|---|
| quiet | 0.15 (0.41/0.09) | 0.04 (0.49/0.02) | 0.00 (0.00/0.00) | 0.15 (0.41/0.09) | 0.00 (0.08/0.00) | 0.41 (6,845) | 6,845 | abstain→abstain | – |
| desk_like | 0.78 (0.67/0.94) | 0.78 (0.65/0.98) | 0.78 (0.65/1.00) | 0.78 (0.67/0.94) | 0.79 (0.66/0.99) | 0.67 (13,545) | 13,545 | abstain→abstain | – |
| fidgeting | unsupported | unsupported | unsupported | unsupported | unsupported | – | 0 | unsupported→– | – |
| repetitive_hand_motion | 0.34 (0.44/0.27) | 0.23 (0.32/0.18) | 0.00 (0.00/0.00) | 0.34 (0.44/0.27) | 0.46 (0.51/0.42) | 0.44 (582) | 582 | weak→abstain | pooled test: precision 0.635 at n_acc 85 -> abstain |
| active_gesturing | unsupported | unsupported | unsupported | unsupported | unsupported | – | 0 | unsupported→– | – |
| exercise_motion | unsupported | unsupported | unsupported | unsupported | unsupported | – | 0 | unsupported→– | – |
| other | unsupported | unsupported | unsupported | unsupported | unsupported | – | 0 | unsupported→– | – |

## Per-dataset per-class test P/R/F1 — primary bundles

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

#### primary-hc — posture

| class | capture24 (50 subj) | hhar_watch (2 subj, descriptive) | mhealth (2 subj, descriptive) | opportunity (1 subj, descriptive) | pamap2 (2 subj, descriptive) | wisdm2019_watch (8 subj) | final |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.91/0.92/0.92 (38401) · gate 0.91@39065→weak | 0.00/0.00/0.00 (0) · gate 0.00@26→weak | 0.44/1.00/0.62 (4) · gate 0.44@9→weak | 0.00/0.00/0.00 (0) | 0.89/0.84/0.86 (75) · gate 0.89@71→weak | 0.00/0.00/0.00 (0) · gate 0.00@25→weak | weak→weak |
| seated_likely | 0.81/0.87/0.84 (31548) · gate 0.81@33775→weak | 0.86/0.81/0.83 (37) · gate 0.86@35→weak | 0.14/0.17/0.15 (6) · gate 0.14@7→weak | 0.86/1.00/0.92 (30) · gate 0.86@35→weak | 0.63/0.76/0.69 (74) · gate 0.63@89→abstain | 0.67/0.74/0.70 (80) · gate 0.67@88→abstain | weak→abstain |
| upright_stationary | 0.43/0.12/0.19 (4036) | 0.92/0.32/0.48 (37) | 0.00/0.00/0.00 (6) | 1.00/0.29/0.44 (7) | 0.77/0.62/0.69 (55) | 1.00/0.58/0.74 (79) | abstain→abstain |

| dataset | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| macro-F1 [95% CI] | 0.650 [0.631, 0.669] | 0.438 [0.416, 0.456]† | 0.256 [0.190, 0.317]† | 0.684 [0.684, 0.684]† | 0.746 [0.682, 0.746]† | 0.479 [0.382, 0.562]† |

#### primary-hc — locomotion

| class | capture24 (50 subj) | hhar_watch (2 subj, descriptive) | mhealth (2 subj, descriptive) | opportunity (1 subj, descriptive) | pamap2 (2 subj, descriptive) | wisdm2019_watch (8 subj) | final |
|---|---|---|---|---|---|---|---|
| stationary | 0.91/0.97/0.94 (71942) · gate 0.98@63194→strong | 0.97/1.00/0.99 (74) · gate 1.00@70→strong | 1.00/0.84/0.91 (19) · gate 1.00@16→weak | 1.00/0.92/0.96 (37) · gate 1.00@19→weak | 0.85/0.88/0.86 (187) · gate 0.96@136→strong | 1.00/0.98/0.99 (937) · gate 1.00@778→strong | strong→strong |
| walking | 0.80/0.55/0.65 (8375) · gate 0.99@2499→strong | 0.92/1.00/0.96 (35) · gate 1.00@30→strong | 0.57/1.00/0.73 (4) · gate 1.00@4→weak | 0.00/0.00/0.00 (0) | 0.71/0.98/0.82 (43) · gate 1.00@22→weak | 0.79/0.96/0.86 (70) · gate 1.00@57→strong | strong→strong |
| running | 0.82/0.74/0.78 (103) · gate 0.87@68→weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10) · gate 1.00@10→weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10) · gate 1.00@10→weak | 1.00/0.96/0.98 (80) · gate 1.00@64→strong | strong→weak |
| stairs | 0.02/0.12/0.04 (8) · gate 0.00@17→weak | 1.00/0.97/0.98 (32) · gate 1.00@27→weak | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.90/0.62/0.73 (29) · gate 1.00@16→weak | 1.00/0.78/0.87 (80) · gate 1.00@52→strong | weak→weak |
| cycling | 0.69/0.60/0.65 (743) · gate 0.70@645→abstain | 1.00/0.88/0.94 (33) · gate 1.00@29→weak | 1.00/1.00/1.00 (4) · gate 1.00@4→weak | 0.00/0.00/0.00 (0) | 1.00/0.89/0.94 (28) · gate 1.00@25→weak | 0.00/0.00/0.00 (0) | weak→abstain |
| vehicle_motion | 0.71/0.39/0.50 (3484) · gate 0.90@979→weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.60/0.09/0.15 (34) · gate 1.00@2→weak | 0.00/0.00/0.00 (0) | weak→weak |
| other | 0.39/0.35/0.37 (5174) | 0.00/0.00/0.00 (0) | 0.75/1.00/0.86 (9) | 0.00/0.00/0.00 (0) | 0.70/0.88/0.78 (66) | 0.00/0.00/0.00 (0) | abstain→abstain |

| dataset | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| macro-F1 [95% CI] | 0.560 [0.439, 0.589] | 0.966 [0.964, 0.970]† | 0.750 [0.728, 0.949]† | 0.319 [0.319, 0.319]† | 0.757 [0.644, 0.791]† | 0.742 [0.707, 0.773]† |

#### primary-hc — arm_behavior

| class | capture24 (50 subj) | mhealth (2 subj, descriptive) | pamap2 (2 subj, descriptive) | wisdm2019_watch (8 subj) | final |
|---|---|---|---|---|---|
| quiet | 0.41/0.09/0.15 (6802) | 0.00/0.00/0.00 (12) | 1.00/0.03/0.06 (31) | 0.00/0.00/0.00 (0) | abstain→abstain |
| desk_like | 0.67/0.94/0.78 (13385) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.78/1.00/0.88 (160) | abstain→abstain |
| repetitive_hand_motion | 0.12/0.07/0.09 (393) · gate 0.00@31→abstain | 0.00/0.00/0.00 (0) | 1.00/0.45/0.62 (29) | 1.00/0.72/0.84 (160) · gate 1.00@54→strong | weak→abstain |

| dataset | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| macro-F1 [95% CI] | 0.341 [0.299, 0.384] | 0.000 [0.000, 0.000]† | 0.227 [0.190, 0.259]† | 0.860 [0.709, 0.981]† |

#### primary-nf — posture

| class | capture24 (50 subj) | hhar_watch (2 subj, descriptive) | mhealth (2 subj, descriptive) | opportunity (1 subj, descriptive) | pamap2 (2 subj, descriptive) | wisdm2019_watch (8 subj) | final |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.85/0.94/0.89 (39388) · gate 0.97@20520→strong | 0.00/0.00/0.00 (0) · gate 0.00@29→weak | 0.25/1.00/0.40 (4) · gate 0.00@1→weak | 0.00/0.00/0.00 (0) | 0.78/0.80/0.79 (71) · gate 0.96@28→weak | 0.00/0.00/0.00 (0) · gate 0.00@8→weak | strong→strong |
| seated_likely | 0.81/0.79/0.80 (30561) · gate 0.81@29535→weak | 0.40/0.05/0.10 (37) · gate 0.40@5→weak | 0.00/0.00/0.00 (6) | 0.81/1.00/0.90 (30) · gate 0.81@37→weak | 0.52/0.85/0.64 (78) · gate 0.52@128→abstain | 0.47/0.55/0.51 (80) · gate 0.47@93→abstain | weak→abstain |
| upright_stationary | 0.33/0.06/0.11 (4036) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.33/0.02/0.03 (55) | 0.00/0.00/0.00 (79) | abstain→abstain |

| dataset | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| macro-F1 [95% CI] | 0.600 [0.585, 0.611] | 0.032 [0.029, 0.035]† | 0.133 [0.133, 0.133]† | 0.448 [0.448, 0.448]† | 0.489 [0.311, 0.542]† | 0.170 [0.115, 0.201]† |

#### primary-nf — locomotion

| class | capture24 (50 subj) | hhar_watch (2 subj, descriptive) | mhealth (2 subj, descriptive) | opportunity (1 subj, descriptive) | pamap2 (2 subj, descriptive) | wisdm2019_watch (8 subj) | final |
|---|---|---|---|---|---|---|---|
| stationary | 0.86/0.98/0.92 (71976) · gate 0.97@55806→strong | 0.84/1.00/0.91 (74) · gate 1.00@73→strong | 0.84/0.84/0.84 (19) · gate 1.00@16→weak | 1.00/0.95/0.97 (37) · gate 1.00@12→weak | 0.79/0.90/0.84 (187) · gate 0.98@116→strong | 1.00/0.89/0.94 (937) · gate 1.00@507→strong | strong→strong |
| walking | 0.74/0.47/0.57 (8341) · gate 0.91@3173→weak | 0.55/1.00/0.71 (35) · gate 0.58@60→abstain | 0.40/1.00/0.57 (4) · gate 0.57@7→weak | 0.00/0.00/0.00 (0) | 0.38/0.91/0.53 (43) · gate 0.26@31→abstain | 0.40/0.86/0.54 (70) · gate 0.39@64→abstain | weak→abstain |
| running | 0.53/0.93/0.67 (103) · gate 0.67@132→abstain | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10) · gate 1.00@10→weak | 0.00/0.00/0.00 (0) | 0.91/1.00/0.95 (10) · gate 1.00@10→weak | 1.00/0.96/0.98 (80) · gate 1.00@68→strong | weak→abstain |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (80) | abstain→abstain |
| cycling | 0.49/0.41/0.45 (743) · gate 0.58@414→abstain | 1.00/0.58/0.73 (33) · gate 1.00@17→weak | 1.00/1.00/1.00 (4) · gate 1.00@4→weak | 0.00/0.00/0.00 (0) · gate 0.00@1→weak | 1.00/0.71/0.83 (28) · gate 1.00@19→weak | 0.00/0.00/0.00 (0) · gate 0.00@28→weak | weak→abstain |
| vehicle_motion | 0.31/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) | abstain→abstain |
| other | 0.27/0.12/0.16 (5174) | 0.00/0.00/0.00 (0) | 0.67/0.44/0.53 (9) | 0.00/0.00/0.00 (0) | 0.65/0.48/0.56 (66) | 0.00/0.00/0.00 (0) | abstain→abstain |

| dataset | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| macro-F1 [95% CI] | 0.396 [0.286, 0.436] | 0.470 [0.344, 0.663]† | 0.658 [0.640, 0.861]† | 0.486 [0.486, 0.486]† | 0.531 [0.499, 0.675]† | 0.411 [0.383, 0.433]† |

#### primary-nf — arm_behavior

| class | capture24 (50 subj) | mhealth (2 subj, descriptive) | pamap2 (2 subj, descriptive) | wisdm2019_watch (8 subj) | final |
|---|---|---|---|---|---|
| quiet | 0.49/0.02/0.04 (6802) | 0.00/0.00/0.00 (12) | 1.00/0.06/0.12 (31) | 0.00/0.00/0.00 (0) | abstain→abstain |
| desk_like | 0.66/0.98/0.79 (13385) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.72/1.00/0.84 (160) | abstain→abstain |
| repetitive_hand_motion | 0.03/0.02/0.03 (393) · gate 0.00@48→abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 1.00/0.61/0.75 (160) · gate 1.00@34→strong | weak→abstain |

| dataset | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| macro-F1 [95% CI] | 0.285 [0.262, 0.304] | 0.000 [0.000, 0.000]† | 0.040 [0.000, 0.070]† | 0.795 [0.609, 0.937]† |

#### primary-art — posture

| class | capture24 (50 subj) | hhar_watch (2 subj, descriptive) | mhealth (2 subj, descriptive) | opportunity (1 subj, descriptive) | pamap2 (2 subj, descriptive) | wisdm2019_watch (8 subj) | final |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.73/0.77/0.75 (40277) · gate 0.81@20174→weak | 0.00/0.00/0.00 (0) | 0.40/0.50/0.44 (4) · gate 1.00@2→weak | 0.00/0.00/0.00 (0) · gate 0.00@27→weak | 0.31/0.91/0.46 (44) · gate 0.16@90→abstain | 0.00/0.00/0.00 (0) · gate 0.00@11→weak | weak→abstain |
| seated_likely | 0.61/0.65/0.63 (29672) | 0.82/0.49/0.61 (37) | 0.27/0.50/0.35 (6) | 0.00/0.00/0.00 (30) | 0.62/0.43/0.51 (105) | 0.72/0.55/0.62 (80) | abstain→abstain |
| upright_stationary | 0.00/0.00/0.00 (4036) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.00/0.00/0.00 (55) | 0.00/0.00/0.00 (79) | abstain→abstain |

| dataset | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| macro-F1 [95% CI] | 0.461 [0.434, 0.484] | 0.203 [0.000, 0.333]† | 0.266 [0.000, 0.556]† | 0.000 [0.000, 0.000]† | 0.321 [0.140, 0.365]† | 0.208 [0.121, 0.291]† |

#### primary-art — locomotion

| class | capture24 (50 subj) | hhar_watch (2 subj, descriptive) | mhealth (2 subj, descriptive) | opportunity (1 subj, descriptive) | pamap2 (2 subj, descriptive) | wisdm2019_watch (8 subj) | final |
|---|---|---|---|---|---|---|---|
| stationary | 0.81/1.00/0.89 (72149) · gate 0.81@88816→weak | 0.47/1.00/0.64 (74) · gate 0.47@156→abstain | 0.49/1.00/0.66 (19) · gate 0.49@39→abstain | 1.00/1.00/1.00 (37) · gate 1.00@37→strong | 0.58/0.98/0.73 (187) · gate 0.58@316→abstain | 0.89/0.99/0.94 (937) · gate 0.89@1035→weak | weak→abstain |
| walking | 0.84/0.08/0.14 (8168) | 0.06/0.03/0.04 (35) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 0.60/0.74/0.67 (43) | 0.49/0.39/0.43 (70) | abstain→abstain |
| running | 0.64/0.51/0.57 (103) · gate 0.70@76→abstain | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10) · gate 1.00@10→weak | 0.00/0.00/0.00 (0) | 0.45/1.00/0.62 (10) · gate 0.45@22→weak | 0.96/0.81/0.88 (80) · gate 0.98@64→strong | weak→abstain |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (80) | abstain→abstain |
| cycling | 0.00/0.00/0.00 (743) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (28) | 0.00/0.00/0.00 (0) | abstain→abstain |
| vehicle_motion | 0.00/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) | abstain→abstain |
| other | 0.21/0.01/0.01 (5174) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (9) | 0.00/0.00/0.00 (0) | 0.83/0.08/0.14 (66) | 0.00/0.00/0.00 (0) | abstain→abstain |

| dataset | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| macro-F1 [95% CI] | 0.231 [0.145, 0.278] | 0.170 [0.149, 0.189]† | 0.276 [0.274, 0.333]† | 1.000 [1.000, 1.000]† | 0.309 [0.275, 0.314]† | 0.450 [0.384, 0.504]† |

#### primary-art — arm_behavior

| class | capture24 (50 subj) | mhealth (2 subj, descriptive) | pamap2 (2 subj, descriptive) | wisdm2019_watch (8 subj) | final |
|---|---|---|---|---|---|
| quiet | 0.00/0.00/0.00 (6802) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) | abstain→abstain |
| desk_like | 0.65/1.00/0.79 (13385) · gate 0.72@9737→abstain | 0.00/0.00/0.00 (0) · gate 0.00@6→weak | 0.00/0.00/0.00 (0) · gate 0.00@17→weak | 0.50/1.00/0.67 (160) · gate 0.65@246→abstain | weak→abstain |
| repetitive_hand_motion | 0.00/0.00/0.00 (393) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (160) | abstain→abstain |

| dataset | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| macro-F1 [95% CI] | 0.263 [0.241, 0.282] | 0.000 [0.000, 0.000]† | 0.000 [0.000, 0.000]† | 0.333 [0.333, 0.333]† |

## Awake lying (recumbent outside sleep periods)

| experiment | recumbent truth | sleep-period share | awake-lying truth (by dataset) | recumbent P/R/F1 on non-sleep windows | awake-lying gate (pooled) | awake-lying status |
|---|---|---|---|---|---|---|
| primary-hc | 44,569 | 0.806 | 8,665 (capture24 8576, mhealth 4, pamap2 85) | 0.41/0.99/0.58 | P=0.411 n=6,237 → abstain | abstain |
| primary-nf | 44,569 | 0.806 | 8,665 (capture24 8576, mhealth 4, pamap2 85) | 0.34/1.00/0.51 | P=0.444 n=1,336 → abstain | abstain |
| primary-art | 44,569 | 0.806 | 8,665 (capture24 8576, mhealth 4, pamap2 85) | 0.27/1.00/0.43 | P=0.281 n=5,522 → abstain | abstain |

The awake-lying gate is reported only: the served `recumbent` status is the pooled gate's, and the class must be read as 'recumbent (mostly sleep-period lying in training data)'.

## Calibration (test; fit on val only)

| experiment | head | method | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal |
|---|---|---|---|---|---|---|
| primary-hc | posture | temp_bias | 0.536→0.389 | 0.308→0.216 | 0.050→0.024 (0.004) | 0.101→0.024 |
| primary-hc | locomotion | vector | 0.569→0.375 | 0.278→0.180 | 0.073→0.022 (0.003) | 0.059→0.010 |
| primary-hc | arm_behavior | vector | 0.938→0.705 | 0.571→0.461 | 0.093→0.072 (0.010) | 0.171→0.054 |
| primary-nf | posture | temp_bias | 0.784→0.484 | 0.456→0.262 | 0.206→0.027 (0.005) | 0.219→0.039 |
| primary-nf | locomotion | vector | 0.820→0.475 | 0.410→0.229 | 0.055→0.015 (0.004) | 0.085→0.011 |
| primary-nf | arm_behavior | temp_bias | 1.049→0.738 | 0.632→0.478 | 0.135→0.068 (0.008) | 0.200→0.050 |
| primary-art | posture | temp_bias | 0.976→0.704 | 0.601→0.432 | 0.074→0.108 (0.005) | 0.188→0.074 |
| primary-art | locomotion | temp_bias | 1.607→0.657 | 0.880→0.310 | 0.306→0.052 (0.004) | 0.170→0.021 |
| primary-art | arm_behavior | temp_bias | 1.270→0.740 | 0.796→0.470 | 0.264→0.056 (0.009) | 0.263→0.048 |

## Transition events

| experiment | event | supported | AUROC | AP | Brier | ECE | F1 ±5 s | F1 ±10 s | median/p90 abs err (s) | status val→final |
|---|---|---|---|---|---|---|---|---|---|---|
| primary-hc | sit_to_stand_like | yes | 0.926 | 0.063 | 0.099 | 0.213 | 0.19 | 0.22 | 2.9/5.4 | abstain→abstain |
| primary-hc | stand_to_sit_like | yes | 0.893 | 0.053 | 0.099 | 0.200 | 0.00 | 0.00 | –/– | abstain→abstain |
| primary-hc | walk_start | yes | 0.923 | 0.091 | 0.101 | 0.214 | 0.42 | 0.47 | 2.3/5.9 | abstain→abstain |
| primary-hc | walk_stop | yes | 0.900 | 0.075 | 0.104 | 0.212 | 0.39 | 0.48 | 2.5/7.0 | abstain→abstain |
| primary-nf | sit_to_stand_like | yes | 0.911 | 0.035 | 0.079 | 0.166 | 0.24 | 0.25 | 2.1/3.7 | abstain→abstain |
| primary-nf | stand_to_sit_like | yes | 0.881 | 0.033 | 0.085 | 0.177 | 0.05 | 0.16 | 8.2/8.8 | abstain→abstain |
| primary-nf | walk_start | yes | 0.899 | 0.041 | 0.106 | 0.228 | 0.35 | 0.42 | 2.0/6.3 | abstain→abstain |
| primary-nf | walk_stop | yes | 0.873 | 0.040 | 0.109 | 0.233 | 0.35 | 0.44 | 2.5/6.5 | abstain→abstain |
| primary-art | sit_to_stand_like | yes | 0.827 | 0.024 | 0.162 | 0.312 | 0.21 | 0.28 | 2.1/6.5 | abstain→abstain |
| primary-art | stand_to_sit_like | yes | 0.781 | 0.023 | 0.181 | 0.357 | 0.07 | 0.16 | 5.1/8.5 | abstain→abstain |
| primary-art | walk_start | yes | 0.751 | 0.022 | 0.176 | 0.352 | 0.28 | 0.29 | 2.0/3.8 | abstain→abstain |
| primary-art | walk_stop | yes | 0.725 | 0.021 | 0.181 | 0.363 | 0.29 | 0.35 | 2.5/6.6 | abstain→abstain |

## Movement intensity

| experiment | set | n | MAE | MAE const | R² | Spearman | 80% coverage |
|---|---|---|---|---|---|---|---|
| primary-hc | pooled | 95,813 | 0.103 | 0.136 | 0.495 | 0.780 | 0.765 |
| primary-hc | capture24 | 95,579 | 0.103 | 0.136 | 0.492 | 0.779 | 0.765 |
| primary-hc | pamap2 | 234 | 0.107 | 0.203 | 0.645 | 0.845 | 0.697 |
| primary-nf | pooled | 95,813 | 0.123 | 0.136 | 0.285 | 0.776 | 0.780 |
| primary-nf | capture24 | 95,579 | 0.123 | 0.136 | 0.280 | 0.776 | 0.780 |
| primary-nf | pamap2 | 234 | 0.135 | 0.203 | 0.500 | 0.798 | 0.654 |
| primary-art | pooled | 95,813 | 0.146 | 0.136 | 0.007 | 0.399 | 0.792 |
| primary-art | capture24 | 95,579 | 0.146 | 0.136 | 0.000 | 0.397 | 0.792 |
| primary-art | pamap2 | 234 | 0.150 | 0.203 | 0.346 | 0.752 | 0.782 |

## OOD

| bundle | OOD set | method | AUROC | AUPRC (prev.) | FPR@95 OOD+ | ID false alarm @op | OOD detect @op |
|---|---|---|---|---|---|---|---|
| ood-hc | daphnet_fog_nonwrist | energy | 0.492 | 0.009 (0.01) | 0.962 | 0.055 | 0.021 |
| ood-hc | daphnet_fog_nonwrist | knn@10 | 0.693 | 0.017 (0.01) | 0.781 | 0.041 | 0.059 |
| ood-hc | daphnet_fog_nonwrist | knn@20 | 0.704 | 0.018 (0.01) | 0.794 | 0.040 | 0.061 |
| ood-hc | daphnet_fog_nonwrist | knn@5 | 0.674 | 0.016 (0.01) | 0.774 | 0.043 | 0.056 |
| ood-hc | daphnet_fog_nonwrist | maha_global (bundle) | 0.515 | 0.040 (0.01) | 0.879 | 0.048 | 0.034 |
| ood-hc | daphnet_fog_nonwrist | maha_min | 0.519 | 0.040 (0.01) | 0.922 | 0.047 | 0.034 |
| ood-hc | daphnet_fog_nonwrist | maha_rel | 0.586 | 0.060 (0.01) | 0.928 | 0.046 | 0.261 |
| ood-hc | heldout_activities_test | energy | 0.776 | 0.091 (0.02) | 0.823 | 0.055 | 0.305 |
| ood-hc | heldout_activities_test | knn@10 | 0.556 | 0.022 (0.02) | 0.796 | 0.041 | 0.019 |
| ood-hc | heldout_activities_test | knn@20 | 0.546 | 0.021 (0.02) | 0.810 | 0.040 | 0.015 |
| ood-hc | heldout_activities_test | knn@5 | 0.560 | 0.022 (0.02) | 0.789 | 0.043 | 0.019 |
| ood-hc | heldout_activities_test | maha_global (bundle) | 0.802 | 0.163 (0.02) | 0.487 | 0.048 | 0.272 |
| ood-hc | heldout_activities_test | maha_min | 0.801 | 0.167 (0.02) | 0.496 | 0.047 | 0.268 |
| ood-hc | heldout_activities_test | maha_rel | 0.524 | 0.109 (0.02) | 0.965 | 0.046 | 0.257 |
| ood-nf | daphnet_fog_nonwrist | energy | 0.600 | 0.012 (0.01) | 0.900 | 0.051 | 0.052 |
| ood-nf | daphnet_fog_nonwrist | knn@10 | 0.672 | 0.017 (0.01) | 0.738 | 0.048 | 0.074 |
| ood-nf | daphnet_fog_nonwrist | knn@20 (bundle) | 0.667 | 0.017 (0.01) | 0.758 | 0.049 | 0.049 |
| ood-nf | daphnet_fog_nonwrist | knn@5 | 0.676 | 0.017 (0.01) | 0.718 | 0.048 | 0.094 |
| ood-nf | daphnet_fog_nonwrist | maha_global | 0.555 | 0.012 (0.01) | 0.929 | 0.058 | 0.045 |
| ood-nf | daphnet_fog_nonwrist | maha_min | 0.573 | 0.017 (0.01) | 0.969 | 0.050 | 0.034 |
| ood-nf | daphnet_fog_nonwrist | maha_rel | 0.579 | 0.014 (0.01) | 0.935 | 0.049 | 0.124 |
| ood-nf | heldout_activities_test | energy | 0.767 | 0.080 (0.02) | 0.990 | 0.051 | 0.256 |
| ood-nf | heldout_activities_test | knn@10 | 0.797 | 0.086 (0.02) | 0.465 | 0.048 | 0.188 |
| ood-nf | heldout_activities_test | knn@20 (bundle) | 0.797 | 0.077 (0.02) | 0.454 | 0.049 | 0.178 |
| ood-nf | heldout_activities_test | knn@5 | 0.797 | 0.091 (0.02) | 0.470 | 0.048 | 0.198 |
| ood-nf | heldout_activities_test | maha_global | 0.781 | 0.173 (0.02) | 0.568 | 0.058 | 0.320 |
| ood-nf | heldout_activities_test | maha_min | 0.736 | 0.155 (0.02) | 0.691 | 0.050 | 0.263 |
| ood-nf | heldout_activities_test | maha_rel | 0.269 | 0.073 (0.02) | 0.977 | 0.049 | 0.088 |
| ood-art | daphnet_fog_nonwrist | energy | 0.769 | 0.019 (0.01) | 0.414 | 0.055 | 0.107 |
| ood-art | daphnet_fog_nonwrist | knn@10 | 0.739 | 0.034 (0.01) | 0.746 | 0.048 | 0.032 |
| ood-art | daphnet_fog_nonwrist | knn@20 | 0.799 | 0.044 (0.01) | 0.631 | 0.049 | 0.131 |
| ood-art | daphnet_fog_nonwrist | knn@5 | 0.685 | 0.031 (0.01) | 0.841 | 0.047 | 0.031 |
| ood-art | daphnet_fog_nonwrist | maha_global (bundle) | 0.625 | 0.012 (0.01) | 0.584 | 0.066 | 0.040 |
| ood-art | daphnet_fog_nonwrist | maha_min | 0.617 | 0.012 (0.01) | 0.621 | 0.066 | 0.040 |
| ood-art | daphnet_fog_nonwrist | maha_rel | 0.402 | 0.010 (0.01) | 0.924 | 0.057 | 0.086 |
| ood-art | heldout_activities_test | energy | 0.456 | 0.018 (0.02) | 0.984 | 0.055 | 0.033 |
| ood-art | heldout_activities_test | knn@10 | 0.797 | 0.066 (0.02) | 0.579 | 0.048 | 0.225 |
| ood-art | heldout_activities_test | knn@20 | 0.793 | 0.066 (0.02) | 0.571 | 0.049 | 0.224 |
| ood-art | heldout_activities_test | knn@5 | 0.800 | 0.067 (0.02) | 0.537 | 0.047 | 0.227 |
| ood-art | heldout_activities_test | maha_global (bundle) | 0.861 | 0.155 (0.02) | 0.373 | 0.066 | 0.374 |
| ood-art | heldout_activities_test | maha_min | 0.861 | 0.152 (0.02) | 0.377 | 0.066 | 0.374 |
| ood-art | heldout_activities_test | maha_rel | 0.694 | 0.084 (0.02) | 0.792 | 0.057 | 0.266 |
| lodo-nohhar-hc | daphnet_fog_nonwrist | energy | 0.365 | 0.006 (0.01) | 0.960 | 0.046 | 0.019 |
| lodo-nohhar-hc | daphnet_fog_nonwrist | knn@10 | 0.693 | 0.016 (0.01) | 0.784 | 0.041 | 0.056 |
| lodo-nohhar-hc | daphnet_fog_nonwrist | knn@20 | 0.705 | 0.018 (0.01) | 0.793 | 0.039 | 0.060 |
| lodo-nohhar-hc | daphnet_fog_nonwrist | knn@5 | 0.674 | 0.015 (0.01) | 0.776 | 0.042 | 0.058 |
| lodo-nohhar-hc | daphnet_fog_nonwrist | maha_global (bundle) | 0.509 | 0.040 (0.01) | 0.881 | 0.050 | 0.035 |
| lodo-nohhar-hc | daphnet_fog_nonwrist | maha_min | 0.511 | 0.040 (0.01) | 0.924 | 0.050 | 0.035 |
| lodo-nohhar-hc | daphnet_fog_nonwrist | maha_rel | 0.579 | 0.058 (0.01) | 0.933 | 0.046 | 0.241 |
| lodo-nohhar-hc | heldout_dataset_hhar_test | energy | 0.426 | 0.005 (0.00) | 0.992 | 0.046 | 0.069 |
| lodo-nohhar-hc | heldout_dataset_hhar_test | knn@10 | 0.518 | 0.002 (0.00) | 0.798 | 0.041 | 0.017 |
| lodo-nohhar-hc | heldout_dataset_hhar_test | knn@20 | 0.533 | 0.002 (0.00) | 0.772 | 0.039 | 0.029 |
| lodo-nohhar-hc | heldout_dataset_hhar_test | knn@5 | 0.518 | 0.002 (0.00) | 0.806 | 0.042 | 0.023 |
| lodo-nohhar-hc | heldout_dataset_hhar_test | maha_global (bundle) | 0.571 | 0.002 (0.00) | 0.891 | 0.050 | 0.034 |
| lodo-nohhar-hc | heldout_dataset_hhar_test | maha_min | 0.544 | 0.002 (0.00) | 0.920 | 0.050 | 0.011 |
| lodo-nohhar-hc | heldout_dataset_hhar_test | maha_rel | 0.274 | 0.001 (0.00) | 0.995 | 0.046 | 0.046 |

| bundle | method (VAL-selected) | threshold | ID test false-alarm rate |
|---|---|---|---|
| ood-hc | maha_global | 14.471 | 0.048 |
| ood-nf | knn@20 | 0.322 | 0.049 |
| ood-art | maha_global | 36.306 | 0.066 |
| primary-hc | maha_global | 14.286 | 0.050 |
| primary-nf | knn@20 | 0.322 | 0.050 |
| primary-art | maha_global | 35.822 | 0.070 |
| linear-hc | maha_global | 14.286 | 0.050 |
| mlp-hc | maha_global | 14.286 | 0.050 |
| linear-art | maha_global | 35.822 | 0.070 |
| mlp-art | maha_global | 35.822 | 0.070 |
| linear-nf | knn@20 | 0.322 | 0.050 |
| w10-hc | maha_global | 14.207 | 0.046 |
| lodo-noc24-hc | maha_global | 13.552 | 0.065 |
| lodo-c24only-hc | maha_global | 14.247 | 0.057 |
| lodo-nohhar-hc | maha_global | 14.291 | 0.050 |
| seed1-hc | maha_global | 14.286 | 0.050 |
| seed2-hc | maha_global | 14.286 | 0.050 |

## Ablations

### 10 s vs 30 s windows (stand-in hc, class heads)

| experiment | head | n | macro-F1 [95% CI] | macro-F1 present-only (legacy) | balanced acc [95% CI] | NLL | Brier | ECE-15 | majority macro-F1 | predicted while absent |
|---|---|---|---|---|---|---|---|---|---|---|
| primary-hc | posture | 74,475 | 0.657 [0.638, 0.676] | 0.657 [0.638, 0.676] | 0.645 [0.629, 0.661] | 0.389 | 0.216 | 0.024 | 0.250 | – |
| primary-hc | locomotion | 91,653 | 0.678 [0.642, 0.706] | 0.678 [0.642, 0.706] | 0.640 [0.595, 0.685] | 0.375 | 0.180 | 0.022 | 0.127 | – |
| primary-hc | arm_behavior | 20,972 | 0.422 [0.375, 0.486] | 0.422 [0.375, 0.486] | 0.434 [0.392, 0.546] | 0.705 | 0.461 | 0.072 | 0.262 | – |
| w10-hc | posture | 227,293 | 0.618 [0.601, 0.634] | 0.618 [0.601, 0.634] | 0.613 [0.600, 0.625] | 0.454 | 0.255 | 0.043 | 0.212 | – |
| w10-hc | locomotion | 282,152 | 0.616 [0.583, 0.641] | 0.616 [0.583, 0.641] | 0.589 [0.560, 0.619] | 0.434 | 0.205 | 0.021 | 0.127 | – |
| w10-hc | arm_behavior | 64,906 | 0.430 [0.379, 0.498] | 0.430 [0.379, 0.498] | 0.443 [0.404, 0.552] | 0.708 | 0.466 | 0.069 | 0.260 | – |

macro-F1 = sklearn convention (union of true and predicted classes); 'present-only' = the earlier number over classes with test support only. † = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

### Linear vs MLP (forced, test)

| experiment | head | n | macro-F1 [95% CI] | macro-F1 present-only (legacy) | balanced acc [95% CI] | NLL | Brier | ECE-15 | majority macro-F1 | predicted while absent |
|---|---|---|---|---|---|---|---|---|---|---|
| linear-hc | posture | 74,475 | 0.618 [0.605, 0.628] | 0.618 [0.605, 0.628] | 0.617 [0.605, 0.627] | 0.413 | 0.231 | 0.014 | 0.250 | – |
| linear-hc | locomotion | 91,653 | 0.620 [0.572, 0.658] | 0.620 [0.572, 0.658] | 0.564 [0.506, 0.616] | 0.424 | 0.198 | 0.037 | 0.127 | – |
| linear-hc | arm_behavior | 20,972 | 0.422 [0.375, 0.486] | 0.422 [0.375, 0.486] | 0.434 [0.392, 0.546] | 0.705 | 0.461 | 0.072 | 0.262 | – |
| mlp-hc | posture | 74,475 | 0.657 [0.638, 0.676] | 0.657 [0.638, 0.676] | 0.645 [0.629, 0.661] | 0.389 | 0.216 | 0.024 | 0.250 | – |
| mlp-hc | locomotion | 91,653 | 0.678 [0.642, 0.706] | 0.678 [0.642, 0.706] | 0.640 [0.595, 0.685] | 0.375 | 0.180 | 0.022 | 0.127 | – |
| mlp-hc | arm_behavior | 20,972 | 0.416 [0.372, 0.462] | 0.416 [0.372, 0.462] | 0.471 [0.427, 0.566] | 0.665 | 0.441 | 0.066 | 0.262 | – |
| linear-art | posture | 74,475 | 0.432 [0.411, 0.455] | 0.432 [0.411, 0.455] | 0.445 [0.422, 0.472] | 0.742 | 0.464 | 0.072 | 0.250 | – |
| linear-art | locomotion | 91,653 | 0.232 [0.193, 0.258] | 0.232 [0.193, 0.258] | 0.235 [0.193, 0.273] | 0.690 | 0.318 | 0.040 | 0.127 | – |
| linear-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.727 | 0.462 | 0.085 | 0.262 | – |
| mlp-art | posture | 74,475 | 0.460 [0.436, 0.488] | 0.460 [0.436, 0.488] | 0.473 [0.448, 0.502] | 0.704 | 0.432 | 0.108 | 0.250 | – |
| mlp-art | locomotion | 91,653 | 0.254 [0.219, 0.277] | 0.254 [0.219, 0.277] | 0.253 [0.212, 0.288] | 0.657 | 0.310 | 0.052 | 0.127 | – |
| mlp-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.740 | 0.470 | 0.056 | 0.262 | – |

macro-F1 = sklearn convention (union of true and predicted classes); 'present-only' = the earlier number over classes with test support only. † = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

### Leave-one-dataset-out transfer (hc)

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.

| posture macro-F1 by test dataset | capture24 | hhar_watch (descriptive) | mhealth (descriptive) | opportunity (descriptive) | pamap2 (descriptive) | wisdm2019_watch |
|---|---|---|---|---|---|---|
| primary-hc | 0.650 | 0.438 | 0.256 | 0.684 | 0.746 | 0.479 |
| lodo-noc24-hc | 0.424 | 0.919 | 0.378 | 0.769 | 0.661 | 0.892 |
| lodo-c24only-hc | 0.704 | 0.192 | 0.383 | 0.626 | 0.502 | 0.236 |
| lodo-nohhar-hc | 0.646 | 0.325 | 0.286 | 0.684 | 0.736 | 0.485 |

| locomotion macro-F1 by test dataset | capture24 | hhar_watch (descriptive) | mhealth (descriptive) | opportunity (descriptive) | pamap2 (descriptive) | wisdm2019_watch |
|---|---|---|---|---|---|---|
| primary-hc | 0.560 | 0.966 | 0.750 | 0.319 | 0.757 | 0.742 |
| lodo-noc24-hc | 0.528 | 0.990 | 0.825 | 1.000 | 0.975 | 0.957 |
| lodo-c24only-hc | 0.662 | 0.510 | 0.579 | 0.151 | 0.663 | 0.296 |
| lodo-nohhar-hc | 0.570 | 0.751 | 0.845 | 0.486 | 0.789 | 0.625 |

| arm_behavior macro-F1 by test dataset | capture24 | mhealth (descriptive) | pamap2 (descriptive) | wisdm2019_watch |
|---|---|---|---|---|
| primary-hc | 0.341 | 0.000 | 0.227 | 0.860 |
| lodo-noc24-hc | 0.392 | – | 1.000 | 0.896 |
| lodo-c24only-hc | 0.399 | 0.000 | 0.000 | 1.000 |
| lodo-nohhar-hc | 0.342 | 0.000 | 0.227 | 0.860 |

### Seed variation (primary hc procedure, archs fixed from seed 0)

| head | seed 0 | seed 1 | seed 2 | mean ± sd |
|---|---|---|---|---|
| posture | 0.657 | 0.663 | 0.655 | 0.658 ± 0.005 |
| locomotion | 0.678 | 0.666 | 0.687 | 0.677 ± 0.011 |
| arm_behavior | 0.422 | 0.457 | 0.448 | 0.442 ± 0.018 |

## Split manifests (subject-level, frozen before windowing)

| dataset | train | val | test | LOSO folds | sha256 |
|---|---|---|---|---|---|
| capture24 | 81 | 20 | 50 | 0 | `b6110fbe0b1ed83d8f7d20d3149c67b41b574aa97b561acc9738b64a06074b67` |
| hhar_watch | 6 | 1 | 2 | 9 | `3e4c143046e562eb233e785b7bc3f6d459a455a0e76638269acae9537f3537af` |
| mhealth | 6 | 2 | 2 | 10 | `cc95780c0706c08f92e61f7267335b366fa761cd29fa35e3dd7d8d36a29f394b` |
| opportunity | 2 | 1 | 1 | 4 | `2df351a0ba583c232c309e1941e3f00f10c0633c0095bb1c4b88b3b375e019b8` |
| pamap2 | 6 | 1 | 2 | 9 | `4aeb6af05b41c67b3a82724026ddb7e8b633c5270c4d00fc0f580f4adea53715` |
| wisdm2019_watch | 35 | 8 | 8 | 0 | `7105df4cac920c71c26957bacdaad065d59d9d0312b2026a4fdf1e0c6415754f` |

Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

## Windows (cached, outside git)

| dataset | spec | window/hop (s) | train | val | test | ood | subjects | loader |
|---|---|---|---|---|---|---|---|---|
| capture24 | w30 | 30/30 | 158,132 | 40,840 | 95,579 | – | 151 | capture24-loader-1 |
| capture24 | w30t | 30/2 | 2,635 | 713 | 1,240 | – | 110 | capture24-loader-1 |
| capture24 | w10 | 10/10 | 354,702 | 125,170 | 293,623 | – | 151 | capture24-loader-1 |
| wisdm2019_watch | w30 | 30/15 | 6,081 | 1,559 | 1,397 | – | 51 | wisdm-loader-1 |
| wisdm2019_watch | w10 | 10/5 | 20,689 | 5,302 | 4,756 | – | 51 | wisdm-loader-1 |
| hhar_watch | w30 | 30/15 | 409 | 34 | 174 | – | 9 | hhar-loader-1 |
| hhar_watch | w30t | 30/2 | 4,414 | 474 | 1,824 | – | 9 | hhar-loader-1 |
| hhar_watch | w10 | 10/5 | 1,448 | 145 | 617 | – | 9 | hhar-loader-1 |
| pamap2 | w30 | 30/15 | 894 | 241 | 397 | – | 9 | pamap2-loader-1+pamap2-fill-50ms |
| pamap2 | w30t | 30/2 | 10,273 | 2,605 | 4,770 | – | 9 | pamap2-loader-1+pamap2-fill-50ms |
| pamap2 | w10 | 10/5 | 3,002 | 785 | 1,314 | – | 9 | pamap2-loader-1+pamap2-fill-50ms |
| mhealth | w30 | 30/15 | 159 | 49 | 49 | – | 10 | mhealth-loader-1 |
| mhealth | w10 | 10/5 | 717 | 231 | 221 | – | 10 | mhealth-loader-1 |
| opportunity | w30 | 30/15 | 183 | 72 | 37 | – | 4 | opportunity-loader-1 |
| opportunity | w30t | 30/2 | 6,188 | 2,922 | 2,502 | – | 4 | opportunity-loader-1 |
| opportunity | w10 | 10/5 | 875 | 471 | 245 | – | 4 | opportunity-loader-1 |
| daphnet_fog | w30 | 30/15 | – | – | – | 850 | 10 | daphnet-loader-1 |

`w30t` = dense 2-s-hop transition windows (Opportunity/PAMAP2/HHAR whole recordings; Capture-24 only windows containing an eligible <= 28-s gap event); class heads never train on them.

## Dataset / label-mapping summary

`label_mappings.json` sha256 `19ae2db05815639e1573c3d83d968fc0c1a41cdc4693e2c98a36f1475c0b16eb`; full table: `eval/inertia/label_mappings.md`.

| dataset | role | labels | rows | used rows posture/locomotion/arm/transition/intensity |
|---|---|---|---|---|
| capture24 | train_wrist | 207 | 1035 | 100/140/30/80/206 |
| daphnet_fog | ood_only | 3 | 15 | 0/0/0/0/0 |
| dsads | excluded_other | 19 | 95 | 0/0/0/0/0 |
| extrasensory_watch | excluded_licence | 51 | 255 | 0/0/0/0/0 |
| gotov | excluded_licence | 17 | 85 | 0/0/0/0/0 |
| har70plus | pooled_ablation_non_wrist | 7 | 35 | 0/0/0/0/0 |
| harth | pooled_ablation_non_wrist | 12 | 60 | 0/0/0/0/0 |
| hhar_watch | train_wrist | 7 | 35 | 2/6/0/2/0 |
| mhealth | train_wrist | 13 | 65 | 3/12/5/6/0 |
| nara_activity_stretch_feedback | future | 12 | 60 | 0/0/0/0/0 |
| opportunity | train_wrist | 54 | 270 | 3/4/0/3/0 |
| pamap2 | train_wrist | 19 | 95 | 7/17/4/8/11 |
| realworld2016 | excluded_licence | 8 | 40 | 0/0/0/0/0 |
| recofit | excluded_other | 22 | 110 | 0/0/0/0/0 |
| uci_hapt_waist | pooled_ablation_non_wrist | 12 | 60 | 0/0/0/0/0 |
| uci_hmp_wrist | excluded_licence | 14 | 70 | 0/0/0/0/0 |
| ut_complex_shoaib2016 | excluded_licence | 13 | 65 | 0/0/0/0/0 |
| wear | excluded_licence | 19 | 95 | 0/0/0/0/0 |
| wisdm2019_watch | train_wrist | 18 | 90 | 2/15/4/14/0 |

## Capture-24 source verification

Training uses the HuggingFace parquet mirror (`hf_mirror_nz00shuuuu`, 151 participants). Every participant downloaded from the Oxford ORA release so far was compared with it: **48 of 48 complete ORA files identical** (449,565,923 rows; 0 failures; rule: row counts equal; ORA time (no zone, read as UTC) == timestamp_ms exactly; x/y/z max |diff| <= 1e-6 (max observed 4.77e-7: HF stores the float32 of the ORA value); annotations exactly equal, missing aligned). Incomplete: P008.csv.gz.tmp (0 bytes; the downloader stopped at 17:04 and is not running). The remaining 103 participants are verified only through the mirror's own SHA256SUMS. Verified: P002 P006 P011 P016 P019 P022 P023 P024 P026 P028 P029 P030 P031 P034 P035 P037 P043 P046 P049 P051 P053 P058 P066 P070 P072 P077 P078 P079 P083 P087 P089 P093 P095 P097 P099 P102 P103 P113 P116 P117 P118 P123 P127 P129 P130 P134 P135 P150.

## Test-split ledger (evaluate-once integrity)

The test split is assembled only inside the TestVault; a re-evaluation needs an enumerated reason (`artifact_lost_identical_rebuild`, `evaluator_bug_fix`, `post_audit_rule_change`, `provenance_rebuild`) plus free-text detail.

| # | experiment | bundle sha256 | test split sha256 | n evals (this split) | rerun reason | detail |
|---|---|---|---|---|---|---|
| 1 | ood-hc | `27f77d7fef2922d2` | `6afd705530ea` | 1 |  |  |
| 2 | primary-hc | `d485c24b3ae5503f` | `6afd705530ea` | 1 |  |  |
| 3 | ood-nf | `91e16681ea3aeb9c` | `6afd705530ea` | 1 |  |  |
| 4 | primary-nf | `8a74b3989a8f3b1a` | `6afd705530ea` | 1 |  |  |
| 5 | linear-hc | `26222b12b4bb0264` | `6afd705530ea` | 1 |  |  |
| 6 | lodo-c24only-hc | `d9a458622f82bbc3` | `6afd705530ea` | 1 |  |  |
| 7 | mlp-hc | `93d773947a6f8fc0` | `6afd705530ea` | 1 |  |  |
| 8 | linear-nf | `c4a5a16145533ae9` | `6afd705530ea` | 1 |  |  |
| 9 | lodo-nohhar-hc | `67a3704c8f5798fa` | `6afd705530ea` | 1 |  |  |
| 10 | ood-art | `5b0df3c3536731cc` | `6afd705530ea` | 1 |  |  |
| 11 | seed1-hc | `85b64aa131f7b876` | `6afd705530ea` | 1 |  |  |
| 12 | w10-hc | `94a865079631df30` | `fe25fb43c8cb` | 1 |  |  |
| 13 | seed2-hc | `48b2b61521e79855` | `6afd705530ea` | 1 |  |  |
| 14 | lodo-noc24-hc | `b73e7fb72e61cc78` | `6afd705530ea` | 1 |  |  |
| 15 | ood-hc | `0ad677d470782c0d` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 16 | ood-nf | `c622221dd1c5cae8` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 17 | lodo-c24only-hc | `c0d3529c78c7e979` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 18 | primary-hc | `f61007169e3d3ad9` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 19 | primary-nf | `573f8b46431726cf` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 20 | lodo-noc24-hc | `f5793b3ac33c64da` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 21 | linear-hc | `b68e2cecc6fa6631` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 22 | linear-nf | `52163f0733739e01` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 23 | w10-hc | `e1256ed06c23ed21` | `fe25fb43c8cb` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 24 | mlp-hc | `f4c14ff205e8863f` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 25 | seed1-hc | `f6630f03aaf96bff` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 26 | linear-art | `afe7aced6ba22245` | `6afd705530ea` | 1 |  |  |
| 27 | mlp-art | `de5c5b711d0bafcc` | `6afd705530ea` | 1 |  |  |
| 28 | lodo-nohhar-hc | `697310ada5cb0bc8` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 29 | primary-art | `02759f77b142d3c1` | `6afd705530ea` | 1 |  |  |
| 30 | seed2-hc | `c565508a8c716e2a` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 31 | ood-art | `dcfe3f2253ed896c` | `6afd705530ea` | 2 | legacy free text (pre-enumeration) | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 32 | ood-hc | `811ef6e2a28314d4` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 33 | ood-nf | `bb828ffb3235147e` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 34 | ood-art | `3784c9c5bdcc7085` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 35 | primary-hc | `f03f85acf7e06e9b` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 36 | primary-nf | `e8a34e919d5d19b5` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 37 | primary-art | `c0eb1a045f749df3` | `6afd705530ea` | 2 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 38 | linear-hc | `6dac0eddb1f9875c` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 39 | mlp-hc | `97115d4109c57015` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 40 | linear-art | `f0a839da6c42f169` | `6afd705530ea` | 2 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 41 | mlp-art | `8df3f9f10866715e` | `6afd705530ea` | 2 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 42 | linear-nf | `ac609c4fd7435a28` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 43 | w10-hc | `1cd36c60fda273ab` | `fe25fb43c8cb` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 44 | lodo-noc24-hc | `62b9566ced026d1e` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 45 | lodo-c24only-hc | `0af9f28cbb271e4e` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 46 | lodo-nohhar-hc | `cb2cd3200eaace91` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 47 | seed1-hc | `1141f03851e3f4e0` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |
| 48 | seed2-hc | `796029c9cb29261c` | `6afd705530ea` | 3 | post_audit_rule_change | red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207 |

Re-evaluations by reason: legacy free text (pre-enumeration): 14 (the run-1 bundle directory was deleted by an external process; the bundles were retrained deterministically and re-evaluated: every metric identical to run 1 at tolerance 1e-9; only bundle hashes differ (the manifest records creation time)); post_audit_rule_change: 17 (a training/selection/gate/metric rule changed after an audit that had seen test results; the new test numbers are NOT pristine).

## Disclosures (test-set exposure and evaluator changes)

- **WISDM / PAMAP2 test numbers are not fully pristine (G-8).** Prototyping in `research/inertia-work/agentD` loaded WISDM-2019 and PAMAP2 subjects that are in the frozen TEST split and printed test-subject deltas next to the validation numbers while the head grid and the arch-selection rule were being chosen; the final `train_heads` GRID and RULE equal the prototype's. No threshold, calibration or status was fit on test, but the procedure was designed with test feedback visible, so read WISDM and PAMAP2 test results as optimistic. The prototype scripts (`proto_*.py`, `run_proto.py`, `run_lodo.py`, `select_rule.py`) load only WISDM and PAMAP2; they contain no Capture-24, HHAR, MHEALTH or Opportunity code path.
- **Evaluator diagnostic changed between runs (G-17).** Run 1 recorded `apply_vs_apply_arrays_max_abs` (bundle.apply vs bundle.apply_arrays); run 2 records `apply_vs_training_side_max_abs` (bundle.apply vs the training-side numpy path). Every metric of the 14 re-evaluated experiments was identical between the runs; only that diagnostic field changed.
- **Rule changes after the audit.** The strong/weak VAL rule (subject-cluster bootstrap, >= 5 subjects), the test gate (weak -> abstain, per-dataset demotion), the merge table and the macro-F1 convention were changed after a red-team audit that had seen these test results; evaluations made with the new rules are recorded as `post_audit_rule_change` re-evaluations and are not pristine either.

## Nara/WHOOP fixture behaviour

There is **no labelled WHOOP data**: nothing above is a WHOOP accuracy result. What the WHOOP path is tested with is a synthetic, deterministic golden fixture (`fixtures/inertia/`, regenerated by `python -m activity_context.inertia.make_golden`, checked by `make_golden --check` and `tests/inertia/test_inertia_golden.py`):

- input: one WHOOP-format infer request — 1 s head + 100 s body + 1 s tail of NPB1 int16 columns at 100 Hz, 4096 LSB/g (still, seated-like tilt with sway, 1.8 Hz gait), hop 5 s;
- path: `inertia-prep-1` (accel only, g, 10 Hz Butterworth filtfilt, resample_poly 1/5 -> 20 Hz, 30 s windows) -> the stand-in encoder `standin:inertia-arch-random-init/ar_transformer-tiny/seed0` (seeded random init, NOT Inertia-1) -> a fixed-weight shadow bundle (`bundle_tiny`, every calibration method, covers, merge_into, MLP + linear heads, kNN OOD) -> the `motion-heads-1` response: 15 windows, heads arm_behavior, locomotion, posture, transition, tier `shadow`, encoder_kind `standin`;
- serve: the same response is reproduced in-process and through the `python -m activity_context.inertia.serve --allow-standin-shadow` subprocess (byte-for-byte on every field but duration_ms); without the flag it is refused;
- Swift: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/MotionHeadsContractTests.swift` decodes the same golden response (`MotionHeadsResponse.decode`), checks the class orders / wire keys, and pushes it through the track builder (every window attaches to an observed second in [e, e+2]).

What it does NOT exercise: real Inertia-1 weights (none are public), WHOOP-specific signal statistics, any accuracy on WHOOP data, or candidate-mode evidence on a real night (stand-ins are refused as evidence).


## Measured vs inferred vs blocked

- **Measured**: every test number above (stand-in encoders, public wrist datasets, frozen subject splits, evaluated once through `load_bundle().apply()`).
- **Inferred**: how a real Inertia-1 embedding would compare — nothing here measures it. Relative ordering of stand-ins indicates what the heads/calibration/OOD machinery does with informative vs uninformative embeddings.
- **Hypothesis**: posture (seated vs standing) from a wrist is inferred probabilistically from behaviour, not observed.
- **Blocked**: real Inertia-1 (`primary-inertia1`), its system-level decoder comparison and any production promotion.

