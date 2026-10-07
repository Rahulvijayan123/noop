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
from .validate import FORBIDDEN_TERMS

CORPUS = Path(__file__).resolve().parent / "data" / "literature_seed.json"
EXCLUDED_TOPICS = frozenset({"acute_illness", "vaccination", "psychological_stress", "medication", "long_term_risk"})
CORPUS_METRIC = {"resting_hr": "rhr", "hrv_rmssd": "hrv"}
MIN_LOCAL_SCORE = 1.0  # BM25: below this a hit shares little more than "heart rate" with the query


class Literature:
    def __init__(self, remote: tuple[str, ...] = (), cache_path: str | None = None) -> None:
        self.remote = remote
        self.cache = litsearch.LitCache(cache_path) if (remote and cache_path) else None

    def search(self, query: str, metric: str, limit: int = 3) -> list[dict[str, Any]]:
        try:
            safe = litsearch.sanitize_query(query, forbidden_terms=FORBIDDEN_TERMS)
            if self.remote:  # curated first; remote only when no curated hit is strong (litsearch's cutoffs)
                records = litsearch.find_evidence(safe, k=max(limit * 2, 5), metric=CORPUS_METRIC.get(metric),
                                                  remote=self.remote, corpus_path=CORPUS, cache=self.cache,
                                                  forbidden_terms=FORBIDDEN_TERMS).get("evidence") or []
            else:  # curated only: the ranked hits themselves (litsearch's cutoffs exist to decide on going remote)
                records = [r for r in litsearch.search_seed(safe, k=max(limit * 2, 5), metric=CORPUS_METRIC.get(metric),
                                                            corpus_path=CORPUS) if r["score"] >= MIN_LOCAL_SCORE]
        except litsearch.UnsafeQueryError as exc:
            raise ValueError(f"query rejected: {exc.code}") from None
        out, seen = [], set()
        for record in records:
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
