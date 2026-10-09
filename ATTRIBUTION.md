# Attribution

NOOP is an independent, unofficial, local-first app for macOS, Android and iOS. It is not affiliated
with, endorsed by, or connected to WHOOP, Inc. "WHOOP" is used nominatively only to
identify the hardware the app interoperates with.

NOOP builds on prior community reverse-engineering and interoperability work:

## WHOOP 4.0 protocol + Swift packages
- **`johnmiddleton12/my-whoop`** — the `WhoopProtocol` and `WhoopStore` Swift packages
  (vendored under `Packages/`), the WHOOP 4.0 BLE framing/command/decode work, and the
  iOS collection logic that NOOP's `WhoopBLE`/`Collect` layers are adapted from.
  See `DISCLAIMER.md` (carried over from that project).

## WHOOP 5.0 / MG protocol
- **`b-nnett/goose`** — the WHOOP 5.0 BLE reverse-engineering (service UUID family
  `fd4b0001-…`, CRC16-Modbus header, CLIENT_HELLO, and the "puffin" packet types)
  that NOOP's `DeviceFamily` Whoop-5 path and `whoop5_protocol.json` are ported from.

## Activity context (HART)
- **`EdgeIntelligenceLab/HART`** (MIT) — the pretrained HART checkpoint
  (`TSPulseForReconstruction`, 856,744 bytes) and the classification-adaptation
  contract (`finetuning_HART/finetune.py` freeze policy and config overrides) that
  `Tools/ActivityContext` loads. Pinned to commit
  `122b4a8b07758deedfcf3b1e87f03eed5ad55967`; the checkpoint is fetched at
  deploy/train time by `Tools/ActivityContext/fetch_artifacts.sh` (never committed),
  with its SHA-256 pinned in the model manifest. The fine-tuned head and scaler are
  trained artifacts on the host, also not committed.
- **WISDM Smartphone and Smartwatch Activity and Biometrics Dataset** (UCI
  archive.ics.uci.edu, dataset 507, DOI 10.24432/C5HK59; Weiss et al., CC BY 4.0) —
  the watch accelerometer+gyroscope streams used to train the coarse-activity head.
  Downloaded at train time (never committed or redistributed); only aggregate
  held-out metrics are recorded (`Tools/ActivityContext/eval/RESULTS.md`).

