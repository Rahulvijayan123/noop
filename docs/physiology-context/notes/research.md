# Physiology-context layer: primary-source research notes

Prepared 2026-10-05 for the Nara WHOOP physiology-context layer (HR, RR → RMSSD/SDNN, RSA-derived respiratory rate, skin temperature, unverified SpO2 byte, 100 Hz IMU activity labels). No repository was edited.

**How each item was checked:**
- **OPENED-FULL:** I read the full text or PDF.
- **OPENED-ABSTRACT:** I read the abstract or official metadata through Europe PMC, Crossref, Semantic Scholar or OpenAlex. I did not read the full text.
- **METADATA-ONLY:** the bibliographic record exists, but I could not read the content.

Anything marked *(derived)* or *(our computation)* is my own inference or calculation. It is not a finding from the source.

---

## 1. Robust scale: MAD × 1.4826, "robust z is not a probability", scale floors

**Sources**
- Rousseeuw PJ, Croux C. 1993. "Alternatives to the Median Absolute Deviation." *JASA* 88(424):1273–1283. DOI 10.1080/01621459.1993.10476408. OPENED-FULL (scanned PDF from KU Leuven; I read pages 1273–1274).
- Leys C, Ley C, Klein O, Bernard P, Licata L. 2013. "Detecting outliers: Do not use standard deviation around the mean, use absolute deviation around the median." *J Exp Soc Psychol* 49(4):764–766. DOI 10.1016/j.jesp.2013.03.013. OPENED-FULL (ULB repository PDF).

**What the sources say**
- **The constant:** MAD_n = b·med|xᵢ − med xⱼ|, and setting b = 1.4826 makes the MAD consistent for σ at the Gaussian (Rousseeuw & Croux).
- **Strengths and limits:** the MAD has a 50% breakdown point but only 37% Gaussian efficiency. It "takes a symmetric view on dispersion". At highly skewed distributions it "may be rather inefficient and artificial" (Rousseeuw & Croux).
- **Small samples:** their Table 1 gives the average MAD_n at Gaussian data as 0.911 (n=10), 0.959 (n=20) and 0.978 (n=40). The paper's authors have published finite-sample correction factors.
- **Implosion:** they define an "implosion" breakdown point, the case where the scale estimate goes to 0.
- **Cutoffs:** Rousseeuw & Croux suggest flagging |xᵢ − med|/MAD above 2.5 or 3.0.
- **Other distributions:** Leys et al. note that b = 1/Q(0.75) of the assumed distribution, which equals 1.4826 only under normality. They recommend 2.5 as a default cutoff and say the threshold choice is "necessarily subjective".

**Applicability to Nara**
- **Not a probability (derived):** a robust z of 1.4826-scaled MAD maps to Gaussian tail probabilities only if the baseline is roughly normal and symmetric. Raw RMSSD, skin temperature deltas and HR are often skewed. Present robust z as a distance in "typical-spread units", never as a percentile or p-value.
- **Small baselines:** with 7–14-day baselines the MAD underestimates σ by about 4–9%, which inflates z.
- **Scale floor (derived):** the MAD collapses to 0 when more than half the values tie, for example with integer-rounded HR or quantized temperature. A floor is mandatory. Neither paper gives a numeric floor, so the floor value is an engineering choice. Tie it to sensor resolution or published typical error (see §2).

## 2. Log-transformed RMSSD, rolling averages, smallest worthwhile change (SWC)

**Sources**
- Buchheit M. 2014. "Monitoring training status with HR measures: do all roads lead to Rome?" *Front Physiol* 5:73. DOI 10.3389/fphys.2014.00073. OPENED-FULL.
- Plews DJ, Laursen PB, Kilding AE, Buchheit M. 2012. "Heart rate variability in elite triathletes, is variation in variability the key to effective training? A case comparison." *Eur J Appl Physiol* 112(11):3729–3741. DOI 10.1007/s00421-012-2354-4. OPENED-ABSTRACT.
- Plews DJ et al. 2013. "Training adaptation and heart rate variability in elite endurance athletes: opening the door to effective monitoring." *Sports Med* 43(9):773–781. DOI 10.1007/s40279-013-0071-8. OPENED-ABSTRACT.
- Plews DJ et al. 2014. "Monitoring training with heart-rate variability: how much compliance is needed for valid assessment?" *IJSPP* 9(5):783–790. DOI 10.1123/ijspp.2013-0455. OPENED-ABSTRACT.

**What the sources say**
- **Plews 2012:** tracked the 7-day rolling average of Ln rMSSD and its CV. In the athlete who became non-functionally over-reached, both declined before the event (slope −0.17 ms/week for Ln rMSSD, −0.65%/week for CV).
- **Plews 2014:** the magnitude of change plateaued after averaging 3–4 days. The authors recommend at least 3 randomly selected valid recordings per week.
- **Typical error (Buchheit):** about 12% CV for resting Ln rMSSD, about 16% after exercise and about 60% during exercise.
- **SWC (Buchheit):** about +3% for resting vagal HRV, with SWC = 0.5 × CV (Le Meur) or 1 × CV (Plews). He calls using the individual's own CV "intuitively a better choice" than the between-athlete SD. The group-based convention is 0.2 standardized units.
- **Recording practice (Buchheit):** short-term (5–10 min) recordings on waking are best practice. rMSSD is usable from 10 s to 1 min. He discourages spectral indices in the field.

