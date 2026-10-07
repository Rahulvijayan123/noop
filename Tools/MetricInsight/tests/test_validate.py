import json
import re
from pathlib import Path

from nara_metric_insight import validate
from nara_metric_insight.literature import Literature

SWIFT = Path(__file__).resolve().parents[3] / "Strand" / "Screens" / "MeasurementContextWording.swift"

EVIDENCE = {
    "get_metric_summary": {"metric": "resting_hr", "units": "bpm", "estimated": False,
                           "latest": {"day": "2026-10-06", "value": 45}, "previous": {"day": "2026-10-05", "value": 48, "change": -3},
                           "baseline": {"usual": "week", "usual_value": 51, "change_vs_usual": -6,
                                        "week": {"center": 51, "nights": 6, "shown": True}, "long": None},
                           "assessment": {"basis": "week_usual"}},
    "get_data_quality": {"measured_nights": 7, "missing_nights": 0, "tracked_nights": 7},
    "get_related_metrics": {"signals": [
        {"metric": "hrv_rmssd", "units": "ms", "estimated": False, "latest": {"day": "2026-10-06", "value": 85}},
        {"metric": "resp_rate", "units": "breaths/min", "estimated": True, "latest": {"day": "2026-10-06", "value": 14.2}}]},
}
RETRIEVED = {"pmid:32023264": {"id": "pmid:32023264", "topic": "day_to_day_variability", "peer_reviewed": True,
                               "finding": "mean daily RHR was 65 bpm"}}
# An interpretation sentence the default citation (day-to-day variability) supports.
SUPPORT = "Night-to-night changes of a few bpm are common."


def answer(**over):
    base = {"headline": "Resting heart rate 45 bpm on Oct 6, below your recent nights",
            "observed": ["Your resting heart rate was 45 bpm on Oct 6, 3 bpm lower than on Oct 5."],
            "interpretation": ["Night-to-night changes of a few bpm are common and may reflect sleep timing."],
            "uncertainty": ["Only 7 nights are measured, so a usual range is not established yet."],
            "citations": ["pmid:32023264"]}
    base.update(over)
    return json.dumps(base)


def test_forbidden_terms_match_the_app_exactly():
    source = SWIFT.read_text()
    block = re.search(r"static let forbiddenTerms: \[String\] = \[(.*?)\]", source, re.S).group(1)
    assert tuple(re.findall(r'"([^"]+)"', block)) == validate.FORBIDDEN_TERMS


def test_a_grounded_hedged_answer_passes():
    result = validate.check(answer(), EVIDENCE, RETRIEVED)
    assert result.ok, result.errors
    assert result.answer["citations"] == ["pmid:32023264"]
    fenced = "```json\n" + answer() + "\n```"
    assert validate.check(fenced, EVIDENCE, RETRIEVED).ok


def test_wording_claims_and_relative_days_are_rejected():
    cases = {
        "wording": answer(interpretation=["A lower resting heart rate can mean you have recovered from stress."]),
        "claim": answer(interpretation=["The drop was caused by better sleep."]),
        "dates": answer(observed=["Your resting heart rate was 45 bpm last night."]),
    }
    for code, text in cases.items():
        result = validate.check(text, EVIDENCE, RETRIEVED)
        assert not result.ok and code in result.codes, (code, result.errors)
    # whole words only: "still" is not "ill", "stressing" is not in the list but "stress" is
    assert validate.check(answer(interpretation=["It is still within a few bpm of Oct 5.", SUPPORT]),
                          EVIDENCE, RETRIEVED).ok
    assert validate.forbidden_term("Still calm") == "calm"


