"""The optional-family seam of ``sensor.biomarkers.v1`` (docs/model-integration/sensor-families.md).

Research and shadow families live in their own subpackages: ``paradigma`` (tremor, arm_swing) and
``rhythm`` (rhythm_shadow). Each exposes the same small interface, and the aggregate route reaches
the implementation only through it:

* ``FAMILIES``: the family keys the adapter serves;
* ``adapter_state()``: a cheap description of whether it can run (flag, artifacts, runtime), with
  no side effects;
* ``compute_family_documents(input_payload, families, *, deadline_s=None)``: one family document
  per requested family. Deployment and data problems come back as withheld documents; an
  exception means the adapter itself is broken.

The standalone providers (``sensor.biomarkers.paradigma.v1``, ``sensor.biomarkers.rhythm.v1``)
call the same functions, so each family has one implementation. The three ways an optional family
can fail to run carry different stable reasons: ``family_disabled`` (the sidecar's flag is off),
``model_unavailable`` / ``runtime_unavailable`` (pinned weights or the isolated runtime are
missing), and ``adapter_broken`` (import error, interface mismatch, or an exception inside the
adapter). A broken adapter never takes the other families down with it.

Missing weights used to publish the family reason ``artifact_unavailable``, the same string a family
without verified input published; the two now read ``model_unavailable`` (here) and
``no_verified_input`` (no input reached the family), the canonical codes of
contracts/reason-codes.json. Stored documents keep the old string and readers still accept it. The
adapter *state* (``GET /v1/providers`` readiness) keeps its name ``artifact_unavailable``: it names
what is missing, not a data reason.
"""

from __future__ import annotations

import importlib
import inspect
import re
import time
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence

from . import FAMILY_TIERS
from .contract import family_document

#: Which adapter implements each optional family.
OPTIONAL_FAMILY_ADAPTERS: dict[str, str] = {
    "tremor": "paradigma",
    "arm_swing": "paradigma",
    "rhythm_shadow": "rhythm",
}

#: Where each adapter is imported from. A provider instance may point an adapter elsewhere (tests
#: inject doubles this way; a later checkpoint can plug in the same way).
DEFAULT_ADAPTER_MODULES: dict[str, str] = {
    "paradigma": f"{__package__}.paradigma",
    "rhythm": f"{__package__}.rhythm",
}

STATE_READY = "ready"
STATE_DISABLED = "disabled"
STATE_ARTIFACT_UNAVAILABLE = "artifact_unavailable"
STATE_RUNTIME_UNAVAILABLE = "runtime_unavailable"
STATE_BROKEN = "adapter_broken"

#: Family reasons (canonical codes, contracts/reason-codes.json): the model / weights are not available,
#: and no verified input reached the family. ``artifact_unavailable`` is what both were before
#: 2026-10-09; it is still read (stored documents) and never written.
REASON_MODEL_UNAVAILABLE = "model_unavailable"
REASON_NO_VERIFIED_INPUT = "no_verified_input"
LEGACY_REASON_ARTIFACT_UNAVAILABLE = "artifact_unavailable"

#: The family reason each non-ready state publishes, and its family status.
STATE_REASONS: dict[str, tuple[str, str]] = {
    STATE_DISABLED: ("withheld", "family_disabled"),
    STATE_ARTIFACT_UNAVAILABLE: ("withheld", REASON_MODEL_UNAVAILABLE),
    STATE_RUNTIME_UNAVAILABLE: ("withheld", "runtime_unavailable"),
    STATE_BROKEN: ("error", "adapter_broken"),
}

#: What exactly is broken about an adapter (the ``reason_counts`` key of the family document).
BROKEN_IMPORT = "adapter_import_error"
BROKEN_INTERFACE = "adapter_interface_mismatch"
BROKEN_EXCEPTION = "adapter_exception"

#: An optional family is not started with less time than this left in its budget.
MIN_OPTIONAL_SECONDS = 1.0

#: ``sensor_biomarker_days`` accepts only revisions of this shape (publish_sensor_biomarker_day).
PROVIDER_REVISION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,95}$")