**Applicability to Nara**
- These are athlete cohorts with standardized morning, seated or supine spot checks. WHOOP's nightly or sleep-window RMSSD is a different measurement condition, so SWC percentages should not be transplanted directly.
- **Transferable:** the log transform, a 7-day rolling mean, requiring 3 or more valid days per week, and SWC scaled by the person's own CV.
- **Not transferable:** the numeric 3% SWC. Recompute it from each user's nightly CV.
- **Derived:** the sources do not explicitly justify the log transform (Buchheit gives no rationale). Munoz 2015 (§3) also log-transformed before analysis.

## 3. HRV depends on recording length; ultra-short RMSSD

**Sources**
- Task Force of the ESC and NASPE. 1996. "Heart rate variability: standards of measurement, physiological interpretation and clinical use." *Circulation* 93(5):1043–1065 (PMID 8598068). Also published in *Eur Heart J* 17(3):354–381, DOI 10.1093/oxfordjournals.eurheartj.a014868. METADATA-ONLY: both publisher pages returned 403 or a paywall.
- Munoz ML et al. 2015. "Validity of (Ultra-)Short Recordings for Heart Rate Variability Measurements." *PLoS One* 10(9):e0138921. DOI 10.1371/journal.pone.0138921. OPENED-FULL.
- Shaffer F, Ginsberg JP. 2017. "An Overview of Heart Rate Variability Metrics and Norms." *Front Public Health* 5:258. DOI 10.3389/fpubh.2017.00258. OPENED-FULL.

**What the sources say**
- **Not interchangeable (Shaffer & Ginsberg):** "24 h, short-term, and ultra-short-term values are not interchangeable." Because "longer recordings are associated with increased HRV, it is inappropriate to compare metrics like SDNN" across epochs of different length.
- **Munoz 2015 (N=3,387, supine, finger-BP-derived intervals, compared against a 240–300 s reference):**
  - RMSSD is valid from a single 10 s segment (r≈0.85–0.86, d≈0.15–0.17) and agrees almost perfectly at 120 s (r=0.986).
  - SDNN needs at least 30 s, or several 10 s segments. A single 10 s SDNN shows large bias (d≈0.87).
  - SDNN rose about 10 ms from 10 s to the full recording. RMSSD changed only about 1.3 ms.
  - Caveat: the short segments sat inside the reference window, which inflates agreement.

**Applicability to Nara**
- **Engineering rule:** only compare or baseline SDNN computed over the same window length. Never mix 1-min, 5-min and whole-night SDNN in one baseline.
- RMSSD is far less length-sensitive, but keep the window fixed anyway.
- All of these results are resting and supine. None of them validates RMSSD during motion or from PPG.
- The Task Force wording itself could not be opened. Cite it as the standard, but quote Shaffer & Ginsberg for the "not comparable" claim.

## 4. RR artifact handling

**Sources**
- Lipponen JA, Tarvainen MP. 2019. "A robust algorithm for heart rate variability time series artefact correction using novel beat classification." *J Med Eng Technol* 43(3):173–181. DOI 10.1080/03091902.2019.1640306. OPENED-ABSTRACT; the full text returned 403.
- Peltola MA. 2012. "Role of editing of R–R intervals in the analysis of heart rate variability." *Front Physiol* 3:148. DOI 10.3389/fphys.2012.00148. OPENED-FULL (PMC3358711).
- Secondary source: the NeuroKit2 `signal_fixpeaks.py` implementation of Lipponen & Tarvainen (GitHub, opened).

**What the sources say**
- **Lipponen & Tarvainen:**
  - Method: time-varying thresholds derived from the distribution of successive RR differences, plus a new beat classification (ectopic, long/short, missed, extra).
  - Results: 100% sensitivity for simulated missed or extra beats, and 96.96% sensitivity with 99.94% specificity for real ectopics.
  - Residual HRV error after correction: under 2%, and under 8% for the hardest small misalignments.
  - NeuroKit2 defaults: alpha=5.2 × quartile deviation over a 91-beat window, an 11-beat median filter, and c1=0.13, c2=0.17. These are code defaults, not something I read in the paper.
- **Peltola:**
  - Even under 5% edited intervals can affect HF, LF, pNN50 and RMSSD in short recordings.
  - Interpolation is preferred over deletion for RMSSD and pNN50. Deletion is acceptable for SDNN.
  - Ectopics inflate SD and high-frequency power.
  - Most studies require at least 80% normal beats per segment. There is no standardized maximum for edited intervals.
- **Not found:** I could not verify a primary source for the "20% from previous RR" percentage filter in the material I opened.

**Applicability to Nara**
- Run artifact correction before computing RMSSD.
- Report the percentage corrected for each window, and reject windows with more than 20% corrected, following the "≥80% normal" convention.
- Successive-difference metrics (RMSSD) are the most artifact-sensitive, so a single uncorrected ectopic can dominate a short window.
- The validation used ECG RR intervals. WHOOP PPG peak-to-peak intervals have different error modes, such as motion-induced peak jitter, so the thresholds are not validated for PPG.

## 5. PRV vs HRV; dependence on motion and conditions

