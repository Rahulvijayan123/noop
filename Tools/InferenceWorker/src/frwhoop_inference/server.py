"""Loopback-only HTTP sidecar (standard library only).

Routes
------
``GET  /healthz``      readiness, per provider
``GET  /v1/providers`` capability manifest (providers + recorded models)
``POST /v1/infer``     one inference request

Rules enforced here:

* bind loopback only; refuse any other host unless ``--allow-non-loopback``
  (tests only);
* verify artifact sha256 at startup; readiness is false with a reason when a
  required artifact is missing or mismatched;
* a per-request wall-clock budget, after which the provider yields
  ``withheld`` + ``timeout`` instead of hanging the caller;
* never crash on bad input: 400 / 404 / 503 with a JSON error body;
* no network access at inference time.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
import traceback
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Mapping, Sequence

from .artifacts import (
    DEFAULT_MODEL_ROOT,
    ManifestState,
    default_manifest_path,
    load_manifest,
    manifest_summary,
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
from .features import BUDGET_MS as FEATURES_BUDGET_MS
from .features import SCHEMA_VERSION as FEATURES_SCHEMA_VERSION
from .features import ALGORITHM_VERSION as FEATURES_ALGORITHM_VERSION
from .features.compute import compute as features_compute
from .features.contract import MAX_BODY_BYTES as FEATURES_MAX_BODY_BYTES
from .features.contract import parse_request as features_parse_request
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
        app = cls(registry=registry, manifest=state, timeout_ms=int(timeout_ms),
                  started_at_utc=_now_utc(), started_monotonic=time.monotonic())
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

    def refresh_readiness(self) -> None:
        # Fail CLOSED when the manifest cannot be read (review F1): with no entries we cannot
        # know which artifacts a provider needs, so no provider may claim readiness. This is
        # different from a readable manifest whose required artifact is missing, which gates
        # only the providers that name that entry.
        manifest_unusable = self.manifest.load_error is not None
        for provider in self.registry.all():
            ready, reason = provider.readiness()
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
            self.provider_states[provider.provider_id] = ProviderState(
                provider=provider, ready=ready, reason=reason,
                version=str(versions.get("adapter", PACKAGE_VERSION)),
                checked_at_utc=_now_utc())

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


def run_inference(app: Application, request: InferRequest) -> dict[str, Any]:
    """Run one request and render the wire response. Never raises for bad input."""
    provider = _select_provider(app, request)
    _check_expected_versions(provider, request)

    state = app.provider_states.get(provider.provider_id)
    if state is not None and not state.ready:
        raise ContractError("provider_not_ready",
                            f"provider {provider.provider_id!r} is not ready: {state.reason}",
                            http_status=503, field="provider.provider_id")

    started = time.monotonic()
    result, timed_out = _run_with_budget(provider, request, app.timeout_ms)
    runtime_ms = int(round((time.monotonic() - started) * 1000))

    if timed_out:
        result = ProviderResult(
            status="withheld", value=None, unit="ms",
            withheld_reason=WithheldReason.TIMEOUT.value,
            diagnostics={"budget_ms": app.timeout_ms, "withheld_detail": "request_budget_exceeded"},
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


def _run_with_budget(
    provider: Provider, request: InferRequest, timeout_ms: int
) -> tuple[ProviderResult | None, bool]:
    """Run ``provider.infer`` under a wall-clock budget.

    One attempt only. On timeout the worker thread is abandoned (daemon) and the
    caller receives ``(None, True)`` so the response becomes a withheld
    ``timeout`` rather than a hung connection.
    """
    box: dict[str, Any] = {}

    def target() -> None:
        try:
            box["result"] = provider.infer(request)
        except ContractError as exc:
            box["error"] = exc
        except Exception as exc:  # pragma: no cover - defensive
            box["error"] = exc
            box["traceback"] = traceback.format_exc()

    thread = threading.Thread(target=target, name=f"infer-{provider.provider_id}", daemon=True)
    thread.start()
    thread.join(max(0.001, timeout_ms / 1000.0))
    if thread.is_alive():
        return None, True
    error = box.get("error")
    if error is not None:
        if isinstance(error, ContractError):
            raise error
        raise ContractError("provider_error",
                            f"provider {provider.provider_id!r} raised "
                            f"{type(error).__name__}: {error}",
                            http_status=500)
    return box.get("result"), False


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


def degraded_timeout_doc(request: Any) -> dict[str, Any]:
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
        "budget_ms": FEATURES_BUDGET_MS,
        "duration_ms": FEATURES_BUDGET_MS,
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

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, status: int, payload: Mapping[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
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
                self._send_json(200, self.app.healthz())
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
        try:
            payload = run_inference(self.app, request)
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
        budget (features.BUDGET_MS, 3000 ms). A budget overrun publishes a
        DEGRADED document (status "timeout", HTTP 200) rather than an error,
        so the worker's core score never waits on the enrichment.
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
        payload, timed_out = self._run_sleep_features(request)
        if timed_out:
            with self.app._lock:
                self.app.withheld_count += 1
        # The document's own wall-clock duration (spec section 10: measured
        # fixture runtime), including this route's watchdog overhead.
        if isinstance(payload, dict):
            payload["duration_ms"] = int(round((time.monotonic() - started) * 1000.0))
        self._send_json(200, payload)

    def _run_sleep_features(self, request: Any) -> tuple[dict[str, Any], bool]:
        """Run the enrichment under a wall-clock budget (spec 7.4).

        Same watchdog pattern as ``run_inference``'s ``_run_with_budget``: the
        computation runs on a daemon thread and the handler never waits past
        ``features.BUDGET_MS``. On timeout the abandoned thread's partial result
        is discarded and a degraded document is returned, so one slow night can
        never pin the scoring lane.
        """
        box: dict[str, Any] = {}

        def target() -> None:
            try:
                box["doc"] = features_compute(request, budget_ms=FEATURES_BUDGET_MS)
            except Exception as exc:  # noqa: BLE001 - degraded, never fatal
                box["error"] = f"{type(exc).__name__}: {exc}"

        thread = threading.Thread(target=target, name="sleep-features", daemon=True)
        thread.start()
        thread.join(max(0.001, FEATURES_BUDGET_MS / 1000.0))
        if thread.is_alive():
            doc = degraded_timeout_doc(request)
            return doc, True
        if "error" in box:
            doc = degraded_error_doc(request, box["error"])
            return doc, False
        return box.get("doc") or degraded_error_doc(request, "empty_result"), False


class InferenceServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], app: Application):
        self.app = app
        super().__init__(address, InferenceHandler)


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
) -> InferenceServer:
    """Build the server. Refuses a non-loopback bind unless explicitly allowed."""
    if not is_loopback_host(host) and not allow_non_loopback:
        raise ValueError(
            f"refusing to bind {host!r}: the inference sidecar is loopback-only "
            "(pass --allow-non-loopback for a test host)")
    app = Application.build(registry=registry, manifest_path=manifest_path,
                            model_root=model_root, timeout_ms=timeout_ms)
    return InferenceServer((host, int(port)), app)


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
    args = build_arg_parser().parse_args(argv)
    if not is_loopback_host(args.host) and not args.allow_non_loopback:
        sys.stderr.write(
            f"frwhoop-inference: refusing to bind {args.host!r}: loopback only "
            "(use --allow-non-loopback for tests)\n")
        return 2
    try:
        server = create_server(args.host, args.port, manifest_path=args.manifest,
                               model_root=args.model_root, timeout_ms=args.timeout_ms,
                               allow_non_loopback=args.allow_non_loopback)
    except ValueError as exc:
        sys.stderr.write(f"frwhoop-inference: {exc}\n")
        return 2
    host, port = server.server_address[0], server.server_address[1]
    ready = server.app.is_ready()
    sys.stderr.write(
        f"frwhoop-inference {PACKAGE_VERSION} listening on http://{host}:{port} "
        f"(ready={ready}"
        + (f", reason={server.app.manifest.reason}" if not ready else "")
        + ")\n")
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
