"""Loopback-only HTTP sidecar (standard library only).

Routes
------
``GET  /healthz``           readiness, per provider, plus the execution (pool) state
``GET  /v1/providers``      capability manifest (providers + recorded models)
``POST /v1/infer``          one inference request
``POST /v1/sleep-features`` the sleep-phenotype enrichment document

Rules enforced here:

* bind loopback only; refuse any other host unless ``--allow-non-loopback``
  (tests only);
* verify artifact sha256 at startup; readiness is false with a reason when a
  required artifact is missing or mismatched;
* bounded execution (``execution.py``): every computation runs in a warm worker
  process of a lane with a fixed number of processes; a request that cannot be
  admitted is answered at once with HTTP 429 ``busy`` + ``Retry-After``;
* a per-request wall-clock budget, after which the provider yields
  ``withheld`` + ``timeout`` (sleep features: the degraded ``timeout`` document)
  and the process that overran is terminated and replaced;
* a fixed pool of HTTP handler threads, so a flood of connections cannot create
  threads without bound and ``/healthz`` stays answerable while jobs run;
* never crash on bad input: 400 / 404 / 503 with a JSON error body;
* no network access at inference time.
"""

from __future__ import annotations

import argparse
import json
import os
import pickle
import queue
import signal
import socket
import sys
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Callable, Mapping, Sequence

from .artifacts import (
    DEFAULT_MODEL_ROOT,
    ManifestState,
    default_manifest_path,
    load_manifest,
    manifest_summary,
    pin_model_root,
    verify_manifest,
)
from .contract import (
    CONTRACT_VERSION,
    MAX_BODY_BYTES,
    PACKAGE_VERSION,
    SERVER_NAME,
    ContractError,
    InferRequest,
    ProviderResult,
    WithheldReason,
    canonical_sha256,
    parse_request,
    utc_day,
)
from .execution import (
    DEFAULT_SLEEP_FEATURES_COMPUTE,
    EXECUTION_SCHEMA,
    LANE_INFER,
    LANE_SLEEP_FEATURES,
    Busy,
    ExecutionConfig,
    JobOutcome,
    WorkerLane,
)
from .features import BUDGET_MS as FEATURES_BUDGET_MS
from .features import SCHEMA_VERSION as FEATURES_SCHEMA_VERSION
from .features import ALGORITHM_VERSION as FEATURES_ALGORITHM_VERSION
from .features.contract import MAX_BODY_BYTES as FEATURES_MAX_BODY_BYTES
from .features.contract import parse_request as features_parse_request
from .identity import runtime_identity
from .providers import Provider, ProviderRegistry, default_providers

LOOPBACK_HOSTS = ("127.0.0.1", "::1", "localhost")

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8787
DEFAULT_TIMEOUT_MS = 20_000

#: Bounds on the best-effort discard of a request body the server refuses to read
#: (see ``InferenceHandler._refuse_body``). Discarding what the client already sent
#: keeps the close orderly - closing a socket with unread data makes the kernel send
#: RST, which can discard the error response before the client reads it - while the
#: byte cap and the read timeout keep a client that lies about Content-Length from
#: pinning the handler thread.
REFUSED_BODY_DRAIN_BYTES = 1024 * 1024
REFUSED_BODY_DRAIN_TIMEOUT_S = 0.25

#: Provider readiness sources. ``inline``: this process calls every provider's
#: ``readiness()`` while building (direct library use and tests). ``worker``: the first warm
#: infer worker reports it (the production ``main()``), so the HTTP process never imports or
#: loads a model it does not run.
READINESS_INLINE = "inline"
READINESS_WORKER = "worker"
READINESS_PENDING_REASON = ("not_ready: warming up (provider readiness is reported by the "
                            "warm worker process)")


# --------------------------------------------------------------------------
# Application state
# --------------------------------------------------------------------------


@dataclass
class ProviderState:
    provider: Provider
    ready: bool
    reason: str | None
    version: str
    checked_at_utc: str

    def to_wire(self) -> dict[str, Any]:
        return {"ready": self.ready, "version": self.version, "reason": self.reason}