**Sources**
- Schäfer A, Vagedes J. 2013. "How accurate is pulse rate variability as an estimate of heart rate variability? A review on studies comparing photoplethysmographic technology with an electrocardiogram." *Int J Cardiol* 166(1):15–29. DOI 10.1016/j.ijcard.2012.03.119. OPENED-ABSTRACT.
- Lam E, Aratia S, Wang J, Tung J. 2020. "Measuring Heart Rate Variability in Free-Living Conditions Using Consumer-Grade Photoplethysmography: Validation Study." *JMIR Biomed Eng* 5(1):e17355. DOI 10.2196/17355. OPENED-ABSTRACT via Crossref. The full text at the URL you gave was blocked by an AWS WAF challenge.

**What the sources say**
- **Schäfer & Vagedes:**
  - PRV is sufficiently accurate in healthy subjects at rest, but tends to slightly overestimate short-term variability (attributed to respiratory coupling).
  - Physical activity and some mental stressors degrade agreement, often "to an inacceptable extent".
  - Evidence on sensor position and algorithm effects is inconclusive. Studies are largely "incommensurable".
- **Lam et al. 2020:**
  - Design: 10 healthy adults wore a Microsoft Band 2 (PPG) and a Shimmer3 ECG for more than 90 min in the daytime and overnight in daily life, giving 10 days and 9 nights.
  - Agreement: mean RMSE was 182 ms by day and 158 ms by night, with R² of 0.00–0.66. Most trials showed poor or fair agreement, and only 2 nights reached moderate agreement.
  - Motion editing: removing motion-affected segments "barely improved" accuracy.
  - Time of day: agreement trended better at night (P=.08).
  - Signal behavior: P-P intervals were less sensitive to rapid R-R changes.
  - Conclusion: PRV is "a poor surrogate for HRV under free-living conditions."

**Applicability to Nara**
- WHOOP "HRV" is PRV. Label it as such internally.
- Restrict trend comparisons to like-for-like states, preferably sleep or low-motion windows at a consistent time of night.
- Do not compare daytime PRV with nocturnal PRV.
- Do not treat motion-masking as a fix; the evidence says it barely helps.
- Lam et al. used a different device and N=10, so their magnitudes do not transfer to WHOOP, but the direction of the findings does.

## 6. RSA/RR-derived respiratory rate: limits

**Sources**
- Charlton PH et al. 2016. "An assessment of algorithms to estimate respiratory rate from the electrocardiogram and photoplethysmogram." *Physiol Meas* 37(4):610–626. DOI 10.1088/0967-3334/37/4/610. OPENED-FULL (PMC5390977).
- Charlton PH et al. 2018. "Breathing Rate Estimation From the Electrocardiogram and Photoplethysmogram: A Review." *IEEE Rev Biomed Eng* 11:2–20. DOI 10.1109/RBME.2017.2763681. OPENED-FULL (PMC7612521).

**What the sources say**
- **Charlton 2016 (314 algorithms; young healthy adults; supine; 32 s windows):**
  - Best ECG algorithm: bias 0.0, limits of agreement ±4.7 breaths/min.
  - Best PPG algorithm: bias 1.0, limits of agreement −5.1 to 7.2 breaths/min. ECG beat PPG.
  - Every top algorithm fused baseline-wander, amplitude and frequency modulations. Frequency modulation (FM, the RSA component) alone was not among the top performers.
  - Coverage: fusion-based algorithms produced estimates for only about 54–75% of windows.
  - RSA "diminish[es] with age". The results "cannot be directly extrapolated" to exercise, elderly or unwell subjects.
- **Charlton 2018:**
  - Modulation strength varies with age, sex, health, hydration, posture and breathing rate itself. FM is diminished in the elderly.
  - Test populations: 64.8% of studies used healthy subjects and only 16.3% used ambulatory data.
  - Windows: most studies used 30–90 s windows, with a non-significant trend toward lower error at longer windows.

**Applicability to Nara**
- An RSA-only (FM-only) estimate from RR intervals is the weakest family of methods.
- It inherits every RR artifact (§4) and every PRV limitation (§5). It degrades with age, with low HRV and outside rest.
- Gate output to rest or sleep, use windows of 32 s or longer, emit "unavailable" rather than a value when quality is low, and never present it as clinical respiratory rate.

## 7. Wrist or distal skin temperature is not core temperature

**Sources**
- Kräuchi K, Wirz-Justice A. 1994. "Circadian rhythm of heat production, heart rate, and skin and core temperature under unmasking conditions in men." *Am J Physiol* 267(3 Pt 2):R819–R829. DOI 10.1152/ajpregu.1994.267.3.R819. OPENED-ABSTRACT.
- Sarabia JA, Rol MA, Mendiola P, Madrid JA. 2008. "Circadian rhythm of wrist temperature in normal-living subjects. A candidate of new index of the circadian system." *Physiol Behav* 95(4):570–580. DOI 10.1016/j.physbeh.2008.08.005. OPENED-ABSTRACT.

**What the sources say**
- **Kräuchi & Wirz-Justice (34 h constant routine, N=7):**
  - Proximal skin temperature runs in phase with rectal temperature.
  - Distal skin (hands and feet) runs in the opposite phase.
  - The other rhythms, including HR, lead core temperature by 25–180 min.
