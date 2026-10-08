# Licence review and proposed corrections: ActiNet, ssl-wearables, ElderNet

Written 2026-10-08 for Spec 03. **This is an engineering reading of the licence text, not legal advice.**
Nothing here changes production. The text edits at the end are proposals; this branch does not apply them.

## 1. What the licences say

All three are University of Oxford software under the same **Academic Use Licence**. The terms below are
identical in substance in each copy.

| Software | Governing text | Evidence |
|---|---|---|
| actinet (Walmsley classifier; the c24 backbone) | actinet `LICENSE.md` on master | sha256 `9a4f1846fcf3aaa94575f0b01c3ec9ad901d1c1b2d8fe48fb9e12ebe88e9ecf8`, identical in sdists 0.5.2–0.7.2 (ELIGIBILITY.md). Local copy: `research/spec03-artifacts/actinet/eligibility-actinet-LICENSE-master/` |
| ssl-wearables v1.0.0 (harnet30 backbone; the `actukb` weights `mtl_30_best.mdl`) | ssl-wearables `LICENSE.md` at v1.0.0 | git blob `64ed9bef…` (ELIGIBILITY.md). The README limits use to academic research, excludes commercial use and points to Oxford University Innovation. |
| ElderNet (`yonbrand/gait-quality` @ `437a38bc`) | upstream `LICENSE.md` | sha256 `0285754f68db29a0b0e66b7be206e6159e81edaf373aaa5b45fc6cca0b282da2`. It says the authors used the ssl-wearables UK Biobank model and are "subject to the same license terms", then reproduces the SSL-wearables Academic Use Licence. |

The clauses that decide each use:

- **1.1(a)** use is limited to "their own internal academic non-commercial research which is undertaken for
  the purposes of education or other scholarly use".
- **1.1(b)** do "not use the Software for or on behalf of any third party or to provide a service or integrate
  all or part of the Software into a product for sale or license to third parties".
- **1.1(e)** "Copyright © 2022, University of Oxford" must appear prominently wherever the Software is
  reproduced.
- **1.2** reproduction, modification or transmission only for academic use, with this licence imposed on the
  receiver, all original and modified source included, and a licence back to the University for modified
  source.
- Banner: "intended for use by academics carrying out research and not for use by consumers or commercial
  businesses". Commercial use needs a licence from Oxford University Innovation (enquiries@innovation.ox.ac.uk).

Neither the actinet README, its readthedocs pages, the ssl-wearables README nor any sdist grants separate
terms for the weights. No "CC BY" text appears in any actinet or actipy sdist (ELIGIBILITY.md §1). The
repository's "CC BY-NC 4.0" statements (§3) are therefore wrong.

## 2. Use categories

| Use | ActiNet | ssl-wearables | ElderNet | Reading |
|---|---|---|---|---|
| **Research use**: offline evaluation on public datasets (the head-to-head, parity tests) | Permitted | Permitted | Permitted | 1.1(a), if the project counts as internal academic, non-commercial research. Keep the copyright notice (1.1(e)). |
| **Personal use**: the owner running a model on their own data | **Unclear** | **Unclear** | **Unclear** | The licence has no personal-use category. It is permitted only if it is "internal academic non-commercial research … for education or other scholarly use". The banner excludes "consumers". Owner decision. |
| **A service on other people's data**: the worker lane processing beta testers' uploads, even in shadow or candidate mode with nothing shown to them | **Likely excluded** | **Likely excluded (live today)** | **Likely excluded (live today)** | 1.1(b) "to provide a service" / "on behalf of any third party". Shadow mode does not change who the processing is for. |
| **Commercial deployment** | Excluded | Excluded | Excluded | Needs a licence from Oxford University Innovation. |
| **Redistribution**: committing source or weights, shipping in an app build, sharing the repo | Weights: not committed (correct). Source: none added by Spec 03. | **The vendored harnet30 source is committed** (`inertia/vendor/ssl_wearables_resnet.py`) | Source and weights not committed (operator-fetch, correct) | 1.2: only for academic use, with this licence imposed on the receiver and grant-back. The vendored file's header says "CC BY-NC 4.0", and the repository's own licence is PolyForm Noncommercial 1.0.0. Neither can relicense Oxford code. |

Existing production use does not establish permission. That the `actukb` and ElderNet lanes run today says
nothing about whether the licence allows them to.

## 3. Statements in the repository that are wrong

| File:line (this branch, = `nara/main` at `dab2124f3`) | Says | Should say |
|---|---|---|
| `Tools/ActivityContext/NOTICE.md:347` | "Upstream licence: CC BY-NC 4.0 (non-commercial)" | University of Oxford Academic Use Licence (actinet and ssl-wearables) |
| `Tools/ActivityContext/activity_context/inertia/registry.py:37` | `"license": "CC BY-NC 4.0 (internal non-commercial use)"` | the Academic Use Licence, naming its source |
| `Tools/ActivityContext/activity_context/inertia/vendor/ssl_wearables_resnet.py:6-7` | "Licensed under CC BY-NC 4.0 by upstream" | the Academic Use Licence, with the Oxford copyright notice clause 1.1(e) requires |
| `ATTRIBUTION.md` | has an ElderNet entry but **no entry** for actinet or ssl-wearables | add one (below) |

