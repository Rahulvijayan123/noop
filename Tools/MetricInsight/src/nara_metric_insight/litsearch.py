#!/usr/bin/env python3
# Vendored from the metric-explain literature design work (litsearch.py + its PubMed-verified seed, here
# data/literature_seed.json). The worker always passes corpus_path and cache explicitly (literature.py).
"""litsearch: small, privacy-safe literature retrieval for the metric-explain agent.

Retrieval order, cheapest and most trustworthy first:

  1. Local curated corpus (rhr_evidence_seed.json), ranked with BM25. No network.
  2. PubMed via NCBI E-utilities: esearch -> esummary (+ optional efetch abstracts).
  3. Europe PMC REST search: alternative to, or fallback for, 2 (MEDLINE records only).

General web search is deliberately not implemented.

Privacy: every query that could leave the process goes through sanitize_query(),
which *rejects* (never silently strips) anything that looks like personal data:
standalone numbers, dates, times, e-mails, URLs, identifiers, personal pronouns,
user-relative time words, and caller-supplied forbidden terms. Only generic
scientific keyword queries pass. The sanitized query is also the cache key, so
cache rows never hold user data and one cache can be shared by all users.

Citations: remote records are built only from the esummary (PubMed) or Europe
PMC response; nothing is synthesized. unverified_citations() lets the caller
check that every PMID/DOI in generated text was actually retrieved.

Stdlib only. Python 3.11+.
CLI: python3 litsearch.py {local,pubmed,europepmc,search,sanitize,verify-seed} ...
"""
from __future__ import annotations

import argparse
import hashlib
import html
import http.client
import json
import math
import os
import re
import socket
import sqlite3
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

# ---------------------------------------------------------------------------
# Configuration and hard caps
# ---------------------------------------------------------------------------
HERE = Path(__file__).resolve().parent
DEFAULT_CORPUS = HERE / "data" / "literature_seed.json"
DEFAULT_CACHE_PATH = HERE / ".cache" / "litsearch.sqlite3"  # override with LITSEARCH_CACHE

TOOL_NAME = "nara_litsearch"
USER_AGENT = "nara_litsearch/0.1 (metric-explain prototype)"
EUTILS_BASE = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
EPMC_SEARCH_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
PUBMED_URL = "https://pubmed.ncbi.nlm.nih.gov/{pmid}/"

MAX_QUERY_CHARS = 200
MAX_QUERY_TERMS = 12
MAX_RESULTS = 10             # k is clamped to this; remote searches fetch this many, then slice
HTTP_TIMEOUT_S = 5.0         # per HTTP request (also bounded by the remaining budget)
TOTAL_BUDGET_S = 8.0         # per search call, or per find_evidence() call
MIN_EFETCH_BUDGET_S = 2.0    # skip abstracts if less budget than this remains
MAX_RESPONSE_BYTES = 2_000_000
SNIPPET_CHARS = 500

NCBI_INTERVAL_NO_KEY_S = 0.35    # NCBI policy: <= 3 requests/s without an API key
NCBI_INTERVAL_WITH_KEY_S = 0.11  # <= 10 requests/s with a key
EPMC_INTERVAL_S = 0.2            # EMBL-EBI publishes no number; stay polite

PARAMS_VERSION = "1"         # bump when query construction/parsing changes (invalidates cache)
CACHE_TTL_S = 30 * 86400
CACHE_EMPTY_TTL_S = 1 * 86400

LOCAL_MIN_SCORE = 3.0        # find_evidence(): if no seed hit reaches this BM25 score, go remote
LOCAL_REL_MIN = 0.5          # ...and keep only seed hits scoring >= this fraction of the top hit
LOCAL_MIN_COVERAGE = 0.5     # ...that match >= this share of the query's idf-weighted terms


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------
class LitSearchError(RuntimeError):
    """Remote search failed: transport error, HTTP error, API error body, bad payload."""


class LitSearchTimeout(LitSearchError):
    """Latency budget exhausted or network timeout."""


class LitSearchRateLimited(LitSearchError):
    """HTTP 429 that could not be retried within the budget."""


class UnsafeQueryError(ValueError):
    """Query rejected by sanitize_query(). `.code` is a short machine-readable reason.

    The message names the rule only; it never echoes the query text, so the
    rejection itself cannot leak user data into logs."""

    def __init__(self, code: str, message: str):
        super().__init__(f"query rejected ({code}): {message}")
        self.code = code


# ---------------------------------------------------------------------------
# Query sanitizer (privacy gate)
# ---------------------------------------------------------------------------
_ROMAN_CONTEXT = frozenset({"type", "phase", "stage", "grade", "class"})
_NUMBER_CONTEXT = _ROMAN_CONTEXT | {"covid"}
_PRONOUNS = frozenset(
    "i me my mine myself we us our ours ourselves you your yours yourself yourselves "
    "he him his himself she her hers herself im ive".split())
_ACRONYMS_OK = frozenset({"US", "ME"})  # United States; myalgic encephalomyelitis
_BOOL_OPS = frozenset({"AND", "OR", "NOT"})
_QUOTE_MAP = str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"'})

_MONTH = (r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|"
          r"sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)")