- **Sarabia (N=99, free-living):**
  - Wrist temperature is inversely phased to oral temperature and leads it by about 60 min.
  - It rises around bedtime, falls on waking, and has a secondary early-afternoon rise.

**Applicability to Nara**
- WHOOP skin temperature is distal. A nightly rise can mean heat dissipation linked to sleep onset or circadian phase, not fever.
- Report deviation from the person's own baseline at a matched circadian or sleep phase.
- Never label it "body temperature" or convert it to core temperature.

## 8. Change detection: CUSUM and EWMA

**Sources**
- Page ES. 1954. "Continuous Inspection Schemes." *Biometrika* 41(1-2):100–115. DOI 10.1093/biomet/41.1-2.100. METADATA-ONLY.
- Roberts SW. 1959. "Control Chart Tests Based on Geometric Moving Averages." *Technometrics* 1(3):239–250. DOI 10.1080/00401706.1959.10489860. OPENED-ABSTRACT.
- Lucas JM, Saccucci MS. 1990. "Exponentially Weighted Moving Average Control Schemes: Properties and Enhancements." *Technometrics* 32(1):1–12. DOI 10.1080/00401706.1990.10484583. OPENED-ABSTRACT.
- Hawkins DM. 1987. "Self-Starting Cusum Charts for Location and Scale." *The Statistician* 36(4):299+. DOI 10.2307/2348827. OPENED-ABSTRACT.
- NIST/SEMATECH e-Handbook of Statistical Methods, §6.3.2.3 (CUSUM), §6.3.2.3.1 (ARL table) and §6.3.2.4 (EWMA). OPENED-FULL. https://www.itl.nist.gov/div898/handbook/pmc/section3/pmc323.htm
- Lu C-W, Reynolds MR. 1999. "EWMA Control Charts for Monitoring the Mean of Autocorrelated Processes." *J Qual Technol* 31(2):166–188. DOI 10.1080/00224065.1999.11979913. METADATA-ONLY.
- Alwan LC, Roberts HV. 1988. "Time-Series Modeling for Statistical Process Control." *J Bus Econ Stat* 6(1):87–95. DOI 10.1080/07350015.1988.10509640. METADATA-ONLY.

**What the sources say**
- **ARL definition (NIST):** the average number of samples before a signal.
- **CUSUM rule of thumb (NIST):** k = δ/2 (0.5σ for a 1σ shift) and h ≈ 4–5σ. The NIST table gives in-control ARL0 = 336 (h=4) and 930 (h=5), and ARL 8.38 and 10.4 for a 1σ shift.
  - *Our computation:* a Markov-chain check reproduces these as one-sided values. Two-sided ARL0 is about 168 (h=4) and about 465 (h=5).
- **EWMA (NIST and Lucas & Saccucci):**
  - Typical λ is 0.2–0.3, with L=3 or taken from the Lucas & Saccucci tables, which "assume independent data from a normal population".
  - Lucas & Saccucci also describe fast-initial-response, combined Shewhart-EWMA and robust-EWMA variants.
  - *Our computation:* (λ=0.1, L=2.814), (λ=0.2, L=2.962) and (λ=0.05, L=2.615) each give ARL0≈500.
- **Self-starting CUSUM (Hawkins):** replaces the unknown μ and σ with the running mean and SD since start-up.

**Applicability to Nara**
- **ARL is in days:** with daily metrics, ARL0≈168 means about one false alarm per metric per user every 5.5 months, even under ideal iid conditions. Across several metrics, false alarms multiply.
- **Autocorrelation (our simulation):** in a two-sided CUSUM with k=0.5, h=4 on AR(1) data, ARL0 falls from about 172 (φ=0) to about 54 (φ=0.3), 35 (φ=0.5) and 24 (φ=0.8).
- **Do not run CUSUM or EWMA on 7-day rolling means**, which are heavily autocorrelated. Run them on daily values or on residuals from a time-series model (the Alwan & Roberts approach). Calibrate ARL empirically on held-out user data.
- Use a self-starting design or require a burn-in before the first alert.

## 9. Heart-rate recovery (HRR) definitions

**Sources**
- Cole CR, Blackstone EH, Pashkow FJ, Snader CE, Lauer MS. 1999. "Heart-rate recovery immediately after exercise as a predictor of mortality." *NEJM* 341(18):1351–1357. DOI 10.1056/NEJM199910283411804. OPENED-ABSTRACT.
- Imai K et al. 1994. "Vagally mediated heart rate recovery after exercise is accelerated in athletes but blunted in patients with chronic heart failure." *JACC* 24(6):1529–1535. DOI 10.1016/0735-1097(94)90150-3. OPENED-ABSTRACT.
- Watanabe J et al. 2001. *Circulation* 104(16):1911–1916. DOI 10.1161/circ.104.16.1911. OPENED-ABSTRACT.
- Shetler K et al. 2001. "Heart rate recovery: validation and methodologic issues." *JACC* 38(7):1980–1987. DOI 10.1016/s0735-1097(01)01652-7. OPENED-ABSTRACT.

