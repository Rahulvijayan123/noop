"""Literature retrieval for explanations: the curated, PubMed-verified corpus first; PubMed / Europe PMC only as
an opt-in fallback (NARA_LITERATURE_REMOTE), run by this worker (never by model code), with queries sanitized by
litsearch.sanitize_query so nothing personal can leave, and cached by the sanitized query (shared, user-free).

Topics the app never infers in its copy (MeasurementContextWording.forbiddenTerms: illness, stress, medication
effects) and background-only entries are not offered as explanations of a day-to-day change.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import litsearch
from .validate import FORBIDDEN_TERMS, TOPIC_WORDS, forbidden_term

CORPUS = Path(__file__).resolve().parent / "data" / "literature_seed.json"
EXCLUDED_TOPICS = frozenset({"acute_illness", "vaccination", "psychological_stress", "medication", "long_term_risk"})
CORPUS_METRIC = {"resting_hr": "rhr", "hrv_rmssd": "hrv"}
# Words every query shares ("resting heart rate"): they rank nothing, so a hit must match the query's topic words.
GENERIC = frozenset(litsearch.tokenize("resting rest heart rate hrv rmssd person people wearable value values "
                                       "level levels"))
MIN_TOPIC_COVERAGE = 0.5   # share of the topic words' idf the entry matches
MIN_RELATIVE_SCORE = 0.5   # and at least half the best hit's BM25 score


def infer_topic(text: str) -> str | None:
    """A remote record's topic from its own words, when exactly one curated topic fits (else none: not citable)."""
    lowered = text.lower()
    fits = [topic for topic, words in TOPIC_WORDS.items() if any(word in lowered for word in words)]
    return fits[0] if len(fits) == 1 else None


class Literature:
    def __init__(self, remote: tuple[str, ...] = (), cache_path: str | None = None) -> None:
        self.remote = remote
        self.cache = litsearch.LitCache(cache_path) if (remote and cache_path) else None

    @staticmethod
    def _curated(query: str, metric: str, k: int) -> list[dict[str, Any]]:
        """Curated hits that match the query's topic, not just its generic words (litsearch's own cutoffs decide
        whether to go remote; locally they would drop sound short queries such as "resting heart rate sleep")."""
        entries, index = litsearch._seed_index(CORPUS)
        vocabulary = {t for e in entries for t in litsearch._entry_tokens(e)}
        topic = [t for t in litsearch.tokenize(query) if t not in GENERIC]
        if not topic:
            raise ValueError("query rejected: name a topic (e.g. sleep, alcohol, training load, heat)")
        topic = [t for t in topic if t in vocabulary]  # a word no entry uses cannot count against a hit
        if not topic:
            return []
        by_id = {e["id"]: i for i, e in enumerate(entries)}
        hits = litsearch.search_seed(query, k=max(k, 10), metric=CORPUS_METRIC.get(metric), corpus_path=CORPUS)
        top = hits[0]["score"] if hits else 0.0
        return [h for h in hits if h["score"] >= MIN_RELATIVE_SCORE * top
                and index.coverage(topic, by_id[h["id"]]) >= MIN_TOPIC_COVERAGE]

    def search(self, query: str, metric: str, limit: int = 3) -> list[dict[str, Any]]:
        try:
            safe = litsearch.sanitize_query(query, forbidden_terms=FORBIDDEN_TERMS)
            if self.remote:  # curated first; remote only when no curated hit is strong (litsearch's cutoffs)
                records = litsearch.find_evidence(safe, k=max(limit * 2, 5), metric=CORPUS_METRIC.get(metric),
                                                  remote=self.remote, corpus_path=CORPUS, cache=self.cache,
                                                  forbidden_terms=FORBIDDEN_TERMS).get("evidence") or []
            else:
                records = self._curated(safe, metric, max(limit * 2, 5))
        except litsearch.UnsafeQueryError as exc:
            raise ValueError(f"query rejected: {exc.code}") from None
        out, seen = [], set()
        for record in records:
            if record.get("source") != "seed":  # remote records: no curated topic, unvetted wording
                text = f"{record.get('title') or ''} {record.get('abstract_snippet') or ''}"
                if forbidden_term(text):
                    continue
                record = dict(record, topic=infer_topic(text))
            if record.get("context_only") or record.get("topic") in EXCLUDED_TOPICS:
                continue
            # A curated entry is one claim (several can come from one paper): cite the claim, not just the paper.
            ident = (f"lit:{record['id']}" if record.get("source") == "seed"
                     else f"pmid:{record['pmid']}" if record.get("pmid") else f"doi:{record.get('doi')}")
            if ident in seen:
                continue
            seen.add(ident)
            out.append({
                "id": ident,
                "title": record.get("title"), "year": record.get("year"), "journal": record.get("journal"),
                "url": record.get("url"), "finding": record.get("claim") or record.get("abstract_snippet"),
                "direction": record.get("direction"), "evidence_type": record.get("evidence_type"),
                "topic": record.get("topic"), "source": record.get("source"),
            })
            if len(out) >= limit:
                break
        return out