def test_numbers_and_dates_must_come_from_the_tools():
    result = validate.check(answer(observed=["Your resting heart rate was 44 bpm on Oct 6."]), EVIDENCE, RETRIEVED)
    assert "grounding" in result.codes
    result = validate.check(answer(observed=["Your average was 47.3 bpm."]), EVIDENCE, RETRIEVED)
    assert "grounding" in result.codes  # an average the model computed itself
    result = validate.check(answer(observed=["Your resting heart rate was 45 bpm on Oct 9."]), EVIDENCE, RETRIEVED)
    assert "dates" in result.codes
    # magnitudes of signed changes, window lengths and retrieved findings are allowed
    ok = answer(observed=["It was 6 bpm below your median of 51 bpm over the last 7 nights."],
                interpretation=["Night-to-night values vary widely between people; a large study saw a mean of 65 bpm."])
    assert validate.check(ok, EVIDENCE, RETRIEVED).ok
    # a general finding grounds numbers only where findings are discussed, never a statement about the person
    personal = answer(observed=["Your resting heart rate was 65 bpm on Oct 6."])
    assert "grounding" in validate.check(personal, EVIDENCE, RETRIEVED).codes


def test_estimated_signals_must_be_called_estimated():
    bad = answer(interpretation=["Your respiratory rate was 14.2 breaths per minute, similar to before."])
    assert "estimated" in validate.check(bad, EVIDENCE, RETRIEVED).codes
    good = answer(interpretation=["Your estimated respiratory rate was 14.2 breaths per minute.", SUPPORT])
    assert validate.check(good, EVIDENCE, RETRIEVED).ok
    sleep = answer(interpretation=["You slept less on Oct 5, which may matter."])
    assert "estimated" in validate.check(sleep, EVIDENCE, RETRIEVED).codes
    general = answer(interpretation=["Changes of a few bpm may reflect sleep timing.", SUPPORT])
    assert validate.check(general, EVIDENCE, RETRIEVED).ok


def test_citations_must_be_retrieved_and_stay_out_of_the_text():
    assert "citations" in validate.check(answer(citations=["pmid:99999999"]), EVIDENCE, RETRIEVED).codes
    inline = answer(interpretation=["Studies (PMID 32023264) report wide personal ranges."])
    assert "citations" in validate.check(inline, EVIDENCE, RETRIEVED).codes


def test_shape_and_length():
    assert validate.check("Sure! Here is what I found.", EVIDENCE, RETRIEVED).codes == ["shape"]
    assert "shape" in validate.check(answer(observed=[]), EVIDENCE, RETRIEVED).codes
    assert "shape" in validate.check(answer(headline="x" * 121), EVIDENCE, RETRIEVED).codes
    assert "shape" in validate.check(answer(uncertainty="one string"), EVIDENCE, RETRIEVED).codes


def test_literature_is_curated_first_and_excludes_topics_the_app_never_infers():
    library = Literature()
    hits = library.search("resting heart rate alcohol sleep", "resting_hr", limit=3)
    assert hits and all(h["id"].startswith("lit:") and h["url"].startswith("https://pubmed") for h in hits)
    assert len({h["id"] for h in hits}) == len(hits)
    # wording the app never uses is refused as a query, and excluded topics are never returned
    try:
        library.search("resting heart rate acute illness infection fever", "resting_hr", limit=5)
    except ValueError as exc:
        assert "forbidden_term" in str(exc)
    else:
        raise AssertionError("an illness query was accepted")
    vaccination = library.search("resting heart rate vaccination vaccine dose", "resting_hr", limit=5)
    assert not any("vaccin" in (h.get("title") or "").lower() for h in vaccination)
    try:
        library.search("my resting heart rate was 45 on 2026-10-06", "resting_hr")
    except ValueError as exc:
        assert "rejected" in str(exc)
    else:  # a personal-looking query is refused even though the corpus is local
        raise AssertionError("personal query accepted")