@dataclass
class Application:
    """Everything the request handler needs, assembled once at startup."""

    registry: ProviderRegistry
    manifest: ManifestState
    timeout_ms: int = DEFAULT_TIMEOUT_MS
    started_at_utc: str = ""
    started_monotonic: float = 0.0
    provider_states: dict[str, ProviderState] = field(default_factory=dict)
    inference_count: int = 0
    withheld_count: int = 0
    error_count: int = 0
    #: ``inline`` or ``worker`` (see READINESS_*).
    readiness_source: str = READINESS_INLINE
    #: When the warm worker's readiness report was adopted (``worker`` source only).
    readiness_reported_at_utc: str | None = None
    _lock: threading.Lock = field(default_factory=threading.Lock)

    # -- startup ------------------------------------------------------------

    @classmethod
    def build(
        cls,
        *,
        registry: ProviderRegistry | None = None,
        manifest_path: str | None = None,
        model_root: str | None = None,
        timeout_ms: int = DEFAULT_TIMEOUT_MS,
        provider_readiness: str = READINESS_INLINE,
    ) -> "Application":
        registry = registry or ProviderRegistry(default_providers())
        path = manifest_path or os.environ.get("FRWHOOP_MANIFEST") or default_manifest_path()
        root = model_root or os.environ.get("FRWHOOP_MODEL_ROOT") or DEFAULT_MODEL_ROOT
        try:
            manifest_raw = load_manifest(path)
            state = verify_manifest(manifest_raw, root, manifest_path=path)
        except Exception as exc:  # a missing/broken manifest is a readiness failure, not a crash
            state = ManifestState(path=path, model_root=root, manifest_version="unknown",
                                  entries=(), checks=(), ok=False,
                                  reason=f"blocked_artifact: manifest unusable ({exc})",
                                  verified_at_utc=_now_utc(), load_error=str(exc))
        if provider_readiness not in (READINESS_INLINE, READINESS_WORKER):
            raise ValueError(f"unknown provider readiness source {provider_readiness!r}")
        app = cls(registry=registry, manifest=state, timeout_ms=int(timeout_ms),
                  started_at_utc=_now_utc(), started_monotonic=time.monotonic(),
                  readiness_source=provider_readiness)
        if provider_readiness == READINESS_WORKER:
            app.mark_readiness_pending()
        else:
            app.refresh_readiness()
        return app

    def blocking_checks(self, provider_id: str) -> list:
        """Manifest artifact checks that block THIS provider.

        A provider is gated only by the manifest entries that declare it as their
        ``provider_id``. Entries with no artifacts (for example a vendored source drop) block
        nobody, and a provider with no entry at all (for example the pure-numpy HRV
        production provider) is never gated by model bytes. This is what keeps a missing
        sleep checkpoint from taking the HRV endpoints down with it.
        """
        entry_ids = {str(entry.get("id")) for entry in self.manifest.entries
                     if str(entry.get("provider_id") or "") == provider_id}
        if not entry_ids:
            return []
        return [check for check in self.manifest.checks
                if check.entry_id in entry_ids and check.required_for_readiness and check.failed]

    def refresh_readiness(self, reported: Mapping[str, Sequence[Any]] | None = None) -> None:
        """Compute per-provider readiness once, gated by the manifest.

        ``reported`` is a warm worker's ``{provider_id: [ready, reason]}``; without it every
        provider's own ``readiness()`` is called in this process. The states are built aside
        and swapped in whole, so a concurrent ``/healthz`` never sees a half-filled map.
        """
        # Fail CLOSED when the manifest cannot be read (review F1): with no entries we cannot
        # know which artifacts a provider needs, so no provider may claim readiness. This is
        # different from a readable manifest whose required artifact is missing, which gates
        # only the providers that name that entry.
        manifest_unusable = self.manifest.load_error is not None
        states: dict[str, ProviderState] = {}
        for provider in self.registry.all():
            if reported is None:
                ready, reason = provider.readiness()
            else:
                entry = reported.get(provider.provider_id)
                if entry is None:
                    ready, reason = False, "not_ready: the warm worker did not report this provider"
                else:
                    ready, reason = bool(entry[0]), entry[1]
            if ready and manifest_unusable:
                ready = False
                reason = ("blocked_artifact: manifest unusable (%s)"
                          % (self.manifest.reason or self.manifest.load_error))
            elif ready:
                blocking = self.blocking_checks(provider.provider_id)
                if blocking:
                    ready = False
                    reason = "blocked_artifact: " + ", ".join(
                        f"{c.entry_id}/{c.artifact_name} ({c.status})" for c in blocking)
            versions = provider.versions()
            states[provider.provider_id] = ProviderState(
                provider=provider, ready=ready, reason=reason,
                version=str(versions.get("adapter", PACKAGE_VERSION)),
                checked_at_utc=_now_utc())
        self.provider_states = states

    def mark_readiness_pending(self) -> None:
        """Every provider not ready until the warm worker reports (``worker`` source)."""
        self.provider_states = {
            provider.provider_id: ProviderState(
                provider=provider, ready=False, reason=READINESS_PENDING_REASON,
                version=str(provider.versions().get("adapter", PACKAGE_VERSION)),
                checked_at_utc=_now_utc())
            for provider in self.registry.all()}

    def adopt_worker_readiness(self, reported: Mapping[str, Sequence[Any]]) -> bool:
        """Adopt the first warm worker's readiness report; later reports change nothing.

        Readiness is computed once at startup, as it always was: a replacement worker that
        disagrees is logged by the caller, not silently swapped in."""
        if self.readiness_source != READINESS_WORKER:
            return False
        with self._lock:
            if self.readiness_reported_at_utc is not None:
                return False
            self.refresh_readiness(reported)
            self.readiness_reported_at_utc = _now_utc()
        return True

    def readiness_pending(self) -> bool:
        return self.readiness_source == READINESS_WORKER and self.readiness_reported_at_utc is None

    def warm_provider_ids(self) -> list[str] | None:
        """Providers a new worker must warm: all of them when the worker is the readiness
        source; otherwise only the ready ones (nothing else is ever dispatched to it)."""
        if self.readiness_source == READINESS_WORKER:
            return None
        return [pid for pid, state in self.provider_states.items() if state.ready]

    # -- queries ------------------------------------------------------------

    def is_ready(self) -> bool:
        """Process readiness: the manifest must verify AND every provider must be ready.

        Per-provider readiness is what gates ``POST /v1/infer`` (a not-ready provider is 503'd
        on its own metric); this process-level flag is the supervisor/health view that
        ``deploy/OPERATIONS.md`` tells operators to read, so it must not report healthy while
        the artifact manifest is unreadable or an artifact it requires is missing.
        """
        return (bool(self.manifest.ok) and bool(self.provider_states)
                and all(s.ready for s in self.provider_states.values()))

    def healthz(self) -> dict[str, Any]:
        return {
            "ready": self.is_ready(),
            "server": SERVER_NAME,
            "package_version": PACKAGE_VERSION,
            "contract_version": CONTRACT_VERSION,
            "started_at_utc": self.started_at_utc,
            "uptime_s": round(time.monotonic() - self.started_monotonic, 3),
            "manifest": {
                "ok": self.manifest.ok,
                "reason": self.manifest.reason,
                "path": self.manifest.path,
                "model_root": self.manifest.model_root,
                "verified_at_utc": self.manifest.verified_at_utc,
                "load_error": self.manifest.load_error,
                "failed_checks": [c.to_wire() for c in self.manifest.checks if c.failed],
            },
            "providers": {pid: state.to_wire() for pid, state in self.provider_states.items()},
            "identity": runtime_identity(self),
            "counters": {
                "inference": self.inference_count,
                "withheld": self.withheld_count,
                "error": self.error_count,
            },
        }

    def providers_capability(self) -> dict[str, Any]:
        out: list[dict[str, Any]] = []
        for provider in self.registry.all():
            state = self.provider_states.get(provider.provider_id)
            capability = dict(provider.capability())
            capability["readiness"] = {
                "ready": bool(state and state.ready),
                "reason": state.reason if state else "not_ready",
            }
            out.append(capability)
        return {
            "contract_version": CONTRACT_VERSION,
            "server": SERVER_NAME,
            "package_version": PACKAGE_VERSION,
            "generated_at_utc": _now_utc(),
            "providers": out,
            "models": manifest_summary(self.manifest),
            "artifact_checks": [c.to_wire() for c in self.manifest.checks],
            "identity": runtime_identity(self),
        }