**What the sources say**
- **Cole 1999 (N=2,428, symptom-limited test):** HRR is peak HR minus HR at 1 min. An abnormal value is ≤12 bpm, with adjusted RR 2.0 for mortality.
- **Watanabe 2001:** notes that earlier studies measured HRR during a cool-down. With no cool-down and a lateral decubitus posture, the abnormal cutoff was ≤18 bpm.
- **Shetler 2001:** found HRR at 2 min with a cutoff of <22 bpm to be the best predictor.
- **Imai 1994:** T30, the time constant of the HR decline over the first 30 s, mainly reflects vagal reactivation and is lengthened by atropine. It is largely insensitive to intensity and to propranolol. T120 depends on workload and sympathetic activity.

**Applicability to Nara**
- The cutoff depends on protocol: 12, 18 or 22 bpm depending on posture, cool-down and time point.
- Free-living "recovery" after uncontrolled efforts has no standardized peak, posture or cool-down, so it is not comparable to clinical HRR or its mortality thresholds.
- If Nara computes it, call it "post-effort HR decline", compute it only within each person, and condition on peak HR and effort.
- T30-style fitting is the most intensity-robust option.

## 10. Personalized HR response modeling

**Source**
- Nazaret A, Tonekaboni S, Darnell G, Ren SY, Sapiro G, Miller AC. 2023. "Modeling personalized heart rate response to exercise and environmental factors with wearables data." *npj Digit Med* 6:207. DOI 10.1038/s41746-023-00926-4. OPENED-FULL (PMC10651837).

**What the source says**
- **Data:** 270,707 outdoor runs from 7,465 Apple Watch users in the Apple Heart and Movement Study. Runs lasted 15–120 min, each user had at least 10 runs, and data were on a 10 s grid.
- **Model:** a hybrid ODE in which HR tracks oxygen demand. A neural network maps intensity to demand, with weather g(W) and fatigue h(t) terms. A per-user embedding is learned from the user's past workouts.
- **Inputs:** pedometer speed, GPS speed, cadence, elevation gain, temperature, humidity and elapsed time. No HR from the target workout is used.
- **Confounders acknowledged:** noisy workload proxies, unobserved pre-workout activity affecting initial HR (handled with an analysis starting after 2 min), weather and fatigue.
- **Evaluation:** a within-user temporal split, with the first 80% of each user's workouts for training and the last 20% for testing. Median MAE was 6.1 bpm (IQR 4.4–8.8).
- **Limitations stated:** runners only, Apple hardware, outdoor runs only, VO2max taken from the watch estimate. All authors are Apple employees.

**Applicability to Nara**
- This gives a methodological template: a forward-in-time per-user split, with workload and environment as explicit inputs.
- Without a workload input, an HR response cannot be read as fitness. WHOOP lacks GPS speed and elevation unless they are imported.
- Activity labels from the IMU are not workload. Expect confounding by terrain, heat and pre-session state.

## 11. Wear/non-wear and stillness ambiguity

**Sources**
- Choi L, Liu Z, Matthews CE, Buchowski MS. 2011. *Med Sci Sports Exerc* 43(2):357–364. DOI 10.1249/MSS.0b013e3181ed61a3. OPENED-FULL.
- van Hees VT et al. 2011. *PLoS One* 6(7):e22922. DOI 10.1371/journal.pone.0022922. OPENED-FULL.
- van Hees VT et al. 2015. "A Novel, Open Access Method to Assess Sleep Duration Using a Wrist-Worn Accelerometer." *PLoS One* 10(11):e0142533. DOI 10.1371/journal.pone.0142533. OPENED-FULL.

**What the sources say**
- **Choi (hip ActiGraph):** non-wear is 90 min or more of zero counts, tolerating up to 2 min of nonzero counts if the 30 min upstream and downstream are zero. The older 60-min Troiano rule misclassified sedentary time and sleep as non-wear: about 308 min per 24 h in adults, against 161 min for the new rule.
- **van Hees 2011 (wrist GENEA):** a 30-min block is non-wear if the SD is below 3.0 mg, or the range is below 50 mg, on at least 2 of 3 axes. The 3.0 mg threshold sits just above the 2.6 mg noise floor of a stationary device. The authors call for validation against direct observation.
- **van Hees 2015:** "absence of body movement is also possible during periods of wakefulness". Daytime inactivity could be inactivity or naps. Against PSG, specificity was 45±23%.

**Applicability to Nara**
- IMU stillness alone cannot separate sleep, quiet wake and an off-wrist strap.
- Thresholds in mg are tied to the device's noise floor and must be re-derived for the WHOOP IMU.
- *(derived)* WHOOP has extra channels that help: PPG signal quality or loss, and skin temperature drifting toward ambient. Make wear an explicit tri-state: worn, not worn, or unknown.

## 12. Sleep regularity, timing, main sleep vs naps, circadian phase

**Sources**
- Phillips AJK et al. 2017. "Irregular sleep/wake patterns are associated with poorer academic performance and delayed circadian and sleep/wake timing." *Sci Rep* 7:3216. DOI 10.1038/s41598-017-03171-4. OPENED-FULL.
- Wittmann M, Dinich J, Merrow M, Roenneberg T. 2006. "Social jetlag: misalignment of biological and social time." *Chronobiol Int* 23(1-2):497–509. DOI 10.1080/07420520500545979. OPENED-ABSTRACT.
- van Hees VT et al. 2018. "Estimating sleep parameters using an accelerometer without sleep diary." *Sci Rep* 8:12975. DOI 10.1038/s41598-018-31266-z. OPENED-FULL.
- Klerman EB et al. 2002. "Comparisons of the variability of three markers of the human circadian pacemaker." *J Biol Rhythms* 17(2):181–193. DOI 10.1177/074873002129002474. OPENED-ABSTRACT.
- Benloucif S et al. 2008. "Measuring melatonin in humans." *J Clin Sleep Med* 4(1):66–69. DOI 10.5664/jcsm.27083. OPENED-ABSTRACT.