_PATTERN_RULES: tuple[tuple[re.Pattern[str], str, str], ...] = (
    (re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+"), "email", "looks like an e-mail address"),
    (re.compile(r"@"), "handle", "'@' is not allowed"),
    (re.compile(r"[a-z][a-z0-9+.-]*://|\bwww\.|\b[a-z0-9-]{2,}\.(?:com|org|net|edu|gov|io|ai|app|co|"
                r"me|us|uk|de|info|health|dev|ly)\b", re.I), "url", "looks like a URL or domain name"),
    (re.compile(r"#"), "hash", "'#' is not allowed"),
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I),
     "identifier", "looks like an identifier (UUID)"),
    (re.compile(r"\b\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\b"), "date", "looks like a date"),
    (re.compile(r"\b\d{1,2}[-/]\d{1,2}(?:[-/]\d{2,4})?\b"), "date", "looks like a date"),
    (re.compile(r"\b\d{1,2}\.\d{1,2}\.\d{2,4}\b"), "date", "looks like a date"),
    (re.compile(rf"\b{_MONTH}\.?\s*\d{{1,4}}(?:st|nd|rd|th)?\b", re.I), "date", "looks like a date"),
    (re.compile(rf"\b\d{{1,2}}(?:st|nd|rd|th)?\s*(?:of\s+)?{_MONTH}\b", re.I), "date", "looks like a date"),
    (re.compile(r"\b(?:19|20)\d{2}s?\b"), "date", "looks like a year"),
    (re.compile(r"\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(?:am|pm|a\.m\.|p\.m\.)(?![a-z])", re.I),
     "time", "looks like a time of day"),
    (re.compile(r"\+?\d[\d\s().-]{6,}\d"), "number", "long digit sequence (phone/account/record number)"),
    (re.compile(r"\d[.,]\d"), "number", "decimal or digit-grouped numbers look like measurements"),
    (re.compile(r"\b(?:yesterday|today|tonight|tomorrow|lately|ago|"
                r"(?:mon|tues|wednes|thurs|fri|satur|sun)days?|"
                r"(?:last|this|past|next)\s+(?:night|morning|afternoon|evening|week|weekend|month|year|"
                r"few\s+(?:days|nights|weeks)|couple\s+of\s+(?:days|nights|weeks)))\b", re.I),
     "relative_time", "refers to a time relative to the user (today, last night, ...)"),
    (re.compile(r"\b(?:uuid|guid|userid|username|e-?mail|phone|telephone|address|dob|birthday|birthdate|"
                r"date\s+of\s+birth|ssn|social\s+security|mrn|medical\s+record|passport|zip\s*code|"
                r"post\s*code|serial|account|(?:user|patient|member|customer|device|strap|subject|"
                r"participant)[\s-]*(?:id|ids|no|number))\b", re.I),
     "id_field", "mentions a personal identifier field"),
    (re.compile(r"[=<>{}\[\]\\|`~^&*_$%]"), "punctuation", "disallowed punctuation"),
)
_HEXISH_RE = re.compile(r"(?=[0-9a-f]*\d)[0-9a-f]{8,}")
_MEASURE_RE = re.compile(
    r"(?:r?hr|hrv|bp|bpm|rmssd|sdnn|temp|age|wt|kg|lbs?|bmi|sleep|steps?|day|night|week|wk|month|yr|year)-?\d+")


def _check_patterns(s: str) -> None:
    for rx, code, msg in _PATTERN_RULES:
        if rx.search(s):
            raise UnsafeQueryError(code, msg)


def _check_digit_token(core: str, prev_low: str) -> None:
    """Digits are allowed only inside names (covid-19, spo2, il-6, h1n1, sars-cov-2,
    hba1c, vo2max) or as 1-2 digits after type/phase/stage/grade/class/covid."""
    low = core.lower()
    if low[0].isdigit():
        if core.isdigit() and len(core) <= 2 and prev_low in _NUMBER_CONTEXT:
            return  # "type 2 diabetes", "covid 19"
        raise UnsafeQueryError("number", "standalone numbers and number+unit values "
                                         "(ages, measurements, counts) are not allowed")
    if sum(ch.isdigit() for ch in core) >= 3 or _HEXISH_RE.fullmatch(low):
        raise UnsafeQueryError("identifier", "token looks like an identifier")
    if _MEASURE_RE.fullmatch(low):
        raise UnsafeQueryError("number", "metric name followed by a value")


def sanitize_query(query: object, *, forbidden_terms: Iterable[str] = ()) -> str:
    """Validate a literature query and return its normalized form.

    Rejects (raises UnsafeQueryError) instead of stripping, so a query that carried
    user data is never "repaired" and sent anyway. Normalization: NFKC, whitespace
    collapsed, lower-cased except AND/OR/NOT and the acronyms US/ME, harmless
    punctuation (? ! , ; : / + .) turned into spaces, possessive 's dropped.
    Idempotent: sanitize_query(sanitize_query(q)) == sanitize_query(q).
    `forbidden_terms`: user-specific strings the server knows (name, device label,
    city, ...); any whole-word occurrence rejects the query.
    """
    if not isinstance(query, str):
        raise UnsafeQueryError("type", "query must be a string")
    s = unicodedata.normalize("NFKC", query).translate(_QUOTE_MAP)
    if any(unicodedata.category(ch)[0] == "C" and ch not in "\t\n\r" for ch in s):
        raise UnsafeQueryError("control_chars", "control or invisible characters are not allowed")
    s = " ".join(s.split())
    if not s:
        raise UnsafeQueryError("empty", "query is empty")
    if len(s) > MAX_QUERY_CHARS:
        raise UnsafeQueryError("length", f"query is longer than {MAX_QUERY_CHARS} characters")
    low = s.lower()
    for term in forbidden_terms:
        t = " ".join(unicodedata.normalize("NFKC", str(term)).lower().split())
        if len(t) >= 2 and re.search(rf"(?<!\w){re.escape(t)}(?!\w)", low):
            raise UnsafeQueryError("forbidden_term", "query contains a term marked as user-specific")
    _check_patterns(s)
    s = re.sub(r"'s\b", "", s, flags=re.I).replace("'", " ")
    s = re.sub(r"[?!,;:/+.–—]", " ", s)
    s = re.sub(r"(?<!\w)-+|-+(?!\w)", " ", s)
    _check_patterns(s)  # again, so punctuation removal cannot reveal a new date/time pattern
    if s.count('"') % 2:
        raise UnsafeQueryError("syntax", "unbalanced double quotes")

    out: list[str] = []
    n_terms, has_word, depth = 0, False, 0
    prev_low, prev_was_op = "", True  # an operator may not start the query
    for tok in s.split():
        for ch in tok:
            depth += (ch == "(") - (ch == ")")
            if depth < 0:
                raise UnsafeQueryError("syntax", "unbalanced parentheses")
        core = tok.strip('"()')
        if not core:
            out.append(tok)
            continue
        if not all(ch.isalnum() or ch == "-" for ch in core):
            raise UnsafeQueryError("punctuation", "only letters, digits, inner hyphens, "
                                                  "double quotes and parentheses are allowed")
        if core in _BOOL_OPS:
            if prev_was_op or tok != core:
                raise UnsafeQueryError("syntax", "boolean operator in an invalid position")
            out.append(core)
            prev_was_op = True
            continue
        low = core.lower()
        if (low in _PRONOUNS and core not in _ACRONYMS_OK
                and not (low == "i" and prev_low in _ROMAN_CONTEXT)):
            raise UnsafeQueryError("pronoun", "personal pronouns suggest user-specific content")
        if any(ch.isdigit() for ch in core):
            _check_digit_token(core, prev_low)
        n_terms += 1
        has_word = has_word or sum(ch.isalpha() for ch in core) >= 2
        out.append(tok if core in _ACRONYMS_OK else tok.lower())
        prev_low, prev_was_op = low, False
    if depth:
        raise UnsafeQueryError("syntax", "unbalanced parentheses")
    if not has_word:
        raise UnsafeQueryError("empty", "no searchable words")
    if n_terms > MAX_QUERY_TERMS:
        raise UnsafeQueryError("terms", f"more than {MAX_QUERY_TERMS} terms")
    if prev_was_op:
        raise UnsafeQueryError("syntax", "query ends with a boolean operator")
    return " ".join(out)