def _now_utc() -> str:
    from datetime import datetime, timezone

    return datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# Inference
# --------------------------------------------------------------------------


def _select_provider(app: Application, request: InferRequest) -> Provider:
    if request.provider_id:
        provider = app.registry.get(request.provider_id)
        if provider is None:
            raise ContractError("unknown_provider",
                                f"no provider {request.provider_id!r} is registered",
                                http_status=404, field="provider.provider_id")
        if provider.metric != request.metric:
            raise ContractError("provider_metric_mismatch",
                                f"provider {provider.provider_id!r} does not serve "
                                f"metric {request.metric!r}",
                                http_status=400, field="provider.provider_id")
        return provider
    provider = app.registry.default_for_metric(request.metric)
    if provider is None:
        raise ContractError("provider_unavailable",
                            f"no provider is registered for metric {request.metric!r}",
                            http_status=503, field="metric")
    return provider


def _check_expected_versions(provider: Provider, request: InferRequest) -> None:
    expected = request.expected_versions
    if not expected:
        return
    actual = provider.versions(request)
    mismatches = {key: (want, actual.get(key))
                  for key, want in expected.items() if actual.get(key) != want}
    if mismatches:
        detail = ", ".join(f"{k}: expected {w!r} got {a!r}" for k, (w, a) in sorted(mismatches.items()))
        raise ContractError("provider_version_mismatch", detail, http_status=400,
                            field="provider.expected_versions")


#: ``execute(provider, request, budget_ms) -> (result | None, timed_out)``. The HTTP server
#: passes its infer lane; it raises :class:`Busy` when the request cannot be admitted and
#: ``ContractError`` for a provider fault.
Executor = Callable[[Provider, InferRequest, int], "tuple[ProviderResult | None, bool]"]


def run_inference(app: Application, request: InferRequest,
                  execute: Executor | None = None) -> dict[str, Any]:
    """Run one request and render the wire response. Never raises for bad input.

    Without ``execute`` (direct library use) the provider runs inline in the caller's
    thread with no budget: nothing is ever left computing in the background. The HTTP
    server always passes its bounded worker lane."""
    provider = _select_provider(app, request)
    _check_expected_versions(provider, request)

    if app.readiness_pending():
        # Not a verdict on the provider: the warm worker has not reported yet.
        raise Busy(LANE_INFER, "infer lane warming up: provider readiness is not reported yet", 5)
    state = app.provider_states.get(provider.provider_id)
    if state is not None and not state.ready:
        raise ContractError("provider_not_ready",
                            f"provider {provider.provider_id!r} is not ready: {state.reason}",
                            http_status=503, field="provider.provider_id")

    started = time.monotonic()
    if execute is None:
        result, timed_out = _run_inline(provider, request), False
    else:
        result, timed_out = execute(provider, request, app.timeout_ms)
    runtime_ms = int(round((time.monotonic() - started) * 1000))

    if timed_out:
        result = ProviderResult(
            status="withheld", value=None, unit="ms",
            withheld_reason=WithheldReason.TIMEOUT.value,
            # Only the worker lane can time out, and an overrun always ends its process.
            diagnostics={"budget_ms": app.timeout_ms, "withheld_detail": "request_budget_exceeded",
                         "worker_terminated": True},
            versions=provider.versions(request),
            final_or_provisional="provisional" if request.context.live else "final",
            publishable=provider.capability().get("publishable", False))
    elif result is None:
        result = ProviderResult(
            status="withheld", value=None, unit="ms",
            withheld_reason=WithheldReason.PROVIDER_ERROR.value,
            diagnostics={"withheld_detail": "provider_returned_none"},
            versions=provider.versions(request),
            final_or_provisional="provisional" if request.context.live else "final",
            publishable=provider.capability().get("publishable", False))

    with app._lock:
        app.inference_count += 1
        if result.status == "withheld":
            app.withheld_count += 1
        elif result.status == "error":
            app.error_count += 1

    return _render(request, provider, result, runtime_ms)


def _run_inline(provider: Provider, request: InferRequest) -> ProviderResult | None:
    """``provider.infer`` in the caller's thread (direct library use only)."""
    try:
        return provider.infer(request)
    except ContractError:
        raise
    except Exception as exc:  # noqa: BLE001 - a provider fault is a 500, never a crash
        raise ContractError("provider_error",
                            f"provider {provider.provider_id!r} raised "
                            f"{type(exc).__name__}: {exc}",
                            http_status=500) from exc


