# Evaluation — `shadow-primary-nf` (primary)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- bundle_sha256 `573f8b46431726cf60270fcc84d0c0aaf8f639e054e5e0414e22fe4caa09abd8`; encoder `standin:nara-imu-feat-1-accel` (standin); evidence_tier_max `shadow`
- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment: 2 (rerun reason: run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

### posture

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.827 | 0.596 [0.582, 0.609] | 0.598 [0.583, 0.611] | 0.784→0.484 | 0.456→0.262 | 0.206→0.027 (0.005) | 0.219→0.039 | 0.103 |

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | yes | 39,463 | 0.847 | 0.941 | 0.892 | 0.058 | strong | 0.855 | P=0.953 n=23,610 pass | strong | 0 |
| seated_likely | yes | 30,792 | 0.811 | 0.785 | 0.798 | 0.051 | weak | 0.300 | P=0.811 n=29,798 fail | weak | 0 |
| upright_stationary | yes | 4,220 | 0.330 | 0.062 | 0.105 | 0.007 | abstain | 1.000 | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 73,985 | 0.598 | 0.600 [0.585, 0.611] | 0.477 | 0.028 | recumbent 0.89 (n=39388), seated_likely 0.80 (n=30561), upright_stationary 0.11 (n=4036) |
| hhar_watch | 74 | 0.027 | 0.048 [0.043, 0.053] | 2.994 | 0.785 | seated_likely 0.10 (n=37), upright_stationary 0.00 (n=37) |
| mhealth | 16 | 0.333 | 0.133 [0.133, 0.133] | 2.310 | 0.584 | recumbent 0.40 (n=4), seated_likely 0.00 (n=6), upright_stationary 0.00 (n=6) |
| opportunity | 37 | 0.500 | 0.448 [0.448, 0.448] | 0.401 | 0.128 | seated_likely 0.90 (n=30), upright_stationary 0.00 (n=7) |
| pamap2 | 204 | 0.556 | 0.489 [0.311, 0.542] | 0.912 | 0.204 | recumbent 0.79 (n=71), seated_likely 0.64 (n=78), upright_stationary 0.03 (n=55) |
| wisdm2019_watch | 159 | 0.275 | 0.254 [0.173, 0.301] | 1.752 | 0.480 | seated_likely 0.51 (n=80), upright_stationary 0.00 (n=79) |

Wrist-only: n=74,475, macro-F1 0.598 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.990, P 0.830; ≥0.6: cov 0.922, P 0.850; ≥0.7: cov 0.768, P 0.875; ≥0.8: cov 0.638, P 0.895; ≥0.9: cov 0.350, P 0.931; ≥0.95: cov 0.021, P 0.840

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  37152    2165     146       0
   6234   24172     386       0
    497    3461     262       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.837 | 0.422 [0.397, 0.447] | 0.417 [0.380, 0.439] | 0.820→0.475 | 0.410→0.229 | 0.055→0.015 (0.004) | 0.085→0.011 | 0.037 |

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,230 | 0.865 | 0.976 | 0.917 | 0.013 | strong | 0.760 | P=0.958 n=63,667 pass | strong | 0 |
| walking | yes | 8,493 | 0.722 | 0.475 | 0.573 | 0.022 | weak | 0.600 | P=0.883 n=3,335 fail | weak | 0 |
| brisk_walking | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| running | yes | 203 | 0.689 | 0.951 | 0.799 | 0.001 | weak | 0.525 | P=0.787 n=230 fail | weak | 0 |
| stairs | yes | 152 | 0.000 | 0.000 | 0.000 | 0.005 | abstain | 1.000 | – | abstain | 0 |
| cycling | yes | 808 | 0.494 | 0.431 | 0.460 | 0.006 | weak | 0.300 | P=0.494 n=705 fail | weak | 0 |
| vehicle_motion | yes | 3,518 | 0.312 | 0.001 | 0.003 | 0.017 | abstain | 1.000 | – | abstain | 0 |
| other | yes | 5,249 | 0.269 | 0.123 | 0.168 | 0.013 | abstain | 1.000 | – | abstain | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 89,829 | 0.415 | 0.396 [0.289, 0.441] | 0.473 | 0.016 | stationary 0.92 (n=71976), walking 0.57 (n=8341), running 0.67 (n=103), stairs 0.00 (n=8), cycling 0.45 (n=743), vehicle_motion 0.00 (n=3484), other 0.16 (n=5174) |
| hhar_watch | 174 | 0.644 | 0.588 [0.431, 0.663] | 0.651 | 0.162 | stationary 0.91 (n=74), walking 0.71 (n=35), stairs 0.00 (n=32), cycling 0.73 (n=33) |
| mhealth | 49 | 0.714 | 0.658 [0.640, 0.861] | 0.504 | 0.091 | stationary 0.84 (n=19), walking 0.57 (n=4), running 1.00 (n=10), stairs 0.00 (n=3), cycling 1.00 (n=4), other 0.53 (n=9) |
| opportunity | 37 | 0.946 | 0.972 [0.972, 0.972] | 0.402 | 0.236 | stationary 0.97 (n=37) |
| pamap2 | 397 | 0.573 | 0.531 [0.499, 0.675] | 0.853 | 0.102 | stationary 0.84 (n=187), walking 0.53 (n=43), running 0.95 (n=10), stairs 0.00 (n=29), cycling 0.83 (n=28), vehicle_motion 0.00 (n=34), other 0.56 (n=66) |
| wisdm2019_watch | 1,167 | 0.678 | 0.617 [0.574, 0.649] | 0.467 | 0.088 | stationary 0.94 (n=937), walking 0.54 (n=70), running 0.98 (n=80), stairs 0.00 (n=80) |

Wrist-only: n=91,653, macro-F1 0.417 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.883, P 0.896; ≥0.6: cov 0.817, P 0.926; ≥0.7: cov 0.757, P 0.946; ≥0.8: cov 0.679, P 0.964; ≥0.9: cov 0.567, P 0.980; ≥0.95: cov 0.440, P 0.987

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71471     916       0      24       1     219       4     595
   3277    4035       0      39       0      76       5    1061
      0       0       0       0       0       0       0       0
      2       7       0     193       0       0       0       1
      4     139       0       0       0       0       0       9
    396      31       0       0       0     348       0      33
   3353      76       0       2       0      30       5      52
   4165     384       0      22       0      32       2     644
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.646 | 0.395 [0.362, 0.493] | 0.353 [0.307, 0.422] | 1.049→0.738 | 0.632→0.478 | 0.135→0.068 (0.008) | 0.200→0.050 | 0.339 |

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.491 | 0.023 | 0.044 | 0.071 | abstain | 1.000 | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.654 | 0.981 | 0.785 | 0.063 | abstain | 1.000 | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.319 | 0.180 | 0.231 | 0.015 | weak | 0.790 | P=0.407 n=145 fail | weak | 0 |
| active_gesturing | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 14 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 20,580 | 0.341 | 0.285 [0.262, 0.304] | 0.735 | 0.067 | quiet 0.04 (n=6802), desk_like 0.79 (n=13385), repetitive_hand_motion 0.03 (n=393) |
| mhealth | 12 | 0.000 | 0.000 [0.000, 0.000] | 1.541 | 0.780 | quiet 0.00 (n=12) |
| pamap2 | 60 | 0.032 | 0.061 [0.000, 0.105] | 1.992 | 0.691 | quiet 0.12 (n=31), repetitive_hand_motion 0.00 (n=29) |
| wisdm2019_watch | 320 | 0.803 | 0.795 [0.609, 0.937] | 0.693 | 0.148 | desk_like 0.84 (n=160), repetitive_hand_motion 0.75 (n=160) |

Wrist-only: n=20,972, macro-F1 0.353 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.981, P 0.650; ≥0.6: cov 0.914, P 0.662; ≥0.7: cov 0.648, P 0.684; ≥0.8: cov 0.007, P 0.400; ≥0.9: cov 0.004, P 0.435; ≥0.95: cov 0.003, P 0.429

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    156    6560       0     129       0       0       0
    157   13293       0      95       0       0       0
      0       0       0       0       0       0       0
      5     472       0     105       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.911 | 0.035 | 0.083→0.079 | 0.203→0.166 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.881 | 0.033 | 0.093→0.085 | 0.233→0.177 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.899 | 0.041 | 0.115→0.106 | 0.273→0.228 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.873 | 0.040 | 0.130→0.109 | 0.312→0.233 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.15/0.64/0.24 | 0.16/0.67/0.25 | 2.1 / 3.7 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.04/0.06/0.05 | 0.14/0.19/0.16 | 8.2 / 8.8 |
| walk_start | 0.30 (weak) | 405 | 0.31/0.41/0.35 | 0.37/0.50/0.42 | 2.0 / 6.3 |
| walk_stop | 0.35 (weak) | 404 | 0.32/0.40/0.35 | 0.39/0.49/0.44 | 2.5 / 6.5 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.173.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.123 | 0.136 | 0.285 | 0.776 | 0.780 |
| capture24 | 95,579 | 0.123 | 0.136 | 0.280 | 0.776 | 0.780 |
| pamap2 | 234 | 0.135 | 0.203 | 0.500 | 0.798 | 0.654 |

## OOD

Bundle method `knn` (k=20), threshold 0.322 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.050 on 97,403 windows.

## Per-window test predictions (outside git)

npz per dataset: uid/subject/session/label (str), t0/t1 (float s, dataset clock: Capture-24 unix s, WISDM device ns/1e9), purity; probs_<head> [N,K] over the fixed class order (NaN = unsupported), raw_logits_<head> (-inf unsupported), movement_intensity, ood_score, is_ood, valid, class_orders_json, bundle_sha256. Join HART windows on (subject, session, t0..t1).

- wisdm2019_watch: `research/inertia-bundles/shadow-primary-nf/test_predictions/wisdm2019_watch.npz` (1,397 windows)
- capture24: `research/inertia-bundles/shadow-primary-nf/test_predictions/capture24.npz` (95,579 windows)

Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