# ---------------------------------------------------------------------------
# Local curated corpus: tokenizer + BM25
# ---------------------------------------------------------------------------
_STOPWORDS = frozenset("""
a about an and are as at be been being but by can could did do does during each for from had has
have how if in into is it its may might of on or per should so than that the their them then there
these they this those to was were what when where which while who why will with within without would
vs versus via not no
""".split())
_WORD_RE = re.compile(r"[^\W_]+")


def _stem(w: str) -> str:
    """Tiny suffix stripper; applied identically to queries and documents."""
    if len(w) <= 3 or w.isdigit():
        return w
    if w.endswith("ies") and len(w) > 4:
        w = w[:-3] + "y"
    elif w.endswith("sses"):
        w = w[:-2]
    elif w.endswith("s") and not w.endswith(("ss", "us", "is")):
        w = w[:-1]
    # no "-ing" rule: it conflated cycling/cycle and evening/even on the seed corpus
    if w.endswith("ed") and len(w) >= 6:
        w = w[:-2]
    if w.endswith("e") and len(w) >= 5:
        w = w[:-1]
    return w


def tokenize(text: str) -> list[str]:
    words = _WORD_RE.findall(unicodedata.normalize("NFKC", text or "").lower())
    return [_stem(w) for w in words if w not in _STOPWORDS and (len(w) > 1 or w.isdigit())]


class BM25Index:
    """Okapi BM25 over pre-tokenized documents. idf = ln(1 + (N - df + 0.5) / (df + 0.5))."""

    def __init__(self, docs: Sequence[Sequence[str]], *, k1: float = 1.5, b: float = 0.75):
        self.k1, self.b = k1, b
        self.n_docs = len(docs)
        self.tfs = [Counter(d) for d in docs]
        self.lengths = [len(d) for d in docs]
        self.avgdl = sum(self.lengths) / self.n_docs if self.n_docs else 0.0
        df = Counter(t for tf in self.tfs for t in tf)
        self.idf = {t: math.log(1.0 + (self.n_docs - n + 0.5) / (n + 0.5)) for t, n in df.items()}

    def idf_of(self, t: str) -> float:
        """idf, with terms absent from the corpus treated as df = 0 (maximally informative)."""
        return self.idf.get(t, math.log(1.0 + (self.n_docs + 0.5) / 0.5))

    def coverage(self, query_tokens: Iterable[str], i: int) -> float:
        """Share of the query's idf mass that document i matches (0..1)."""
        q = set(query_tokens)
        total = sum(self.idf_of(t) for t in q)
        return sum(self.idf_of(t) for t in q if t in self.tfs[i]) / total if total else 0.0

    def score(self, query_tokens: Iterable[str], i: int) -> float:
        tf, dl = self.tfs[i], self.lengths[i]
        norm = self.k1 * (1.0 - self.b + self.b * dl / self.avgdl) if self.avgdl else self.k1
        total = 0.0
        for t in set(query_tokens):
            f = tf.get(t, 0)
            if f:
                total += self.idf[t] * f * (self.k1 + 1.0) / (f + norm)
        return total

    def search(self, query_tokens: Sequence[str], k: int = 5) -> list[tuple[int, float]]:
        q = set(query_tokens)
        scored = [(i, s) for i in range(self.n_docs) if (s := self.score(q, i)) > 0.0]
        scored.sort(key=lambda x: (-x[1], x[0]))
        return scored[:max(0, k)]


def _as_list(x: Any) -> list:
    return list(x) if isinstance(x, (list, tuple)) else ([] if x is None else [x])


def load_corpus(path: str | os.PathLike | None = None) -> list[dict]:
    """Load seed entries ({"entries": [...]} or a bare list). Entries that are not
    verified or lack a numeric PMID are dropped: only verified records are citable."""
    data = json.loads(Path(path or DEFAULT_CORPUS).read_text(encoding="utf-8"))
    entries = data.get("entries", []) if isinstance(data, dict) else data
    return [e for e in entries
            if e.get("verified") is True and str((e.get("citation") or {}).get("pmid", "")).isdigit()]


def _entry_tokens(e: dict) -> list[str]:
    topic = str(e.get("topic", "")).replace("_", " ")
    keywords = " ".join(_as_list(e.get("keywords")))
    cit = e.get("citation") or {}
    # topic and keywords are repeated as a cheap field boost
    text = " ".join([topic, topic, keywords, keywords, e.get("claim", ""),
                     cit.get("title", ""), e.get("population", "")])
    return tokenize(text)