def outcome_to_infer_result(provider: Provider, outcome: JobOutcome) -> tuple[ProviderResult | None, bool]:
    """Map a lane outcome to ``(result, timed_out)``; a fault raises ``ContractError``."""
    if outcome.status == "ok":
        return outcome.value, False
    if outcome.status == "timeout":
        return None, True
    if outcome.status == "crashed":
        raise ContractError("provider_error",
                            f"provider {provider.provider_id!r} worker process exited while "
                            f"computing: {outcome.detail}", http_status=500)
    error = outcome.error or {}
    if error.get("kind") == "contract":
        raise ContractError(str(error.get("code") or "provider_error"),
                            str(error.get("message") or ""),
                            http_status=int(error.get("http_status") or 500),
                            field=error.get("field"))
    if error.get("kind") == "client_gone":
        raise ClientGone()
    raise ContractError("provider_error",
                        f"provider {provider.provider_id!r} raised "
                        f"{error.get('type', 'Exception')}: {error.get('message', '')}",
                        http_status=500)


class ClientGone(Exception):
    """The client disconnected while its request waited for a worker: answer nobody."""


def _render_result_payload(result: ProviderResult) -> dict[str, Any] | None:
    """The ``result`` envelope object; structured stage results included."""
    if result.status != "ok":
        return None
    payload: dict[str, Any] = {"value": result.value, "unit": result.unit}
    if result.stages is not None:
        payload["stages"] = result.stages
        payload["label_space"] = result.label_space
    return payload


def _render(request: InferRequest, provider: Provider, result: ProviderResult,
            runtime_ms: int) -> dict[str, Any]:
    capability = provider.capability()
    publishable = bool(result.publishable and capability.get("publishable", False))
    payload: dict[str, Any] = {
        "status": result.status,
        "metric": request.metric,
        "provider_id": provider.provider_id,
        "versions": result.versions,
        "input": {"sha256": request.input_sha256, "refs": list(request.input_refs)},
        "result": _render_result_payload(result),
        "interval": {
            "start_utc": request.context.interval_start_utc,
            "end_utc": request.context.interval_end_utc,
            "iana_timezone": request.context.iana_timezone,
            "local_day": utc_day(request.context.start_ts, request.context.iana_timezone),
        },
        "final_or_provisional": result.final_or_provisional,
        "coverage": result.coverage,
        "raw_scores": result.raw_scores,
        "diagnostics": result.diagnostics,
        "runtime_ms": int(runtime_ms),
        "publishable": publishable,
        "accuracy_label": capability.get("accuracy_label"),
    }
    if result.label_space is not None:
        payload["label_space"] = result.label_space
    if result.status == "withheld":
        payload["withheld_reason"] = result.withheld_reason
    return payload


# --------------------------------------------------------------------------
# Sleep-features degraded documents (budget overrun / module failure)
# --------------------------------------------------------------------------


def degraded_timeout_doc(request: Any, budget_ms: int = FEATURES_BUDGET_MS) -> dict[str, Any]:
    """The budget-overrun document: status "timeout", every block withheld.

    The worker publishes core results with feature status withheld/timeout
    and retries on the ordinary next eligible scoring pass (spec 7.4)."""
    return {
        "schema_version": FEATURES_SCHEMA_VERSION,
        "algorithm_version": FEATURES_ALGORITHM_VERSION,
        "status": "timeout",
        "status_reasons": ["enrichment_budget_exceeded"],
        "nights": [
            {
                "night_id": n.night_id,
                "start_utc": _fmt_features_utc(n.start),
                "end_utc": _fmt_features_utc(n.end),
                "is_nap": n.is_nap,
                "user_edited": n.user_edited,
                "stage_source": "sleep-v2",
                "stage_algorithm_version": "sleep-stager-v2",
                "continuity": {"status": "withheld", "reasons": ["enrichment_budget_exceeded"]},
                "architecture": {"status": "withheld", "reasons": ["enrichment_budget_exceeded"]},
                "stage_physiology": {"status": "withheld", "reasons": ["enrichment_budget_exceeded"]},
                "settling": {"status": "withheld", "reasons": ["enrichment_budget_exceeded"]},
                "thermal": {"status": "withheld", "reasons": ["enrichment_budget_exceeded"]},
                "respiratory_variability": {"status": "withheld",
                                            "reasons": ["enrichment_budget_exceeded"]},
                "metric_status": {"night_gate": {"status": "withheld",
                                                 "reasons": ["enrichment_budget_exceeded"]},
                                  "module_errors": []},
                "coverage": {},
            }
            for n in request.nights
        ],
        "regularity": {"status": "withheld", "reasons": ["enrichment_budget_exceeded"]},
        "dependencies": {"config_version": "sleep-features-defaults-1"},
        "capabilities": {
            "oxygen_events": {"ready": False, "reason": "unverified_sparse_oxygen"},
            "waveform_staging": {"ready": False, "reason": "continuous_ppg_not_delivered"},
        },
        "budget_ms": int(budget_ms),
        "duration_ms": int(budget_ms),
    }


def degraded_error_doc(request: Any, error: str) -> dict[str, Any]:
    """The module-failure document: status "error", blocks withheld with the
    reason; one broken feature never erases the rest of the response shape."""
    doc = degraded_timeout_doc(request)
    doc["status"] = "error"
    doc["status_reasons"] = ["enrichment_error"]
    doc["error"] = error[:512]
    for night in doc["nights"]:
        for key in ("continuity", "architecture", "stage_physiology", "settling", "thermal",
                    "respiratory_variability"):
            night[key] = {"status": "withheld", "reasons": ["enrichment_error"]}
        night["metric_status"]["night_gate"] = {"status": "withheld",
                                                "reasons": ["enrichment_error"]}
    doc["regularity"] = {"status": "withheld", "reasons": ["enrichment_error"]}
    doc.pop("budget_ms", None)
    return doc