def test_a_citation_must_be_about_something_the_explanation_says():
    retrieved = {"pmid:1": {"id": "pmid:1", "topic": "menstrual_cycle", "finding": "", "peer_reviewed": True},
                 "pmid:2": {"id": "pmid:2", "topic": "alcohol", "finding": "", "peer_reviewed": True}}
    text = answer(interpretation=["Alcohol can raise heart rate in the hours after drinking."], citations=["pmid:2"])
    assert validate.check(text, EVIDENCE, retrieved).ok
    off_topic = answer(interpretation=["Alcohol can raise heart rate in the hours after drinking."], citations=["pmid:1"])
    assert "citations" in validate.check(off_topic, EVIDENCE, retrieved).codes
    absent = answer(interpretation=["No alcohol was recorded, and nights vary."], citations=["pmid:2"])
    assert "citations" in validate.check(absent, EVIDENCE, retrieved).codes  # research about what did not happen


# The independent review's bypasses, on evidence shaped like the real-model smoke run (latest 59 bpm on Oct 6,
# 58 on Oct 5, median 52, usual range 51-53).
REVIEW = {
    "get_metric_summary": {"metric": "resting_hr", "units": "bpm", "estimated": False,
                           "latest": {"day": "2026-10-06", "value": 59}, "previous": {"day": "2026-10-05", "value": 58, "change": 1},
                           "baseline": {"usual": "long", "usual_value": 52, "usual_low": 51, "usual_high": 53,
                                        "change_vs_usual": 7,
                                        "long": {"center": 52, "low": 51, "high": 53, "nights": 30, "shown": True}}},
    "get_metric_series": {"units": "bpm", "nights": [{"day": "2026-10-04", "value": 58}, {"day": "2026-10-05", "value": 58},
                                                     {"day": "2026-10-06", "value": 59}]},
    "get_data_quality": {"measured_nights": 38, "missing_nights": 2, "tracked_nights": 40},
    "get_sleep_context": {"nights": [{"day": "2026-10-06", "duration_h": 6.2, "efficiency_pct": 90,
                                      "onset_local": "23:40", "wake_local": "06:12"}], "estimated": True},
    "get_related_metrics": {"signals": [{"metric": "hrv_rmssd", "units": "ms", "estimated": True,
                                         "latest": {"day": "2026-10-06", "value": 85}, "usual": 69, "change_vs_usual": 16}]},
}


REVIEW_LIT = {"lit:rhr-variability": {"id": "lit:rhr-variability", "topic": "day_to_day_variability",
                                     "peer_reviewed": True, "finding": ""}}


def review(**over):
    base = {"headline": "Resting heart rate 59 bpm on Oct 6, above your usual range",
            "observed": ["Your resting heart rate was 59 bpm on Oct 6, 7 bpm above your median of 52 bpm."],
            "interpretation": [SUPPORT], "uncertainty": ["Two tracked nights have no measurement."],
            "citations": ["lit:rhr-variability"]}
    base.update(over)
    return json.dumps(base)


def test_the_review_bypasses_are_closed():
    assert validate.check(review(), REVIEW, REVIEW_LIT).ok, validate.check(review(), REVIEW, REVIEW_LIT).errors
    rejected = {
        "Your resting heart rate was 51 bpm on Oct 6, 7 bpm below your median of 58 bpm.": "grounding",
        "It fell 6 bpm to 53 bpm.": "direction",
        "It was 7 bpm below your median.": "direction",
        "Your resting heart rate was 0 bpm on Oct 5.": "grounding",
        "Your resting heart rate was 75bpm on Oct 6.": "grounding",
        "Your estimated bedtime was 3:17.": "grounding",
        "Your estimated sleep was 6 bpm.": "grounding",
        "Twelve nights were missing.": "grounding",
        "It rose because your training was harder.": "claim",
        "This can be a side effect of travel.": "wording",
        "Stresses can raise resting heart rate.": "wording",
        "Illnesses and infections can raise it.": "wording",
        "Str​ess can raise it.": "text",
        "Strеss can raise it.": "text",
        "It was higher two days ago.": "dates",
        "It was higher on Monday.": "dates",
        "Your HRV was 85 ms on Oct 6.": "estimated",
        "Your sleep was short on Oct 6.": "estimated",
        "It was 59 bpm on 10/6.": "dates",
    }
    for sentence, code in rejected.items():
        result = validate.check(review(observed=[sentence]), REVIEW, REVIEW_LIT)
        assert code in result.codes, (sentence, result.errors)
    # and what must still pass
    for sentence in ("A change of 1 may be ordinary variation.", "Your estimated sleep was 6.2 h on Oct 6.",
                     "Your estimated bedtime was 23:40 on Oct 6.", "It was 1 bpm above Oct 5 and 59 bpm on Oct 6.",
                     "Your estimated HRV was 85 ms on Oct 6, 16 ms above your median of 69 ms.",
                     "Your resting heart rate stayed within 51-53 bpm over most of the last 30 nights."):
        result = validate.check(review(observed=[sentence]), REVIEW, REVIEW_LIT)
        assert result.ok, (sentence, result.errors)