**What the sources say**
- **Sleep Regularity Index (Phillips):**
  - Definition: the probability of being in the same state 24 h apart, compared minute by minute and scaled as 200(x − ½). In practice it ranges from 0 to 100.
  - It "does not require designation of a main daily sleep episode".
  - Only non-missing pairs were used, and the analysis took whole-week blocks to avoid day-of-week bias.
  - Irregular sleepers' DLMO (dim-light melatonin onset) was about 2.2 h later, measured with hourly saliva at ≤5 lux.
- **Main sleep vs naps (van Hees 2018, HDCZA):**
  - The main sleep-period window is the longest block per noon-to-noon day.
  - Candidate blocks must last more than 30 min, and gaps under 60 min are merged, both explicitly to avoid absorbing naps.
  - The method gives no information on daytime sleep.
- **Circadian markers:** melatonin phase estimates are the most precise marker (SD 0.23–0.35 h, against 0.78 h for core temperature; Klerman). Benloucif recommends reporting low-threshold DLMO.
- **Social jetlag (Wittmann):** the workday vs free-day timing mismatch, measured by MCTQ (Munich ChronoType Questionnaire).
  - *Not verified from an opened source:* the exact mid-sleep formula (mid-sleep on free days minus mid-sleep on workdays).

**Applicability to Nara**
- Compute the SRI only over complete paired data. Report coverage, and require whole weeks.
- Keep main sleep and naps distinct, using HDCZA-like rules.
- Any HR- or temperature-derived "circadian phase" is a masked proxy, affected by activity, posture and sleep. Kräuchi (§7) shows the HR rhythm is visible only under constant routine. Never call it endogenous phase or equate it with DLMO.

## 13. Temporal leakage in overlapping-window evaluation

**Sources**
- Roberts DR et al. 2017. "Cross-validation strategies for data with temporal, spatial, hierarchical, or phylogenetic structure." *Ecography* 40(8):913–929. DOI 10.1111/ecog.02881. OPENED-ABSTRACT via Crossref.
- López de Prado M. 2018. *Advances in Financial Machine Learning*. Wiley. ISBN 978-1-119-48208-6. I opened the table of contents only: Ch. 7 covers "Why K-Fold CV Fails in Finance", §7.4 "Purged K-Fold CV", §7.4.1 "Purging the Training Set", §7.4.2 "Embargo", and Ch. 12 covers "Combinatorial Purged CV".
- Bergmeir C, Benítez JM. 2012. "On the use of cross-validation for time series predictor evaluation." *Information Sciences* 191:192–213. DOI 10.1016/j.ins.2011.12.028. METADATA-ONLY.
- Bergmeir C, Hyndman RJ, Koo B. 2018. *CSDA* 120:70–83. DOI 10.1016/j.csda.2017.11.003. OPENED-FULL (preprint).

**What the sources say**
- **Roberts:** ignoring dependence causes "serious underestimation of predictive error". They recommend blocked CV "wherever dependence structures exist… even if no correlation structure is visible in the fitted model residuals".
- **Bergmeir, Hyndman & Koo:**
  - Random removal "invalidates the CV in the dependent setting".
  - h-block ("non-dependent") CV leaves out the h neighbouring observations.
  - Standard K-fold CV is valid only for purely autoregressive models whose errors are uncorrelated.