def _fmt_features_utc(ts: int) -> str:
    from datetime import datetime, timezone

    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# HTTP plumbing
# --------------------------------------------------------------------------


class InferenceHandler(BaseHTTPRequestHandler):
    server_version = f"{SERVER_NAME}/{PACKAGE_VERSION}"
    protocol_version = "HTTP/1.1"

    # -- helpers ------------------------------------------------------------

    @property
    def app(self) -> Application:
        return self.server.app  # type: ignore[attr-defined]

    def setup(self) -> None:
        # A read timeout on every connection: with a fixed handler pool, a stalled client
        # or an idle keep-alive connection must give its thread back eventually.
        self.timeout = self.server.execution.http_idle_timeout_s  # type: ignore[attr-defined]
        super().setup()

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, status: int, payload: Mapping[str, Any],
                   headers: Mapping[str, str] | None = None) -> None:
        body = json.dumps(payload, sort_keys=True, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if self.close_connection:
            # Say so explicitly: a refused body ends the connection, and a client
            # that keeps the socket alive must not pipeline onto it.
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _send_error_json(self, status: int, code: str, message: str,
                         field_name: str | None = None) -> None:
        error: dict[str, Any] = {"code": code, "message": message}
        if field_name:
            error["field"] = field_name
        self._send_json(status, {"status": "error", "error": error})

    def _send_busy(self, exc: Busy) -> None:
        """HTTP 429 ``busy`` + ``Retry-After`` (docs/model-integration/README.md): the request
        was not admitted, nothing was computed, and the caller should come back later."""
        error = {"code": "busy", "message": exc.message, "lane": exc.lane,
                 "retry_after_s": exc.retry_after_s}
        self._send_json(429, {"status": "error", "error": error},
                        headers={"Retry-After": str(exc.retry_after_s)})

    def _client_still_connected(self) -> bool:
        """False once the client has hung up (EOF), so a request that outwaited its client
        is not computed for nobody. A client that keeps the socket open counts as present."""
        try:
            previous = self.connection.gettimeout()
        except OSError:
            return False
        try:
            self.connection.settimeout(0.0)
            return self.connection.recv(1, socket.MSG_PEEK) != b""
        except (BlockingIOError, InterruptedError):
            return True
        except OSError:
            return False
        finally:
            try:
                self.connection.settimeout(previous)
            except OSError:
                pass

    def _drain_refused_body(self, length: int | None) -> None:
        """Best-effort discard of a body this request will not read.

        Bounded twice over: at most ``REFUSED_BODY_DRAIN_BYTES`` bytes and at most
        ``REFUSED_BODY_DRAIN_TIMEOUT_S`` of waiting for them, so a client that
        declares a huge body and then stalls cannot hold the handler thread.
        """
        remaining = REFUSED_BODY_DRAIN_BYTES if length is None else min(
            length, REFUSED_BODY_DRAIN_BYTES)
        if remaining <= 0:
            return
        previous = self.connection.gettimeout()
        try:
            self.connection.settimeout(REFUSED_BODY_DRAIN_TIMEOUT_S)
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    return
                remaining -= len(chunk)
        except (OSError, ValueError):
            return
        finally:
            try:
                self.connection.settimeout(previous)
            except OSError:  # pragma: no cover - the socket is already gone
                pass

    def _refuse_body(self, code: str, message: str, http_status: int = 400,
                     length: int | None = None) -> ContractError:
        """Refuse a request body we will not read, and end the connection.

        The server speaks HTTP/1.1, which is keep-alive by default. A body left
        unread in the socket would be parsed as the NEXT request on the same
        connection (request desynchronisation), and a client that is still sending
        would block against a server that never reads. Discarding what is already
        buffered and then closing is therefore part of the error, not a separate
        concern.
        """
        self._drain_refused_body(length)
        self.close_connection = True
        return ContractError(code, message, http_status=http_status)

    def _read_body(self, limit: int = MAX_BODY_BYTES) -> bytes:
        length_header = self.headers.get("Content-Length")
        if length_header is None:
            return b""
        try:
            length = int(length_header)
        except ValueError as exc:
            raise self._refuse_body("invalid_request", "Content-Length is not an integer") from exc
        if length < 0:
            raise self._refuse_body("invalid_request", "Content-Length is negative")
        if length > limit:
            raise self._refuse_body("payload_too_large",
                                    f"body exceeds {limit} bytes", http_status=413,
                                    length=length)
        return self.rfile.read(length)

    # -- routes -------------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        try:
            if path in ("/healthz", "/health", "/"):
                payload = self.app.healthz()
                payload["execution"] = self.server.execution_snapshot()  # type: ignore[attr-defined]
                self._send_json(200, payload)
                return
            if path == "/v1/providers":
                self._send_json(200, self.app.providers_capability())
                return
            self._send_error_json(404, "not_found", f"no route for GET {path}")
        except Exception as exc:  # pragma: no cover - defensive
            self._send_error_json(500, "server_error", f"{type(exc).__name__}: {exc}")

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/v1/sleep-features":
            self._handle_sleep_features()
            return
        if path != "/v1/infer":
            try:
                self._read_body()
            except ContractError as exc:
                self._send_error_json(exc.http_status, exc.code, exc.message, exc.field)
                return
            self._send_error_json(404, "not_found", f"no route for POST {path}")
            return
        try:
            raw = self._read_body()
        except ContractError as exc:
            self._send_error_json(exc.http_status, exc.code, exc.message, exc.field)
            return
        try:
            body = json.loads(raw.decode("utf-8")) if raw else None
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            self._send_error_json(400, "malformed_json", f"request body is not valid JSON: {exc}")
            return
        try:
            request = parse_request(body)
        except ContractError as exc:
            self._send_error_json(exc.http_status, exc.code, exc.message, exc.field)
            return
        server: InferenceServer = self.server  # type: ignore[assignment]
        try:
            payload = run_inference(
                self.app, request,
                execute=lambda provider, req, budget_ms: server.execute_infer(
                    provider, req, budget_ms, still_wanted=self._client_still_connected))
        except Busy as exc:
            self._send_busy(exc)
            return
        except ClientGone:
            self.close_connection = True
            return
        except ContractError as exc:
            self._send_error_json(exc.http_status, exc.code, exc.message, exc.field)
            return
        except Exception as exc:  # pragma: no cover - defensive
            self._send_error_json(500, "server_error", f"{type(exc).__name__}: {exc}")
            return
        self._send_json(200, payload)

    def _handle_sleep_features(self) -> None:
        """POST /v1/sleep-features: the deterministic sleep-phenotype enrichment.

        Not an inference request and NOT a candidate provider (spec 7.1): a
        bundle of descriptive features must not be disguised as a scalar
        result or stuffed into stage arrays, so this is its own typed
        request/response on the same loopback server, with its own bounded
        budget (``FRWHOOP_SLEEP_FEATURES_BUDGET_MS``, default features.BUDGET_MS,
        3000 ms) and its own worker lane. A budget overrun publishes a DEGRADED
        document (status "timeout", HTTP 200) rather than an error, so the
        worker's core score never waits on the enrichment; a lane that cannot
        admit the request answers 429 ``busy`` at once.
        """
        try:
            raw = self._read_body(FEATURES_MAX_BODY_BYTES)
        except ContractError as exc:
            self._send_error_json(exc.http_status, exc.code, exc.message, exc.field)
            return
        try:
            body = json.loads(raw.decode("utf-8")) if raw else None
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            self._send_error_json(400, "malformed_json", f"request body is not valid JSON: {exc}")
            return
        try:
            request = features_parse_request(body)
        except ContractError as exc:
            self._send_error_json(exc.http_status, exc.code, exc.message, exc.field)
            return
        except Exception as exc:  # pragma: no cover - defensive
            self._send_error_json(400, "invalid_request", f"{type(exc).__name__}: {exc}")
            return
        started = time.monotonic()
        server: InferenceServer = self.server  # type: ignore[assignment]
        try:
            payload, timed_out = server.run_sleep_features(
                request, still_wanted=self._client_still_connected)
        except Busy as exc:
            self._send_busy(exc)
            return
        except ClientGone:
            self.close_connection = True
            return
        if timed_out:
            with self.app._lock:
                self.app.withheld_count += 1
        # The document's own wall-clock duration (spec section 10: measured
        # fixture runtime), including this route's watchdog overhead.
        if isinstance(payload, dict):
            payload["duration_ms"] = int(round((time.monotonic() - started) * 1000.0))
        self._send_json(200, payload)


class BoundedThreadingMixIn:
    """A fixed pool of handler threads and a bounded number of open connections.

    ``ThreadingMixIn`` starts a thread per connection, so a flood of connections (or a
    pile of requests each waiting on a busy provider) grows threads without bound. Here at
    most ``threads + backlog`` accepted connections exist at once: ``threads`` being served
    and up to ``backlog`` waiting for a handler. One more gets an immediate ``busy`` answer
    and is closed. Every admission wait and every job is bounded, so a handler thread is
    always given back and ``/healthz`` keeps an answer."""

    def _start_handler_pool(self, threads: int, backlog: int) -> None:
        self._connections: "queue.Queue[tuple[Any, Any] | None]" = queue.Queue()
        self._pool_lock = threading.Lock()
        self._pool_threads = max(1, int(threads))
        self._pool_capacity = self._pool_threads + max(0, int(backlog))
        self._open_connections = 0
        self._busy_handlers = 0
        self._refused_connections = 0
        self._handler_threads = [
            threading.Thread(target=self._handler_loop, name=f"http-{i}", daemon=True)
            for i in range(self._pool_threads)]
        for thread in self._handler_threads:
            thread.start()

    def process_request(self, request: Any, client_address: Any) -> None:
        with self._pool_lock:
            admitted = self._open_connections < self._pool_capacity
            if admitted:
                self._open_connections += 1
            else:
                self._refused_connections += 1
        if admitted:
            self._connections.put((request, client_address))
        else:
            self._refuse_connection(request)

    def _handler_loop(self) -> None:
        while True:
            item = self._connections.get()
            if item is None:
                return
            request, client_address = item
            with self._pool_lock:
                self._busy_handlers += 1
            try:
                self.finish_request(request, client_address)  # type: ignore[attr-defined]
            except Exception:  # noqa: BLE001 - one connection's fault never kills a handler
                self.handle_error(request, client_address)  # type: ignore[attr-defined]
            finally:
                self.shutdown_request(request)  # type: ignore[attr-defined]
                with self._pool_lock:
                    self._busy_handlers -= 1
                    self._open_connections -= 1

    def _refuse_connection(self, request: Any) -> None:
        body = json.dumps({"status": "error", "error": {
            "code": "busy", "lane": "http", "retry_after_s": 1,
            "message": "connection limit reached: every handler thread is busy"}}).encode("utf-8")
        head = ("HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json; charset=utf-8\r\n"
                f"Retry-After: 1\r\nConnection: close\r\nContent-Length: {len(body)}\r\n\r\n")
        try:
            request.settimeout(0.2)
            request.sendall(head.encode("ascii") + body)
        except OSError:
            pass
        self.shutdown_request(request)  # type: ignore[attr-defined]

    def _stop_handler_pool(self) -> None:
        threads = getattr(self, "_handler_threads", [])
        for _ in threads:
            self._connections.put(None)
        for thread in threads:
            thread.join(timeout=2.0)

    def handler_pool_snapshot(self) -> dict[str, Any]:
        with self._pool_lock:
            return {"threads": self._pool_threads, "busy": self._busy_handlers,
                    "open_connections": self._open_connections,
                    "connection_capacity": self._pool_capacity,
                    "refused_connections": self._refused_connections}


class InferenceServer(BoundedThreadingMixIn, HTTPServer):
    """The loopback HTTP server, its handler pool and its two worker lanes.

    Lanes start lazily on the first request (``start_workers()`` starts them at once, as
    ``main()`` does), so a server built for a quick test never pays a worker start it does
    not use."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], app: Application, *,
                 execution: ExecutionConfig | None = None,
                 sleep_features_compute: str = DEFAULT_SLEEP_FEATURES_COMPUTE):
        self.app = app
        self.execution = execution or ExecutionConfig.from_env(os.environ)
        # ``module:callable`` the sleep-features workers call (tests substitute a slow one).
        self.sleep_features_compute = sleep_features_compute
        try:
            # The infer workers rebuild exactly this registry; an unpicklable provider is a
            # startup error, not a worker that can never start.
            self._registry_blob = pickle.dumps(app.registry, protocol=pickle.HIGHEST_PROTOCOL)
        except Exception as exc:
            raise ValueError(f"the provider registry cannot be sent to a worker process: "
                             f"{type(exc).__name__}: {exc}") from exc
        self.lanes: dict[str, WorkerLane] = {
            LANE_INFER: WorkerLane(self.execution.infer, init_payload=self._infer_init,
                                   math_threads=self.execution.math_threads,
                                   on_hello=self._on_infer_hello),
            LANE_SLEEP_FEATURES: WorkerLane(self.execution.sleep_features,
                                            init_payload=self._sleep_features_init,
                                            math_threads=self.execution.math_threads),
        }
        try:
            super().__init__(address, InferenceHandler)
        except BaseException:
            self._close_lanes()
            raise
        self._start_handler_pool(self.execution.http_threads, self.execution.http_backlog)
        if app.readiness_pending():
            # Provider readiness comes from the first warm infer worker, so that lane cannot
            # wait for a request to start it.
            self.lanes[LANE_INFER].start()

    # -- worker lanes ------------------------------------------------------------

    def _infer_init(self) -> dict[str, Any]:
        return {"kind": LANE_INFER, "registry": self._registry_blob, "sys_path": list(sys.path),
                "math_threads": self.execution.math_threads,
                "warm_providers": self.app.warm_provider_ids()}

    def _sleep_features_init(self) -> dict[str, Any]:
        return {"kind": LANE_SLEEP_FEATURES, "sys_path": list(sys.path),
                "math_threads": self.execution.math_threads,
                "budget_ms": self.execution.sleep_features_budget_ms,
                "compute": self.sleep_features_compute}

    def _on_infer_hello(self, hello: Mapping[str, Any]) -> None:
        # What the warm worker measured it loaded; /healthz reports it ahead of this process's
        # own (unloaded) copy of each provider. A respawned worker replaces the report.
        loaded = hello.get("loaded")
        if isinstance(loaded, Mapping):
            self.app.worker_loaded_identity = {str(k): v for k, v in loaded.items()
                                               if isinstance(v, Mapping)}
        reported = hello.get("readiness") or {}
        if self.app.adopt_worker_readiness(reported):
            ready = sorted(pid for pid, state in self.app.provider_states.items() if state.ready)
            sys.stderr.write(f"frwhoop-inference: provider readiness from worker "
                             f"pid={hello.get('pid')}: ready={ready}\n")

    def start_workers(self) -> None:
        for lane in self.lanes.values():
            lane.start()

    def wait_workers_ready(self, timeout: float = 120.0) -> bool:
        deadline = time.monotonic() + timeout
        return all(lane.wait_ready(max(0.0, deadline - time.monotonic()))
                   for lane in self.lanes.values())

    def execute_infer(self, provider: Provider, request: InferRequest, budget_ms: int, *,
                      still_wanted: Callable[[], bool] | None = None
                      ) -> tuple[ProviderResult | None, bool]:
        outcome = self.lanes[LANE_INFER].run(
            LANE_INFER, {"provider_id": provider.provider_id, "request": request},
            budget_s=max(1, int(budget_ms)) / 1000.0, still_wanted=still_wanted)
        return outcome_to_infer_result(provider, outcome)

    def run_sleep_features(self, request: Any, *, still_wanted: Callable[[], bool] | None = None
                           ) -> tuple[dict[str, Any], bool]:
        """The enrichment document under its budget; ``(doc, timed_out)``. Raises ``Busy``."""
        budget_ms = self.execution.sleep_features_budget_ms
        outcome = self.lanes[LANE_SLEEP_FEATURES].run(
            LANE_SLEEP_FEATURES, {"request": request}, budget_s=budget_ms / 1000.0,
            still_wanted=still_wanted)
        if outcome.status == "timeout":
            return degraded_timeout_doc(request, budget_ms), True
        if outcome.status == "crashed":
            return degraded_error_doc(request, f"worker_crashed: {outcome.detail}"), False
        if outcome.status == "error":
            error = outcome.error or {}
            if error.get("kind") == "client_gone":
                raise ClientGone()
            return degraded_error_doc(request, f"{error.get('type') or error.get('code') or 'Error'}: "
                                               f"{error.get('message', '')}"), False
        doc = outcome.value
        return (doc if isinstance(doc, dict) and doc else degraded_error_doc(request, "empty_result")), False

    def execution_snapshot(self) -> dict[str, Any]:
        """``/healthz``'s ``execution`` block: limits, pool state and counters per lane."""
        lanes = {name: lane.snapshot() for name, lane in self.lanes.items()}
        lanes[LANE_INFER]["budget_ms"] = self.app.timeout_ms
        lanes[LANE_SLEEP_FEATURES]["budget_ms"] = self.execution.sleep_features_budget_ms
        return {
            "schema": EXECUTION_SCHEMA,
            "limits": self.execution.to_wire(),
            "http": self.handler_pool_snapshot(),
            "provider_readiness": {"source": self.app.readiness_source,
                                   "reported_at_utc": self.app.readiness_reported_at_utc},
            "lanes": lanes,
        }

    # -- shutdown ------------------------------------------------------------------

    def _close_lanes(self) -> None:
        for lane in getattr(self, "lanes", {}).values():
            lane.close()

    def server_close(self) -> None:
        super().server_close()
        # Lanes first: a handler waiting on a job is released when its worker goes away.
        self._close_lanes()
        self._stop_handler_pool()


def is_loopback_host(host: str) -> bool:
    return host in LOOPBACK_HOSTS


def create_server(
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
    *,
    registry: ProviderRegistry | None = None,
    manifest_path: str | None = None,
    model_root: str | None = None,
    timeout_ms: int = DEFAULT_TIMEOUT_MS,
    allow_non_loopback: bool = False,
    execution: ExecutionConfig | None = None,
    provider_readiness: str = READINESS_INLINE,
) -> InferenceServer:
    """Build the server. Refuses a non-loopback bind unless explicitly allowed."""
    if not is_loopback_host(host) and not allow_non_loopback:
        raise ValueError(
            f"refusing to bind {host!r}: the inference sidecar is loopback-only "
            "(pass --allow-non-loopback for a test host)")
    app = Application.build(registry=registry, manifest_path=manifest_path,
                            model_root=model_root, timeout_ms=timeout_ms,
                            provider_readiness=provider_readiness)
    return InferenceServer((host, int(port)), app, execution=execution)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="frwhoop-inference",
        description="FRWHOOP physiology inference sidecar (loopback only).")
    parser.add_argument("--host", default=os.environ.get("FRWHOOP_HOST", DEFAULT_HOST))
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("FRWHOOP_PORT", DEFAULT_PORT)))
    parser.add_argument("--manifest", default=os.environ.get("FRWHOOP_MANIFEST"),
                        help="path to models/manifest.json")
    parser.add_argument("--model-root", default=os.environ.get("FRWHOOP_MODEL_ROOT"),
                        help="root of the checksum-verified artifact cache")
    parser.add_argument("--timeout-ms", type=int,
                        default=int(os.environ.get("FRWHOOP_REQUEST_TIMEOUT_MS", DEFAULT_TIMEOUT_MS)),
                        help="per-request wall-clock budget in milliseconds")
    parser.add_argument("--allow-non-loopback", action="store_true",
                        help="TEST ONLY: permit a non-loopback bind")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    # Pin the artifact root before anything reads it (the parser defaults and the optional
    # providers both read FRWHOOP_MODEL_ROOT/FRWHOOP_MANIFEST), so a model-root switch takes
    # effect only on restart. Worker processes are started later from this environment, so
    # they inherit the pinned root.
    pin_model_root(os.environ)
    args = build_arg_parser().parse_args(argv)
    if not is_loopback_host(args.host) and not args.allow_non_loopback:
        sys.stderr.write(
            f"frwhoop-inference: refusing to bind {args.host!r}: loopback only "
            "(use --allow-non-loopback for tests)\n")
        return 2
    execution = ExecutionConfig.from_env(os.environ)
    # The warm worker reports provider readiness, so this process never loads a model it
    # does not run (FRWHOOP_INFERENCE_READINESS=inline restores in-process readiness).
    readiness = (os.environ.get("FRWHOOP_INFERENCE_READINESS") or READINESS_WORKER).strip().lower()
    if readiness not in (READINESS_INLINE, READINESS_WORKER):
        sys.stderr.write(f"frwhoop-inference: ignoring FRWHOOP_INFERENCE_READINESS={readiness!r}\n")
        readiness = READINESS_WORKER
    try:
        server = create_server(args.host, args.port, manifest_path=args.manifest,
                               model_root=args.model_root, timeout_ms=args.timeout_ms,
                               allow_non_loopback=args.allow_non_loopback,
                               execution=execution, provider_readiness=readiness)
    except ValueError as exc:
        sys.stderr.write(f"frwhoop-inference: {exc}\n")
        return 2
    # SIGTERM (systemd stop) ends serve_forever, so the lanes terminate and reap their
    # workers before the process exits.
    signal.signal(signal.SIGTERM,
                  lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    server.start_workers()
    host, port = server.server_address[0], server.server_address[1]
    ready = server.app.is_ready()
    sys.stderr.write(
        f"frwhoop-inference {PACKAGE_VERSION} listening on http://{host}:{port} "
        f"(ready={ready}"
        + (f", reason={server.app.manifest.reason}" if not ready and server.app.manifest.reason
           else "")
        + f"; readiness={readiness}; infer workers={execution.infer.workers} "
          f"waiting<={execution.infer.max_waiting}; sleep_features workers="
          f"{execution.sleep_features.workers} waiting<={execution.sleep_features.max_waiting} "
          f"budget_ms={execution.sleep_features_budget_ms}; math_threads={execution.math_threads}; "
          f"http_threads={execution.http_threads})\n")
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