## Transition expert (postural transitions)
- **FORTH-TRACE** (Karagiannaki, Panousopoulou, Tsakalides; Zenodo record 841301,
  DOI 10.5281/zenodo.841301, CC BY-SA 4.0) — left/right-wrist Shimmer IMU with
  explicit sit-to-stand / stand-to-sit (and stand-to-walk / walk-to-stand) labels at
  51.2 Hz; the only public wrist dataset with explicit postural-transition labels.
  Used to train/validate the transition expert. Downloaded at train time (never
  committed or redistributed); attribution and share-alike obligations apply to the
  dataset itself (the trained model is this project's own artifact).
- **Smartphone-Based Recognition of Human Activities and Postural Transitions**
  ("HAPT"; Reyes-Ortiz, Anguita, Ghio, Oneto, Parra; UCI archive.ics.uci.edu
  dataset 341, DOI 10.24432/C54G7M, CC BY 4.0) — waist-phone 50 Hz accelerometer +
  gyroscope with all six explicit postural transitions (sit↔stand, sit/stand↔lie).
  Used as cross-placement transfer training data; reported separately by placement.
- **PAMAP2 Physical Activity Monitoring** (Reiss & Stricker; UCI
  archive.ics.uci.edu dataset 231, DOI 10.24432/C5NW2H, CC BY 4.0) — wrist (hand)
  IMU at 100 Hz with sitting/standing/lying protocol states; transitions derived
  from state boundaries. Used as wrist-domain transition training data.

## Activity context (Inertia-1 motion heads)
- **`yang-ai-lab/Inertia-1`** (MIT, "Copyright (c) 2026 The Inertia-1 Authors") — the ART and PatchTST
  encoder architectures. Only the encoder-side `encode()` path is narrowly vendored into
  `Tools/ActivityContext/activity_context/inertia/vendor/` (MIT header with upstream path in every file;
  full licence in `Tools/ActivityContext/NOTICE.md`), pinned to commit
  `afcd725314c95f4afefce118821349df7d61e7e8`. No official pretrained checkpoint is publicly available, so
  none is used or committed; the lane runs only against an explicitly supplied, hash-verified checkpoint,
  and the stand-ins and fixtures (including a small seeded random-init test checkpoint) are not Inertia-1.
  Contract: `Tools/ActivityContext/INERTIA1.md`.
- **Public activity datasets (CC BY 4.0, plus GOTOV and WEAR under CC BY-NC-SA 4.0)** used offline to train and
  evaluate the stand-in heads — never committed or redistributed; only aggregate metrics and label vocabularies
  are recorded. Full
  creator lists, titles, DOIs, introductory papers and the changes made (unit conversion to g, 10 Hz
  low-pass, resampling to 20 Hz, windowing, frozen subject splits, label mapping to Nara classes) are in
  `Tools/ActivityContext/NOTICE.md`:
  - **CAPTURE-24** — Chan Chang, Walmsley, Gershuny, Harms, Thomas, Milton, Kelly, Foster, Wong, Gray,
    Haque, Hollowell & Doherty (2021), University of Oxford, doi:10.5287/bodleian:NGx0JOMP5.
  - **HHAR** — Blunck, Bhattacharya, Prentow, Kjærgaard & Dey (2015), UCI, doi:10.24432/C5689X.
  - **PAMAP2** — Reiss (2012), UCI, doi:10.24432/C5NW2H.
  - **MHEALTH** — Banos, Garcia & Saez (2014), UCI, doi:10.24432/C5TW22.
  - **OPPORTUNITY** — Roggen, Calatroni, Nguyen-Dinh, Chavarriaga & Sagha (2010), UCI, doi:10.24432/C5M027.
  - **Daphnet Freezing of Gait** (out-of-distribution probe only) — Roggen, Plotnik & Hausdorff (2010), UCI,
    doi:10.24432/C56K78.
  - **WISDM-2019** (also used by the HART path above) — Weiss (2019), UCI, doi:10.24432/C5HK59.
  - **CC BY-NC-SA 4.0 — non-commercial use approved by the owner on 2026-10-06** (Nara is non-commercial): head
    bundles trained on these record `training_data_licences` including "CC BY-NC-SA 4.0", stay outside git and are
    for non-commercial use only; no raw data is committed or redistributed.
    - **GOTOV** (older adults; right-wrist GENEActiv + COSMED measured MET) — Paraschiakos, Beekman, Knobbe, Cachucho
      & Slagboom (2021), 4TU.ResearchData, doi:10.4121/12716081.v2; paper Paraschiakos et al. (2020), UMUAI,
      doi:10.1007/s11257-020-09268-2.
    - **WEAR** (outdoor workouts; Bangle.js wrists) — Bock, Kuehne, Van Laerhoven & Moeller (2024), IMWUT 8(4) 175,
      doi:10.1145/3699776 (University of Siegen).
  - Reference only (label vocabularies audited, no samples used): **UCI HAPT** (Reyes-Ortiz, Anguita, Oneto &
    Parra, doi:10.24432/C54G7M), **HARTH** (Logacjov, Kongsvold, Bach, Bårdstu & Mork, doi:10.24432/C5NC90),
    **HAR70+** (Logacjov & Ustad, doi:10.24432/C5CW3D).

## Activity context (ElderNet gait quality)
- **`yonbrand/gait-quality`** (ElderNet) — **Copyright © 2022, University of Oxford**, University of Oxford
  SSL-wearables **Academic Use Licence** (use limited to the licensee's own internal academic, non-commercial
  research; no service for third parties; accepted by the owner on 2026-10-05; text in
  `Tools/ActivityContext/NOTICE.md`). Pinned to commit `437a38bcc69f42717fe73c1f7dbea7e1f7a50d23`. **Not
  redistributed:** this repository contains no Oxford source code and no ElderNet weights. The operator fetches
  the six fine-tuned checkpoints and the upstream source files from the pinned commit at install time
  (`python -m activity_context.eldernet.weights fetch`, `python -m activity_context.eldernet.upstream fetch`,
  both sha256-pinned), and `Tools/ActivityContext/activity_context/eldernet/upstream.py` imports upstream's own
  `models.py` (ResNet-18 from OxWearables/ssl-wearables + FC heads) and `gait_quality/detection.py` /
  `quality.py` from that checkout after verifying every file. Running it as a service on other people's data
  (the worker lane, off by default) may fall outside the licence — see `Tools/ActivityContext/ELDERNET.md`.
  Please cite: Brand, Y. E., Buchman, A. S., Kluge, F., Palmerini, L., Becker, C., Cereatti, A., Maetzler, W.,
  Vereijken, B., Yarnall, A. J., Rochester, L., Del Din, S., Mueller, A., Hausdorff, J. M. & Perlman, O.
  (2026). Continuous Assessment of Daily-Living Gait Using Self-Supervised Learning of Wrist-Worn Accelerometer
  Data. *npj Digital Medicine*. doi:10.1038/s41746-026-02528-2. Contract: `Tools/ActivityContext/ELDERNET.md`.
- **Mobilise-D Technical Validation Study (TVS) dataset** (v1.0.2, CC BY 4.0) — ElderNet was fine-tuned on
  it, and 70 s of upstream's committed toy excerpt (participant PD4010, INDIP left wrist) is part of the golden
  test fixture `Tools/ActivityContext/fixtures/eldernet/golden_gait_quality_request.json` (converted to WHOOP
  i16 columns). Del Din, S. et al. (2025), Zenodo, doi:10.5281/zenodo.15861907.
- **Validation-only datasets** (never committed; aggregate metrics only): **GOTOV** (Paraschiakos et al.,
  LUMC; CC BY-NC-SA 4.0, accepted by the owner) and **OxWalk** (Small, von Fritsch, Doherty, Khalid & Price,
  University of Oxford, 2022; CC BY 4.0; doi:10.5287/bodleian:ORQ2abnbR), plus the CC BY 4.0 sets listed
  under Inertia-1 above.

## Activity context (RecGym gym-exercise recognition, shadow)
- **`MKorp7/HAR_IMU_CNN-Transformer`** (MIT, "Copyright (c) 2025 MKorp7") — the CNN + Transformer exercise
  classifier. Pinned to commit `e085ac0e116aa5997d5f593ac1d0dd0c801859b1`. `src/models/imu_transformer.py`
  (inference) and `src/data/recgym.py` (offline scaler reproduction only) are vendored byte for byte under
  `Tools/ActivityContext/activity_context/recgym/vendor/` with the MIT notice, upstream path and commit in every
  file. The checkpoint (`models.zip:models/wrist_-_imu_only_best.pt`, wrist, IMU only, 12 classes) is not
  committed: it is staged by sha256 from the pinned commit (sidecar model manifest entry `recgym_cnn_transformer`,
  or `python -m activity_context.recgym.weights fetch`). Contract: `Tools/ActivityContext/RECGYM.md`.
- **RecGym** (Bian, S. & Lukowicz, P. (2025), UCI Machine Learning Repository, doi:10.24432/C5PW4K; CC BY 4.0;
  intro paper Bian, Rey, Yuan & Lukowicz, arXiv:2503.06311) — the model's training data. The StandardScaler upstream
  fitted on it was not shipped; `activity_context/recgym/recgym_wrist_imu_scaler.json` is Nara's refit from the
  public dataset (Kaggle mirror `zhaxidelebsz/10-gym-exercises-with-615-abstracted-features` v6, the copy upstream
  used), and twelve test-subject windows are part of the golden fixture
  `Tools/ActivityContext/fixtures/recgym/golden_upstream.json`. Changes made (by Nara): wrist IMU windows only,
  upstream's own windowing; the values are unchanged.

## Xiaomi Smart Band (Mi Band) import
- **`artyomxx/xiaomi-band-ios-export`** — documented the Mi Fitness iOS app's on-device
  SQLite layout (`DataBase/<user_id>/de/<user_id>.db`, JSON `value` columns, the `*_day`
  rollups and the `sleep` table's `items[]` hypnogram with state codes). NOOP's
  `XiaomiBandImporter` is **re-derived** from those findings and verified against a real
  Mi Band 10 export; **no code is copied** (the reference tool is AGPL, NOOP is not).
- **Gadgetbridge** (`Freeyourgadget/Gadgetbridge`) — referenced only for *protocol facts*
  about the live Mi-protobuf BLE stack in the roadmap's research notes. GPLv3; NOOP copies
  **none** of its code and has not built the live lane.

## Facts learned from a decompiled app

The facts-only doctrine above is usually applied to other open-source RE projects. It applies the same
way when a fact originates in a **decompile of the vendor's own app** — a case that recurs because
several third-party WHOOP projects are decompile-derived.

The line is between the fact and the expression of it:

- **A protocol fact may be re-derived** — a byte offset, field width, enum value, scale factor. It is
  attributed at the point of use, and it ships as an **unvalidated candidate**: decoded and logged,
  never backing a shipped metric, until independent captures from real hardware clear it.
- **The implementation may not be copied** — not verbatim, not transcribed. Nor may string literals,
  assets, or anything else that is authored expression rather than an observation about the wire.

This is long-standing practice, not a one-off. Worked examples already in the tree:

- **`spo2_candidate_82`** (`Interpreter.swift`) — WHOOP 5 v18 byte `@82` read as a strap-computed SpO₂
  percentage, attributed as *"a decompile-sourced decode (gen5.rs `spo2_pct`), reimplemented here as a
  protocol fact with attribution"*. A guard test stops it ever writing `spo2Pct`, and it is still a
  candidate because the cross-device evidence is split.
- **The R22 config opcodes** (`Whoop5Config.swift` / `.kt`) — `SET_FF_VALUE (0x78)` and the flag key
  names, corroborated against *Asherlc/dofek docs/whoop-ble-protocol.md (Android APK decompilation)*
  and validated byte-for-byte against a decrypted HCI capture.
- **The disputed battery opcode** (`Commands.swift`, `Enums.kt`) — a decompile reads
  `GET_EXTENDED_BATTERY_INFO` as 87 where our table says 98. Both readings are recorded and the
  question is settled by probing real firmware, not by picking a source.
- **The MG ECG ("Labrador") packet layouts** (`Whoop5Ecg.swift` / `.kt`, `docs/PROTOCOL.md` §9.1) —
  field order, widths and enum values for `FilteredLabradorPacket` / `RawLabradorPacket`, plus the
  `{revision, arg, padding}` command payload shape, re-derived from static analysis of the vendor's iOS
  client. The four command NUMBERS were already in our own `CommandNumber` table from the whoomp/goose
  work above. Most of it still ships as an **unvalidated candidate**: the decode backs no metric, and the
  fields nobody can attest (the wrist enum's raw values, the progress "timed out" sentinel, the ECG
  sample unit, the packet type byte) are carried raw rather than named. **One exception is now attested
  rather than inferred:** `ControlSignal`'s raw values were also read off the client's enum order, and a
  WHOOP MG (`WS50_r00`, fw `50.39.1.0`) contradicts that reading — `1` stops generation, `2` starts it,
  `0` is refused. The enum now carries the hardware values with the device and firmware named. A
  hardware-observed value is strictly stronger than the inference it replaces, but it is one device.
  The on-strap rhythm classifier's verdict is decoded as a byte and is never presented as a finding —
  NOOP is not a medical device.

And the line held from the other side:

- **`StrainTargetNotifier`** (both platforms) — *"CLEAN-ROOM: this reimplements the BEHAVIOUR only. The
  copy is NOOP's own — NOT WHOOP's decompiled strings."* Behaviour re-derived; the user-facing text
  written fresh.
- **The `LINK_VALID` handshake**, rejected in
  [`docs/BLE_REVERSE_ENGINEERING.md`](docs/BLE_REVERSE_ENGINEERING.md) — its reply payload is a
  literal string lifted from the app. Expression, not a fact about the wire, so it stays out
  regardless of whether the handshake turns out to be real.

## Oura ring (gen 3/4/5) protocol
NOOP's Oura code is **original clean-room** work. The local BLE source
(`Strand/BLE/OuraLiveSource.swift` + `android/.../ble/OuraLiveSource.kt`) and the JVM/Swift-pure
`OuraProtocol` package (`Packages/OuraProtocol/`, `android/.../com/noop/oura/`) were written from
**documented protocol facts only**, cited tersely in `docs/OURA_PROTOCOL.md`. The community
reverse-engineering resources below were consulted as **facts-only references** (byte layouts,
service/characteristic UUIDs, framing and auth shapes); **no RE source code is copied** into NOOP.
- **`open_ring`**: consulted for protocol facts only. Licensed **GPL-3.0**; NOOP copies none of
  its code and is not a derivative work of it.
- **`open_oura`**, **`ringverse`**, **`relue`**: consulted for protocol facts only. These carry
  **no license**, so NOOP treats them as reference documentation of observed behaviour only and
  copies no code from them.

NOOP reads only the ring's own decoded raw signals and its own open event tags, computes NOOP's
own Charge/Rest, and **never** reads or displays Oura's encrypted readiness or sleep scores. The
documented Oura file-import lane (`Packages/StrandImport/Sources/StrandImport/OuraExportParser.swift`)
remains available as a fallback.

## Other
- **GRDB.swift** (`groue/GRDB.swift`) — SQLite persistence (via Swift Package Manager).
- **MarkdownUI** (`gonzalezreal/swift-markdown-ui`) — renders the AI Coach's Markdown
  replies (via Swift Package Manager).
- **AemiSDR** (`Aemi-Studio/AemiSDR`, MIT or MPL-2.0, Aemi Studio) — the backdrop blur and Metal lens behind the
  iOS Liquid Glass look (Settings → Display → Liquid Glass). Vendored in `Packages/AemiSDR`; its `VENDORED.md`
  lists the changes from upstream.
- **OpenUI** (`thesysdev/openui`, MIT, Thesys Inc.) — the OpenUI Lang format behind Sana's interactive cards
  (plans, checklists, forms, timers). `Packages/OpenUILang` is a Swift port of its `@openuidev/lang-core`; its
  `PORTED.md` lists the upstream commit and the differences.

NOOP contains no WHOOP proprietary code, binaries, firmware, logos, or assets, and
performs no DRM circumvention. It operates only with the user's own device and data.
NOOP is **not a medical device**; all metrics (HR, HRV, recovery, strain, sleep,
SpO₂, temperature) are approximations and not clinically validated.