#: rhythm_shadow carries model score vectors only (CONTRACTS.md section 2).
RHYTHM_SCORE_KEYS = frozenset({"deepbeat_quality_scores", "deepbeat_rhythm_scores",
                               "siamaf_rhythm_scores"})

#: Words a shadow rhythm stage must never use as a key: no burden, episode, alert or diagnosis.
FORBIDDEN_RHYTHM_KEY_FRAGMENTS = ("burden", "episode", "alert", "notif", "diagnos")

_DETAIL_LIMIT = 300


def _describe(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}"[:_DETAIL_LIMIT]


def adapter_families(name: str) -> tuple[str, ...]:
    return tuple(f for f, adapter in OPTIONAL_FAMILY_ADAPTERS.items() if adapter == name)


@dataclass(frozen=True)
class LoadedAdapter:
    """An adapter module that passed the interface check, or why it did not."""

    name: str
    source: str
    module: Any = None
    broken_code: str | None = None
    broken_detail: str | None = None

    @property
    def broken(self) -> bool:
        return self.broken_code is not None


def _interface_problem(name: str, module: Any) -> str | None:
    families = getattr(module, "FAMILIES", None)
    if not isinstance(families, (tuple, list, frozenset, set)):
        return "FAMILIES is missing or not a collection of family keys"
    missing = set(adapter_families(name)) - set(families)
    if missing:
        return f"FAMILIES does not include {sorted(missing)}"
    for attribute in ("adapter_state", "compute_family_documents"):
        if not callable(getattr(module, attribute, None)):
            return f"{attribute} is missing or not callable"
    try:
        inspect.signature(module.adapter_state).bind()
        inspect.signature(module.compute_family_documents).bind({}, [], deadline_s=None)
    except (TypeError, ValueError) as exc:
        return f"signature mismatch: {exc}"
    return None


def load_adapter(name: str, spec: Any) -> LoadedAdapter:
    """Import ``spec`` (a module path) or take an injected object, then check its interface."""
    source = spec if isinstance(spec, str) else getattr(spec, "__name__", type(spec).__name__)
    if isinstance(spec, str):
        try:
            module = importlib.import_module(spec)
        except Exception as exc:  # an optional dependency or the adapter itself fails to import
            return LoadedAdapter(name, source, broken_code=BROKEN_IMPORT,
                                 broken_detail=_describe(exc))
    else:
        module = spec
    problem = _interface_problem(name, module)
    if problem is not None:
        return LoadedAdapter(name, source, broken_code=BROKEN_INTERFACE, broken_detail=problem)
    return LoadedAdapter(name, source, module=module)


def make_state(name: str, state: str, *, detail: str | None = None,
               **extra: Any) -> dict[str, Any]:
    """An ``adapter_state()`` result. Adapters build theirs with this, so every state has one shape."""
    if state != STATE_READY and state not in STATE_REASONS:
        raise ValueError(f"unknown adapter state {state!r}")
    reason = None if state == STATE_READY else STATE_REASONS[state][1]
    out: dict[str, Any] = {"adapter": name, "state": state, "reason": reason,
                           "detail": (detail or None) and str(detail)[:_DETAIL_LIMIT]}
    out.update(extra)
    return out


def broken_state(name: str, code: str, detail: str, source: str | None = None) -> dict[str, Any]:
    return make_state(name, STATE_BROKEN, detail=detail, detail_code=code,
                      **({"module": source} if source else {}))


def evaluate_state(adapter: LoadedAdapter) -> dict[str, Any]:
    """The adapter's state, or ``adapter_broken`` when it cannot even say."""
    if adapter.broken:
        return broken_state(adapter.name, adapter.broken_code, adapter.broken_detail or "",
                            adapter.source)
    try:
        state = adapter.module.adapter_state()
    except Exception as exc:
        return broken_state(adapter.name, BROKEN_EXCEPTION, _describe(exc), adapter.source)
    if not isinstance(state, Mapping) or state.get("state") not in (STATE_READY, *STATE_REASONS):
        return broken_state(adapter.name, BROKEN_INTERFACE,
                            f"adapter_state returned {state!r}"[:_DETAIL_LIMIT], adapter.source)
    state = dict(state)
    if state["state"] == STATE_BROKEN:
        state.setdefault("detail_code", BROKEN_EXCEPTION)
    return state