**Applicability to Nara**
- With overlapping windows (for example HART's 120-sample window with a 30-sample hop, 75% overlap), a random window split leaks near-duplicates.
- Split by subject (HART uses LOSO) or by contiguous time blocks.
- Purge training windows that overlap the test span, and embargo a gap at least as long as one window plus any rolling-feature lookback.

## 14. Block bootstrap for dependent data

**Sources**
- Künsch HR. 1989. "The Jackknife and the Bootstrap for General Stationary Observations." *Ann Stat* 17(3):1217–1241. DOI 10.1214/aos/1176347265. OPENED-ABSTRACT (Project Euclid).
- Politis DN, Romano JP. 1994. "The Stationary Bootstrap." *JASA* 89(428):1303–1313. DOI 10.1080/01621459.1994.10476870. OPENED-ABSTRACT.

**What the sources say**
- **Künsch:** resample blocks of l consecutive observations. Consistency requires l→∞ and l/n→0.
- **Politis & Romano:** blocks of random, geometrically distributed length make the resampled series stationary, for weakly dependent stationary data.

**Applicability to Nara**
- Use a block or stationary bootstrap for confidence intervals on per-user trends and on evaluation metrics computed from overlapping windows.
- *(derived)* Choose a mean block length that exceeds the autocorrelation horizon, for example at least 7 days for daily metrics built on 7-day rolling features.
- Neither source gives a numeric block length. Automatic block-length selection exists in later literature, which I did not verify here.
- Non-stationarity, such as training phases or illness, violates the assumptions of both methods.

## 15. FDA DHT guidance (December 2023)

**Source**
- U.S. FDA (CDER, CBER, CDRH, OCE). "Digital Health Technologies for Remote Data Acquisition in Clinical Investigations: Guidance for Industry, Investigators, and Other Stakeholders." Final guidance, December 2023. Docket FDA-2021-D-1128. https://www.fda.gov/media/155022/download. OPENED-FULL.

**What the source says**
- **Verification:** "confirmation by examination and provision of objective evidence that the parameter that the DHT measures (e.g., acceleration, temperature, pressure) is measured accurately and precisely."
- **Validation:** "confirmation… that the selected DHT appropriately assesses the clinical event or characteristic in the proposed participant population (e.g., step count or heart rate)."
- **Population example:** step algorithms validated in healthy people "may not be applicable for participants with Parkinson's disease with a shuffling gait."
- **Factors to evaluate:** placement (wrist vs hip) and activities that may be misinterpreted, such as a "bumpy car ride misinterpreted as a tremor".
- **Scope of the terms:** they are not the same as the Quality System Regulation definitions in 21 CFR 820.

**Applicability to Nara**
- Nara is not running a clinical investigation, but the framework fits.
- WHOOP raw accelerometry, PPG and temperature need verification. Each derived metric (RMSSD, respiratory rate, activity label) needs validation in Nara's intended population.
- Nothing validated on WISDM or HART datasets carries over to disease cohorts automatically.
- The SpO2 byte has neither verification nor validation.

## 16. WISDM dataset

**Sources**
- Weiss GM. 2019. "WISDM Smartphone and Smartwatch Activity and Biometrics Dataset." UCI Machine Learning Repository, DOI 10.24432/C5HK59. OPENED: the UCI page plus the official `WISDM-dataset-description.pdf` extracted from the dataset zip.
- Weiss GM, Yoneda K, Hayajneh T. 2019. "Smartphone and Smartwatch-Based Biometrics Using Activities of Daily Living." *IEEE Access* 7:133190–133202. DOI 10.1109/ACCESS.2019.2940729. OPENED-ABSTRACT.

**What the sources say**
- **Subjects and protocol:** 51 subjects (IDs 1600–1650), 18 scripted activities of 3 min each, about 54 min per subject.
- **Devices:** the watch was on the dominant hand (LG G Watch, Android Wear 1.5). The phone was in a pocket (Nexus 5/5X or Galaxy S5).
- **Sensors and sampling:** accelerometer (m/s²) and gyroscope (rad/s) at a nominal 20 Hz. The rates "are just suggestions to the operating systems", so polling can be delayed. Record counts vary by sensor.
- **Activities:** walking, jogging, stairs, sitting, standing, typing, brushing teeth, eating soup/chips/pasta/sandwich, drinking, kicking, catch, dribbling, writing, clapping and folding clothes.
- **Windowing:** the provided features use 10 s non-overlapping windows.
- **Missing:** there is no sleep or lying class, no free-living data, and the description gives no demographic or health data.

**Applicability to Nara**
- Mismatched sampling rate: WISDM is 20 Hz with jitter, WHOOP is 100 Hz.
- Mismatched placement: the dominant wrist, against WHOOP's usual non-dominant wrist or bicep.
- Mismatched population and context: scripted, healthy, short bouts.
- A classifier trained on WISDM is not validated for free-living or disease cohorts, and it has no rest or sleep class.

## 17. HART upstream (EdgeIntelligenceLab/HART)

**Source**
- GitHub repository https://github.com/EdgeIntelligenceLab/HART: README, CITATION.md, `configs/hart_config_L120_d48.json`, `finetuning_HART/HAR_dataloader.py`, `finetune.py`, and `data_preprocessing/Resampling.py`. OPENED-FULL.
- Paper: Jare S, Kumar KG, Srivastava N, Arjunan P. "HART: A Pretrained Time-Series Foundation Model and Benchmark for Human Activity Recognition." FMSys'26 workshop at CPS-IoT Week 2026. The DOI is "to be added". The paper itself was not opened.

**What the source says**
- **Architecture:** HART adapts IBM Granite TSPulse, a dual-domain time and FFT masked-reconstruction model. Settings: d_model=48, 8 encoder blocks, 2 decoder blocks, patch length/stride 12, 5 register tokens and a 0.3 mask ratio, for 206,860 parameters.
- **Pretraining data:** 26 HAR datasets (including WISDM, UCI-HAR, PAMAP2), with accelerometer, gyroscope and magnetometer channels.
- **Input requirements:**
  - Everything is resampled to 30 Hz with a polyphase anti-alias FIR, and the README warns that mismatched rates shift FFT-domain structure.
  - Windows are 120 samples (4 s), with a 30-sample hop in the examples.
  - Channels are per-dataset columns.
  - Standard scaling is fit on the training fold.
  - The README does not specify units or placement.
- **Classification:** a gated-attention head is fine-tuned per dataset under LOSO. There is no universal label set.
- **Results:** in-distribution accuracy/F1 0.753/0.680, out-of-distribution 0.749/0.566.
- **License and weights:** MIT, with weights in `checkpoints/pretrained_hart_L120_d48/`.

**Applicability to Nara**
- WHOOP 100 Hz IMU data must be polyphase-resampled to 30 Hz (up 3, down 10) and windowed at 120 samples.
- Units and scaling must match the fine-tuning data.
- A labeled fine-tune is required, because no off-the-shelf head exists.
- Out-of-distribution F1 of about 0.57 says to expect substantial degradation on WHOOP placement and populations. Treat labels as low-confidence context, not ground truth.

---

## Verified sources

| # | Source | Status |
|---|---|---|
| 1 | Rousseeuw & Croux 1993, JASA | OPENED-FULL (pp. 1273–1274 read) |
| 1 | Leys et al. 2013, JESP | OPENED-FULL |
| 2 | Buchheit 2014, Front Physiol | OPENED-FULL |
| 2 | Plews et al. 2012, EJAP | OPENED-ABSTRACT |
| 2 | Plews et al. 2013, Sports Med | OPENED-ABSTRACT |
| 2 | Plews et al. 2014, IJSPP | OPENED-ABSTRACT |
| 3 | Task Force ESC/NASPE 1996, Circulation / EHJ | METADATA-ONLY, not verified (403/paywall) |
| 3 | Munoz et al. 2015, PLoS One | OPENED-FULL |
| 3 | Shaffer & Ginsberg 2017, Front Public Health | OPENED-FULL |
| 4 | Lipponen & Tarvainen 2019, JMET | OPENED-ABSTRACT (full text 403) |
| 4 | Peltola 2012, Front Physiol | OPENED-FULL |
| 4 | NeuroKit2 signal_fixpeaks.py | OPENED (secondary, code) |
| 4 | "20% RR change" percentage filter | NOT VERIFIED (no primary source opened) |
| 5 | Schäfer & Vagedes 2013, Int J Cardiol | OPENED-ABSTRACT |
| 5 | Lam et al. 2020, JMIR Biomed Eng e17355 | OPENED-ABSTRACT (Crossref); full text blocked by WAF |
| 6 | Charlton et al. 2016, Physiol Meas | OPENED-FULL |
| 6 | Charlton et al. 2018, IEEE RBME | OPENED-FULL |
| 7 | Kräuchi & Wirz-Justice 1994, Am J Physiol | OPENED-ABSTRACT |
| 7 | Sarabia et al. 2008, Physiol Behav | OPENED-ABSTRACT |
| 8 | Page 1954, Biometrika | METADATA-ONLY |
| 8 | Roberts 1959, Technometrics | OPENED-ABSTRACT |
| 8 | Lucas & Saccucci 1990, Technometrics | OPENED-ABSTRACT |
| 8 | Hawkins 1987, The Statistician | OPENED-ABSTRACT |
| 8 | NIST e-Handbook §6.3.2.3, 6.3.2.3.1, 6.3.2.4 | OPENED-FULL |
| 8 | Lu & Reynolds 1999, JQT | METADATA-ONLY |
| 8 | Alwan & Roberts 1988, JBES | METADATA-ONLY |
| 8 | ARL two-sided values and AR(1) simulation | Our computation, not from source |
| 9 | Cole et al. 1999, NEJM | OPENED-ABSTRACT (full text 403; cool-down detail taken from Watanabe 2001 background) |
| 9 | Imai et al. 1994, JACC | OPENED-ABSTRACT |
| 9 | Watanabe et al. 2001, Circulation | OPENED-ABSTRACT |
| 9 | Shetler et al. 2001, JACC | OPENED-ABSTRACT |
| 10 | Nazaret et al. 2023, npj Digit Med | OPENED-FULL |
| 11 | Choi et al. 2011, MSSE | OPENED-FULL |
| 11 | van Hees et al. 2011, PLoS One | OPENED-FULL |
| 11 | van Hees et al. 2013, PLoS One | OPENED (non-wear criteria are in supplement S1, not opened) |
| 11 | van Hees et al. 2015, PLoS One | OPENED-FULL |
| 12 | Phillips et al. 2017, Sci Rep | OPENED-FULL |
| 12 | Wittmann et al. 2006, Chronobiol Int | OPENED-ABSTRACT (mid-sleep formula not verified) |
| 12 | van Hees et al. 2018, Sci Rep | OPENED-FULL |
| 12 | Klerman et al. 2002, J Biol Rhythms | OPENED-ABSTRACT |
| 12 | Benloucif et al. 2008, JCSM | OPENED-ABSTRACT |
| 13 | Roberts et al. 2017, Ecography | OPENED-ABSTRACT (Crossref) |
| 13 | López de Prado 2018 (Wiley) | OPENED (publisher page and TOC PDF only) |
| 13 | Bergmeir & Benítez 2012, Inf Sci | METADATA-ONLY |
| 13 | Bergmeir, Hyndman & Koo 2018, CSDA | OPENED-FULL (preprint) |
| 14 | Künsch 1989, Ann Stat | OPENED-ABSTRACT |
| 14 | Politis & Romano 1994, JASA | OPENED-ABSTRACT |
| 15 | FDA DHT final guidance, Dec 2023 | OPENED-FULL (PDF) |
| 16 | WISDM UCI page and dataset description PDF | OPENED-FULL |
| 16 | Weiss, Yoneda & Hayajneh 2019, IEEE Access | OPENED-ABSTRACT |
| 17 | HART GitHub repo (README, config, code) | OPENED-FULL |
| 17 | HART FMSys'26 paper | NOT OPENED (DOI pending) |