_INDEX_CACHE: dict[tuple[str, float], tuple[list[dict], BM25Index]] = {}


def _seed_index(path: str | os.PathLike | None) -> tuple[list[dict], BM25Index]:
    p = Path(path or DEFAULT_CORPUS).resolve()
    key = (str(p), p.stat().st_mtime)
    if key not in _INDEX_CACHE:
        entries = load_corpus(p)
        _INDEX_CACHE[key] = (entries, BM25Index([_entry_tokens(e) for e in entries]))
    return _INDEX_CACHE[key]


def _seed_record(e: dict, score: float, coverage: float, rank: int) -> dict:
    c = e["citation"]
    pmid = str(c["pmid"])
    return {
        "source": "seed", "curated": True, "id": e["id"], "rank": rank, "score": round(score, 3),
        "coverage": round(coverage, 3),
        "pmid": pmid, "doi": c.get("doi"), "title": c.get("title"), "journal": c.get("journal"),
        "year": c.get("year"), "first_author": c.get("first_author"),
        "url": PUBMED_URL.format(pmid=pmid), "abstract_snippet": None,
        "claim": e.get("claim"), "direction": e.get("direction"),
        "typical_magnitude": e.get("typical_magnitude"), "evidence_type": e.get("evidence_type"),
        "population": e.get("population"), "topic": e.get("topic"), "metric": _as_list(e.get("metric")),
        "context_only": bool(e.get("context_only")),
    }


def search_seed(query: str, k: int = 5, *, metric: str | Iterable[str] | None = None,
                corpus_path: str | os.PathLike | None = None) -> list[dict]:
    """BM25 top-k over the curated corpus; zero-score entries are never returned.
    Each hit carries `score` (BM25) and `coverage` (share of query idf matched).
    `metric`: a corpus metric tag, or several (an entry with any of them qualifies).
    Local only (nothing leaves the process), so the query is not sanitized here."""
    k = _clamp_k(k)
    entries, index = _seed_index(corpus_path)
    qtok = tokenize(query)
    tags = {metric} if isinstance(metric, str) else set(metric or ())
    out: list[dict] = []
    for i, score in index.search(qtok, k=len(entries)):
        if tags and not tags & set(_as_list(entries[i].get("metric"))):
            continue
        out.append(_seed_record(entries[i], score, index.coverage(qtok, i), len(out) + 1))
        if len(out) >= k:
            break
    return out


# ---------------------------------------------------------------------------
# HTTP: deadline, rate limiting, retries
# ---------------------------------------------------------------------------
_sleep = time.sleep  # indirection so tests can patch it


class Deadline:
    """Overall latency budget shared by all requests of one search."""

    def __init__(self, budget_s: float = TOTAL_BUDGET_S, *, clock: Callable[[], float] = time.monotonic):
        self._clock = clock
        self.expires_at = clock() + budget_s

    def remaining(self) -> float:
        return self.expires_at - self._clock()

    def request_timeout(self, cap: float = HTTP_TIMEOUT_S) -> float:
        left = self.remaining()
        if left <= 0.05:
            raise LitSearchTimeout("latency budget exhausted")
        return min(cap, left)


class _RateLimiter:
    """Minimum spacing between request starts to one host (per process; production
    with several workers needs a shared limiter or an NCBI API key)."""

    def __init__(self, min_interval_s: float):
        self.min_interval_s = min_interval_s
        self._lock = threading.Lock()
        self._next_at = 0.0

    def wait(self, deadline: Deadline, interval_s: float | None = None) -> None:
        gap = self.min_interval_s if interval_s is None else interval_s
        with self._lock:
            delay = self._next_at - time.monotonic()
            if delay > 0:
                if delay >= deadline.remaining():
                    raise LitSearchTimeout("latency budget exhausted while rate limiting")
                _sleep(delay)
            self._next_at = time.monotonic() + gap


NCBI_LIMITER = _RateLimiter(NCBI_INTERVAL_NO_KEY_S)
EPMC_LIMITER = _RateLimiter(EPMC_INTERVAL_S)


def _http_get(url: str, timeout: float) -> tuple[int, dict[str, str], bytes]:
    """One GET -> (status, lower-cased headers, body). Transport failures raise
    LitSearchTimeout / LitSearchError. Messages name the host only: the URL may
    carry an API key, and NCBI 429 bodies echo the client IP."""
    host = urllib.parse.urlsplit(url).hostname or "?"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                               "Accept": "application/json, application/xml;q=0.9"})
    started = time.monotonic()
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        headers = {k.lower(): v for k, v in (e.headers.items() if e.headers else [])}
        e.close()
        return e.code, headers, b""
    except urllib.error.URLError as e:
        if isinstance(e.reason, (TimeoutError, socket.timeout)):
            raise LitSearchTimeout(f"{host}: timed out") from None
        raise LitSearchError(f"{host}: network error ({type(e.reason).__name__})") from None
    except (TimeoutError, socket.timeout):
        raise LitSearchTimeout(f"{host}: timed out") from None
    except (OSError, http.client.HTTPException) as e:
        raise LitSearchError(f"{host}: network error ({type(e).__name__})") from None
    chunks: list[bytes] = []
    size = 0
    with resp:
        status = resp.status
        headers = {k.lower(): v for k, v in resp.headers.items()}
        try:
            while True:
                if time.monotonic() - started > timeout:
                    raise LitSearchTimeout(f"{host}: response took longer than {timeout:.1f}s")
                chunk = resp.read1(65536)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_RESPONSE_BYTES:
                    raise LitSearchError(f"{host}: response larger than {MAX_RESPONSE_BYTES} bytes")
                chunks.append(chunk)
        except (TimeoutError, socket.timeout):
            raise LitSearchTimeout(f"{host}: timed out") from None
        except (OSError, http.client.HTTPException) as e:
            raise LitSearchError(f"{host}: network error ({type(e).__name__})") from None
    return status, headers, b"".join(chunks)