# ---------------------------------------------------------------------------
# Family documents
# ---------------------------------------------------------------------------

def state_documents(families: Iterable[str], state: Mapping[str, Any]) -> list[dict[str, Any]]:
    """One document per family for an adapter that cannot run, carrying the state's reason."""
    status, reason = STATE_REASONS[state["state"]]
    detail_code = state.get("detail_code") or reason
    adapter_block = {"name": state.get("adapter"), "state": state["state"]}
    if state.get("detail"):
        adapter_block["detail"] = state["detail"]
    if state.get("detail_code"):
        adapter_block["detail_code"] = state["detail_code"]
    return [family_document(family=family, status=status, reason=reason, measurements={},
                            reason_counts={detail_code: 1}, extra={"adapter": dict(adapter_block)})
            for family in families]


def timeout_documents(families: Iterable[str], name: str, budget_s: float | None) -> list[dict[str, Any]]:
    """Documents for families whose time budget ran out before or while they ran."""
    detail = (f"optional family budget exhausted ({budget_s:.1f} s left)"
              if budget_s is not None else "optional family budget exhausted")
    return [family_document(family=family, status="withheld", reason="timeout", measurements={},
                            reason_counts={"optional_family_budget_exhausted": 1},
                            extra={"adapter": {"name": name, "state": STATE_READY,
                                               "detail": detail}})
            for family in families]


def _keys(node: Any) -> Iterable[str]:
    if isinstance(node, Mapping):
        for key, value in node.items():
            yield str(key)
            yield from _keys(value)
    elif isinstance(node, (list, tuple)):
        for item in node:
            yield from _keys(item)


def _publishable_anywhere(node: Any) -> bool:
    if isinstance(node, Mapping):
        if node.get("publishable") is True:
            return True
        return any(_publishable_anywhere(value) for value in node.values())
    if isinstance(node, (list, tuple)):
        return any(_publishable_anywhere(item) for item in node)
    return False


def _document_problem(family: str, doc: Any) -> str | None:
    """Why an adapter's document breaks the family contract, or None."""
    if not isinstance(doc, Mapping):
        return "document is not an object"
    if doc.get("status") not in ("ok", "withheld", "error"):
        return f"status {doc.get('status')!r} is not ok/withheld/error"
    if not isinstance(doc.get("measurements", {}), Mapping):
        return "measurements is not an object"
    counts = doc.get("reason_counts", {})
    if not isinstance(counts, Mapping) or not all(
            isinstance(v, int) and not isinstance(v, bool) for v in counts.values()):
        return "reason_counts is not an object of integers"
    revision = doc.get("provider_revision")
    if not isinstance(revision, str) or not PROVIDER_REVISION_RE.match(revision):
        return f"provider_revision {revision!r} is not publishable"
    if family == "rhythm_shadow":
        extra = set(doc.get("measurements") or {}) - RHYTHM_SCORE_KEYS
        if extra:
            return f"rhythm_shadow measurements outside the score vectors: {sorted(extra)}"
        extra = set(doc.get("raw_scores") or {}) - RHYTHM_SCORE_KEYS
        if extra:
            return f"rhythm_shadow raw_scores outside the score vectors: {sorted(extra)}"
        for key in _keys(doc):
            lowered = key.lower()
            if any(fragment in lowered for fragment in FORBIDDEN_RHYTHM_KEY_FRAGMENTS):
                return f"rhythm_shadow carries a clinical key {key!r}"
        if _publishable_anywhere(doc):
            return "rhythm_shadow claims publishable output"
    return None