def test_every_explanation_cites_a_peer_reviewed_source():
    assert "citations" in validate.check(answer(citations=[]), EVIDENCE, RETRIEVED).codes
    preprint = {"pmid:32023264": dict(RETRIEVED["pmid:32023264"], peer_reviewed=False)}
    result = validate.check(answer(), EVIDENCE, preprint)
    assert any("not a peer-reviewed" in e for e in result.errors)


def test_because_is_allowed_when_it_is_hedged_and_grounded():
    hedged = answer(interpretation=["Your resting heart rate was likely lower because nights like Oct 5 vary.", SUPPORT])
    assert validate.check(hedged, EVIDENCE, RETRIEVED).ok, validate.check(hedged, EVIDENCE, RETRIEVED).errors
    certain = answer(interpretation=["Your resting heart rate was lower because nights vary.", SUPPORT])
    assert "claim" in validate.check(certain, EVIDENCE, RETRIEVED).codes


def test_the_root_agent_must_have_loaded_every_required_variable():
    required = frozenset({"get_metric_summary", "get_chat_history", "get_health_records"})
    result = validate.check(answer(), EVIDENCE, RETRIEVED, called={"get_metric_summary"}, required=required)
    assert any(e.startswith("context:load these first: get_chat_history, get_health_records") for e in result.errors)
    assert validate.check(answer(), EVIDENCE, RETRIEVED, called=set(required), required=required).ok


def test_sentences_a_real_model_wrote_that_are_correct_are_accepted():
    evidence = {
        "get_metric_summary": {"metric": "hrv_rmssd", "units": "ms", "latest": {"day": "2026-10-06", "value": 51},
                               "previous": {"day": "2026-10-05", "value": 66, "change": -15},
                               "baseline": {"usual": "long", "usual_value": 66, "usual_low": 58, "usual_high": 74,
                                            "change_vs_usual": -15,
                                            "long": {"center": 66, "low": 58, "high": 74, "nights": 31, "shown": True}}},
        "get_state_breakdown": {"night": "2026-10-06", "states": [
            {"state": "sleep", "units": "ms", "value": 51, "usual": {"center": 66, "low": 58, "high": 74, "nights": 31}}]},
    }
    lit = {"lit:hrv-evening-exercise": {"id": "lit:hrv-evening-exercise", "topic": "training_load",
                                        "peer_reviewed": True, "finding": ""}}
    text = json.dumps({
        "headline": "Your HRV was lower than usual during sleep on Oct 6",
        "observed": ["The 51 ms during sleep was below your usual sleep band of 58-74 ms."],
        "interpretation": ["A late training session can likely keep HRV lower that night."],
        "uncertainty": ["One night says little on its own."], "citations": ["lit:hrv-evening-exercise"]})
    result = validate.check(text, evidence, lit)
    assert result.ok, result.errors
    # and the size of a change still has to match: 15 lower, not 15 higher
    flipped = text.replace("The 51 ms during sleep was below your usual sleep band of 58-74 ms.",
                           "It was 15 ms higher than your usual.")
    assert "direction" in validate.check(flipped, evidence, lit).codes


