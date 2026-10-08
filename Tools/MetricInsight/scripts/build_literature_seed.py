#!/usr/bin/env python3
"""Build the curated literature corpus (src/nara_metric_insight/data/literature_seed.json) from hand-written
claims plus live PubMed verification.

What is hand-written here: claim, topic, direction, typical_magnitude, evidence_type,
population, keywords. What is NOT hand-written: every bibliographic field. title,
journal, year, first_author and doi are copied verbatim from the NCBI esummary record
for the PMID, and the raw esummary bytes are saved to build/literature/verification/esummary_<pmid>.json
(outside the package, not committed).

Four guards run before an entry is accepted:
  1. expect_author / expect_year must match the esummary record (catches PMID typos).
  2. every string in `support` must occur in the PubMed abstract fetched with efetch
     (catches claims or numbers that the abstract does not state).
  3. every number in the claim must occur in the abstract (thousands separators aside).
  4. the record is a journal article (esummary pubtype), never a preprint or a retracted publication.
  5. an entry that can be offered as an explanation has a title the explanation card may show (no forbidden
     term, nothing that reads as a hint of an illness: literature.ALARMING_TITLE).
An entry that fails either guard is dropped and listed in verification/manifest.json.
Abstracts are checked in memory only; they are not written to disk.

Usage:  uv run python scripts/build_literature_seed.py   (network; one esummary per PMID plus one efetch, paced
        under 3 req/s)
Env:    NCBI_EMAIL, NCBI_API_KEY      (optional; omitted from requests when unset)
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE / "src"))
from nara_metric_insight.literature import ALARMING_TITLE, EXCLUDED_TOPICS  # noqa: E402
from nara_metric_insight.validate import forbidden_term  # noqa: E402
OUT = HERE / "src" / "nara_metric_insight" / "data" / "literature_seed.json"
VERIFY_DIR = HERE / "build" / "literature" / "verification"
EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
TOOL = "nara_litsearch"
MIN_INTERVAL_S = 0.4  # stays under the 3 req/s keyless limit

WEARABLE_92K = "92,457 US adults who wore a wrist-worn heart rate tracker for at least 35 weeks (2016-2018)"

SPECS: list[dict] = [
    dict(
        id="rhr-norm-between-person", pmid="32023264", expect_author="Quer", expect_year="2020",
        metric=["rhr"], topic="normal_range", direction="variable",
        claim=("In 92,457 adults with long-term wrist-tracker data, mean daily RHR was 65 bpm with a range of "
               "40 to 109 bpm across individuals, and one person's normal RHR could differ from another's by as "
               "much as 70 bpm."),
        typical_magnitude="mean 65 bpm; individual range 40-109 bpm; personal norms differ by up to 70 bpm",
        evidence_type="large_wearable_cohort", population=WEARABLE_92K,
        keywords=["normal", "range", "baseline", "average", "typical", "population", "individual", "norm", "wearable"],
        support=["92,457", "65 beats per minute", "40 to 109 bpm", "as much as 70 bpm"],
    ),
    dict(
        id="rhr-variability-within-person", pmid="32023264", expect_author="Quer", expect_year="2020",
        metric=["rhr"], topic="day_to_day_variability", direction="variable",
        claim=("Within individuals, daily RHR was much more consistent than between people and stayed relatively "
               "stable over the short term for most, but 20% had at least one week in which their RHR fluctuated "
               "by 10 bpm or more."),
        typical_magnitude="a week with >=10 bpm fluctuation in 20% of individuals (median 320 days of data each)",
        evidence_type="large_wearable_cohort", population=WEARABLE_92K,
        keywords=["day-to-day", "fluctuation", "variability", "week", "stable", "change", "spike", "outlier",
                  "noise", "baseline"],
        support=["much more consistent over time", "20% experienced at least 1 week", "10 bpm or more",
                 "median of 320 days"],
    ),
    dict(
        id="rhr-seasonality", pmid="32023264", expect_author="Quer", expect_year="2020",
        metric=["rhr"], topic="seasonality", direction="variable",
        claim=("Daily RHR showed a small but statistically significant seasonal trend, lowest around July and "
               "highest around January in this US cohort."),
        typical_magnitude=None,
        evidence_type="large_wearable_cohort", population=WEARABLE_92K,
        keywords=["season", "seasonal", "winter", "summer", "month", "time of year", "january", "july"],
        support=["minimum in July", "maximum in January", "small but significant seasonal trend"],
    ),
    dict(
        id="rhr-population-reference", pmid="21905522", expect_author="Ostchega", expect_year="2011",
        metric=["rhr"], topic="normal_range", direction="variable",
        claim=("In US national survey data, seated resting pulse in adults averaged about 72 bpm and was slightly "
               "higher in women (74 bpm) than men (71 bpm); clinically defined bradycardia (<60 bpm) was reported "
               "in 15.2% of males and 6.9% of adult females."),
        typical_magnitude="adult mean ~72 bpm (women 74, men 71); <60 bpm in 15.2% of males, 6.9% of adult females",
        evidence_type="national_survey",
        population=("35,302 NHANES participants (1999-2008) without conditions or medications affecting pulse; "
                    "seated pulse after ~4 min rest"),
        keywords=["normal", "reference", "population", "percentile", "sex", "women", "men", "bradycardia", "low",
                  "tachycardia", "nhanes"],
        support=["35,302", "72 beats/min", "74 beats/min", "71 beats/min", "15.2%", "6.9%"],
    ),
    dict(
        id="rhr-age-real-world", pmid="31304404", expect_author="Avram", expect_year="2019",
        metric=["rhr"], topic="age", direction="decrease",
        claim=("Among 66,788 adults taking on-demand smartphone PPG readings, increasing age was associated with "
               "lower heart rate, while female sex, higher BMI and more medical conditions were associated with "
               "higher heart rate."),
        typical_magnitude=("95th percentile <=110 bpm (age 18-45), <=100 bpm (45-60), <=95 bpm (>60); "
                           "spot readings, not strictly resting"),
        evidence_type="large_digital_cohort",
        population="66,788 Health eHeart Study participants; 3,144,332 smartphone PPG spot measurements (2014-2018)",
        keywords=["age", "older", "aging", "younger", "sex", "female", "bmi", "weight", "obesity", "demographics"],
        support=["66,788", "increasing age was associated with a reduced HR", "number of medical conditions"],
    ),
    dict(
        id="rhr-fever", pmid="2424378", expect_author="Karjalainen", expect_year="1986",
        metric=["rhr"], topic="acute_illness", direction="increase",
        claim=("During acute febrile infections in 27 young men, mean heart rate was 84.0 bpm versus 66.5 bpm after "
               "recovery, rising on average 8.5 bpm per 1 degree C of temperature and staying high even during sleep."),
        typical_magnitude="~8.5 bpm per 1 degree C; 84.0 vs 66.5 bpm (febrile vs recovered, 24-h ECG)",
        evidence_type="small_observational_study",
        population="27 young men with uncomplicated acute febrile infection; 24-h ECG during fever and after recovery",
        # no bare "cold": BM25 would match it to "cold exposure" (temperature), not the common cold
        keywords=["fever", "febrile", "temperature", "infection", "illness", "sick", "flu", "influenza", "virus",
                  "inflammation"],
        support=["84.0 beats per minute", "66.5 beats per minute", "8.5 beats per minute", "even during sleep"],
    ),
    dict(
        id="rhr-covid-presymptomatic", pmid="33208926", expect_author="Mishra", expect_year="2020",
        metric=["rhr"], topic="acute_illness", direction="increase",
        claim=("In smartwatch data from 32 people with COVID-19, 81% showed changes in heart rate, daily steps or "
               "time asleep, and an alert based on extreme RHR elevations relative to the personal baseline could "
               "have flagged 63% of cases before symptom onset."),
        typical_magnitude=None,
        evidence_type="wearable_cohort",
        population="32 COVID-19 cases from a cohort of nearly 5,300 smartwatch wearers",
        keywords=["covid", "covid-19", "infection", "illness", "sick", "presymptomatic", "early", "warning",
                  "respiratory", "virus"],
        support=["26 of them (81%)", "63%", "extreme elevations in resting heart rate relative to the individual baseline"],
    ),
    dict(
        id="rhr-vaccination", pmid="35440684", expect_author="Quer", expect_year="2022",
        metric=["rhr"], topic="vaccination", direction="increase",
        claim=("After COVID-19 vaccination, RHR rose above the personal baseline in most wearers, peaking on day 2 "
               "and returning to normal by day 6, with a rise greater than one standard deviation in 47% after the "
               "second dose."),
        typical_magnitude="peak day 2, back to normal by day 6; >1 SD above personal norm in 47% after dose 2",
        evidence_type="large_wearable_cohort",
        population="5,674 smartwatch or fitness-band wearers with peri-vaccination data (most received mRNA vaccines)",
        keywords=["vaccine", "vaccination", "shot", "booster", "immune", "reactogenicity", "covid"],
        support=["peaked on day 2", "returned to normal by day 6", "47% of participants after their second vaccine dose",
                 "5674"],
    ),
    dict(
        id="rhr-alcohol-acute", pmid="32609894", expect_author="Tasnim", expect_year="2020",
        metric=["rhr"], topic="alcohol", direction="increase",
        claim=("In placebo-controlled trials, a single dose of alcohol raised heart rate within six hours at low, "
               "medium and high doses (by 5.1, 4.6 and 5.8 bpm), and after high doses (>30 g) heart rate stayed "
               "elevated for up to 24 hours."),
        typical_magnitude="+4.6 to +5.8 bpm within 6 h; high dose: +6.2 bpm at 7-12 h and +2.7 bpm at >=13 h",
        evidence_type="systematic_review_meta_analysis",
        population="32 RCTs, 767 adults (642 male, mostly healthy, mean age 33)",
        keywords=["alcohol", "drinking", "drinks", "ethanol", "beer", "wine", "hangover", "night out", "party"],
        support=["increase HR by 5.1 bpm", "increased HR by 4.6 bpm", "increased HR by 5.8 bpm",
                 "increased HR by 6.2 bpm", "HR by 2.7 bpm", "High-dose alcohol increases HR at all times up to 24 hours"],
    ),
    dict(
        id="hrv-alcohol-sleep", pmid="29549064", expect_author="Pietil", expect_year="2018",
        metric=["hrv"], topic="alcohol", direction="decrease",
        claim=("In 4,098 employees recorded in daily life, alcohol intake was dose-dependently associated with more "
               "sympathetic and less parasympathetic regulation in the first three hours of sleep, with effects "
               "seen even at low intake."),
        typical_magnitude="HRV-derived recovery state -9.3, -24.0 and -39.2 percentage units for low, moderate, high intake",
        evidence_type="large_observational_cohort",
        population=("4,098 Finnish employees (56% women, mean age 45) with beat-to-beat recordings on days with and "
                    "without alcohol"),
        keywords=["alcohol", "drinking", "sleep", "recovery", "night", "autonomic", "hrv", "parasympathetic"],
        support=["4098 subjects", "dose-dependently associated with increased sympathetic regulation",
                 "9.3, 24.0, and 39.2 percentage units", "low alcohol intake"],
    ),
    dict(
        id="rhr-overreaching", pmid="18308872", expect_author="Bosquet", expect_year="2008",
        metric=["rhr"], topic="training_load", direction="increase",
        claim=("In a meta-analysis of competitive athletes, short-term training overload (2-week cutoff) moderately "
               "increased resting HR (SMD 0.55), longer overload did not change resting values, and the authors note "
               "such changes may fall within normal day-to-day variability."),
        typical_magnitude="SMD 0.55 (moderate) after short-term overload; no change after long-term overload",
        evidence_type="systematic_review_meta_analysis",
        population="competitive athletes in increased-training-load studies",
        keywords=["overtraining", "overreaching", "training load", "overload", "strain", "fatigue", "athlete",
                  "hard training", "recovery"],
        support=["SMD = 0.55", "without alteration of resting values", "day-to-day variability"],
    ),
    dict(
        id="rhr-evening-exercise", pmid="40234380", expect_author="Leota", expect_year="2025",
        metric=["rhr", "hrv"], topic="training_load", direction="increase",
        claim=("In 14,689 physically active wearable users (over 4 million nights), later exercise timing and higher "
               "exercise strain were associated with higher nocturnal RHR and lower nocturnal HRV, while bouts "
               "ending at least 4 hours before sleep onset were not associated with changes in sleep."),
        typical_magnitude=None,
        evidence_type="large_wearable_cohort",
        population="14,689 physically active adults wearing a biometric device for one year; 4,084,354 person-nights",
        keywords=["evening", "exercise", "workout", "late", "training", "strain", "timing", "bedtime", "night", "sleep"],
        support=["14,689", "higher nocturnal resting heart rate", "4 hours before sleep onset"],
    ),
    dict(
        id="rhr-endurance-training", pmid="30513777", expect_author="Reimers", expect_year="2018",
        metric=["rhr"], topic="aerobic_fitness", direction="decrease",
        claim=("A meta-analysis of 191 controlled studies in healthy people found that all sport types lowered RHR, "
               "but only endurance training and yoga did so significantly in both sexes, with larger reductions in "
               "people with higher starting RHR and smaller ones in older participants."),
        typical_magnitude=None,
        evidence_type="systematic_review_meta_analysis",
        population="healthy participants in 191 controlled exercise studies (215 samples)",
        keywords=["fitness", "aerobic", "endurance", "training", "exercise", "cardio", "running", "cycling", "yoga",
                  "adaptation", "fitter"],
        support=["191 studies", "All types of sports decreased the RHR",
                 "only endurance training and yoga significantly decreased the RHR in both sexes",
                 "negatively with the average age"],
    ),
    dict(
        id="rhr-detraining", pmid="42558561", expect_author="Zhang", expect_year="2026",
        metric=["rhr"], topic="detraining", direction="increase",
        claim=("In a meta-analysis of 86 RCTs with an exercise phase followed by detraining, the training-related "
               "improvement in resting heart rate was no longer significant at any detraining follow-up, while some "
               "other cardiometabolic benefits persisted for a time."),
        typical_magnitude=None,
        evidence_type="systematic_review_meta_analysis",
        population="86 RCTs (n=5,670) with exercise training followed by a detraining phase",
        keywords=["detraining", "stopping", "break", "time off", "inactivity", "sedentary", "rest days",
                  "deconditioning", "injury"],
        support=["86 studies (n=5,670)", "resting heart rate", "no longer significant in any of the follow-up subgroups"],
    ),
    dict(
        id="rhr-sleep-restriction", pmid="42185632", expect_author="Gonzalez", expect_year="2026",
        metric=["rhr"], topic="sleep_restriction", direction="increase",
        claim=("In a within-person analysis of 2,596 women's wearable data, a 10% decrease in weekly sleep duration "
               "was associated with a 1.2% increase in RHR, regardless of menstrual cycle phase."),
        typical_magnitude="+1.2% RHR per 10% decrease in weekly sleep duration",
        evidence_type="large_wearable_cohort",
        population="2,596 women; 1.2 million days of wearable data (within-participant natural experiment)",
        keywords=["sleep", "short sleep", "sleep loss", "sleep deprivation", "sleep restriction", "less sleep",
                  "tired", "insomnia", "duration"],
        support=["2596 women", "RHR increased 1.2% with a 10% decrease in weekly sleep duration",
                 "regardless of cycle phase"],
    ),
    dict(
        id="rhr-menstrual-cycle-pattern", pmid="39715818", expect_author="Jasinski", expect_year="2024",
        metric=["rhr", "hrv"], topic="menstrual_cycle", direction="variable",
        claim=("Across 45,811 menstrual cycles from 11,590 wrist-wearable users, RHR followed a regular within-cycle "
               "pattern, lowest around cycle day 5 and highest around day 26, with smaller fluctuations in older "
               "participants and those using birth control."),
        typical_magnitude=None,
        evidence_type="large_wearable_cohort",
        population="11,590 menstruating wrist-wearable users; 45,811 cycles",
        keywords=["menstrual", "period", "cycle", "luteal", "follicular", "ovulation", "hormonal", "contraception",
                  "birth control", "women"],
        support=["11,590 participants", "45,811 menstrual cycles", "RHRmin and RMSSDmax at cycle day 5",
                 "RHRmax at day 26", "birth control"],
    ),
    dict(
        id="rhr-menstrual-luteal", pmid="28465583", expect_author="Shilaih", expect_year="2017",
        metric=["rhr"], topic="menstrual_cycle", direction="increase",
        claim=("In 91 women tracked over 274 ovulatory cycles with a wrist sensor during sleep, pulse rate was 2.1 "
               "bpm higher in the fertile window and 3.8 bpm higher in the mid-luteal phase than during menstruation."),
        typical_magnitude="+2.1 bpm (fertile window) and +3.8 bpm (mid-luteal) vs menstrual phase",
        evidence_type="prospective_observational",
        population="91 healthy, non-pregnant women aged 22-42; 274 ovulatory cycles; wrist PPG during sleep",
        keywords=["menstrual", "period", "luteal", "ovulation", "fertile", "cycle", "women", "pms"],
        support=["91 healthy", "274 ovulatory cycles", "2.1 beat-per-minute", "3.8 beat-per-minute"],
    ),
    dict(
        id="rhr-altitude", pmid="20417339", expect_author="Naeije", expect_year="2010",
        metric=["rhr"], topic="altitude", direction="increase",
        claim=("On exposure to high altitude, heart rate rises along with cardiac output, and after a few days of "
               "acclimatization cardiac output returns to normal while heart rate remains increased, a pattern that "
               "persists with prolonged stays."),
        typical_magnitude=None,
        evidence_type="narrative_review",
        population="people exposed to high altitude, from acute to lifelong stays (review)",
        # no bare "travel": most trips are not to altitude (jet lag, flights, disrupted sleep)
        keywords=["altitude", "mountain", "elevation", "hypoxia", "high altitude", "ski", "hiking",
                  "acclimatization"],
        support=["increase in cardiac output with tachycardia", "heart rate remains increased",
                 "essentially unchanged with prolonged or lifelong altitude sojourns"],
    ),
    dict(
        id="rhr-bedroom-heat", pmid="41462246", expect_author="O'Connor", expect_year="2025",
        metric=["rhr", "hrv"], topic="heat", direction="increase",
        claim=("In 47 older adults monitored through a summer, nighttime bedroom temperatures above 24 degrees C were "
               "associated with elevated sleeping heart rate and higher odds of clinically relevant HRV reductions, "
               "with larger effects at higher temperatures."),
        typical_magnitude=("HR elevation size not given in abstract; odds of a clinically relevant HRV drop OR 1.4 "
                           "(24-26 C), 2.0 (26-28 C), 2.9 (28-32 C) vs <24 C"),
        evidence_type="small_observational_study",
        population="47 community-dwelling adults aged 65+ in Queensland, Australia; 14,179 nighttime hours",
        keywords=["heat", "hot", "temperature", "bedroom", "warm", "summer", "heatwave", "climate",
                  "room temperature", "night"],
        support=["47 community-dwelling adults", "elevated heart rate", "14,179 valid nighttime hours",
                 "greater effects observed as temperature increased"],
    ),
    # rhr-hydration-caution (PMID 25924806, Hooper 2015) was removed on 2026-10-07: its title ("Clinical symptoms, signs
    # and tests for ... dehydration") cannot be shown under a person's explanation.
    dict(
        id="rhr-energy-drinks", pmid="37695306", expect_author="Gualberto", expect_year="2024",
        metric=["rhr"], topic="caffeine", direction="variable",
        claim=("A meta-analysis of 17 RCTs in healthy adults found that acute energy-drink consumption raised blood "
               "pressure but did not significantly change resting heart rate."),
        typical_magnitude="no significant resting HR change (systolic BP +4.71 mmHg at 60-80 min)",
        evidence_type="systematic_review_meta_analysis",
        population="healthy adults in 17 RCTs of acute energy-drink consumption",
        keywords=["caffeine", "coffee", "energy drink", "stimulant", "espresso", "tea", "pre-workout"],
        support=["17 RCTs", "resting heart rate and QT/QTc interval were not significant", "4.71 mmHg"],
    ),
    dict(
        id="rhr-psychological-stress", pmid="40700646", expect_author="Presby", expect_year="2025",
        metric=["rhr", "hrv"], topic="psychological_stress", direction="increase",
        claim=("In 181,574 WHOOP wearers surveyed monthly, people reporting more perceived stress tended to have "
               "higher RHR (standardized coefficient 0.09, the largest between-person association found), and in "
               "cross-lagged models higher reported stress preceded higher RHR and lower HRV."),
        typical_magnitude="small: standardized coefficient 0.09 (Perceived Stress Scale vs RHR, between-person)",
        evidence_type="large_wearable_cohort",
        population="181,574 WHOOP wearers with monthly mental-health surveys over 13 months",
        keywords=["stress", "anxiety", "mental", "work", "exam", "worry", "depression", "mood", "pressure", "burnout"],
        support=["181,574", "standardized coefficient of 0.09", "higher levels of reported stress preceded higher RHRs"],
    ),
    dict(
        id="rhr-beta-blockers", pmid="19487713", expect_author="McAlister", expect_year="2009",
        metric=["rhr"], topic="medication", direction="decrease", context_only=True,
        claim=("In 23 placebo-controlled heart-failure trials, beta-blockers lowered resting heart rate, and the size "
               "of the heart-rate reduction rather than the dose was associated with the survival benefit (18% lower "
               "risk of death per 5 bpm reduction)."),
        typical_magnitude=None,
        evidence_type="systematic_review_meta_analysis",
        population="19,209 patients with heart failure (mostly systolic dysfunction) in 23 RCTs",
        keywords=["beta-blocker", "beta blocker", "medication", "medicine", "drug", "metoprolol", "bisoprolol",
                  "carvedilol", "propranolol", "prescription"],
        support=["23 beta-blocker trials", "5 beats/min", "18% reduction", "resting heart rates"],
    ),
    dict(
        id="rhr-wearable-accuracy", pmid="32552580", expect_author="Zhang", expect_year="2020",
        metric=["rhr", "hr"], topic="wearable_accuracy", direction="variable",
        claim=("A meta-analysis of 44 validation studies covering 15 brands found that wrist-worn PPG heart rate "
               "agreed closely with ECG or chest-strap references at rest (mean difference -0.01 bpm) and during "
               "sleep (-0.40 bpm), with larger errors during resistance training (-7.26 bpm) and cycling (-4.55 bpm)."),
        typical_magnitude="mean difference -0.01 bpm (rest), -0.40 bpm (sleep); -7.26 (resistance), -4.55 (cycling)",
        evidence_type="systematic_review_meta_analysis",
        population="44 studies (738 effect sizes) comparing wrist-worn PPG devices with ECG or chest straps",
        keywords=["accuracy", "validity", "error", "wearable", "watch", "sensor", "ppg", "optical", "measurement",
                  "artifact", "reliable"],
        support=["44 articles", "15 different brands", "-0.40 bpm", "-0.01 bpm", "-7.26 bpm", "-4.55 bpm"],
    ),
    dict(
        id="rhr-long-term-risk", pmid="28552551", expect_author="Aune", expect_year="2017",
        metric=["rhr"], topic="long_term_risk", direction="increase", context_only=True,
        claim=("In a dose-response meta-analysis of eighty-seven prospective studies, each 10 bpm higher resting "
               "heart rate was associated with higher risk of all-cause mortality (RR 1.17) and cardiovascular "
               "disease (RR 1.15)."),
        typical_magnitude="per 10 bpm higher RHR: all-cause mortality RR 1.17 (95% CI 1.14-1.19); CVD RR 1.15 (1.11-1.18)",
        evidence_type="systematic_review_meta_analysis",
        population="87 prospective cohort studies",
        keywords=["risk", "mortality", "death", "longevity", "cardiovascular", "heart disease", "long-term",
                  "prognosis", "health risk"],
        support=["Eighty seven studies", "1.17 (95% CI: 1.14-1.19", "1.15 (95% CI: 1.11-1.18",
                 "per 10 beats per minute increase"],
    ),
    # ---------------------------------------------------------------- the other key metrics (2026-10-07)
    # HRV (SDNN and RMSSD), wrist temperature, respiratory rate, blood oxygen, awake heart rate, steps
    # and walking, energy expenditure. Same rules as above: claims from the abstract only.
    # ------------------------------------------------------------------ HRV
    dict(
        id="hrv-age-population-wearable", pmid="33328029", expect_author="Natarajan", expect_year="2020",
        metric=["hrv"], topic="age", direction="decrease",
        claim=("In a cross-sectional study of more than 8 million Fitbit users, wrist-derived HRV metrics decreased "
               "with age, with parasympathetic function declining faster than sympathetic function, and RMSSD "
               "showed no significant difference between the sexes."),
        typical_magnitude=None,
        evidence_type="large_wearable_cohort",
        population="8 203 261 Fitbit users; interbeat intervals from one randomly selected 24 h period (Sept 1, 2018)",
        keywords=["age", "older", "aging", "younger", "population", "norm", "benchmark", "sex", "wearable",
                  "rmssd"],
        support=["8 203 261 Fitbit users", "HRV metrics decrease with age",
                 "parasympathetic function declines faster than sympathetic function",
                 "such a difference is not seen with RMSSD"],
    ),
    dict(
        id="hrv-norms-depend-on-context", pmid="29034226", expect_author="Shaffer", expect_year="2017",
        metric=["hrv"], topic="normal_range", direction="variable",
        claim=("A review of HRV metrics and published norms emphasizes that recording length, age and sex shape "
               "baseline HRV values, and cautions that 24 h, short-term (about 5 min) and ultra-short-term "
               "(under 5 min) normative values are not interchangeable."),
        typical_magnitude=None,
        evidence_type="narrative_review",
        population="published normative HRV values for clinical, healthy and optimal-performance populations (review)",
        keywords=["norm", "normal", "reference", "recording length", "short-term", "24-hour", "baseline",
                  "comparison", "sdnn", "rmssd"],
        support=["including recording period length, subject age, and sex",
                 "24 h, short-term, and ultra-short-term normative values are not interchangeable",
                 "short-term (~5 min), and ultra-short-term (<5 min) HRV"],
    ),
    dict(
        id="hrv-rmssd-vs-sdnn-recording-length", pmid="26414314", expect_author="Munoz", expect_year="2015",
        metric=["hrv"], topic="wearable_accuracy", direction="variable",
        claim=("In 3,387 adults, RMSSD agreed better than SDNN with longer reference recordings at every recording "
               "length tested; a single 10 s ECG gave a valid RMSSD, whereas for SDNN the authors recommend 30 s "
               "or several 10 s recordings."),
        typical_magnitude=("single 10 s recordings vs 240-300 s reference: r = 0.853-0.862 for RMSSD, "
                           "r = 0.758-0.764 for SDNN"),
        evidence_type="cross_sectional",
        population="3,387 adults; 10 s, 30 s and 120 s ECG segments compared with 240-300 s recordings",
        keywords=["sdnn", "rmssd", "recording length", "short recording", "window", "measurement", "accuracy",
                  "ecg", "validity"],
        support=["measured in 3,387 adults",
                 "For all recording lengths and agreement measures, RMSSD outperformed SDNN",
                 "Even a single 10s (standard ECG) recording yields a valid RMSSD measurement",
                 "For SDNN we would recommend either 30s or multiple 10s ECGs"],
    ),
    dict(
        id="hrv-sleep-deprivation", pmid="40895095", expect_author="Zhang", expect_year="2025",
        metric=["hrv"], topic="sleep_restriction", direction="decrease",
        claim=("A meta-analysis of 11 randomized controlled trials (549 participants) found that sleep deprivation "
               "was associated with a significant decrease in RMSSD, while the reduction in SDNN was not "
               "statistically significant."),
        typical_magnitude=None,
        evidence_type="systematic_review_meta_analysis",
        population="549 participants in 11 randomized controlled trials of sleep deprivation published 2010-2024",
        keywords=["sleep loss", "short sleep", "sleep deprivation", "all-nighter", "less sleep", "late night",
                  "rmssd", "autonomic"],
        support=["11 eligible studies involving 549 participants", "RMSSD showed a significant decrease",
                 "a non-significant reduction in SDNN"],
    ),
    dict(
        id="hrv-marathon-next-night", pmid="20419617", expect_author="Hynynen", expect_year="2010",
        metric=["hrv"], topic="training_load", direction="decrease",
        claim=("In ten healthy, physically active men, nocturnal RMSSD fell to 87% of rest-day values after moderate "
               "endurance exercise and to 55% after a marathon, with SDNN falling to 90% and 64%; the authors "
               "interpret these changes as prolonged dose-response effects."),
        typical_magnitude="RMSSD 87% (moderate exercise) and 55% (marathon) of rest-day baseline; SDNN 90% and 64%",
        evidence_type="cohort",
        population=("ten healthy, physically active men; nocturnal R-R intervals after a rest day, a moderate "
                    "endurance exercise and a marathon"),
        keywords=["marathon", "long run", "hard workout", "endurance", "race", "training", "night after",
                  "workout", "exercise load"],
        support=["ten healthy, physically active men",
                 "root-mean-square of differences between adjacent R-R intervals to 87+/-10% and 55+/-16%",
                 "Standard deviation of R-R intervals decreased to 90+/-9% and 64+/-10%",
                 "prolonged dose-response effects on autonomic modulation after exercises"],
    ),
    dict(
        id="hrv-night-to-night-variability", pmid="41309064", expect_author="Grosicki", expect_year="2026",
        metric=["hrv"], topic="day_to_day_variability", direction="variable",
        claim=("In about 2 million nightly HRV readings from more than 21,000 wearable users, at least five of seven "
               "nights were needed to estimate a week's HRV coefficient of variation reliably, and higher "
               "night-to-night variation was associated with more alcohol, lower physical activity and shorter, "
               "less consistent sleep."),
        typical_magnitude="five of seven nights gave intraclass correlation >= 0.80 with the full-week HRV-CV",
        evidence_type="large_wearable_cohort",
        population="more than 21,000 wearable device users; about 2 million nocturnal HRV readings",
        keywords=["night-to-night", "variability", "coefficient of variation", "fluctuation", "consistency",
                  "week", "baseline", "noise", "swing", "alcohol"],
        support=["2 million nocturnal HRV readings from >21,000 wearable device users",
                 "At least five of seven nights were required",
                 "greater alcohol consumption, lower physical activity, shorter and less consistent sleep"],
    ),
    dict(
        id="hrv-rmssd-parasympathetic-monitoring", pmid="41516438", expect_author="Esco", expect_year="2025",
        metric=["hrv"], topic="day_to_day_variability", direction="variable",
        claim=("A narrative review of athlete HRV monitoring describes RMSSD as a robust, practical measure with a "
               "strong association with parasympathetic activity and reliability in short and ultra-short "
               "recordings, and favors routine near-daily measurements summarized as weekly averages and "
               "coefficient of variation over isolated readings."),
        typical_magnitude=None,
        evidence_type="narrative_review",
        population="athletes (narrative review of HRV monitoring with mobile devices)",
        keywords=["rmssd", "parasympathetic", "vagal", "weekly average", "trend", "single reading", "monitoring",
                  "athlete", "daily measurement"],
        support=["strong association with parasympathetic activity",
                 "reliability in both short- and ultra-short-term recordings",
                 "superiority of routine, near-daily HRV measurements over isolated assessments",
                 "the utility of weekly averages and the coefficient of variation"],
    ),
    # ------------------------------------------------------------------ wrist / skin temperature
    dict(
        id="temp-menstrual-cycle-wrist", pmid="29175999", expect_author="Shilaih", expect_year="2018",
        metric=["temp"], topic="menstrual_cycle", direction="increase",
        claim=("Across 437 menstrual cycles recorded with a wrist sensor worn during sleep, a sustained 3-day "
               "temperature shift appeared in 82% of cycles, and early-luteal wrist skin temperature averaged "
               "0.33°C higher than in the fertile window. These cycle changes were not altered by lifestyle "
               "factors such as alcohol or eating before bed."),
        typical_magnitude="early-luteal phase 0.33°C above the fertile window; sustained shift in 82% of cycles",
        evidence_type="cohort",
        population=("One hundred and thirty-six eumenorrheic, non-pregnant women wearing wrist skin temperature "
                    "sensors during sleep; 437 cycles; ovulation confirmed with at-home LH tests"),
        keywords=["menstrual", "period", "cycle", "luteal", "ovulation", "fertile window", "women", "hormonal",
                  "phase"],
        support=["WST was recorded across 437 cycles",
                 "A sustained 3-day temperature shift was observed in 357/437 cycles (82%)",
                 "0.33°C higher than in the fertile window",
                 "lifestyle factors, like having sex, alcohol, or eating prior to bed"],
    ),
    dict(
        id="temp-wrist-circadian-vs-oral", pmid="18761026", expect_author="Sarabia", expect_year="2008",
        metric=["temp"], topic="circadian", direction="variable",
        claim=("In university students wearing a wrist sensor in daily life, wrist skin temperature followed a daily "
               "rhythm opposite in phase to oral temperature and about 60 minutes ahead of it, starting to rise "
               "around bedtime and dropping sharply after waking."),
        typical_magnitude="wrist rhythm phase-advanced by 60 min relative to oral temperature",
        evidence_type="cross_sectional",
        population=("99 university students in normal living conditions; wireless wrist sensor compared with oral "
                    "temperature and sleep diaries"),
        keywords=["circadian", "bedtime", "daily rhythm", "body clock", "core temperature", "oral temperature",
                  "waking", "time of day", "night"],
        support=["inverse phase relationship with OT", "phase-advanced by 60 min with respect to OT",
                 "WT started to increase in association to bed time", "dropped sharply after awakening"],
    ),
    dict(
        id="temp-wrist-rise-at-sleep-onset", pmid="41324514", expect_author="Rodrigues Neto", expect_year="2026",
        metric=["temp"], topic="sleep_architecture", direction="variable",
        claim=("In actigraphy recordings from people living in different climates and from night-shift workers, "
               "wrist temperature rose slightly before and significantly after sleep onset and fell slightly before "
               "and markedly after sleep offset, regardless of environmental temperature or time of day. The pattern "
               "was consistent across latitudes and seasons."),
        typical_magnitude=None,
        evidence_type="cross_sectional",
        population=("participants from Brazilian cities with diverse climates and night-shift workers; wrist "
                    "actigraphs with skin temperature sensors"),
        keywords=["sleep onset", "falling asleep", "waking", "night shift", "day sleep", "nap", "warming",
                  "bedtime", "wake time"],
        support=["rose slightly before and significantly after sleep onset",
                 "decreased slightly before and markedly after sleep offset",
                 "regardless of environmental temperature or time of day",
                 "consistent across latitudes and seasons"],
    ),
    dict(
        id="temp-humid-heat-during-sleep", pmid="15578234", expect_author="Okamoto-Mizuno", expect_year="2005",
        metric=["temp"], topic="heat", direction="increase",
        claim=("In eight healthy men sleeping under controlled conditions, a full night of humid heat (32 degrees C, "
               "80% relative humidity) was accompanied by significantly higher mean skin and rectal temperatures and "
               "more total wakefulness than 26 degrees C and 50% humidity."),
        typical_magnitude=None,
        evidence_type="controlled_lab_study",
        population="eight healthy males sleeping under controlled air temperature and humidity",
        keywords=["heat", "hot night", "humid", "bedroom", "room temperature", "summer", "warm",
                  "air conditioning", "humidity", "heatwave"],
        support=["a humid heat climate (Ta=32 degrees C, RH=80%)",
                 "control climate [air temperature (Ta)=26 degrees C, relative humidity (RH)=50%]",
                 "Tre and mean Tsk were significantly higher in H",
                 "total amount of wakefulness was significantly increased in H"],
    ),
    # ------------------------------------------------------------------ respiratory rate
    dict(
        id="resp-night-to-night-consistency", pmid="38875674", expect_author="Toften", expect_year="2022",
        metric=["resp"], topic="day_to_day_variability", direction="variable",
        claim=("In a 3-month home pilot with 6 healthy adults, the nightly average respiratory rate from a bedside "
               "radar sleep monitor was consistent from night to night. In the validation part of the study, the "
               "monitor produced a respiratory rate 84% of the time, with a mean absolute error of 0.18 respirations "
               "per minute against respiratory inductance plethysmography."),
        typical_magnitude=None,
        evidence_type="cohort",
        population=("6 healthy adults using a bedside radar sleep monitor at home for 3 months; 37 healthy adults in "
                    "full-night validation against respiratory inductance plethysmography"),
        keywords=["night-to-night", "consistency", "stable", "baseline", "breathing rate", "nightly average",
                  "variability", "change", "trend"],
        support=["analyzed for 6 healthy participants in a pilot study",
                 "used Somnofy at home for 3 months",
                 "the nightly average was consistent from night to night",
                 "measured RR 84% of the time, with mean absolute error of 0.18"],
    ),
    dict(
        id="resp-sleep-stages", pmid="27597768", expect_author="Gutierrez", expect_year="2016",
        metric=["resp"], topic="sleep_architecture", direction="variable",
        claim=("In 38 adults without obstructive sleep apnea studied with overnight polysomnography, respiratory rate "
               "was higher during wakefulness than in any sleep stage, and respiratory rate variability was greatest "
               "awake and lowest in deep N3 sleep."),
        typical_magnitude=None,
        evidence_type="cross_sectional",
        population=("38 adults without obstructive sleep apnea (apnea-hypopnea index <5) undergoing all-night "
                    "polysomnography"),
        keywords=["sleep stage", "deep sleep", "rem", "light sleep", "awake", "wake", "breathing rate",
                  "variability", "sleep architecture"],
        support=["38 adults with no obstructive sleep apnea", "being greater in wakefulness than in any sleep stage",
                 "RRV was greater during wakefulness compared to any sleep stage",
                 "RRV correlated with the depth of sleep, being lowest during N3"],
    ),
    dict(
        id="resp-wearable-accuracy-psg", pmid="32043961", expect_author="Berryhill", expect_year="2020",
        metric=["resp", "rhr"], topic="wearable_accuracy", direction="variable",
        claim=("Against polysomnography in 32 healthy adults, a WHOOP wearable measured respiratory rate with low "
               "bias (1.8%) and precision error (6.7%) versus inductance plethysmography, and heart rate during "
               "sleep with a bias of -0.17% and precision of 1.5% versus ECG."),
        typical_magnitude="respiratory rate bias 1.8%, precision 6.7%; heart rate bias -0.17%, precision 1.5%",
        evidence_type="controlled_lab_study",
        population=("32 community-based adults without medical conditions or sleep disorders (21 women; mean age "
                    "23.8 years); one polysomnography night"),
        keywords=["accuracy", "validation", "whoop", "wearable", "polysomnography", "error", "breathing rate",
                  "reliable", "measurement"],
        support=["In 32 participants (21 women", "respiratory rate (bias, 1.8%; precision, 6.7%)",
                 "heart rate (bias, -0.17%; precision, 1.5%)",
                 "electrocardiogram and inductance plethysmography during polysomnography"],
    ),
    dict(
        id="resp-altitude-sleep", pmid="29713290", expect_author="Boos", expect_year="2018",
        metric=["resp", "hrv"], topic="altitude", direction="variable",
        claim=("In sixteen healthy servicemen sleeping at up to 3600 m over eight nights, ECG-derived respiratory "
               "rate and time-domain HRV during sleep showed no significant change, while non-linear HRV measures "
               "were more sensitive to altitude."),
        typical_magnitude=None,
        evidence_type="cohort",
        population=("Sixteen healthy British military servicemen (mean age 31.4 years); baseline at 800 m, then "
                    "eight nights at up to 3600 m; nocturnal cardiac patch"),
        keywords=["altitude", "mountain", "elevation", "hypoxia", "trek", "ski trip", "hiking", "acclimatization",
                  "breathing rate"],
        support=["at a sleeping altitude of up to 3600 m",
                 "no significant changes in the ECG-derived respiratory rate",
                 "any of the time domain measures of HRV during sleep",
                 "Non-linear HRV is more sensitive to the effects of HA"],
    ),
    # ------------------------------------------------------------------ SpO2
    dict(
        id="spo2-wearable-accuracy-umbrella", pmid="39080098", expect_author="Doherty", expect_year="2024",
        metric=["spo2"], topic="wearable_accuracy", direction="variable",
        claim=("An umbrella review of 24 systematic reviews covering 249 validation studies found that consumer "
               "wearables measured blood oxygen saturation with a mean absolute difference of up to 2.0% against "
               "reference standards."),
        typical_magnitude="mean absolute difference up to 2.0%",
        evidence_type="systematic_review",
        population="249 validation studies of consumer wearables (430,465 participants) across 24 systematic reviews",
        keywords=["blood oxygen", "oxygen saturation", "accuracy", "error", "wearable", "smartwatch",
                  "validation", "reliable", "pulse oximetry"],
        support=["24 systematic reviews met our inclusion criteria",
                 "249 non-duplicate validation studies of consumer wearable devices",
                 "wearables showed a mean absolute difference of up to 2.0%"],
    ),
    dict(
        id="spo2-smartwatch-device-differences", pmid="37437005", expect_author="Jiang", expect_year="2023",
        metric=["spo2"], topic="wearable_accuracy", direction="variable",
        claim=("Compared with a clinical-grade pulse oximeter, consumer smartwatch SpO2 accuracy differed "
               "significantly between devices, with mean absolute errors from 2.2% for the closest to 5.8% for the "
               "farthest, and on one watch only 69.5% of attempted measurements succeeded."),
        typical_magnitude=("MAE 2.2% (Apple Watch Series 7) to 5.8% (Garmin Venu 2s); successful readings "
                           "69.5-88.9% of attempts"),
        evidence_type="cross_sectional",
        population=("49 adults aged 18-85, with and without chronic lung conditions, compared against a "
                    "clinical-grade pulse oximeter"),
        keywords=["smartwatch", "blood oxygen", "accuracy", "error", "missing", "failed reading", "device",
                  "brand", "oxygen saturation"],
        support=["statistically significant differences in accuracy between devices",
                 "closest to the reference standard (MAE = 2.2%",
                 "farthest from the reference standard (MAE = 5.8%",
                 "only 69.5% of attempted measurements were successful"],
    ),
    dict(
        id="spo2-skin-pigmentation", pmid="35971142", expect_author="Shi", expect_year="2022",
        metric=["spo2"], topic="wearable_accuracy", direction="variable",
        claim=("A meta-analysis of 32 studies (6505 participants) found that pulse oximetry probably overestimates "
               "oxygen saturation in people with high skin pigmentation (pooled mean bias 1.11%) and in people "
               "described as Black/African American (1.52%), although accuracy root-mean-square stayed below 4% in "
               "all subgroups."),
        typical_magnitude="overestimation 1.11% (high pigmentation), 1.52% (Black/African American); Arms < 4% in all subgroups",
        evidence_type="systematic_review_meta_analysis",
        population="32 studies (6505 participants) comparing pulse oximetry with arterial CO-oximetry",
        keywords=["skin tone", "skin color", "pigmentation", "darker skin", "ethnicity", "bias", "overestimate",
                  "pulse oximeter", "accuracy"],
        support=["We included 32 studies (6505 participants)",
                 "high level of skin pigmentation (pooled mean bias 1.11%",
                 "people described as Black/African American (1.52%",
                 "appear acceptably accurate (with Arms < 4%)"],
    ),
    dict(
        id="spo2-high-altitude-sleep", pmid="22379248", expect_author="Nussbaumer-Ochsner", expect_year="2012",
        metric=["spo2"], topic="altitude", direction="decrease",
        claim=("In sixteen healthy mountaineers, median nocturnal oxygen saturation fell from 96% at 490 m to 67% on "
               "the first night at 4559 m and was 71% on the third night there, while sleep quality, initially "
               "impaired, improved with acclimatization."),
        typical_magnitude="median nocturnal SpO2 96% at 490 m; 67% (first night) and 71% (third night) at 4559 m",
        evidence_type="cohort",
        population="Sixteen healthy mountaineers; polysomnography at 490 m and on the first and third nights at 4559 m",
        keywords=["altitude", "mountain", "elevation", "hypoxia", "ski", "hiking", "acclimatization",
                  "blood oxygen", "trek"],
        support=["One night in a sleep laboratory at 490 meters",
                 "decreased during the 1st night at 4559 m from 96% to 67%",
                 "During the 3rd night at 4559 m, oxygen saturation was 71%",
                 "sleep quality is initially impaired but improves with acclimatization"],
    ),
    dict(
        id="spo2-normal-sleep-values", pmid="8989066", expect_author="Gries", expect_year="1996",
        metric=["spo2"], topic="normal_range", direction="variable",
        claim=("In healthy people with normal overnight sleep studies (aged 1 month to 85 years), the lowest SpO2 of "
               "the night averaged 90.4% and the median overnight SpO2 averaged 96.5%, with lower values in those "
               "older than 60."),
        typical_magnitude="lowest nightly value 90.4% +/- 3.1%; median 96.5% +/- 1.5%; median 95.1% in people over 60",
        evidence_type="cross_sectional",
        population=("Three hundred fifty people with normal overnight polysomnography and no known craniofacial, "
                    "neurologic or lung conditions, aged 1 month to 85 years"),
        keywords=["blood oxygen", "oxygen saturation", "dip", "lowest", "night", "normal", "sleep",
                  "desaturation", "older"],
        support=["ranged in age from 1 month to 85 years", "the mean +/- SD Low Sat was 90.4%",
                 "The mean Sat 50 was 96.5%", "older subjects (> 60 years of age) had lower Sat 10"],
    ),
    # ------------------------------------------------------------------ daytime heart rate (awake, at rest)
    dict(
        id="hr-caffeine-resting", pmid="39008947", expect_author="Glaister", expect_year="2025",
        metric=["hr"], topic="caffeine", direction="variable",
        claim=("In a randomized, double-blind crossover trial in 16 male cyclists, 5 mg/kg of caffeine did not "
               "significantly change resting heart rate thirty-five minutes later compared with placebo."),
        typical_magnitude=None,
        evidence_type="randomized_trial",
        population="16 male cyclists (age 37 +/- 9 years) tested in an air-conditioned laboratory",
        keywords=["caffeine", "coffee", "espresso", "pre-workout", "stimulant", "energy drink", "tea",
                  "resting heart rate"],
        support=["double-blind, randomized, crossover design, 16 male cyclists",
                 "5 mg·kg-1 of caffeine or placebo",
                 "Thirty-five minutes post-supplementation, additional resting heart rate",
                 "but not on heart rate (p = .351)"],
    ),
    dict(
        id="hr-circadian-rhythm", pmid="17542944", expect_author="Vandewalle", expect_year="2007",
        metric=["hr", "hrv"], topic="circadian", direction="variable",
        claim=("Under constant-routine conditions in eight healthy young men, heart rate showed a robust endogenous "
               "circadian rhythm with its fitted peak in the afternoon (16:36), while HRV measures peaked in the "
               "early morning (between 05:00 and 06:59)."),
        typical_magnitude="heart rate fitted maximum 16:36; HRV maxima between 05:00 and 06:59",
        evidence_type="controlled_lab_study",
        population="Eight healthy males (age 24.4 +/- 4.4 years) assessed during 29-h constant routines",
        keywords=["time of day", "afternoon", "morning", "circadian", "body clock", "daily rhythm", "evening",
                  "daytime", "night"],
        support=["HR and HRV variables revealed robust endogenous circadian rhythms",
                 "in the afternoon (16:36 hours)", "in the early morning (between 05:00 and 06:59 hours)",
                 "Eight healthy males (age 24.4 +/- 4.4 years)"],
    ),
    dict(
        id="hr-posture-standing", pmid="31611089", expect_author="Hnatkova", expect_year="2019",
        metric=["hr"], topic="posture", direction="increase",
        claim=("In 175 healthy women and 176 healthy men, heart rate was about 10 bpm higher when sitting and about "
               "30 bpm higher when standing than when lying, with no difference between the sexes in these "
               "increases; women's heart rate was about 5 bpm higher than men's when lying down."),
        typical_magnitude="about +10 bpm lying to sitting, +30 bpm lying to standing; women about 5 bpm higher",
        evidence_type="controlled_lab_study",
        population=("175 healthy females and 176 healthy males (aged 33.1 years on average); repeated supine, "
                    "sitting and standing tests"),
        keywords=["posture", "standing", "sitting", "lying", "position", "upright", "stand up", "orthostatic",
                  "body position"],
        support=["175 and 176 healthy females and males", "increased heart rate by approximately 10 and 30 bpm",
                 "with no statistical differences between the sex groups",
                 "approximately 5 beats per minute (bpm) faster than males"],
    ),
    dict(
        id="hr-elevated-after-exercise", pmid="15461995", expect_author="Mourot", expect_year="2004",
        metric=["hr"], topic="training_load", direction="increase",
        claim=("After a single bout of constant or interval exercise in ten young men, R-R intervals were "
               "significantly shorter (heart rate higher) during early recovery, and twenty-four and 48 h later a "
               "persistently elevated heart rate was still seen in the upright posture."),
        typical_magnitude=None,
        evidence_type="controlled_lab_study",
        population=("ten male subjects (mean age 24.6 years) measured before and 1, 24 and 48 h after exercise, "
                    "supine and upright"),
        keywords=["after workout", "post-exercise", "hard session", "interval training", "elevated", "next day",
                  "training", "standing heart rate", "exercise"],
        support=["R-R intervals, TP, and HF/TP were significantly decreased",
                 "during the early recovery, when compared with control values",
                 "Twenty-four and 48 h after the end of the exercise",
                 "a persistent tachycardia continued to be observed in the upright posture"],
    ),
    # ------------------------------------------------------------------ steps / cadence / walking speed
    dict(
        id="steps-daily-normative-range", pmid="21798015", expect_author="Tudor-Locke", expect_year="2011",
        metric=["steps"], topic="normal_range", direction="variable",
        claim=("A review of step-count evidence reports that healthy adults typically take between 4,000 and 18,000 "
               "steps per day and that 10,000 steps/day is reasonable for this population; a direct estimate of the "
               "minimal amount of moderate-to-vigorous activity in free-living behaviour is 7,000-8,000 steps/day."),
        typical_magnitude="typical 4,000-18,000 steps/day; 7,000-8,000 steps/day aligns with minimal MVPA",
        evidence_type="narrative_review",
        population="healthy adults (review of normative pedometer and accelerometer step data)",
        keywords=["steps", "daily steps", "step count", "normal", "average", "typical", "step goal", "active",
                  "how many steps"],
        support=["healthy adults typically take between 4,000 and 18,000 steps/day",
                 "10,000 steps/day is reasonable for this population",
                 "free-living behaviour is 7,000-8,000 steps/day"],
    ),
    dict(
        id="steps-cadence-intensity", pmid="30654810", expect_author="Tudor-Locke", expect_year="2019",
        metric=["steps"], topic="physical_activity", direction="variable",
        claim=("In 76 healthy adults aged 21-40 walking on a treadmill, cadences of 100 and 130 steps/min were "
               "reasonable heuristic thresholds for moderate (3 METs) and vigorous (6 METs) intensity."),
        typical_magnitude="100 steps/min for 3 METs (moderate); 130 steps/min for 6 METs (vigorous)",
        evidence_type="cross_sectional",
        population="76 healthy adults aged 21-40 (10 men and 10 women per 5-year age group) walking on a treadmill",
        keywords=["cadence", "steps per minute", "brisk walking", "pace", "intensity", "moderate", "vigorous",
                  "walking speed", "zone"],
        support=["laboratory-based cross-sectional study, 76 healthy adults",
                 "Cadence thresholds of 100 and 130 steps/min",
                 "ambulatory intensity, respectively, in 21-40 year olds",
                 "absolutely-defined moderate (3 METs) and vigorous (6 METs) intensity"],
    ),
    dict(
        id="steps-walking-speed-by-age", pmid="21820535", expect_author="Bohannon", expect_year="2011",
        metric=["steps"], topic="age", direction="variable",
        claim=("A descriptive meta-analysis of healthy adults walking at a normal pace found mean gait speed ranged "
               "from 143.4 cm/second in men aged 40 to 49 years to 94.3 cm/second in women aged 80 to 99 years, "
               "and speeds were homogeneous within each age and sex stratum."),
        typical_magnitude="mean 143.4 cm/s (men 40-49) down to 94.3 cm/s (women 80-99)",
        evidence_type="systematic_review_meta_analysis",
        population="23111 apparently healthy adults from published studies, grouped by sex and decade of age",
        keywords=["walking speed", "gait speed", "pace", "age", "older", "aging", "walking", "slow walking",
                  "brisk"],
        support=["mean of 143.4 cm/second for men aged 40 to 49 years",
                 "mean of 94.3 cm/second for women aged 80 to 99 years",
                 "The gait speed was homogeneous within strata"],
    ),
    dict(
        id="steps-wearable-accuracy", pmid="39080098", expect_author="Doherty", expect_year="2024",
        metric=["steps"], topic="wearable_accuracy", direction="variable",
        claim=("An umbrella review of 24 systematic reviews found that consumer wearables mostly underestimated step "
               "counts, with reported mean absolute percentage errors ranging from -9% to 12%."),
        typical_magnitude="mean absolute percentage error -9% to 12% (mostly undercounting)",
        evidence_type="systematic_review",
        population="249 validation studies of consumer wearables (430,465 participants) across 24 systematic reviews",
        keywords=["accuracy", "step count", "undercount", "error", "tracker", "watch", "pedometer", "validation",
                  "wrist"],
        support=["24 systematic reviews met our inclusion criteria", "Wearables mostly underestimated step counts",
                 "ranging from - 9 to 12%"],
    ),
    dict(
        id="steps-weekday-vs-weekend", pmid="21893605", expect_author="Hirvensalo", expect_year="2011",
        metric=["steps"], topic="day_to_day_variability", direction="variable",
        claim=("In 1853 Finnish adults wearing pedometers for 7 consecutive days, total steps were higher on weekdays "
               "than on weekend days, whereas steps taken in continuous bouts of at least 10 min were higher on "
               "weekend days."),
        typical_magnitude="mean 7499 +/- 2908 steps/day",
        evidence_type="cross_sectional",
        population="1853 adults aged 30-45 years from the Cardiovascular Risk in Young Finns study (winter 2007-08)",
        keywords=["weekend", "weekday", "day of week", "saturday", "sunday", "workday", "routine", "variation",
                  "daily steps"],
        support=["data was collected from 1853 participants in 7 consecutive days",
                 "higher mean total steps on weekdays than on weekend days",
                 "they took more aerobic steps on weekend days than weekdays",
                 "bouts of at least 10 min continuous ambulatory activity"],
    ),
    dict(
        id="steps-coffee-randomized", pmid="36947466", expect_author="Marcus", expect_year="2023",
        metric=["steps"], topic="caffeine", direction="increase",
        claim=("In a randomized case-crossover trial of 100 adults over 14 days, days assigned to caffeinated coffee "
               "were associated with 10,646 daily steps versus 9665 on caffeine-avoidance days (mean difference "
               "1058), and with 397 versus 432 minutes of nightly sleep."),
        typical_magnitude="+1058 steps/day on coffee days (95% CI 441 to 1675); 36 fewer minutes of nightly sleep",
        evidence_type="randomized_trial",
        population=("100 ambulatory adults (mean age 39 years; 51% women) with a wrist-worn accelerometer and "
                    "continuously recording ECG"),
        keywords=["coffee", "caffeine", "espresso", "latte", "morning coffee", "steps", "activity", "movement",
                  "walking"],
        support=["A total of 100 adults were fitted", "sent over a period of 14 days",
                 "10,646 and 9665 daily steps (mean difference, 1058",
                 "397 and 432 minutes of nightly sleep"],
    ),
    # ------------------------------------------------------------------ energy expenditure
    dict(
        id="energy-wearable-accuracy", pmid="30194221", expect_author="O'Driscoll", expect_year="2020",
        metric=["energy"], topic="wearable_accuracy", direction="variable",
        claim=("A meta-analysis of 60 validation studies (104 effect sizes) in healthy adults found that energy "
               "expenditure estimates from wrist- and arm-worn monitors varied in accuracy by activity type with "
               "large heterogeneity, and devices combining heart rate or heat sensing with accelerometry had lower "
               "error in most activity types."),
        typical_magnitude=None,
        evidence_type="systematic_review_meta_analysis",
        population=("healthy adults in 60 studies comparing wrist- or arm-worn monitors with indirect calorimetry, "
                    "room calorimeters or doubly labelled water"),
        keywords=["calories", "energy", "accuracy", "error", "calorie burn", "estimate", "tracker", "watch",
                  "active calories", "validation"],
        support=["60 studies (104 effect sizes) were included",
                 "Devices showed variable accuracy depending on activity type",
                 "Large and significant heterogeneity was observed for many devices",
                 "Combining heart rate or heat sensing technology with accelerometry decreased the error"],
    ),
    dict(
        id="energy-life-course-dlw", pmid="34385400", expect_author="Pontzer", expect_year="2021",
        metric=["energy"], topic="age", direction="variable",
        claim=("In a large doubly labeled water database spanning ages 8 days to 95 years, total daily energy "
               "expenditure adjusted for fat-free mass remained stable in adulthood from 20 to 60 years, even "
               "during pregnancy, and then declined in older adults."),
        typical_magnitude=None,
        evidence_type="cross_sectional",
        population="males and females aged 8 days to 95 years in a large, diverse doubly labeled water database",
        keywords=["metabolism", "age", "older", "calories", "daily burn", "slowing", "middle age",
                  "energy needs", "aging"],
        support=["measured by the doubly labeled water method", "aged 8 days to 95 years",
                 "remains stable in adulthood (20 to 60 years), even during pregnancy",
                 "then declines in older adults"],
    ),
    dict(
        id="energy-constrained-total-expenditure", pmid="26832439", expect_author="Pontzer", expect_year="2016",
        metric=["energy"], topic="physical_activity", direction="variable",
        claim=("In 332 adults from five populations, after adjusting for body size and composition, total energy "
               "expenditure measured by doubly labeled water was positively correlated with accelerometer-measured "
               "physical activity, but the relationship was markedly stronger at lower activity levels and total "
               "expenditure plateaued in the most active."),
        typical_magnitude=None,
        evidence_type="cross_sectional",
        population="332 adults living in five populations; doubly labeled water and accelerometry",
        keywords=["calories", "activity", "exercise", "plateau", "metabolism", "adaptation", "daily burn",
                  "more active", "steps"],
        support=["a large (n = 332) sample of adults living in five populations",
                 "the relationship was markedly stronger over the lower range of physical activity",
                 "upper range of physical activity, total energy expenditure plateaued"],
    ),
    dict(
        id="energy-resting-largest-share", pmid="42445885", expect_author="Geißler", expect_year="2026",
        metric=["energy"], topic="normal_range", direction="variable",
        claim=("Resting energy expenditure is described as the largest component of total daily energy expenditure; "
               "in 38 healthy young adults after an overnight fast, fat-free mass was its dominant determinant "
               "(R2 = 0.90 in a model with sex and age), and no HRV-derived measure was significantly associated "
               "with it."),
        typical_magnitude="R2 = 0.90 for a model of fat-free mass, sex and age",
        evidence_type="cross_sectional",
        population="38 healthy young participants after an overnight fast; indirect calorimetry and bioimpedance",
        keywords=["resting", "bmr", "metabolism", "baseline burn", "calories", "muscle mass", "fat-free mass",
                  "resting energy", "daily burn"],
        support=["represents the largest component of total daily energy expenditure",
                 "38 healthy young participants following an overnight fast",
                 "FFM was the dominant determinant of REE (R2 = 0.90",
                 "None of the HRV-derived parameters was significantly associated with REE"],
    ),
]

META_CONVENTIONS = {
    "direction": ("Change in the listed metric associated with the factor in `topic`. 'variable' means no "
                  "significant change, a mixed or cyclical pattern, or a measurement/variability fact. For "
                  "topic long_term_risk the direction is the outcome risk as RHR rises."),
    "typical_magnitude": "Uses only numbers stated in the PubMed abstract; null when the abstract gives none.",
    "context_only": ("true = background or caution material (medication, long-term risk). Do not offer it as a "
                     "cause of a day-to-day change unless the user's own context makes it relevant."),
    "keywords": "Retrieval aids for lexical search. Not part of the claim and not taken from the source.",
    "metric": ("Corpus tags (metrics.InsightMetric.literature): rhr resting heart rate during sleep, hr awake heart "
               "rate at rest, hrv heart rate variability (RMSSD and SDNN), temp wrist/skin temperature, resp "
               "respiratory rate, spo2 blood oxygen, steps daily steps and walking, energy energy expenditure."),
    "claims": ("Written from the PubMed abstract only; full texts were not reviewed. Each claim's numbers "
               "were machine-checked against the abstract text at build time, and every source is a journal "
               "article that is neither a preprint nor retracted (see verification/manifest.json)."),
}

_last_call = [0.0]


def _get(url: str, attempts: int = 4) -> tuple[int, bytes]:
    for _ in range(attempts):
        wait = MIN_INTERVAL_S - (time.monotonic() - _last_call[0])
        if wait > 0:
            time.sleep(wait)
        _last_call[0] = time.monotonic()
        req = urllib.request.Request(url, headers={"User-Agent": f"{TOOL}/0.1 (seed build)"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(float(e.headers.get("Retry-After", "2")) + 0.5)
                continue
            raise
    raise RuntimeError(f"rate limited after {attempts} attempts")


def _params(**kw) -> str:
    kw["tool"] = TOOL
    if os.environ.get("NCBI_EMAIL"):
        kw["email"] = os.environ["NCBI_EMAIL"]
    if os.environ.get("NCBI_API_KEY"):
        kw["api_key"] = os.environ["NCBI_API_KEY"]
    return urllib.parse.urlencode(kw)


def _public_url(endpoint: str, **kw) -> str:
    """URL as recorded in the manifest: never contains email or api_key."""
    kw["tool"] = TOOL
    return EUTILS + endpoint + "?" + urllib.parse.urlencode(kw)


# A number in a claim: a digit run (with . or , groups) not glued to a letter, so SpO2, R2 and N3 are labels.
_NUMBER = re.compile(r"(?<![a-z\d.,])\d+(?:[.,]\d+)*", re.I)


def _norm(s: str) -> str:
    s = s.replace("−", "-").replace("–", "-").replace(" ", " ")
    return re.sub(r"\s+", " ", s).strip().lower()


def fetch_abstracts(pmids: list[str]) -> dict[str, str]:
    status, body = _get(EUTILS + "efetch.fcgi?" + _params(db="pubmed", id=",".join(pmids), retmode="xml"))
    root = ET.fromstring(body)
    out: dict[str, str] = {}
    for art in root.iter("PubmedArticle"):
        pmid = (art.findtext("./MedlineCitation/PMID") or "").strip()
        parts = ["".join(a.itertext()) for a in art.iter("AbstractText")]
        out[pmid] = " ".join(p.strip() for p in parts if p.strip())
    return out


def citation_from_esummary(rec: dict) -> dict:
    pubdate = rec.get("pubdate") or ""
    year = pubdate[:4] if pubdate[:4].isdigit() else (rec.get("sortpubdate") or "")[:4]
    doi = next((a.get("value") for a in rec.get("articleids", []) if a.get("idtype") == "doi"), None)
    first_author = rec.get("sortfirstauthor") or (rec.get("authors") or [{}])[0].get("name")
    return {
        "pmid": str(rec["uid"]),
        "doi": doi,
        "title": rec.get("title"),
        "journal": rec.get("source"),
        "year": int(year) if year.isdigit() else None,
        "first_author": first_author,
    }


def main() -> int:
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    started = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    pmids = list(dict.fromkeys(s["pmid"] for s in SPECS))
    records: dict[str, dict] = {}
    manifest: dict[str, dict] = {}

    for pmid in pmids:
        url = EUTILS + "esummary.fcgi?" + _params(db="pubmed", id=pmid, retmode="json")
        status, body = _get(url)
        path = VERIFY_DIR / f"esummary_{pmid}.json"
        path.write_bytes(body)  # raw response bytes, unmodified
        info = {
            "pmid": pmid,
            "request": _public_url("esummary.fcgi", db="pubmed", id=pmid, retmode="json"),
            "http_status": status,
            "fetched_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
            "file": f"verification/{path.name}",
            "bytes": len(body),
            "sha256": hashlib.sha256(body).hexdigest(),
        }
        try:
            data = json.loads(body)
            rec = data["result"][pmid]
            if "error" in rec or not rec.get("title"):
                raise ValueError(rec.get("error", "missing title"))
            records[pmid] = rec
            info["esummary_ok"] = True
        except (KeyError, ValueError, json.JSONDecodeError) as exc:
            info["esummary_ok"] = False
            info["error"] = str(exc)
        manifest[pmid] = info
        print(f"esummary {pmid}: {status} {'ok' if info['esummary_ok'] else 'FAILED'}", file=sys.stderr)

    abstracts = fetch_abstracts([p for p in pmids if p in records])

    entries, dropped = [], []
    for spec in SPECS:
        pmid = spec["pmid"]
        reasons = []
        rec = records.get(pmid)
        if rec is None:
            reasons.append("esummary failed")
        else:
            cit = citation_from_esummary(rec)
            if not (cit["first_author"] or "").startswith(spec["expect_author"]):
                reasons.append(f"first author {cit['first_author']!r} != expected {spec['expect_author']!r}")
            if str(cit["year"]) != spec["expect_year"]:
                reasons.append(f"year {cit['year']} != expected {spec['expect_year']}")
            abstract = _norm(abstracts.get(pmid, ""))
            missing = [t for t in spec["support"] if _norm(t) not in abstract]
            if not abstract:
                reasons.append("no abstract returned by efetch")
            elif missing:
                reasons.append(f"support terms not in abstract: {missing}")
            plain = re.sub(r"(?<=\d),(?=\d{3}(?!\d))", "", abstract)
            unstated = [n for n in _NUMBER.findall(spec["claim"]) if not re.search(
                rf"(?<![a-z\d.,]){re.escape(n.replace(',', ''))}(?!\d|[.,]\d)", plain)]
            if unstated:
                reasons.append(f"claim numbers not in the abstract: {unstated}")
            offered = not spec.get("context_only") and spec["topic"] not in EXCLUDED_TOPICS
            if offered and (forbidden_term(cit["title"] or "") or ALARMING_TITLE.search(cit["title"] or "")):
                reasons.append(f"the title cannot be shown under an explanation: {cit['title']!r}")
            kinds = [str(k) for k in rec.get("pubtype") or []]
            if "Journal Article" not in kinds or any(bad in k for k in kinds for bad in (
                    "Preprint", "Retracted Publication", "Retraction of Publication")):
                reasons.append(f"not a journal article in good standing: {kinds}")
            manifest[pmid].setdefault("support_checks", {})[spec["id"]] = {
                "terms": spec["support"], "missing": missing}
        if reasons:
            dropped.append({"id": spec["id"], "pmid": pmid, "reasons": reasons})
            continue
        entries.append({
            "id": spec["id"],
            "metric": spec["metric"],
            "topic": spec["topic"],
            "claim": spec["claim"],
            "direction": spec["direction"],
            "typical_magnitude": spec["typical_magnitude"],
            "evidence_type": spec["evidence_type"],
            "population": spec["population"],
            "context_only": spec.get("context_only", False),
            "keywords": spec["keywords"],
            "citation": cit,
            "verified": True,
            "verification_file": manifest[pmid]["file"],
        })

    for pmid, info in manifest.items():
        info["used_by"] = [e["id"] for e in entries if e["citation"]["pmid"] == pmid]

    seed = {
        "meta": {
            "name": "nara_literature_seed",
            "schema_version": 1,
            "built_at": started.isoformat(),
            "builder": "scripts/build_literature_seed.py",
            "entry_count": len(entries),
            "citation_source": ("NCBI E-utilities esummary.fcgi (db=pubmed, retmode=json). title, journal "
                                "(esummary 'source'), year (first 4 chars of 'pubdate'), first_author "
                                "('sortfirstauthor') and doi (articleids idtype=doi) are copied verbatim."),
            "conventions": META_CONVENTIONS,
            "dropped": dropped,
        },
        "entries": entries,
    }
    OUT.write_text(json.dumps(seed, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (VERIFY_DIR / "manifest.json").write_text(
        json.dumps({"built_at": started.isoformat(), "records": list(manifest.values()), "dropped": dropped},
                   indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {len(entries)} entries ({len(dropped)} dropped) -> {OUT}", file=sys.stderr)
    for d in dropped:
        print(f"  DROPPED {d['id']} ({d['pmid']}): {d['reasons']}", file=sys.stderr)
    return 0 if not dropped else 1


if __name__ == "__main__":
    sys.exit(main())