def checked_documents(name: str, families: Sequence[str], returned: Any) -> list[dict[str, Any]]:
    """The adapter's documents for ``families``, held to the family contract.

    A family the adapter did not answer, or answered with a document that breaks the contract,
    becomes ``adapter_broken`` (interface mismatch). The release tier is always the contract's:
    an adapter can never raise its own tier.
    """
    by_family: dict[str, Any] = {}
    if isinstance(returned, (list, tuple)):
        for doc in returned:
            if isinstance(doc, Mapping) and doc.get("family") in families:
                by_family.setdefault(doc["family"], doc)
    out: list[dict[str, Any]] = []
    for family in families:
        doc = by_family.get(family)
        problem = ("no document returned for the family" if doc is None
                   else _document_problem(family, doc))
        if problem is not None:
            out.extend(state_documents([family], broken_state(name, BROKEN_INTERFACE, problem)))
            continue
        doc = dict(doc)
        doc["release_tier"] = FAMILY_TIERS[family]
        out.append(doc)
    return out


def compute_optional_families(
    input_payload: Mapping[str, Any],
    families: Sequence[str],
    *,
    modules: Mapping[str, Any],
    deadline: float | None,
) -> list[dict[str, Any]]:
    """Dispatch the requested optional families to their adapters.

    Each adapter runs in isolation: an import error, interface mismatch or exception in one
    adapter yields ``adapter_broken`` documents for its own families only. ``deadline`` is a
    ``time.monotonic()`` value; what is left of it is passed on as ``deadline_s``.
    """
    grouped: dict[str, list[str]] = {}
    for family in families:
        name = OPTIONAL_FAMILY_ADAPTERS.get(family)
        if name is not None:
            grouped.setdefault(name, []).append(family)
    docs: list[dict[str, Any]] = []
    for name, wanted in grouped.items():
        adapter = load_adapter(name, modules.get(name, DEFAULT_ADAPTER_MODULES[name]))
        if adapter.broken:
            docs.extend(state_documents(wanted, evaluate_state(adapter)))
            continue
        remaining = None if deadline is None else deadline - time.monotonic()
        if remaining is not None and remaining < MIN_OPTIONAL_SECONDS:
            docs.extend(timeout_documents(wanted, name, max(0.0, remaining)))
            continue
        try:
            returned = adapter.module.compute_family_documents(
                input_payload, list(wanted), deadline_s=remaining)
        except Exception as exc:
            docs.extend(state_documents(
                wanted, broken_state(name, BROKEN_EXCEPTION, _describe(exc), adapter.source)))
            continue
        docs.extend(checked_documents(name, wanted, returned))
    return docs


def optional_loaded_identity(modules: Mapping[str, Any]) -> dict[str, str]:
    """What the ready optional adapters verified they would load, keyed ``<adapter>.<key>``.

    ``loaded_identity()`` is optional in the adapter interface: an adapter without it reports
    nothing, and one that raises reports ``<adapter>.error`` instead of breaking the health route.
    """
    out: dict[str, str] = {}
    for name in sorted(set(OPTIONAL_FAMILY_ADAPTERS.values())):
        adapter = load_adapter(name, modules.get(name, DEFAULT_ADAPTER_MODULES[name]))
        report = None if adapter.broken else getattr(adapter.module, "loaded_identity", None)
        if not callable(report):
            continue
        try:
            for key, value in sorted(dict(report()).items()):
                out[f"{name}.{key}"] = str(value)
        except Exception as exc:  # noqa: BLE001 - a broken report is itself the identity
            out[f"{name}.error"] = _describe(exc)
    return out


def optional_family_capabilities(modules: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    """Per-family readiness for ``/v1/providers``: one adapter state per optional family."""
    out: dict[str, dict[str, Any]] = {}
    for name in sorted(set(OPTIONAL_FAMILY_ADAPTERS.values())):
        adapter = load_adapter(name, modules.get(name, DEFAULT_ADAPTER_MODULES[name]))
        state = evaluate_state(adapter)
        per_family = state.get("families") if isinstance(state.get("families"), Mapping) else {}
        for family in adapter_families(name):
            entry = {
                "tier": FAMILY_TIERS[family],
                "publishable": False,
                "adapter": name,
                "implementation": adapter.source,
                "ready": state["state"] == STATE_READY,
                "state": state["state"],
                "reason": state.get("reason"),
                "detail": state.get("detail"),
            }
            for key in ("detail_code", "flags", "models", "runtime"):
                if key in state:
                    entry[key] = state[key]
            if isinstance(per_family.get(family), Mapping):
                entry.update(per_family[family])
            out[family] = entry
    return out