def _retry_after_s(value: str | None, default: float = 1.0) -> float:
    try:
        return max(0.0, float(value)) if value is not None else default
    except ValueError:
        return default  # HTTP-date form: just use the default


def _fetch(url: str, limiter: _RateLimiter, deadline: Deadline, *, interval_s: float, label: str) -> bytes:
    """GET with per-host spacing and at most one retry (429/5xx) if it fits the budget."""
    for attempt in (1, 2):
        limiter.wait(deadline, interval_s)
        status, headers, body = _http_get(url, deadline.request_timeout())
        if status == 200:
            return body
        if status in (429, 500, 502, 503, 504) and attempt == 1:
            delay = _retry_after_s(headers.get("retry-after"))
            if delay + 0.5 < deadline.remaining():
                _sleep(delay)
                continue
        if status == 429:
            raise LitSearchRateLimited(f"{label}: HTTP 429 (rate limited)")
        raise LitSearchError(f"{label}: HTTP {status}")
    raise AssertionError("unreachable")


def _json(body: bytes, label: str) -> Any:
    try:
        return json.loads(body)
    except ValueError:
        raise LitSearchError(f"{label}: malformed JSON response") from None


def _clamp_k(k: int) -> int:
    return max(1, min(int(k), MAX_RESULTS))


