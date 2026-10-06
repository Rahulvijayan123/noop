# Evaluation — `shadow-primary-art` (primary)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- bundle_sha256 `02759f77b142d3c1ca2a1d6a9520e34194e67edaf2faaf1e53f64af276850e58`; encoder `standin:inertia-arch-random-init/ar_transformer-small/seed0` (standin); evidence_tier_max `shadow`
- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment: 1 (rerun reason: None); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

### posture

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.678 | 0.473 [0.448, 0.502] | 0.460 [0.436, 0.488] | 0.976→0.704 | 0.601→0.432 | 0.074→0.108 (0.005) | 0.188→0.074 | 0.250 |

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | yes | 40,325 | 0.725 | 0.768 | 0.746 | 0.115 | weak | 0.590 | P=0.805 n=20,304 fail | weak | 0 |
| seated_likely | yes | 29,930 | 0.615 | 0.652 | 0.633 | 0.086 | abstain | 1.000 | – | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.000 | 0.000 | 0.000 | 0.020 | abstain | 1.000 | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 73,985 | 0.474 | 0.461 [0.434, 0.484] | 0.699 | 0.110 | recumbent 0.75 (n=40277), seated_likely 0.63 (n=29672), upright_stationary 0.00 (n=4036) |
| hhar_watch | 74 | 0.243 | 0.305 [0.000, 0.500] | 1.501 | 0.255 | seated_likely 0.61 (n=37), upright_stationary 0.00 (n=37) |
| mhealth | 16 | 0.333 | 0.266 [0.000, 0.556] | 1.217 | 0.304 | recumbent 0.44 (n=4), seated_likely 0.35 (n=6), upright_stationary 0.00 (n=6) |
| opportunity | 37 | 0.000 | 0.000 [0.000, 0.000] | 1.452 | 0.604 | seated_likely 0.00 (n=30), upright_stationary 0.00 (n=7) |
| pamap2 | 204 | 0.446 | 0.321 [0.140, 0.365] | 1.256 | 0.369 | recumbent 0.46 (n=44), seated_likely 0.51 (n=105), upright_stationary 0.00 (n=55) |
| wisdm2019_watch | 159 | 0.275 | 0.312 [0.182, 0.436] | 1.468 | 0.246 | seated_likely 0.62 (n=80), upright_stationary 0.00 (n=79) |

Wrist-only: n=74,475, macro-F1 0.460 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.799, P 0.698; ≥0.6: cov 0.319, P 0.798; ≥0.7: cov 0.092, P 0.804; ≥0.8: cov 0.001, P 0.448; ≥0.9: cov 0.000, P –; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  30971    9354       0       0
  10416   19514       0       0
   1341    2879       0       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.809 | 0.253 [0.212, 0.288] | 0.254 [0.219, 0.277] | 1.607→0.657 | 0.880→0.310 | 0.306→0.052 (0.004) | 0.170→0.021 | 0.107 |

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,403 | 0.810 | 0.998 | 0.895 | 0.055 | weak | 0.300 | P=0.811 n=90,399 fail | weak | 0 |
| walking | yes | 8,320 | 0.789 | 0.082 | 0.149 | 0.036 | abstain | 1.000 | – | abstain | 0 |
| brisk_walking | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| running | yes | 203 | 0.754 | 0.680 | 0.715 | 0.001 | weak | 0.300 | P=0.754 n=183 fail | weak | 0 |
| stairs | yes | 152 | 0.000 | 0.000 | 0.000 | 0.005 | abstain | 1.000 | – | abstain | 0 |
| cycling | yes | 808 | 0.000 | 0.000 | 0.000 | 0.009 | abstain | 1.000 | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.000 | 0.000 | 0.000 | 0.022 | abstain | 1.000 | – | abstain | 0 |
| other | yes | 5,249 | 0.218 | 0.008 | 0.016 | 0.017 | abstain | 1.000 | – | abstain | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 89,829 | 0.228 | 0.231 [0.146, 0.278] | 0.654 | 0.051 | stationary 0.89 (n=72149), walking 0.14 (n=8168), running 0.57 (n=103), stairs 0.00 (n=8), cycling 0.00 (n=743), vehicle_motion 0.00 (n=3484), other 0.01 (n=5174) |
| hhar_watch | 174 | 0.257 | 0.170 [0.149, 0.189] | 1.609 | 0.279 | stationary 0.64 (n=74), walking 0.04 (n=35), stairs 0.00 (n=32), cycling 0.00 (n=33) |
| mhealth | 49 | 0.333 | 0.276 [0.274, 0.333] | 1.124 | 0.240 | stationary 0.66 (n=19), walking 0.00 (n=4), running 1.00 (n=10), stairs 0.00 (n=3), cycling 0.00 (n=4), other 0.00 (n=9) |
| opportunity | 37 | 1.000 | 1.000 [1.000, 1.000] | 0.146 | 0.135 | stationary 1.00 (n=37) |
| pamap2 | 397 | 0.401 | 0.309 [0.275, 0.314] | 1.370 | 0.151 | stationary 0.73 (n=187), walking 0.67 (n=43), running 0.62 (n=10), stairs 0.00 (n=29), cycling 0.00 (n=28), vehicle_motion 0.00 (n=34), other 0.14 (n=66) |
| wisdm2019_watch | 1,167 | 0.546 | 0.562 [0.480, 0.616] | 0.519 | 0.130 | stationary 0.94 (n=937), walking 0.43 (n=70), running 0.88 (n=80), stairs 0.00 (n=80) |