`ATTRIBUTION.md:96-107` and `Tools/ActivityContext/NOTICE.md:93-100` (ElderNet) are already correct.

## 4. Who the live lanes run for

`ELIGIBILITY.md` contradicted itself: its table (05:44 UTC, 2026-10-08) showed `actukb` candidate rows for the
owner **and** one beta tester, while its licence paragraph said the lane ran on "one beta tester's account".
The facts:

- **The worker has no per-account gate for either lane.** The only settings are `FRWHOOP_INERTIA_*` and
  `FRWHOOP_ELDERNET_*` (enabled, mode, bundle, checkpoint, threads, timeout and budget). Nothing in
  `ActivityMotionHeads.swift` or `ActivityGaitQuality.swift` filters by account. When the lane is on, it runs
  for **every account whose raw IMU reaches the worker**.
- **Rows seen in production at 05:44 UTC** (aggregate counts, ELIGIBILITY.md §1): `actukb` candidate rows for
  the owner and one beta tester, plus one owner shadow row. ElderNet rows for one beta tester. Raw IMU arrived
  from the owner and two beta testers between 10-05 and 10-08.
- **Not re-verified today.** A fresh read-only aggregate query was attempted on 2026-10-08 and refused by this
  session's permission policy. Counts may have grown since 05:44 UTC.

So the audience question is not "one tester or two". **Any beta tester who uploads raw IMU is processed by
both Oxford-licensed lanes while they are enabled.** That is the use clause 1.1(b) bears on.

## 5. Decisions for the owner

1. **Is Nara's worker lane on beta testers' data "internal academic non-commercial research"?** If not, the
   live `actukb` (ssl-wearables) and ElderNet lanes need either a per-account restriction to the owner, an
   Oxford University Innovation licence, or to be switched off. The Spec 03 ActiNet classifier stays
   unregistered either way.
2. **Personal use.** Does running these models on the owner's own data count as research under 1.1(a)?
3. **The committed vendored harnet30 source.** Keep it (with the correct licence header and 1.2 obligations
   if the repository is ever shared), or move it to the operator-fetch pattern ElderNet uses.
4. **Whether to apply §6** on `main`. That is a documentation-only change, but it touches files Spec 03 does
   not own.

## 6. Proposed text (not applied)

`Tools/ActivityContext/NOTICE.md`, replace the paragraph under "## ssl-wearables / ActiNet (Oxford Wearables
Group)":

```text
`activity_context/inertia/vendor/ssl_wearables_resnet.py` is an inference-only copy of the harnet30 ResNet from
https://github.com/OxWearables/ssl-wearables (tag v1.0.0, `sslearning/models/accNet.py`). The pinned weights are
converted from ssl-wearables `mtl_30_best.mdl` and from ActiNet's `ssl-ukb-c24-mw-30s-20260128` classifier
(https://github.com/OxWearables/actinet); the Spec 03 shadow classifier (activity_context/actinet_classifier/)
uses ActiNet's `ssl-ukb-c24-rw-30s-20260128`.
Copyright © 2022, University of Oxford.
License: University of Oxford Academic Use Licence (actinet LICENSE.md sha256 9a4f1846…; ssl-wearables v1.0.0
LICENSE.md). Use is limited to the licensee's own internal academic, non-commercial research (clause 1.1(a));
no use for or on behalf of a third party or to provide a service (1.1(b)); reproduction or transmission only for
academic use with these terms imposed on the receiver (1.2). Commercial use needs a licence from Oxford
University Innovation (enquiries@innovation.ox.ac.uk). The weights are not redistributed from this repository.
Whether the worker lanes on beta testers' data fall inside clause 1.1 is an open owner decision
(docs/pretrained-models/integration/licence-corrections.md).
```

`Tools/ActivityContext/activity_context/inertia/registry.py:37`:

```python
"license": "University of Oxford Academic Use Licence (actinet / ssl-wearables LICENSE.md); "
           "internal academic non-commercial research only, no service to third parties",
```

`Tools/ActivityContext/activity_context/inertia/vendor/ssl_wearables_resnet.py:6-7`:

```python
# Copyright © 2022, University of Oxford. Licensed by upstream under the University of Oxford Academic Use
# Licence (ssl-wearables LICENSE.md): internal academic, non-commercial research only (NOTICE.md).
```

`ATTRIBUTION.md`, a new entry before "## Activity context (ElderNet gait quality)":

```markdown
## Activity context (ssl-wearables / ActiNet)
- **`OxWearables/ssl-wearables`** (v1.0.0) and **`OxWearables/actinet`** (0.7.2): **Copyright © 2022,
  University of Oxford**, University of Oxford **Academic Use Licence** (internal academic, non-commercial
  research only; no service for or on behalf of third parties; commercial use needs a licence from Oxford
  University Innovation). The harnet30 feature extractor is vendored for inference in
  `Tools/ActivityContext/activity_context/inertia/vendor/ssl_wearables_resnet.py`. Weights are fetched and
  converted by the operator, sha256-pinned, and never committed. Contracts: `Tools/ActivityContext/INERTIA1.md`
  (encoder lane) and `docs/pretrained-models/ACTINET_CLASSIFIER.md` (Spec 03 shadow classifier).
```

Test impact if applied: none of the licence strings is asserted by a test on this branch
(`git grep -n "CC BY-NC 4.0" -- '*test*'` finds nothing).