# ---------------------------------------------------------------------------
# Cache (sqlite, global scope)
# ---------------------------------------------------------------------------
class LitCache:
    """TTL cache for remote search results. Keys hold no user data: they are a hash
    of source + PARAMS_VERSION + flags + the *sanitized* query. Errors and partial
    results are never stored."""

    def __init__(self, path: str | os.PathLike, *, clock: Callable[[], float] = time.time):
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._clock = clock
        self._lock = threading.Lock()
        self._db = sqlite3.connect(self.path, timeout=2.0, check_same_thread=False)
        with self._lock, self._db:
            self._db.execute("CREATE TABLE IF NOT EXISTS cache (key TEXT PRIMARY KEY, source TEXT NOT NULL,"
                             " query TEXT NOT NULL, created_at REAL NOT NULL, expires_at REAL NOT NULL,"
                             " payload TEXT NOT NULL)")
            self._db.execute("CREATE INDEX IF NOT EXISTS cache_expires ON cache(expires_at)")

    @staticmethod
    def make_key(source: str, normalized_query: str, **flags: Any) -> str:
        blob = json.dumps({"s": source, "v": PARAMS_VERSION, "q": normalized_query, "f": flags},
                          sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(blob.encode("utf-8")).hexdigest()

    def get(self, key: str) -> Any | None:
        with self._lock:
            row = self._db.execute("SELECT payload, expires_at FROM cache WHERE key = ?", (key,)).fetchone()
            if row is None:
                return None
            if row[1] <= self._clock():
                with self._db:
                    self._db.execute("DELETE FROM cache WHERE key = ?", (key,))
                return None
        return json.loads(row[0])

    def put(self, key: str, source: str, query: str, payload: Any, ttl_s: float) -> None:
        now = self._clock()
        with self._lock, self._db:
            self._db.execute("INSERT OR REPLACE INTO cache VALUES (?, ?, ?, ?, ?, ?)",
                             (key, source, query, now, now + ttl_s, json.dumps(payload, ensure_ascii=False)))

    def purge_expired(self) -> int:
        with self._lock, self._db:
            return self._db.execute("DELETE FROM cache WHERE expires_at <= ?", (self._clock(),)).rowcount

    def __len__(self) -> int:
        with self._lock:
            return self._db.execute("SELECT COUNT(*) FROM cache").fetchone()[0]

    def close(self) -> None:
        with self._lock:
            self._db.close()


_DEFAULT = object()
_default_cache: LitCache | None = None
_default_cache_lock = threading.Lock()


def get_default_cache() -> LitCache:
    global _default_cache
    with _default_cache_lock:
        if _default_cache is None:
            _default_cache = LitCache(os.environ.get("LITSEARCH_CACHE") or DEFAULT_CACHE_PATH)
        return _default_cache


def _resolve_cache(cache: Any) -> LitCache | None:
    return get_default_cache() if cache is _DEFAULT else cache


# ---------------------------------------------------------------------------
# Shared record helpers
# ---------------------------------------------------------------------------
def _evidence_type(pub_types: Iterable[str] | None) -> str | None:
    pts = {str(p).lower().replace("-", " ") for p in pub_types or []}
    if not pts:
        return None
    if "meta analysis" in pts:
        return "meta_analysis"
    if "systematic review" in pts:
        return "systematic_review"
    if "randomized controlled trial" in pts:
        return "randomized_controlled_trial"
    if any("review" in p for p in pts):
        return "review"
    if "observational study" in pts:
        return "observational_study"
    return "other"


def _remote_record(source: str, c: dict, rank: int) -> dict:
    pmid = c["pmid"]
    return {
        "source": source, "curated": False, "id": f"pmid:{pmid}", "rank": rank, "score": None,
        "pmid": pmid, "doi": c.get("doi"), "title": c.get("title"), "journal": c.get("journal"),
        "year": c.get("year"), "first_author": c.get("first_author"),
        "pub_types": list(c.get("pub_types") or []), "evidence_type": _evidence_type(c.get("pub_types")),
        "url": PUBMED_URL.format(pmid=pmid), "abstract_snippet": None,
    }


_SENT_SPLIT_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9(\[])")
_CONCLUSION_LABELS = ("RESULT", "CONCLUSION", "FINDING", "INTERPRETATION")


def make_snippet(parts: Sequence[tuple[str, str]] | None, query: str, limit: int = SNIPPET_CHARS) -> str | None:
    """Pick the 2 abstract sentences with the most query-term overlap (small boost for
    RESULTS/CONCLUSIONS), kept in original order, capped at `limit` characters."""
    if not parts:
        return None
    qterms = set(tokenize(query))
    cands: list[tuple[float, int, str]] = []
    for label, text in parts:
        boost = 0.5 if any(lbl in (label or "").upper() for lbl in _CONCLUSION_LABELS) else 0.0
        for sent in _SENT_SPLIT_RE.split(text):
            if sent.strip():
                cands.append((len(qterms & set(tokenize(sent))) + boost, len(cands), sent.strip()))
    if not cands:
        return None
    best = sorted(sorted(cands, key=lambda c: (-c[0], c[1]))[:2], key=lambda c: c[1])
    snippet = best[0][2]
    for prev, cur in zip(best, best[1:]):
        snippet += (" " if cur[1] == prev[1] + 1 else " ... ") + cur[2]
    if len(snippet) > limit:
        snippet = snippet[:limit].rsplit(" ", 1)[0] + " ..."
    return snippet


def _year(s: str | None) -> int | None:
    m = re.search(r"\b(1[89]\d{2}|20\d{2})\b", s or "")
    return int(m.group(1)) if m else None


# ---------------------------------------------------------------------------
# PubMed (NCBI E-utilities)
# ---------------------------------------------------------------------------
def _ncbi_get(endpoint: str, params: dict, deadline: Deadline) -> bytes:
    p = dict(params, tool=TOOL_NAME)
    email = os.environ.get("NCBI_EMAIL", "").strip()
    api_key = os.environ.get("NCBI_API_KEY", "").strip()
    if email:
        p["email"] = email
    if api_key:
        p["api_key"] = api_key
    url = EUTILS_BASE + endpoint + "?" + urllib.parse.urlencode(p)
    interval = NCBI_INTERVAL_WITH_KEY_S if api_key else NCBI_INTERVAL_NO_KEY_S
    return _fetch(url, NCBI_LIMITER, deadline, interval_s=interval, label=f"NCBI {endpoint}")


def _citation_from_esummary(rec: dict) -> dict:
    """Same field mapping as build_seed.py: every citation field is copied from esummary."""
    pubdate = rec.get("pubdate") or ""
    year = pubdate[:4] if pubdate[:4].isdigit() else (rec.get("sortpubdate") or "")[:4]
    doi = next((a.get("value") for a in rec.get("articleids", []) if a.get("idtype") == "doi"), None)
    return {
        "pmid": str(rec["uid"]), "doi": doi, "title": rec.get("title"), "journal": rec.get("source"),
        "year": int(year) if year.isdigit() else None,
        "first_author": rec.get("sortfirstauthor") or (rec.get("authors") or [{}])[0].get("name"),
        "pub_types": list(rec.get("pubtype") or []),
    }


def fetch_pubmed_summaries(pmids: Sequence[str], *, deadline: Deadline | None = None) -> dict[str, dict]:
    """esummary for up to 200 PMIDs (one request) -> {pmid: citation}. PMIDs that
    esummary does not return, or returns with an error, are simply absent."""
    ids = [p for p in dict.fromkeys(str(x).strip() for x in pmids) if p.isdigit()]
    if not ids:
        return {}
    if len(ids) > 200:
        raise ValueError("at most 200 PMIDs per esummary request")
    data = _json(_ncbi_get("esummary.fcgi", {"db": "pubmed", "id": ",".join(ids), "retmode": "json"},
                           deadline or Deadline()), "esummary")
    if not isinstance(data, dict) or "error" in data or not isinstance(data.get("result"), dict):
        raise LitSearchError("esummary: API error")
    res = data["result"]
    out = {}
    for pmid in ids:
        rec = res.get(pmid)
        if isinstance(rec, dict) and not rec.get("error") and rec.get("title") and str(rec.get("uid")) == pmid:
            out[pmid] = _citation_from_esummary(rec)
    return out


def _parse_efetch(body: bytes) -> dict[str, list[tuple[str, str]]]:
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        raise LitSearchError("efetch: malformed XML response") from None
    out: dict[str, list[tuple[str, str]]] = {}
    for art in root.iter("PubmedArticle"):
        pmid = (art.findtext("MedlineCitation/PMID") or "").strip()
        parts = []
        for node in art.iterfind("MedlineCitation/Article/Abstract/AbstractText"):
            text = " ".join("".join(node.itertext()).split())
            if text:
                parts.append(((node.get("Label") or node.get("NlmCategory") or "").upper(), text))
        if pmid:
            out[pmid] = parts
    return out


def search_pubmed(query: str, k: int = 5, *, with_abstracts: bool = True, reviews_only: bool = False,
                  cache: Any = _DEFAULT, deadline: Deadline | None = None) -> list[dict]:
    """esearch (relevance, has abstract, English) -> esummary -> optional efetch.
    Returns records in esearch order: {source, pmid, doi, title, journal, year,
    first_author, pub_types, evidence_type, abstract_snippet, url, curated=False, cached}."""
    q = sanitize_query(query)  # before cache lookup or any network access
    k = _clamp_k(k)
    store = _resolve_cache(cache)
    key = LitCache.make_key("pubmed", q, abstracts=with_abstracts, reviews=reviews_only)
    if store is not None and (hit := store.get(key)) is not None:
        return [dict(r, cached=True) for r in hit[:k]]
    dl = deadline or Deadline()
    # Peer-reviewed journal articles only: no preprints, no retracted papers (Nara cites only peer-reviewed work).
    term = (f"({q}) AND hasabstract AND english[la] AND journal article[pt] "
            f"NOT preprint[pt] NOT retracted publication[pt]")
    if reviews_only:
        term += " AND (systematic[sb] OR meta-analysis[pt])"
    data = _json(_ncbi_get("esearch.fcgi", {"db": "pubmed", "term": term, "retmode": "json",
                                            "retmax": MAX_RESULTS, "sort": "relevance"}, dl), "esearch")
    er = data.get("esearchresult") if isinstance(data, dict) else None
    if not isinstance(er, dict) or "ERROR" in er or "error" in data:
        raise LitSearchError("esearch: API error")
    ids = [str(i) for i in er.get("idlist", []) if str(i).isdigit()][:MAX_RESULTS]
    records: list[dict] = []
    complete = True
    if ids:
        summaries = fetch_pubmed_summaries(ids, deadline=dl)
        records = [_remote_record("pubmed", summaries[p], rank)
                   for rank, p in enumerate((p for p in ids if p in summaries), 1)]
        if with_abstracts and records:
            if dl.remaining() >= MIN_EFETCH_BUDGET_S:
                try:
                    abstracts = _parse_efetch(_ncbi_get(
                        "efetch.fcgi", {"db": "pubmed", "id": ",".join(r["pmid"] for r in records),
                                        "retmode": "xml"}, dl))
                    for r in records:
                        r["abstract_snippet"] = make_snippet(abstracts.get(r["pmid"]), q)
                except LitSearchError:
                    complete = False  # degrade to titles only; do not cache
            else:
                complete = False
    if store is not None and complete:
        store.put(key, "pubmed", q, records, CACHE_TTL_S if records else CACHE_EMPTY_TTL_S)
    return [dict(r, cached=False) for r in records[:k]]


# ---------------------------------------------------------------------------
# Europe PMC
# ---------------------------------------------------------------------------
def _strip_html(s: Any) -> str:
    if not s:
        return ""
    s = re.sub(r"<(?:br|p|div|h\d)\b[^>]*>|</(?:p|div|h\d)>", " ", str(s), flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)
    return " ".join(html.unescape(s).split())


def _epmc_abstract_parts(text: Any) -> list[tuple[str, str]]:
    if not text:
        return []
    pieces = re.split(r"<h4[^>]*>(.*?)</h4>", str(text), flags=re.I | re.S)
    parts = [("", _strip_html(pieces[0]))]
    parts += [(_strip_html(pieces[i]).upper(), _strip_html(pieces[i + 1])) for i in range(1, len(pieces) - 1, 2)]
    return [(lbl, body) for lbl, body in parts if body]


def _epmc_record(r: dict, query: str, rank: int) -> dict | None:
    pmid = str(r.get("pmid") or "")
    title = _strip_html(r.get("title"))
    if not pmid.isdigit() or not title:
        return None
    j = (r.get("journalInfo") or {}).get("journal") or {}
    authors = (r.get("authorList") or {}).get("author") or []
    first = next((a.get("fullName") or a.get("collectiveName") for a in authors
                  if a.get("fullName") or a.get("collectiveName")), None)
    if not first and r.get("authorString"):
        first = str(r["authorString"]).split(",")[0].strip().rstrip(".") or None
    pub_types = (r.get("pubTypeList") or {}).get("pubType") or []
    citation = {
        "pmid": pmid, "doi": r.get("doi"), "title": title,
        "journal": j.get("isoabbreviation") or j.get("medlineAbbreviation") or j.get("title") or r.get("journalTitle"),
        "year": _year(str(r.get("pubYear") or "")), "first_author": first,
        "pub_types": [pub_types] if isinstance(pub_types, str) else list(pub_types),
    }
    rec = _remote_record("europepmc", citation, rank)
    rec["abstract_snippet"] = make_snippet(_epmc_abstract_parts(r.get("abstractText")), query)
    return rec


def search_europepmc(query: str, k: int = 5, *, reviews_only: bool = False, cache: Any = _DEFAULT,
                     deadline: Deadline | None = None) -> list[dict]:
    """Europe PMC search restricted to MEDLINE records with abstracts, matching in
    title or abstract (full-text matching was observed to be much noisier).
    One request (resultType=core includes abstracts). Same record shape as PubMed."""
    q = sanitize_query(query)
    k = _clamp_k(k)
    store = _resolve_cache(cache)
    key = LitCache.make_key("europepmc", q, reviews=reviews_only)
    if store is not None and (hit := store.get(key)) is not None:
        return [dict(r, cached=True) for r in hit[:k]]
    dl = deadline or Deadline()
    full = f"(TITLE:({q}) OR ABSTRACT:({q})) AND SRC:MED AND HAS_ABSTRACT:y AND LANG:eng"
    if reviews_only:
        full += ' AND (PUB_TYPE:"review" OR PUB_TYPE:"systematic-review" OR PUB_TYPE:"meta-analysis")'
    url = EPMC_SEARCH_URL + "?" + urllib.parse.urlencode(
        {"query": full, "format": "json", "resultType": "core", "pageSize": MAX_RESULTS})
    data = _json(_fetch(url, EPMC_LIMITER, dl, interval_s=EPMC_INTERVAL_S, label="Europe PMC search"),
                 "Europe PMC")
    if not isinstance(data, dict) or "errCode" in data or not isinstance(data.get("resultList"), dict):
        raise LitSearchError("Europe PMC: API error")
    records = []
    for r in data["resultList"].get("result") or []:
        rec = _epmc_record(r, q, len(records) + 1)
        if rec:
            records.append(rec)
    if store is not None:
        store.put(key, "europepmc", q, records, CACHE_TTL_S if records else CACHE_EMPTY_TTL_S)
    return [dict(r, cached=False) for r in records[:k]]


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------
_REMOTES: dict[str, Callable[..., list[dict]]] = {"pubmed": search_pubmed, "europepmc": search_europepmc}


def find_evidence(query: str, k: int = 5, *, metric: str | None = None,
                  remote: Sequence[str] | None = ("pubmed", "europepmc"),
                  local_min_score: float = LOCAL_MIN_SCORE, cache: Any = _DEFAULT,
                  deadline: Deadline | None = None, corpus_path: str | os.PathLike | None = None,
                  forbidden_terms: Iterable[str] = ()) -> dict:
    """Curated corpus first; remote sources (in order) only if no seed hit is strong.
    A seed hit is kept if score >= max(local_min_score, LOCAL_REL_MIN x top score) and
    coverage >= LOCAL_MIN_COVERAGE (it matches most of the query, not one generic word).
    A failing or empty remote source falls through to the next one.
    Returns {"query", "evidence", "local_top_score", "remote_used", "tried", "elapsed_s"}."""
    started = time.monotonic()
    q = sanitize_query(query, forbidden_terms=forbidden_terms)
    k = _clamp_k(k)
    local = search_seed(q, k=k, metric=metric, corpus_path=corpus_path)
    cutoff = max(local_min_score, LOCAL_REL_MIN * local[0]["score"]) if local else local_min_score
    result: dict[str, Any] = {
        "query": q,
        "evidence": [r for r in local if r["score"] >= cutoff and r["coverage"] >= LOCAL_MIN_COVERAGE],
        "local_top_score": local[0]["score"] if local else 0.0, "remote_used": None, "tried": [],
    }
    if not result["evidence"] and remote:
        dl = deadline or Deadline()
        for src in remote:
            if src not in _REMOTES:
                raise ValueError(f"unknown remote source: {src!r}")
            try:
                recs = _REMOTES[src](q, k, cache=cache, deadline=dl)
            except LitSearchError as e:
                result["tried"].append({"source": src, "error": f"{type(e).__name__}: {e}"})
                continue
            result["tried"].append({"source": src, "hits": len(recs)})
            if recs:
                result["evidence"], result["remote_used"] = recs, src
                break
    result["elapsed_s"] = round(time.monotonic() - started, 3)
    return result


# ---------------------------------------------------------------------------
# Citation guard
# ---------------------------------------------------------------------------
_PMID_RE = re.compile(r"(?:\bPMID\s*[:#]?\s*|pubmed\.ncbi\.nlm\.nih\.gov/|ncbi\.nlm\.nih\.gov/pubmed/)(\d{1,9})\b",
                      re.I)
_DOI_RE = re.compile(r"\b(10\.\d{4,9}/[^\s\"'<>]+)", re.I)


def extract_pmids(text: str) -> set[str]:
    return {m.group(1) for m in _PMID_RE.finditer(text or "")}


def extract_dois(text: str) -> set[str]:
    return {m.group(1).rstrip(".,;:)]}").lower() for m in _DOI_RE.finditer(text or "")}


def unverified_citations(text: str, evidence: Iterable[dict]) -> dict[str, set[str]]:
    """PMIDs/DOIs that appear in generated text but are not in the retrieved evidence.
    Anything returned here must be removed (or the answer regenerated) before display."""
    evidence = list(evidence)
    pmids = {str(e["pmid"]) for e in evidence if e.get("pmid")}
    dois = {str(e["doi"]).lower() for e in evidence if e.get("doi")}
    return {"pmids": extract_pmids(text) - pmids, "dois": extract_dois(text) - dois}


def verify_seed_citations(corpus_path: str | os.PathLike | None = None, *,
                          deadline: Deadline | None = None) -> list[dict]:
    """Re-check every seed citation against live esummary (one batched request).
    Returns a list of mismatches; empty means title/journal/year/doi/first author all match."""
    entries = load_corpus(corpus_path)
    live = fetch_pubmed_summaries([e["citation"]["pmid"] for e in entries], deadline=deadline)
    problems = []
    for e in entries:
        c = e["citation"]
        got = live.get(str(c["pmid"]))
        if got is None:
            problems.append({"id": e["id"], "pmid": c["pmid"], "problem": "not returned by esummary"})
            continue
        for field in ("title", "journal", "year", "doi", "first_author"):
            if c.get(field) != got.get(field):
                problems.append({"id": e["id"], "pmid": c["pmid"], "field": field,
                                 "seed": c.get(field), "pubmed": got.get(field)})
    return problems


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _cli(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Literature retrieval for metric explanations.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("local", "pubmed", "europepmc", "search", "sanitize"):
        p = sub.add_parser(name)
        p.add_argument("query")
        p.add_argument("-k", type=int, default=5)
        if name in ("local", "search"):
            p.add_argument("--metric")
        if name in ("pubmed", "europepmc"):
            p.add_argument("--reviews", action="store_true", help="systematic reviews / meta-analyses only")
        if name in ("pubmed", "europepmc", "search"):
            p.add_argument("--no-cache", action="store_true")
        if name == "pubmed":
            p.add_argument("--no-abstracts", action="store_true")
        if name == "search":
            p.add_argument("--remote", default="pubmed,europepmc", help="comma list, or 'none'")
            p.add_argument("--min-score", type=float, default=LOCAL_MIN_SCORE)
    sub.add_parser("verify-seed")
    a = ap.parse_args(argv)
    cache = None if getattr(a, "no_cache", False) else _DEFAULT
    started = time.monotonic()
    try:
        if a.cmd == "local":
            out: Any = search_seed(a.query, a.k, metric=a.metric)
        elif a.cmd == "pubmed":
            out = search_pubmed(a.query, a.k, with_abstracts=not a.no_abstracts, reviews_only=a.reviews, cache=cache)
        elif a.cmd == "europepmc":
            out = search_europepmc(a.query, a.k, reviews_only=a.reviews, cache=cache)
        elif a.cmd == "search":
            remote = () if a.remote.strip().lower() == "none" else tuple(s.strip() for s in a.remote.split(","))
            out = find_evidence(a.query, a.k, metric=a.metric, remote=remote, local_min_score=a.min_score,
                                cache=cache)
        elif a.cmd == "sanitize":
            out = sanitize_query(a.query)
        else:
            out = verify_seed_citations()
    except UnsafeQueryError as e:
        print(json.dumps({"error": "unsafe_query", "code": e.code, "message": str(e)}))
        return 2
    except LitSearchError as e:
        print(json.dumps({"error": type(e).__name__, "message": str(e)}))
        return 1
    print(json.dumps({"cmd": a.cmd, "elapsed_s": round(time.monotonic() - started, 3), "result": out},
                     indent=2, ensure_ascii=False))
    return 1 if a.cmd == "verify-seed" and out else 0


if __name__ == "__main__":
    sys.exit(_cli())
