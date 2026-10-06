# Tools/ActivityContext — third-party notices

HART (EdgeIntelligenceLab/HART)
  Pinned commit: 122b4a8b07758deedfcf3b1e87f03eed5ad55967
  License: MIT (upstream LICENSE in the HART repository).
  Used for: the pretrained TSPulse checkpoint and the classification-adapter
  contract (TSPulseForClassification.from_pretrained + finetune.py overrides).
  Artifact: finetuning_HART/pretrained_checkpoint/* (downloaded by
  fetch_artifacts.sh with pinned sha256 digests; never committed).

WISDM Smartphone and Smartwatch Activity and Biometrics Dataset
  Weiss, G. (2019). UCI Machine Learning Repository.
  https://doi.org/10.24432/C5HK59 — License: CC BY 4.0.
  Used for: watch-stream adaptation training (20 Hz accel m/s^2 + gyro rad/s).
  Raw archive is a download-time artifact (310 MB, sha256 pinned in
  fetch_artifacts.py); derived windows/metrics keep this attribution.

granite-tsfm / tsfm_public (the TSPulseForClassification implementation)
  Apache-2.0 (see the granite-tsfm package). Runtime dependency of the
  optional [model] extra only. torch / transformers keep their own licenses.

Inertia-1 (yang-ai-lab/Inertia-1)
  https://github.com/yang-ai-lab/Inertia-1
  Pinned commit: afcd725314c95f4afefce118821349df7d61e7e8
  License: MIT, "Copyright (c) 2026 The Inertia-1 Authors" (full text below).
  Used for: the ART and PatchTST encoder architectures. Only what encode() needs is vendored, with
  identical module/attribute names so upstream Lightning state_dicts load strictly; no
  pytorch-lightning, no training code. Each vendored file carries the upstream path, the SHA and this
  notice. Vendored files (activity_context/inertia/vendor/) and their upstream sources:
    vendor/ar_transformer.py  <- inertia1/methods/ar_transformer_module.py
    vendor/patchtst.py        <- inertia1/methods/patchtst_module.py,
                                 inertia1/augmentations/patchtst.py,
                                 inertia1/models/backbones/patchtst/patchTST_accel.py,
                                 inertia1/models/backbones/patchtst/layers/attention.py,
                                 inertia1/models/backbones/patchtst/layers/basics.py,
                                 inertia1/models/backbones/patchtst/layers/pos_encoding.py
    vendor/__init__.py        (notice + file map only)
  Weights: no official pretrained checkpoint is publicly available (audited 2026-10-05); none is
  committed. fixtures/inertia/encoder_tiny.ckpt is a seeded random initialisation of the vendored
  architecture made by Nara for tests — it is not Inertia-1 and carries no upstream weights.

  MIT License

  Copyright (c) 2026 The Inertia-1 Authors

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

scipy / torch (optional [inertia] extra) and scikit-learn / pandas / pyarrow ([inertia-train])
  BSD-3-Clause / BSD-style / Apache-2.0 respectively; runtime dependencies only, not vendored.

Public datasets used by the Inertia head pipeline (activity_context/inertia/, offline research only)
------------------------------------------------------------------------------------------------------
Every dataset in this first list is licensed under the Creative Commons Attribution 4.0 International
licence (CC BY 4.0, https://creativecommons.org/licenses/by/4.0/) as stated on its official record (checked
2026-10-05); GOTOV and WEAR (CC BY-NC-SA 4.0) are listed separately below. None of their raw data is
committed or redistributed by this repository; the files are downloaded by the operator into
$INERTIA_DATA_ROOT (outside git).

Changes made (all datasets, by Nara): accelerometer streams converted to g (m/s^2 / 9.80665, milli-g /
1000), filtered (4th-order 10 Hz Butterworth, zero-phase) and resampled to 20 Hz, split at gaps > 1 s,
cut into 30 s / 10 s windows (inertia-prep-1; PAMAP2: <= 50 ms dropouts linearly filled), assigned to
frozen subject splits (Tools/ActivityContext/splits/), and source labels mapped to Nara activity classes
through the audited crosswalk activity_context/inertia/label_mappings.json. Committed outputs derived from
the data are aggregate metrics, tables and label vocabularies only (eval/inertia/, label_mappings.json).
Use does not imply endorsement by the dataset creators.

CAPTURE-24 — training (wrist), evaluation, decoder replay
  Chan Chang, S., Walmsley, R., Gershuny, J., Harms, T., Thomas, E., Milton, K., Kelly, P., Foster, C.,
  Wong, A., Gray, N., Haque, S., Hollowell, S., & Doherty, A. (2021). Capture-24: Activity tracker
  dataset for human activity recognition. University of Oxford. https://doi.org/10.5287/bodleian:NGx0JOMP5
  (https://ora.ox.ac.uk/objects/uuid:99d7c092-d865-4a19-b096-cc16440cd001). Licence: CC BY 4.0.
  Paper: Chan, S., Hang, Y., Tong, C., Acquah, A., Schonfeldt, A., Gershuny, J., & Doherty, A. (2024).
  CAPTURE-24: A large dataset of wrist-worn activity tracker data collected in the wild for human
  activity recognition. Scientific Data 11, 1135. https://doi.org/10.1038/s41597-024-03960-3
  Read from a parquet mirror of the release (HuggingFace nz00shuuuu); every participant file also
  downloaded from ORA (48 so far) was verified identical. The data owners ask that no attempt be made to
  identify individuals in the data; Nara makes none.

WISDM Smartphone and Smartwatch Activity and Biometrics Dataset — training (watch accel), replay
  Weiss, G. (2019). UCI Machine Learning Repository. https://doi.org/10.24432/C5HK59 — CC BY 4.0.
  (Also listed above for the HART path.)

Heterogeneity Activity Recognition (HHAR), watch subset — training (wrist)
  Blunck, H., Bhattacharya, S., Prentow, T., Kjærgaard, M., & Dey, A. (2015). Heterogeneity Activity
  Recognition [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5689X — CC BY 4.0.
  Paper (requested citation): Stisen, A., Blunck, H., Bhattacharya, S., Prentow, T. S., Kjærgaard, M. B.,
  Dey, A., Sonne, T., & Jensen, M. M. (2015). Smart Devices are Different: Assessing and Mitigating Mobile
  Sensing Heterogeneities for Activity Recognition. SenSys 2015. https://doi.org/10.1145/2809695.2809718

PAMAP2 Physical Activity Monitoring — training (hand IMU), movement-intensity targets
  Reiss, A. (2012). PAMAP2 Physical Activity Monitoring [Dataset]. UCI Machine Learning Repository.
  https://doi.org/10.24432/C5NW2H — CC BY 4.0.
  Paper: Reiss, A., & Stricker, D. (2012). Introducing a New Benchmarked Dataset for Activity Monitoring.
  16th International Symposium on Wearable Computers (ISWC). https://doi.org/10.1109/ISWC.2012.13

MHEALTH — training (right lower arm)
  Banos, O., Garcia, R., & Saez, A. (2014). MHEALTH [Dataset]. UCI Machine Learning Repository.
  https://doi.org/10.24432/C5TW22 — CC BY 4.0.
  Paper: Banos, O., Garcia, R., Holgado-Terriza, J. A., Damas, M., Pomares, H., Rojas, I., Saez, A., &
  Villalonga, C. (2014). mHealthDroid: A Novel Framework for Agile Development of Mobile Health
  Applications. IWAAL 2014, LNCS. https://doi.org/10.1007/978-3-319-13105-4_14

OPPORTUNITY Activity Recognition — training (wrist/forearm), transition timing
  Roggen, D., Calatroni, A., Nguyen-Dinh, L., Chavarriaga, R., & Sagha, H. (2010). OPPORTUNITY Activity
  Recognition [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5M027 — CC BY 4.0.
  Paper: Roggen, D., Calatroni, A., Rossi, M., et al. (2010). Collecting complex activity datasets in
  highly rich networked sensor environments. INSS 2010. https://doi.org/10.1109/INSS.2010.5573462

Daphnet Freezing of Gait — out-of-distribution probe only (non-wrist; never trained on)
  Roggen, D., Plotnik, M., & Hausdorff, J. (2010). Daphnet Freezing of Gait [Dataset]. UCI Machine
  Learning Repository. https://doi.org/10.24432/C56K78 — CC BY 4.0.
  Paper: Bächlin, M., Plotnik, M., Roggen, D., Maidan, I., Hausdorff, J. M., Giladi, N., & Tröster, G.
  (2010). Wearable Assistant for Parkinson's Disease Patients With the Freezing of Gait Symptom. IEEE
  Trans. Inf. Technol. Biomed. 14(2), 436-446. https://doi.org/10.1109/TITB.2009.2036165

Datasets licensed CC BY-NC-SA 4.0 — training (wrist), evaluation; used since 2026-10-06
  Licence: Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0,
  https://creativecommons.org/licenses/by-nc-sa/4.0/). The owner approved their NON-COMMERCIAL use for
  training the Inertia motion heads on 2026-10-06 (Nara is non-commercial: PolyForm Noncommercial 1.0.0).
  No raw or windowed data of theirs is committed or redistributed; committed outputs are aggregate metrics,
  tables and label vocabularies only. Head bundles trained on them are derived material: they record
  `training_data_licences` = ["CC BY 4.0", "CC BY-NC-SA 4.0"] in manifest.json, stay outside git, and must
  only be used non-commercially (and, if ever shared, under CC BY-NC-SA 4.0 with this attribution). Use does
  not imply endorsement by the dataset creators.

GOTOV Human Physical Activity and Energy Expenditure Dataset on Older Individuals — training (right wrist),
evaluation, measured-MET movement-intensity targets
  Paraschiakos, S., Beekman, M., Knobbe, A., Cachucho, R., & Slagboom, E. (2021). GOTOV Human Physical
  Activity and Energy Expenditure Dataset on Older Individuals [Dataset]. 4TU.ResearchData (Leiden University
  Medical Center / LIACS). https://doi.org/10.4121/12716081.v2 — CC BY-NC-SA 4.0.
  Papers (requested citations): Paraschiakos, S., Cachucho, R., Moed, M., et al. (2020). Activity recognition
  using wearable sensors for tracking the elderly. User Modeling and User-Adapted Interaction 30, 567-605.
  https://doi.org/10.1007/s11257-020-09268-2 ; Paraschiakos, S., de Sá, C. R., Okai, J., Slagboom, E. P.,
  Beekman, M., & Knobbe, A. (2020). RNNs on monitoring physical activity energy expenditure in older people.
  https://arxiv.org/abs/2006.01169
  Changes made (by Nara): only the right-wrist GENEActiv stream (already in g) and the COSMED METS column are
  read; samples placed on the device's uniform 600/7 Hz clock (the CSV timestamps stay within 15 ms of it);
  the first/last 10 s of every protocol-imputed labelled segment masked (gotov-guard-10s); per-window measured
  MET formed from the breath-by-breath METS (gotov-met-1: held <= 15 s, time-weighted, first 60 s of each
  activity masked); then the common changes above (10 Hz low-pass, 20 Hz, 30 s windows, frozen subject split
  Tools/ActivityContext/splits/gotov.json, crosswalk labels). Ankle/chest/Equivital data are not used.

WEAR: An Outdoor Sports Dataset for Wearable and Egocentric Activity Recognition — training (one wrist per
subject), evaluation
  Bock, M., Kuehne, H., Van Laerhoven, K., & Moeller, M. (2024). WEAR: An Outdoor Sports Dataset for
  Wearable and Egocentric Activity Recognition. Proc. ACM Interact. Mob. Wearable Ubiquitous Technol. 8(4),
  Article 175. https://doi.org/10.1145/3699776 — dataset (University of Siegen,
  https://github.com/mariusbock/wear) licensed CC BY-NC-SA 4.0.
  Changes made (by Nara): only the raw/inertial/50hz accelerometer of ONE wrist per subject (left unless < 95 %
  of its samples are finite, else right; already in g) is read; non-finite rows removed (the run is split, never
  interpolated); then the common changes above (frozen subject split Tools/ActivityContext/splits/wear.json,
  crosswalk labels). Leg streams and the egocentric video are not used.

Reference only (label vocabularies and documentation audited into label_mappings.json; no samples used
for training, evaluation or any committed number; role pooled_ablation_non_wrist):
  Smartphone-Based Recognition of Human Activities and Postural Transitions (UCI HAPT): Reyes-Ortiz, J.,
    Anguita, D., Oneto, L., & Parra, X. (2015). UCI Machine Learning Repository.
    https://doi.org/10.24432/C54G7M — CC BY 4.0.
  HARTH: Logacjov, A., Kongsvold, A., Bach, K., Bårdstu, H. B., & Mork, P. J. UCI Machine Learning
    Repository. https://doi.org/10.24432/C5NC90 — CC BY 4.0. Paper: Sensors 21(23), 7853 (2021),
    https://doi.org/10.3390/s21237853
  HAR70+: Logacjov, A., & Ustad, A. UCI Machine Learning Repository. https://doi.org/10.24432/C5CW3D —
    CC BY 4.0. Paper: Ustad, A., et al. Sensors 23(5), 2368 (2023), https://doi.org/10.3390/s23052368
  The crosswalk also lists label names of datasets that are EXCLUDED from all use (DSADS, RealWorld 2016,
  ExtraSensory, UT Complex [no licence stated], UCI HMP [conflicting licence], RecoFit) so the exclusion is
  auditable; no data of theirs is used. (GOTOV and WEAR were in this list until the 2026-10-06 decision.)
