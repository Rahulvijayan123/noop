# Inertia-1 heads — evaluation summary

> **SUPERSEDED — pending re-evaluation.** These numbers were produced before the red-team fixes (subject-clustered strong/weak rule, per-dataset test gate with weak → abstain, sealed gate files, compatible-only merges, union macro-F1, awake-lying and single-label reporting, provenance). Every bundle is being retrained from a clean commit and re-evaluated (`post_audit_rule_change`); `pipeline_cli summary` regenerates this file with the per-dataset tables and the disclosures (WISDM/PAMAP2 test exposure during prototyping; evaluator field change between runs 1 and 2).

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

Status: real Inertia-1 evaluation **BLOCKED** (no public checkpoint; `pipeline_cli embed --encoder inertia-1/ar_transformer-small/30s@20hz` fails with `model_missing: blocked: no checkpoint`). The bundles below use stand-in encoders (`standin:handcrafted-stats-v1` = engineered baseline, `standin:nara-imu-feat-1-accel` = what the decoder already sees, `standin:inertia-arch-random-init/ar_transformer-small/seed0` = negative control). All are `evidence_tier_max = shadow`.

## Experiments

| experiment | role | encoder | window | training datasets | bundle | sha256 | evaluated |
|---|---|---|---|---|---|---|---|
| ood-hc | ood_bench | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-ood-hc` | `0ad677d470782c0d` | yes (n=2) |
| ood-nf | ood_bench | nf | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-ood-nf` | `c622221dd1c5cae8` | yes (n=2) |
| ood-art | ood_bench | art | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-ood-art` | `dcfe3f2253ed896c` | yes (n=2) |
| primary-hc | primary | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-primary-hc` | `f61007169e3d3ad9` | yes (n=2) |
| primary-nf | primary | nf | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-primary-nf` | `573f8b46431726cf` | yes (n=2) |
| primary-art | primary | art | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-primary-art` | `02759f77b142d3c1` | yes (n=1) |
| linear-hc | arch | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-linear-hc` | `b68e2cecc6fa6631` | yes (n=2) |
| mlp-hc | arch | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-mlp-hc` | `f4c14ff205e8863f` | yes (n=2) |
| linear-art | arch | art | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-linear-art` | `afe7aced6ba22245` | yes (n=1) |
| mlp-art | arch | art | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-mlp-art` | `de5c5b711d0bafcc` | yes (n=1) |
| linear-nf | arch | nf | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-linear-nf` | `52163f0733739e01` | yes (n=2) |
| w10-hc | window | hc | w10 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-w10-hc` | `e1256ed06c23ed21` | yes (n=2) |
| lodo-noc24-hc | lodo | hc | w30 | wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-lodo-noc24-hc` | `f5793b3ac33c64da` | yes (n=2) |
| lodo-c24only-hc | lodo | hc | w30 | capture24 | `shadow-lodo-c24only-hc` | `c0d3529c78c7e979` | yes (n=2) |
| lodo-nohhar-hc | lodo | hc | w30 | capture24, wisdm2019_watch, pamap2, mhealth, opportunity | `shadow-lodo-nohhar-hc` | `697310ada5cb0bc8` | yes (n=2) |
| seed1-hc | seed | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-seed1-hc` | `f6630f03aaf96bff` | yes (n=2) |
| seed2-hc | seed | hc | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-seed2-hc` | `c565508a8c716e2a` | yes (n=2) |
| primary-inertia1 | primary | inertia1 | w30 | capture24, wisdm2019_watch, hhar_watch, pamap2, mhealth, opportunity | `shadow-primary-inertia1` | `` | blocked |

## Headline (pooled test, subject-cluster bootstrap 95% CI)

| experiment | head | n | macro-F1 [95% CI] | balanced acc [95% CI] | NLL | Brier | ECE-15 | majority macro-F1 |
|---|---|---|---|---|---|---|---|---|
| primary-hc | posture | 74,475 | 0.657 [0.638, 0.676] | 0.645 [0.629, 0.661] | 0.389 | 0.216 | 0.024 | 0.250 |
| primary-hc | locomotion | 91,653 | 0.678 [0.642, 0.706] | 0.640 [0.595, 0.685] | 0.375 | 0.180 | 0.022 | 0.127 |
| primary-hc | arm_behavior | 20,972 | 0.422 [0.375, 0.486] | 0.434 [0.392, 0.546] | 0.705 | 0.461 | 0.072 | 0.262 |
| primary-nf | posture | 74,475 | 0.598 [0.583, 0.611] | 0.596 [0.582, 0.609] | 0.484 | 0.262 | 0.027 | 0.250 |
| primary-nf | locomotion | 91,653 | 0.417 [0.380, 0.439] | 0.422 [0.397, 0.447] | 0.475 | 0.229 | 0.015 | 0.127 |
| primary-nf | arm_behavior | 20,972 | 0.353 [0.307, 0.422] | 0.395 [0.362, 0.493] | 0.738 | 0.478 | 0.068 | 0.262 |
| primary-art | posture | 74,475 | 0.460 [0.436, 0.488] | 0.473 [0.448, 0.502] | 0.704 | 0.432 | 0.108 | 0.250 |
| primary-art | locomotion | 91,653 | 0.254 [0.219, 0.277] | 0.253 [0.212, 0.288] | 0.657 | 0.310 | 0.052 | 0.127 |
| primary-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.740 | 0.470 | 0.056 | 0.262 |
| linear-hc | posture | 74,475 | 0.618 [0.605, 0.628] | 0.617 [0.605, 0.627] | 0.413 | 0.231 | 0.014 | 0.250 |
| linear-hc | locomotion | 91,653 | 0.620 [0.572, 0.658] | 0.564 [0.506, 0.616] | 0.424 | 0.198 | 0.037 | 0.127 |
| linear-hc | arm_behavior | 20,972 | 0.422 [0.375, 0.486] | 0.434 [0.392, 0.546] | 0.705 | 0.461 | 0.072 | 0.262 |
| mlp-hc | posture | 74,475 | 0.657 [0.638, 0.676] | 0.645 [0.629, 0.661] | 0.389 | 0.216 | 0.024 | 0.250 |
| mlp-hc | locomotion | 91,653 | 0.678 [0.642, 0.706] | 0.640 [0.595, 0.685] | 0.375 | 0.180 | 0.022 | 0.127 |
| mlp-hc | arm_behavior | 20,972 | 0.416 [0.372, 0.462] | 0.471 [0.427, 0.566] | 0.665 | 0.441 | 0.066 | 0.262 |
| linear-art | posture | 74,475 | 0.432 [0.411, 0.455] | 0.445 [0.422, 0.472] | 0.742 | 0.464 | 0.072 | 0.250 |
| linear-art | locomotion | 91,653 | 0.232 [0.193, 0.258] | 0.235 [0.193, 0.273] | 0.690 | 0.318 | 0.040 | 0.127 |
| linear-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.727 | 0.462 | 0.085 | 0.262 |
| mlp-art | posture | 74,475 | 0.460 [0.436, 0.488] | 0.473 [0.448, 0.502] | 0.704 | 0.432 | 0.108 | 0.250 |
| mlp-art | locomotion | 91,653 | 0.254 [0.219, 0.277] | 0.253 [0.212, 0.288] | 0.657 | 0.310 | 0.052 | 0.127 |
| mlp-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.740 | 0.470 | 0.056 | 0.262 |
| linear-nf | posture | 74,475 | 0.567 [0.554, 0.582] | 0.574 [0.562, 0.587] | 0.552 | 0.290 | 0.087 | 0.250 |
| linear-nf | locomotion | 91,653 | 0.393 [0.366, 0.414] | 0.375 [0.351, 0.394] | 0.507 | 0.234 | 0.044 | 0.127 |
| linear-nf | arm_behavior | 20,972 | 0.353 [0.307, 0.422] | 0.395 [0.362, 0.493] | 0.738 | 0.478 | 0.068 | 0.262 |
| w10-hc | posture | 227,293 | 0.618 [0.601, 0.634] | 0.613 [0.600, 0.625] | 0.454 | 0.255 | 0.043 | 0.212 |
| w10-hc | locomotion | 282,152 | 0.616 [0.583, 0.641] | 0.589 [0.560, 0.619] | 0.434 | 0.205 | 0.021 | 0.127 |
| w10-hc | arm_behavior | 64,906 | 0.430 [0.379, 0.498] | 0.443 [0.404, 0.552] | 0.708 | 0.466 | 0.069 | 0.260 |

## Per-class test F1 (precision/recall) — primary bundles

#### posture

| class | primary-hc F1 (P/R) | primary-nf F1 (P/R) | primary-art F1 (P/R) | linear-hc F1 (P/R) | mlp-hc F1 (P/R) | test support | final status (primary-hc) |
|---|---|---|---|---|---|---|---|
| recumbent | 0.91 (0.91/0.92) | 0.89 (0.85/0.94) | 0.75 (0.72/0.77) | 0.91 (0.89/0.93) | 0.91 (0.91/0.92) | 38,480 | strong→strong |
| seated_likely | 0.84 (0.81/0.87) | 0.80 (0.81/0.79) | 0.63 (0.61/0.65) | 0.83 (0.81/0.85) | 0.84 (0.81/0.87) | 31,775 | weak→weak |
| upright_stationary | 0.22 (0.47/0.14) | 0.10 (0.33/0.06) | 0.00 (0.00/0.00) | 0.11 (0.29/0.07) | 0.22 (0.47/0.14) | 4,220 | abstain→abstain |
| postural_transition | unsupported | unsupported | unsupported | unsupported | unsupported | 0 | unsupported→– |

#### locomotion

| class | primary-hc F1 (P/R) | primary-nf F1 (P/R) | primary-art F1 (P/R) | linear-hc F1 (P/R) | mlp-hc F1 (P/R) | test support | final status (primary-hc) |
|---|---|---|---|---|---|---|---|
| stationary | 0.94 (0.91/0.97) | 0.92 (0.86/0.98) | 0.89 (0.81/1.00) | 0.93 (0.89/0.98) | 0.94 (0.91/0.97) | 73,196 | strong→strong |
| walking | 0.66 (0.80/0.56) | 0.57 (0.72/0.48) | 0.15 (0.79/0.08) | 0.63 (0.82/0.51) | 0.66 (0.80/0.56) | 8,527 | strong→strong |
| brisk_walking | unsupported | unsupported | unsupported | unsupported | unsupported | 0 | unsupported→– |
| running | 0.88 (0.91/0.85) | 0.80 (0.69/0.95) | 0.72 (0.75/0.68) | 0.78 (0.95/0.67) | 0.88 (0.91/0.85) | 203 | strong→weak |
| stairs | 0.73 (0.72/0.74) | 0.00 (0.00/0.00) | 0.00 (0.00/0.00) | 0.72 (0.69/0.76) | 0.73 (0.72/0.74) | 152 | weak→weak |
| cycling | 0.67 (0.72/0.63) | 0.46 (0.49/0.43) | 0.00 (0.00/0.00) | 0.62 (0.71/0.55) | 0.67 (0.72/0.63) | 808 | weak→weak |
| vehicle_motion | 0.50 (0.71/0.38) | 0.00 (0.31/0.00) | 0.00 (0.00/0.00) | 0.37 (0.76/0.25) | 0.50 (0.71/0.38) | 3,518 | weak→weak |
| other | 0.37 (0.40/0.35) | 0.17 (0.27/0.12) | 0.02 (0.22/0.01) | 0.28 (0.34/0.24) | 0.37 (0.40/0.35) | 5,249 | abstain→abstain |

#### arm_behavior

| class | primary-hc F1 (P/R) | primary-nf F1 (P/R) | primary-art F1 (P/R) | linear-hc F1 (P/R) | mlp-hc F1 (P/R) | test support | final status (primary-hc) |
|---|---|---|---|---|---|---|---|
| quiet | 0.15 (0.41/0.09) | 0.04 (0.49/0.02) | 0.00 (0.00/0.00) | 0.15 (0.41/0.09) | 0.00 (0.08/0.00) | 6,845 | abstain→abstain |
| desk_like | 0.78 (0.67/0.94) | 0.78 (0.65/0.98) | 0.78 (0.65/1.00) | 0.78 (0.67/0.94) | 0.79 (0.66/0.99) | 13,545 | abstain→abstain |
| fidgeting | unsupported | unsupported | unsupported | unsupported | unsupported | 0 | unsupported→– |
| repetitive_hand_motion | 0.34 (0.44/0.27) | 0.23 (0.32/0.18) | 0.00 (0.00/0.00) | 0.34 (0.44/0.27) | 0.46 (0.51/0.42) | 582 | weak→weak |
| active_gesturing | unsupported | unsupported | unsupported | unsupported | unsupported | 0 | unsupported→– |
| exercise_motion | unsupported | unsupported | unsupported | unsupported | unsupported | 0 | unsupported→– |
| other | unsupported | unsupported | unsupported | unsupported | unsupported | 0 | unsupported→– |

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

| experiment | head | n | macro-F1 [95% CI] | balanced acc [95% CI] | NLL | Brier | ECE-15 | majority macro-F1 |
|---|---|---|---|---|---|---|---|---|
| primary-hc | posture | 74,475 | 0.657 [0.638, 0.676] | 0.645 [0.629, 0.661] | 0.389 | 0.216 | 0.024 | 0.250 |
| primary-hc | locomotion | 91,653 | 0.678 [0.642, 0.706] | 0.640 [0.595, 0.685] | 0.375 | 0.180 | 0.022 | 0.127 |
| primary-hc | arm_behavior | 20,972 | 0.422 [0.375, 0.486] | 0.434 [0.392, 0.546] | 0.705 | 0.461 | 0.072 | 0.262 |
| w10-hc | posture | 227,293 | 0.618 [0.601, 0.634] | 0.613 [0.600, 0.625] | 0.454 | 0.255 | 0.043 | 0.212 |
| w10-hc | locomotion | 282,152 | 0.616 [0.583, 0.641] | 0.589 [0.560, 0.619] | 0.434 | 0.205 | 0.021 | 0.127 |
| w10-hc | arm_behavior | 64,906 | 0.430 [0.379, 0.498] | 0.443 [0.404, 0.552] | 0.708 | 0.466 | 0.069 | 0.260 |

### Linear vs MLP (forced, test)

| experiment | head | n | macro-F1 [95% CI] | balanced acc [95% CI] | NLL | Brier | ECE-15 | majority macro-F1 |
|---|---|---|---|---|---|---|---|---|
| linear-hc | posture | 74,475 | 0.618 [0.605, 0.628] | 0.617 [0.605, 0.627] | 0.413 | 0.231 | 0.014 | 0.250 |
| linear-hc | locomotion | 91,653 | 0.620 [0.572, 0.658] | 0.564 [0.506, 0.616] | 0.424 | 0.198 | 0.037 | 0.127 |
| linear-hc | arm_behavior | 20,972 | 0.422 [0.375, 0.486] | 0.434 [0.392, 0.546] | 0.705 | 0.461 | 0.072 | 0.262 |
| mlp-hc | posture | 74,475 | 0.657 [0.638, 0.676] | 0.645 [0.629, 0.661] | 0.389 | 0.216 | 0.024 | 0.250 |
| mlp-hc | locomotion | 91,653 | 0.678 [0.642, 0.706] | 0.640 [0.595, 0.685] | 0.375 | 0.180 | 0.022 | 0.127 |
| mlp-hc | arm_behavior | 20,972 | 0.416 [0.372, 0.462] | 0.471 [0.427, 0.566] | 0.665 | 0.441 | 0.066 | 0.262 |
| linear-art | posture | 74,475 | 0.432 [0.411, 0.455] | 0.445 [0.422, 0.472] | 0.742 | 0.464 | 0.072 | 0.250 |
| linear-art | locomotion | 91,653 | 0.232 [0.193, 0.258] | 0.235 [0.193, 0.273] | 0.690 | 0.318 | 0.040 | 0.127 |
| linear-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.727 | 0.462 | 0.085 | 0.262 |
| mlp-art | posture | 74,475 | 0.460 [0.436, 0.488] | 0.473 [0.448, 0.502] | 0.704 | 0.432 | 0.108 | 0.250 |
| mlp-art | locomotion | 91,653 | 0.254 [0.219, 0.277] | 0.253 [0.212, 0.288] | 0.657 | 0.310 | 0.052 | 0.127 |
| mlp-art | arm_behavior | 20,972 | 0.262 [0.240, 0.283] | 0.333 [0.333, 0.333] | 0.740 | 0.470 | 0.056 | 0.262 |

### Leave-one-dataset-out transfer (hc)

| posture macro-F1 by test dataset | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| primary-hc | 0.650 | 0.657 | 0.256 | 0.684 | 0.746 | 0.719 |
| lodo-noc24-hc | 0.424 | 0.919 | 0.378 | 0.769 | 0.661 | 0.892 |
| lodo-c24only-hc | 0.704 | 0.287 | 0.383 | 0.626 | 0.502 | 0.354 |
| lodo-nohhar-hc | 0.646 | 0.487 | 0.286 | 0.684 | 0.736 | 0.728 |

| locomotion macro-F1 by test dataset | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| primary-hc | 0.560 | 0.966 | 0.750 | 0.958 | 0.757 | 0.928 |
| lodo-noc24-hc | 0.528 | 0.990 | 0.825 | 1.000 | 0.975 | 0.957 |
| lodo-c24only-hc | 0.662 | 0.850 | 0.579 | 0.604 | 0.663 | 0.740 |
| lodo-nohhar-hc | 0.570 | 0.939 | 0.845 | 0.972 | 0.789 | 0.938 |

| arm_behavior macro-F1 by test dataset | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| primary-hc | 0.341 | 0.000 | 0.341 | 0.860 |
| lodo-noc24-hc | 0.392 | – | 1.000 | 0.896 |
| lodo-c24only-hc | 0.399 | 0.000 | 0.000 | 1.000 |
| lodo-nohhar-hc | 0.342 | 0.000 | 0.341 | 0.860 |

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

`label_mappings.json` sha256 `a7d142240bf1247845714c2e0157a3deb7f8a7d1e9f4fd23acfb28170c9b7b21`; full table: `eval/inertia/label_mappings.md`.

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

## Test-split ledger (evaluate-once integrity)

| # | experiment | bundle sha256 | test split sha256 | n evals of experiment | rerun reason |
|---|---|---|---|---|---|
| 1 | ood-hc | `27f77d7fef2922d2` | `6afd705530ea` | 1 |  |
| 2 | primary-hc | `d485c24b3ae5503f` | `6afd705530ea` | 1 |  |
| 3 | ood-nf | `91e16681ea3aeb9c` | `6afd705530ea` | 1 |  |
| 4 | primary-nf | `8a74b3989a8f3b1a` | `6afd705530ea` | 1 |  |
| 5 | linear-hc | `26222b12b4bb0264` | `6afd705530ea` | 1 |  |
| 6 | lodo-c24only-hc | `d9a458622f82bbc3` | `6afd705530ea` | 1 |  |
| 7 | mlp-hc | `93d773947a6f8fc0` | `6afd705530ea` | 1 |  |
| 8 | linear-nf | `c4a5a16145533ae9` | `6afd705530ea` | 1 |  |
| 9 | lodo-nohhar-hc | `67a3704c8f5798fa` | `6afd705530ea` | 1 |  |
| 10 | ood-art | `5b0df3c3536731cc` | `6afd705530ea` | 1 |  |
| 11 | seed1-hc | `85b64aa131f7b876` | `6afd705530ea` | 1 |  |
| 12 | w10-hc | `94a865079631df30` | `fe25fb43c8cb` | 1 |  |
| 13 | seed2-hc | `48b2b61521e79855` | `6afd705530ea` | 1 |  |
| 14 | lodo-noc24-hc | `b73e7fb72e61cc78` | `6afd705530ea` | 1 |  |
| 15 | ood-hc | `0ad677d470782c0d` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 16 | ood-nf | `c622221dd1c5cae8` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 17 | lodo-c24only-hc | `c0d3529c78c7e979` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 18 | primary-hc | `f61007169e3d3ad9` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 19 | primary-nf | `573f8b46431726cf` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 20 | lodo-noc24-hc | `f5793b3ac33c64da` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 21 | linear-hc | `b68e2cecc6fa6631` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 22 | linear-nf | `52163f0733739e01` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 23 | w10-hc | `e1256ed06c23ed21` | `fe25fb43c8cb` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 24 | mlp-hc | `f4c14ff205e8863f` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 25 | seed1-hc | `f6630f03aaf96bff` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 26 | linear-art | `afe7aced6ba22245` | `6afd705530ea` | 1 |  |
| 27 | mlp-art | `de5c5b711d0bafcc` | `6afd705530ea` | 1 |  |
| 28 | lodo-nohhar-hc | `697310ada5cb0bc8` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 29 | primary-art | `02759f77b142d3c1` | `6afd705530ea` | 1 |  |
| 30 | seed2-hc | `c565508a8c716e2a` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |
| 31 | ood-art | `dcfe3f2253ed896c` | `6afd705530ea` | 2 | run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed |

14 re-evaluations: the run-1 bundle directory was deleted by an external process; the bundles were retrained from identical code/data/splits and re-evaluated. Every metric of all 14 re-evaluated experiments was identical to run 1 (field-by-field comparison of evaluation.json, tolerance 1e-9) — training and evaluation are deterministic on CPU. Only bundle hashes differ (the manifest records creation time).

## Measured vs inferred vs blocked

- **Measured**: every test number above (stand-in encoders, public wrist datasets, frozen subject splits, evaluated once through `load_bundle().apply()`).
- **Inferred**: how a real Inertia-1 embedding would compare — nothing here measures it. Relative ordering of stand-ins indicates what the heads/calibration/OOD machinery does with informative vs uninformative embeddings.
- **Hypothesis**: posture (seated vs standing) from a wrist is inferred probabilistically from behaviour, not observed.
- **Blocked**: real Inertia-1 (`primary-inertia1`), its system-level decoder comparison and any production promotion.