Wrist-only: n=91,653, macro-F1 0.254 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.987, P 0.815; ≥0.6: cov 0.970, P 0.822; ≥0.7: cov 0.921, P 0.843; ≥0.8: cov 0.548, P 0.890; ≥0.9: cov 0.044, P 0.943; ≥0.95: cov 0.001, P 0.937

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  73270      47       0       9       0       0       0      77
   7551     686       0      15       0       0       0      68
      0       0       0       0       0       0       0       0
      9      52       0     138       0       0       0       4
    118      31       0       0       0       0       0       3
    796      12       0       0       0       0       0       0
   3514       2       0       0       0       0       0       2
   5145      40       0      21       0       0       0      43
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.646 | 0.333 [0.333, 0.333] | 0.262 [0.240, 0.283] | 1.270→0.740 | 0.796→0.470 | 0.264→0.056 (0.009) | 0.263→0.048 | 0.307 |

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.000 | 0.000 | 0.000 | 0.069 | abstain | 1.000 | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.646 | 1.000 | 0.785 | 0.056 | weak | 0.695 | P=0.713 n=11,074 fail | weak | 0 |
| fidgeting | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.000 | 0.000 | 0.000 | 0.018 | abstain | 1.000 | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 14 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 20,580 | 0.333 | 0.263 [0.241, 0.282] | 0.721 | 0.056 | quiet 0.00 (n=6802), desk_like 0.79 (n=13385), repetitive_hand_motion 0.00 (n=393) |
| mhealth | 12 | 0.000 | 0.000 [0.000, 0.000] | 1.383 | 0.687 | quiet 0.00 (n=12) |
| pamap2 | 60 | 0.000 | 0.000 [0.000, 0.000] | 1.991 | 0.674 | quiet 0.00 (n=31), repetitive_hand_motion 0.00 (n=29) |
| wisdm2019_watch | 320 | 0.500 | 0.333 [0.333, 0.333] | 1.691 | 0.349 | desk_like 0.67 (n=160), repetitive_hand_motion 0.00 (n=160) |

Wrist-only: n=20,972, macro-F1 0.262 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 1.000, P 0.646; ≥0.6: cov 0.957, P 0.661; ≥0.7: cov 0.504, P 0.717; ≥0.8: cov 0.038, P 0.576; ≥0.9: cov 0.000, P –; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
      0    6845       0       0       0       0       0
      0   13545       0       0       0       0       0
      0       0       0       0       0       0       0
      0     582       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.827 | 0.024 | 0.162→0.162 | 0.341→0.312 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.781 | 0.023 | 0.181→0.181 | 0.349→0.357 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.751 | 0.022 | 0.176→0.176 | 0.350→0.352 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.725 | 0.021 | 0.182→0.181 | 0.370→0.363 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.65 (weak) | 36 | 0.17/0.28/0.21 | 0.22/0.36/0.28 | 2.1 / 6.5 |
| stand_to_sit_like | 0.40 (weak) | 36 | 0.05/0.14/0.07 | 0.11/0.31/0.16 | 5.1 / 8.5 |
| walk_start | 0.60 (weak) | 405 | 0.37/0.22/0.28 | 0.38/0.23/0.29 | 2.0 / 3.8 |
| walk_stop | 0.55 (weak) | 404 | 0.36/0.24/0.29 | 0.43/0.29/0.35 | 2.5 / 6.6 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.218.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.146 | 0.136 | 0.007 | 0.399 | 0.792 |
| capture24 | 95,579 | 0.146 | 0.136 | 0.000 | 0.397 | 0.792 |
| pamap2 | 234 | 0.150 | 0.203 | 0.346 | 0.752 | 0.782 |

## OOD

Bundle method `maha_global` (k=None), threshold 35.822 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.070 on 97,403 windows.

## Per-window test predictions (outside git)

npz per dataset: uid/subject/session/label (str), t0/t1 (float s, dataset clock: Capture-24 unix s, WISDM device ns/1e9), purity; probs_<head> [N,K] over the fixed class order (NaN = unsupported), raw_logits_<head> (-inf unsupported), movement_intensity, ood_score, is_ood, valid, class_orders_json, bundle_sha256. Join HART windows on (subject, session, t0..t1).

- wisdm2019_watch: `research/inertia-bundles/shadow-primary-art/test_predictions/wisdm2019_watch.npz` (1,397 windows)
- capture24: `research/inertia-bundles/shadow-primary-art/test_predictions/capture24.npz` (95,579 windows)

Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
