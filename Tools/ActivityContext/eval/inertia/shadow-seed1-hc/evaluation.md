# Evaluation — `shadow-seed1-hc` (seed)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- bundle_sha256 `f6630f03aaf96bff5c34c44e91ba87c62e1a0750423d541a86b07377b39a4a30`; encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment: 2 (rerun reason: run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

### posture

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.861 | 0.650 [0.634, 0.667] | 0.663 [0.643, 0.683] | 0.506→0.372 | 0.290→0.207 | 0.036→0.021 (0.004) | 0.095→0.021 | 0.056 |

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | yes | 38,431 | 0.913 | 0.923 | 0.918 | 0.031 | strong | 0.800 | P=0.960 n=30,812 pass | strong | 0 |
| seated_likely | yes | 31,824 | 0.817 | 0.882 | 0.848 | 0.025 | weak | 0.300 | P=0.817 n=34,334 fail | weak | 0 |
| upright_stationary | yes | 4,220 | 0.469 | 0.147 | 0.224 | 0.006 | abstain | 1.000 | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 73,985 | 0.644 | 0.654 [0.638, 0.674] | 0.370 | 0.021 | recumbent 0.92 (n=38352), seated_likely 0.85 (n=31597), upright_stationary 0.19 (n=4036) |
| hhar_watch | 74 | 0.662 | 0.730 [0.709, 0.746] | 1.021 | 0.115 | seated_likely 0.89 (n=37), upright_stationary 0.57 (n=37) |
| mhealth | 16 | 0.611 | 0.546 [0.357, 0.722] | 0.762 | 0.317 | recumbent 0.62 (n=4), seated_likely 0.22 (n=6), upright_stationary 0.80 (n=6) |
| opportunity | 37 | 0.643 | 0.684 [0.684, 0.684] | 0.447 | 0.118 | seated_likely 0.92 (n=30), upright_stationary 0.44 (n=7) |
| pamap2 | 204 | 0.745 | 0.749 [0.662, 0.749] | 0.583 | 0.077 | recumbent 0.86 (n=75), seated_likely 0.68 (n=74), upright_stationary 0.71 (n=55) |
| wisdm2019_watch | 159 | 0.710 | 0.770 [0.626, 0.886] | 0.705 | 0.092 | seated_likely 0.74 (n=80), upright_stationary 0.80 (n=79) |

Wrist-only: n=74,475, macro-F1 0.663 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.985, P 0.866; ≥0.6: cov 0.908, P 0.888; ≥0.7: cov 0.814, P 0.909; ≥0.8: cov 0.687, P 0.933; ≥0.9: cov 0.472, P 0.958; ≥0.95: cov 0.273, P 0.971

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35456    2933      42       0
   3109   28053     662       0
    250    3348     622       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.870 | 0.680 [0.642, 0.715] | 0.666 [0.634, 0.695] | 0.567→0.376 | 0.282→0.180 | 0.062→0.019 (0.003) | 0.059→0.010 | 0.025 |

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,190 | 0.916 | 0.962 | 0.939 | 0.019 | strong | 0.690 | P=0.961 n=69,384 pass | strong | 0 |
| walking | yes | 8,533 | 0.783 | 0.574 | 0.662 | 0.014 | strong | 0.935 | P=0.977 n=3,005 pass | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| running | yes | 203 | 0.890 | 0.837 | 0.863 | 0.000 | strong | 0.725 | P=0.935 n=153 fail | weak | 0 |
| stairs | yes | 152 | 0.416 | 0.868 | 0.563 | 0.003 | weak | 0.805 | P=0.706 n=177 fail | weak | 0 |
| cycling | yes | 808 | 0.717 | 0.675 | 0.695 | 0.001 | weak | 0.300 | P=0.718 n=759 fail | weak | 0 |
| vehicle_motion | yes | 3,518 | 0.663 | 0.483 | 0.559 | 0.018 | weak | 0.670 | P=0.818 n=1,629 fail | weak | 0 |
| other | yes | 5,249 | 0.400 | 0.362 | 0.380 | 0.013 | abstain | 1.000 | – | abstain | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 89,829 | 0.570 | 0.567 [0.466, 0.634] | 0.380 | 0.019 | stationary 0.94 (n=71936), walking 0.66 (n=8381), running 0.75 (n=103), stairs 0.02 (n=8), cycling 0.67 (n=743), vehicle_motion 0.56 (n=3484), other 0.37 (n=5174) |
| hhar_watch | 174 | 0.978 | 0.978 [0.955, 1.000] | 0.087 | 0.049 | stationary 1.00 (n=74), walking 0.96 (n=35), stairs 0.98 (n=32), cycling 0.97 (n=33) |
| mhealth | 49 | 0.863 | 0.845 [0.827, 0.949] | 0.158 | 0.083 | stationary 0.91 (n=19), walking 0.80 (n=4), running 1.00 (n=10), stairs 0.50 (n=3), cycling 1.00 (n=4), other 0.86 (n=9) |
| opportunity | 37 | 0.973 | 0.986 [0.986, 0.986] | 0.249 | 0.189 | stationary 0.99 (n=37) |
| pamap2 | 397 | 0.806 | 0.795 [0.745, 0.959] | 0.448 | 0.072 | stationary 0.87 (n=187), walking 0.82 (n=43), running 1.00 (n=10), stairs 0.74 (n=29), cycling 0.96 (n=28), vehicle_motion 0.39 (n=34), other 0.78 (n=66) |
| wisdm2019_watch | 1,167 | 0.931 | 0.947 [0.917, 0.973] | 0.106 | 0.046 | stationary 1.00 (n=937), walking 0.92 (n=70), running 0.97 (n=80), stairs 0.89 (n=80) |