def test_the_usual_range_wording_follows_the_apps_call():
    evidence = json.loads(json.dumps(EVIDENCE))
    evidence["get_metric_summary"]["baseline"].update(
        usual_low=46, usual_high=54, call={"state": "off", "side": "below", "low": 46, "high": 54,
                                           "outside": ["this_week"], "shown_usual": "this_week"})
    evidence["get_related_metrics"]["night_vitals"] = {"night": "2026-10-06", "vitals": [
        {"vital": "sleep_hrv_ln", "units": "ms", "value": 85, "state": "in_range", "usual_low": 60, "usual_high": 90,
         "side": None, "estimated": False},
        {"vital": "sleep_resp", "units": "breaths/min", "value": 14.2, "state": "learning", "usual_low": None,
         "usual_high": None, "side": None, "estimated": True}]}
    agrees = answer(observed=["Your resting heart rate was 45 bpm on Oct 6, below your usual range of 46-54 bpm.",
                              "Your HRV stayed within its usual range."])
    result = validate.check(agrees, evidence, RETRIEVED)
    assert result.ok, result.errors
    contradictions = {
        "Your resting heart rate was 45 bpm on Oct 6, within your usual range.": "Off usual",
        "Your resting heart rate was 45 bpm on Oct 6, above your usual range.": "below its usual range, not above",
        "Your resting heart rate was 45 bpm on Oct 6, and your HRV was outside its usual range.": "hrv_rmssd In range",
        "Your estimated respiratory rate was inside its usual range on Oct 6.": "Learning",
    }
    for sentence, reason in contradictions.items():
        result = validate.check(answer(observed=[sentence]), evidence, RETRIEVED)
        assert not result.ok and "usual" in result.codes and any(reason in e for e in result.errors), result.errors
    # Negated, it agrees: "not within your usual range" is the app's "Off usual".
    negated = answer(observed=["Your resting heart rate of 45 bpm on Oct 6 was not within your usual range."])
    assert validate.check(negated, evidence, RETRIEVED).ok
    # While the app is still learning, saying so is right (sentences a real model wrote, curly apostrophe included).
    evidence["get_metric_summary"]["baseline"]["call"] = {"state": "learning", "side": None, "low": None, "high": None,
                                                          "outside": [], "shown_usual": None}
    for sentence in ("Nara is still learning your usual, so it can’t yet say whether this is within your usual range.",
                     "Nara is still learning your usual, so it has not called this reading in or outside your usual "
                     "range."):
        result = validate.check(answer(observed=[sentence]), evidence, RETRIEVED)
        assert result.ok, (sentence, result.errors)
    claimed = answer(observed=["Your resting heart rate stayed within your usual range."])
    assert "usual" in validate.check(claimed, evidence, RETRIEVED).codes


def test_checks_read_each_sentence_and_each_clause():
    # A value after a sentence that named Oct 5 belongs to its own sentence, not to Oct 5.
    two = answer(observed=["Your resting heart rate was 48 bpm on Oct 5. Your usual is 51 bpm."])
    result = validate.check(two, EVIDENCE, RETRIEVED)
    assert result.ok, result.errors
    one = answer(observed=["On Oct 5 your resting heart rate was 51 bpm."])
    assert "grounding" in validate.check(one, EVIDENCE, RETRIEVED).codes
    # A hedge in one clause ("this does not show ...") does not void the pattern the sentence names (a real model's
    # sentence); "no alcohol was recorded" still cannot be a reason to cite alcohol research.
    retrieved = dict(RETRIEVED, **{"lit:x": {"id": "lit:x", "topic": "training_load", "peer_reviewed": True,
                                             "finding": "late exercise and overnight HRV"}})
    hedged = answer(interpretation=["Your evening walking and cycling may be relevant; evening exercise can be "
                                    "associated with lower overnight HRV, though this does not show what explains "
                                    "your reading."], citations=["lit:x"])
    result = validate.check(hedged, EVIDENCE, retrieved)
    assert result.ok, result.errors
    absent = answer(interpretation=["No exercise was recorded that evening."], citations=["lit:x"])
    assert "citations" in validate.check(absent, EVIDENCE, retrieved).codes
