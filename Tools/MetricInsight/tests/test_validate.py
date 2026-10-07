import json
import re
from pathlib import Path

from nara_metric_insight import validate
from nara_metric_insight.literature import Literature

SWIFT = Path(__file__).resolve().parents[3] / "Strand" / "Screens" / "MeasurementContextWording.swift"

EVIDENCE = {
    "get_metric_summary": {"latest": {"day": "2026-10-06", "value": 45}, "previous": {"day": "2026-10-05", "value": 48, "change": -3},
                           "baseline": {"nights": 6, "median": 51, "change_vs_median": -6},
                           "assessment": {"basis": "insufficient_history", "nights_available": 6, "nights_needed": 7}},
    "get_data_quality": {"measured_nights": 7, "missing_nights": 83, "window_nights": 90},
    "get_related_metrics": {"signals": [{"metric": "hrv_rmssd", "estimated": False, "latest": {"day": "2026-10-06", "value": 85}},
                                        {"metric": "resp_rate", "estimated": True, "latest": {"day": "2026-10-06", "value": 14.2}}]},
}
RETRIEVED = {"pmid:32023264": {"id": "pmid:32023264", "finding": "mean daily RHR was 65 bpm"}}


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
    assert validate.check(answer(interpretation=["It is still within a few bpm of Oct 5."]), EVIDENCE, RETRIEVED).ok
    assert validate.forbidden_term("Still calm") == "calm"


def test_numbers_and_dates_must_come_from_the_tools():
    result = validate.check(answer(observed=["Your resting heart rate was 44 bpm on Oct 6."]), EVIDENCE, RETRIEVED)
    assert "grounding" in result.codes
    result = validate.check(answer(observed=["Your average was 47.3 bpm."]), EVIDENCE, RETRIEVED)
    assert "grounding" in result.codes  # an average the model computed itself
    result = validate.check(answer(observed=["Your resting heart rate was 45 bpm on Oct 9."]), EVIDENCE, RETRIEVED)
    assert "dates" in result.codes
    # magnitudes of signed changes, window lengths and retrieved findings are allowed
    ok = answer(observed=["It was 6 bpm below your median of 51 bpm over the last 7 nights; a large study saw a mean of 65 bpm."])
    assert validate.check(ok, EVIDENCE, RETRIEVED).ok


def test_estimated_signals_must_be_called_estimated():
    bad = answer(interpretation=["Your respiratory rate was 14.2 breaths per minute, similar to before."])
    assert "estimated" in validate.check(bad, EVIDENCE, RETRIEVED).codes
    good = answer(interpretation=["Your estimated respiratory rate was 14.2 breaths per minute."])
    assert validate.check(good, EVIDENCE, RETRIEVED).ok
    sleep = answer(interpretation=["You slept less on Oct 5, which may matter."])
    assert "estimated" in validate.check(sleep, EVIDENCE, RETRIEVED).codes
    general = answer(interpretation=["Changes of a few bpm may reflect sleep timing."])
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
    retrieved = {"pmid:1": {"id": "pmid:1", "topic": "menstrual_cycle", "finding": ""},
                 "pmid:2": {"id": "pmid:2", "topic": "alcohol", "finding": ""}}
    text = answer(interpretation=["Alcohol can raise heart rate in the hours after drinking."], citations=["pmid:2"])
    assert validate.check(text, EVIDENCE, retrieved).ok
    off_topic = answer(interpretation=["Alcohol can raise heart rate in the hours after drinking."], citations=["pmid:1"])
    assert "citations" in validate.check(off_topic, EVIDENCE, retrieved).codes
    absent = answer(interpretation=["No alcohol was recorded, and nights vary."], citations=["pmid:2"])
    assert "citations" in validate.check(absent, EVIDENCE, retrieved).codes  # research about what did not happen