Wrist-only: n=91,653, macro-F1 0.666 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.931, P 0.907; ≥0.6: cov 0.878, P 0.933; ≥0.7: cov 0.832, P 0.952; ≥0.8: cov 0.781, P 0.968; ≥0.9: cov 0.687, P 0.981; ≥0.95: cov 0.568, P 0.988

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  70395     767       0       6      18      61     648    1295
   1980    4898       0       3     105      98      96    1353
      0       0       0       0       0       0       0       0
      4      27       0     170       0       0       0       2
      3       9       0       0     132       0       0       8
    204      25       0       0       0     545       2      32
   1573      81       0       0       2       3    1698     161
   2657     448       0      12      60      53     117    1902
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.651 | 0.456 [0.414, 0.565] | 0.457 [0.414, 0.513] | 0.947→0.718 | 0.577→0.466 | 0.092→0.059 (0.010) | 0.176→0.048 | 0.299 |

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.477 | 0.181 | 0.262 | 0.064 | abstain | 1.000 | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.681 | 0.904 | 0.777 | 0.063 | weak | 0.640 | P=0.712 n=14,109 fail | weak | 0 |
| fidgeting | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.408 | 0.282 | 0.333 | 0.016 | weak | 0.745 | P=0.469 n=177 fail | weak | 0 |
| active_gesturing | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 14 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 20,580 | 0.395 | 0.387 [0.340, 0.439] | 0.717 | 0.060 | quiet 0.26 (n=6802), desk_like 0.78 (n=13385), repetitive_hand_motion 0.12 (n=393) |
| mhealth | 12 | 0.000 | 0.000 [0.000, 0.000] | 1.267 | 0.707 | quiet 0.00 (n=12) |
| pamap2 | 60 | 0.239 | 0.353 [0.211, 0.469] | 1.318 | 0.419 | quiet 0.12 (n=31), repetitive_hand_motion 0.59 (n=29) |
| wisdm2019_watch | 320 | 0.850 | 0.876 [0.717, 0.979] | 0.591 | 0.101 | desk_like 0.93 (n=160), repetitive_hand_motion 0.82 (n=160) |

Wrist-only: n=20,972, macro-F1 0.457 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.943, P 0.664; ≥0.6: cov 0.770, P 0.694; ≥0.7: cov 0.581, P 0.716; ≥0.8: cov 0.284, P 0.721; ≥0.9: cov 0.033, P 0.660; ≥0.95: cov 0.006, P 0.625

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
   1236    5470       0     139       0       0       0
   1197   12249       0      99       0       0       0
      0       0       0       0       0       0       0
    158     260       0     164       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.930 | 0.064 | 0.091→0.089 | 0.201→0.190 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.901 | 0.056 | 0.098→0.098 | 0.204→0.195 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.928 | 0.095 | 0.091→0.089 | 0.203→0.186 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.905 | 0.078 | 0.101→0.099 | 0.220→0.200 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.14/0.56/0.22 | 0.15/0.61/0.24 | 2.7 / 4.6 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.80 (weak) | 405 | 0.50/0.33/0.40 | 0.57/0.38/0.45 | 2.4 / 5.6 |
| walk_stop | 0.60 (weak) | 404 | 0.43/0.36/0.40 | 0.53/0.45/0.49 | 2.5 / 7.0 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.136.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.102 | 0.136 | 0.511 | 0.790 | 0.773 |
| capture24 | 95,579 | 0.102 | 0.136 | 0.508 | 0.790 | 0.773 |
| pamap2 | 234 | 0.110 | 0.203 | 0.605 | 0.837 | 0.705 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.286 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.050 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
