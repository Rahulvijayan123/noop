"""Bounded execution for the sidecar: admission, isolated worker processes, budgets.

Every provider computation (``POST /v1/infer``) and every sleep-feature computation
(``POST /v1/sleep-features``) runs in a worker process that belongs to a *lane*. A lane
owns a fixed number of processes; one process runs one job at a time, so the number of
processes is the number of jobs that can be active. Nothing computes on a thread of the
HTTP server.

Why processes: a Python thread cannot be stopped. The previous design joined a daemon
thread with a timeout and answered ``timeout`` while the thread kept computing, so
repeated overruns piled up live threads and CPU without bound. A process can be
terminated, so a slot is given back only when its job has finished or its process has
been terminated AND reaped.

Rules this module enforces:

* **Admission.** A request takes an idle process or waits a short, bounded time for one
  (``queue_wait_ms``; longer, ``start_wait_ms``, only while a process is still warming
  up). At most ``max_waiting`` requests wait per lane. Anything beyond that is answered
  at once with :class:`Busy` (HTTP 429 ``busy`` + ``Retry-After``).
* **Budget.** The handler waits for the result until the job's budget. On overrun the
  process gets SIGTERM at once; the lane supervisor waits ``kill_grace_ms``, sends
  SIGKILL if it is still alive, reaps it, starts a replacement and only then makes the
  slot available again. The HTTP handler never waits for the replacement.
* **Warm processes.** A process imports and constructs its registry (or the sleep-feature
  code) once, calls every provider's ``readiness()`` once (which loads checkpoints), and
  only then reports ``hello``. Requests never pay an import or a model load.
* **Math threads.** Each process is started with the BLAS/OpenMP/numexpr thread variables
  set before the interpreter imports anything, and caps torch (and TensorFlow, when it is
  loaded) after warm-up.

The parent talks to a process over a private ``socketpair``: length-prefixed pickle
frames between a parent and the child it started from its own code, never a network
socket.
"""

from __future__ import annotations

import atexit
import math
import os
import pickle
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import traceback
import weakref
from dataclasses import dataclass
from typing import Any, Callable, Mapping

EXECUTION_SCHEMA = "sidecar-execution/1"

#: Library thread variables set in every worker process before it imports anything.
MATH_THREAD_ENV: tuple[str, ...] = (
    "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS",
    "NUMEXPR_MAX_THREADS", "VECLIB_MAXIMUM_THREADS", "BLIS_NUM_THREADS", "NUMBA_NUM_THREADS",
    "TF_NUM_INTRAOP_THREADS", "TF_NUM_INTEROP_THREADS",
)

LANE_INFER = "infer"
LANE_SLEEP_FEATURES = "sleep_features"

_FRAME_HEADER = struct.Struct("!Q")
#: A frame larger than this is a protocol fault, not a payload (the largest real frame is
#: a parsed sleep-features request, a few MB).
MAX_FRAME_BYTES = 256 * 1024 * 1024


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------


def _env_int(env: Mapping[str, str], name: str, default: int, low: int, high: int) -> int:
    raw = (env.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        sys.stderr.write(f"frwhoop-inference: ignoring {name}={raw!r} (not an integer); "
                         f"using {default}\n")
        return default
    clamped = min(high, max(low, value))
    if clamped != value:
        sys.stderr.write(f"frwhoop-inference: {name}={value} is outside [{low}, {high}]; "
                         f"using {clamped}\n")
    return clamped


@dataclass(frozen=True)
class LaneConfig:
    """Admission and process limits for one lane."""

    name: str
    #: Worker processes == jobs that can be active at once.
    workers: int
    #: Requests allowed to wait for a busy lane; more are answered ``busy`` at once.
    max_waiting: int
    #: How long a waiting request waits for a busy worker before ``busy``.
    queue_wait_ms: int
    #: How long a waiting request waits while a worker is still warming up.
    start_wait_ms: int
    #: A worker that has not reported ``hello`` by then is killed and started again.
    start_timeout_ms: int
    #: SIGTERM -> SIGKILL grace when a job overruns its budget.
    kill_grace_ms: int


@dataclass(frozen=True)
class ExecutionConfig:
    """Every execution limit of the sidecar, read once at startup."""

    infer: LaneConfig
    sleep_features: LaneConfig
    #: Compute budget of one sleep-features request (the watchdog the degraded
    #: ``timeout`` document reports).
    sleep_features_budget_ms: int
    #: Threads each worker's numerical libraries may use.
    math_threads: int
    #: HTTP handler threads (each serves one connection at a time).
    http_threads: int
    #: Accepted connections that may queue for a handler thread; beyond it a connection
    #: gets an immediate ``busy`` answer and is closed.
    http_backlog: int
    #: Idle keep-alive / slow-client read timeout per connection.
    http_idle_timeout_s: int

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "ExecutionConfig":
        """Defaults chosen for the 4 vCPU / 8 GB Droplet the sidecar shares with the worker
        (docs/model-integration/runtime-bounds.md, "Limits chosen"): one warm process per
        lane keeps the cgroup well under ``MemoryHigh=2G`` and two single-threaded jobs fit
        ``CPUQuota=150%``."""
        env = os.environ if env is None else env
        from .features import BUDGET_MS as FEATURES_BUDGET_MS

        start_wait = _env_int(env, "FRWHOOP_INFERENCE_START_WAIT_MS", 30_000, 0, 120_000)
        start_timeout = _env_int(env, "FRWHOOP_INFERENCE_START_TIMEOUT_MS", 180_000, 1_000, 600_000)
        kill_grace = _env_int(env, "FRWHOOP_INFERENCE_KILL_GRACE_MS", 1_000, 50, 10_000)
        infer = LaneConfig(
            name=LANE_INFER,
            workers=_env_int(env, "FRWHOOP_INFERENCE_MAX_ACTIVE", 1, 1, 8),
            max_waiting=_env_int(env, "FRWHOOP_INFERENCE_MAX_WAITING", 2, 0, 32),
            queue_wait_ms=_env_int(env, "FRWHOOP_INFERENCE_QUEUE_WAIT_MS", 250, 0, 5_000),
            start_wait_ms=start_wait, start_timeout_ms=start_timeout, kill_grace_ms=kill_grace)
        features = LaneConfig(
            name=LANE_SLEEP_FEATURES,
            workers=_env_int(env, "FRWHOOP_SLEEP_FEATURES_MAX_ACTIVE", 1, 1, 8),
            max_waiting=_env_int(env, "FRWHOOP_SLEEP_FEATURES_MAX_WAITING", 1, 0, 32),
            queue_wait_ms=_env_int(env, "FRWHOOP_SLEEP_FEATURES_QUEUE_WAIT_MS", 250, 0, 5_000),
            start_wait_ms=start_wait, start_timeout_ms=start_timeout, kill_grace_ms=kill_grace)
        return cls(
            infer=infer,
            sleep_features=features,
            sleep_features_budget_ms=_env_int(env, "FRWHOOP_SLEEP_FEATURES_BUDGET_MS",
                                              FEATURES_BUDGET_MS, 100, 120_000),
            math_threads=_env_int(env, "FRWHOOP_INFERENCE_MATH_THREADS", 1, 1, 4),
            http_threads=_env_int(env, "FRWHOOP_INFERENCE_HTTP_THREADS", 12, 2, 64),
            http_backlog=_env_int(env, "FRWHOOP_INFERENCE_HTTP_BACKLOG", 16, 0, 256),
            http_idle_timeout_s=_env_int(env, "FRWHOOP_INFERENCE_HTTP_IDLE_TIMEOUT_S", 60, 1, 600))

    def to_wire(self) -> dict[str, Any]:
        return {
            "math_threads": self.math_threads,
            "http": {"threads": self.http_threads, "backlog": self.http_backlog,
                     "idle_timeout_s": self.http_idle_timeout_s},
            "sleep_features_budget_ms": self.sleep_features_budget_ms,
        }


# --------------------------------------------------------------------------
# Frames
# --------------------------------------------------------------------------


class FrameError(Exception):
    """The peer closed the socket, stalled past the deadline, or sent garbage."""


class FrameDeadline(FrameError):
    """The deadline passed before the whole frame moved."""


def encode_frame(obj: Any) -> bytes:
    """Pickle ``obj`` into one frame; raises (pickling error, ``ValueError``) when it cannot."""
    data = pickle.dumps(obj, protocol=pickle.HIGHEST_PROTOCOL)
    if len(data) > MAX_FRAME_BYTES:
        raise ValueError(f"frame of {len(data)} bytes exceeds {MAX_FRAME_BYTES}")
    return _FRAME_HEADER.pack(len(data)) + data


def send_frame(sock: socket.socket, obj: Any, deadline: float | None = None) -> None:
    send_encoded(sock, encode_frame(obj), deadline)


def send_encoded(sock: socket.socket, frame: bytes, deadline: float | None = None) -> None:
    _set_deadline(sock, deadline)
    try:
        sock.sendall(frame)
    except (socket.timeout, TimeoutError) as exc:
        raise FrameDeadline("send timed out") from exc
    except OSError as exc:
        raise FrameError(f"send failed: {exc}") from exc


def recv_frame(sock: socket.socket, deadline: float | None = None) -> Any:
    """One frame, or raise :class:`FrameError` (EOF, deadline, oversized frame)."""
    header = _recv_exact(sock, _FRAME_HEADER.size, deadline)
    (length,) = _FRAME_HEADER.unpack(header)
    if length > MAX_FRAME_BYTES:
        raise FrameError(f"peer announced a {length}-byte frame")
    payload = _recv_exact(sock, length, deadline)
    try:
        return pickle.loads(payload)
    except Exception as exc:  # noqa: BLE001 - a frame that does not decode is a protocol fault
        raise FrameError(f"undecodable frame: {type(exc).__name__}: {exc}") from exc


def _set_deadline(sock: socket.socket, deadline: float | None) -> None:
    if deadline is None:
        sock.settimeout(None)
    else:
        sock.settimeout(max(0.001, deadline - time.monotonic()))


def _recv_exact(sock: socket.socket, length: int, deadline: float | None) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining > 0:
        _set_deadline(sock, deadline)
        try:
            chunk = sock.recv(min(remaining, 1 << 20))
        except (socket.timeout, TimeoutError) as exc:
            raise FrameDeadline("deadline") from exc
        except OSError as exc:
            raise FrameError(f"recv failed: {exc}") from exc
        if not chunk:
            raise FrameError("eof")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


# --------------------------------------------------------------------------
# Parent side: lanes and their worker processes
# --------------------------------------------------------------------------


class Busy(Exception):
    """The lane cannot admit the request now. Not a result: the caller comes back later."""

    def __init__(self, lane: str, message: str, retry_after_s: int):
        super().__init__(message)
        self.lane = lane
        self.message = message
        self.retry_after_s = max(1, int(retry_after_s))


@dataclass
class JobOutcome:
    """What happened to one job.

    ``status`` is ``ok`` (``value`` holds the result), ``error`` (the job raised; ``error``
    holds the class and message), ``timeout`` (budget overrun; the process was terminated)
    or ``crashed`` (the process died while computing)."""

    status: str
    value: Any = None
    error: dict[str, Any] | None = None
    runtime_ms: int = 0
    worker_pid: int | None = None
    detail: str | None = None


def _utc(ts: float | None) -> str | None:
    if ts is None:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


class _Worker:
    """One slot of a lane and the process currently filling it."""

    def __init__(self, index: int):
        self.index = index
        # new | starting | idle | busy | stopping | backoff | closed
        self.state = "new"
        self.proc: subprocess.Popen | None = None
        self.sock: socket.socket | None = None
        self.pid: int | None = None
        self.jobs = 0
        self.job_deadline: float | None = None
        self.stop_reason: str | None = None
        self.stop_requested_at: float | None = None
        self.next_start_at = 0.0
        self.start_failures_in_row = 0
        self.started_wall: float | None = None
        self.ready_wall: float | None = None
        self.startup_ms: int | None = None
        self.hello: dict[str, Any] = {}

    def to_wire(self) -> dict[str, Any]:
        return {
            "index": self.index,
            "state": self.state,
            "pid": self.pid,
            "jobs": self.jobs,
            "started_at_utc": _utc(self.started_wall),
            "ready_at_utc": _utc(self.ready_wall),
            "startup_ms": self.startup_ms,
            "rss_kb_at_ready": self.hello.get("rss_kb"),
            "framework_threads": self.hello.get("framework_threads"),
        }


_LIVE_LANES: "weakref.WeakSet[WorkerLane]" = weakref.WeakSet()


@atexit.register
def _close_live_lanes() -> None:  # pragma: no cover - interpreter shutdown
    for lane in list(_LIVE_LANES):
        try:
            lane.close()
        except Exception:  # noqa: BLE001 - best effort at exit
            pass


class WorkerLane:
    """A fixed set of warm worker processes behind bounded admission.

    ``init_payload`` returns the first frame a new process receives (what to build and
    warm). ``on_hello`` is called, outside the lane lock, every time a process reports
    ready, with its ``hello`` dict (the infer lane uses it to publish provider readiness).
    """

    def __init__(self, config: LaneConfig, *, init_payload: Callable[[], dict[str, Any]],
                 math_threads: int = 1, on_hello: Callable[[dict[str, Any]], None] | None = None,
                 python: str | None = None, extra_env: Mapping[str, str] | None = None):
        self.config = config
        self._init_payload = init_payload
        self._math_threads = int(math_threads)
        self._on_hello = on_hello
        self._python = python or sys.executable
        self._extra_env = dict(extra_env or {})
        self._cond = threading.Condition()
        self._workers = [_Worker(i) for i in range(int(config.workers))]
        self._waiting = 0
        self._closed = False
        self._started = False
        self._supervisor: threading.Thread | None = None
        self._job_seq = 0
        self._ever_ready = False
        self._last_startup_s: float | None = None
        self.counters: dict[str, int] = {
            "admitted": 0, "completed": 0, "errors": 0, "busy_rejections": 0,
            "timeouts": 0, "terminations": 0, "kills": 0, "crashes": 0, "respawns": 0,
            "starts": 0, "start_failures": 0, "client_gone": 0,
        }
        self.last_start_error: str | None = None
        self.last_exit: str | None = None
        _LIVE_LANES.add(self)

    # -- lifecycle --------------------------------------------------------------

    def start(self) -> None:
        """Start every process now (warm-up runs in the background)."""
        with self._cond:
            self._ensure_started_locked()

    def _ensure_started_locked(self) -> None:
        if self._started or self._closed:
            return
        self._started = True
        self._supervisor = threading.Thread(target=self._supervise, name=f"lane-{self.config.name}",
                                            daemon=True)
        self._supervisor.start()

    def close(self) -> None:
        """Refuse new work, wake every waiter, and terminate and reap every process."""
        with self._cond:
            if self._closed:
                return
            self._closed = True
            self._cond.notify_all()
            workers = list(self._workers)
        for worker in workers:
            self._terminate_and_reap(worker, reason="shutdown", count=False)
            with self._cond:
                worker.state = "closed"
        supervisor = self._supervisor
        if supervisor is not None and supervisor is not threading.current_thread():
            supervisor.join(timeout=5.0)

    def wait_ready(self, timeout: float) -> bool:
        """Start the lane and block until every process is warm (tests and tools)."""
        deadline = time.monotonic() + timeout
        with self._cond:
            self._ensure_started_locked()
            while not all(w.state in ("idle", "busy") for w in self._workers):
                remaining = deadline - time.monotonic()
                if remaining <= 0 or self._closed:
                    return False
                self._cond.wait(min(remaining, 0.25))
            return True

    # -- admission and jobs -------------------------------------------------------

    def run(self, kind: str, payload: Any, budget_s: float,
            still_wanted: Callable[[], bool] | None = None) -> JobOutcome:
        """Run one job under ``budget_s``. Raises :class:`Busy` when not admitted.

        ``still_wanted`` is asked once, and only when the request had to wait: a client that
        gave up while it waited gets its slot handed straight back instead of a computation
        nobody reads."""
        worker, waited = self._acquire()
        if waited and still_wanted is not None and not still_wanted():
            # The client hung up while it waited: give the slot straight back.
            with self._cond:
                self.counters["client_gone"] += 1
            self._release(worker)
            return JobOutcome(status="error", error={"kind": "client_gone"}, detail="client_gone")
        with self._cond:
            self._job_seq += 1
            job_id = self._job_seq
            started = time.monotonic()
            deadline = started + max(0.001, float(budget_s))
            worker.job_deadline = deadline
            sock, pid = worker.sock, worker.pid
            self.counters["admitted"] += 1
        try:
            send_frame(sock, ("job", job_id, kind, payload), deadline=deadline)
            while True:
                frame = recv_frame(sock, deadline=deadline)
                if isinstance(frame, tuple) and len(frame) == 3 and frame[0] == "result" \
                        and frame[1] == job_id:
                    break
                raise FrameError(f"unexpected frame {type(frame).__name__}")
        except FrameError as exc:
            runtime_ms = int(round((time.monotonic() - started) * 1000))
            if isinstance(exc, FrameDeadline) or time.monotonic() >= deadline:
                with self._cond:
                    self.counters["timeouts"] += 1
                self._begin_stop(worker, "timeout")
                return JobOutcome(status="timeout", runtime_ms=runtime_ms, worker_pid=pid,
                                  detail="budget_exceeded")
            with self._cond:
                self.counters["crashes"] += 1
            self._begin_stop(worker, f"crashed: {exc}")
            return JobOutcome(status="crashed", runtime_ms=runtime_ms, worker_pid=pid,
                              detail=f"worker process stopped answering ({exc})")
        reply = frame[2] if isinstance(frame[2], dict) else {}
        runtime_ms = int(round((time.monotonic() - started) * 1000))
        self._release(worker)
        if reply.get("ok"):
            with self._cond:
                self.counters["completed"] += 1
            return JobOutcome(status="ok", value=reply.get("value"), runtime_ms=runtime_ms,
                              worker_pid=pid)
        with self._cond:
            self.counters["errors"] += 1
        return JobOutcome(status="error", error=dict(reply.get("error") or {}),
                          runtime_ms=runtime_ms, worker_pid=pid)

    def _acquire(self) -> tuple[_Worker, bool]:
        arrival = time.monotonic()
        with self._cond:
            if self._closed:
                raise Busy(self.config.name, f"{self.config.name} lane is shutting down", 5)
            self._ensure_started_locked()
            worker = self._take_idle_locked()
            if worker is not None:
                return worker, False
            if self._waiting >= self.config.max_waiting:
                self.counters["busy_rejections"] += 1
                raise self._busy_locked("all workers are busy and the wait queue is full")
            self._waiting += 1
            try:
                while True:
                    limit = self.config.queue_wait_ms / 1000.0
                    if self._warming_locked():
                        limit = max(limit, self.config.start_wait_ms / 1000.0)
                    remaining = arrival + limit - time.monotonic()
                    if remaining <= 0:
                        self.counters["busy_rejections"] += 1
                        raise self._busy_locked("no worker became free within the wait bound")
                    self._cond.wait(remaining)
                    if self._closed:
                        raise Busy(self.config.name, f"{self.config.name} lane is shutting down", 5)
                    worker = self._take_idle_locked()
                    if worker is not None:
                        return worker, True
            finally:
                self._waiting -= 1

    def _take_idle_locked(self) -> _Worker | None:
        for worker in self._workers:
            if worker.state == "idle":
                worker.state = "busy"
                return worker
        return None

    def _warming_locked(self) -> bool:
        """True only before this lane's first worker has ever been ready: the longer
        ``start_wait_ms`` covers the initial warm-up, never a replacement after an overrun
        (a caller then hears ``busy`` with a ``Retry-After`` of the last start time)."""
        return not self._ever_ready

    def _busy_locked(self, why: str) -> Busy:
        active = sum(1 for w in self._workers if w.state == "busy")
        message = (f"{self.config.name} lane busy: {why} (capacity {len(self._workers)}, "
                   f"active {active}, waiting {self._waiting})")
        return Busy(self.config.name, message, self._retry_after_locked())

    def _retry_after_locked(self) -> int:
        now = time.monotonic()
        if any(w.state in ("new", "starting", "backoff", "stopping") for w in self._workers):
            return min(60, max(1, int(math.ceil(self._last_startup_s or 5.0))))
        deadlines = [w.job_deadline - now for w in self._workers
                     if w.state == "busy" and w.job_deadline is not None]
        if deadlines:
            return min(60, max(1, int(math.ceil(min(deadlines)))))
        return 1

    def _release(self, worker: _Worker) -> None:
        with self._cond:
            worker.job_deadline = None
            if worker.state == "busy":
                worker.jobs += 1
                worker.state = "idle"
            self._cond.notify_all()

    def _begin_stop(self, worker: _Worker, reason: str) -> None:
        """Take the slot out of service and send SIGTERM now; the supervisor finishes it."""
        with self._cond:
            worker.state = "stopping"
            worker.stop_reason = reason
            worker.stop_requested_at = time.monotonic()
            worker.job_deadline = None
            proc = worker.proc
            self._cond.notify_all()
        if proc is not None and proc.poll() is None:
            try:
                proc.send_signal(signal.SIGTERM)
            except OSError:
                pass

    # -- supervision ----------------------------------------------------------------

    def _supervise(self) -> None:
        while True:
            with self._cond:
                if self._closed:
                    return
                action: tuple[str, _Worker] | None = None
                now = time.monotonic()
                for worker in self._workers:
                    if worker.state == "stopping":
                        action = ("recycle", worker)
                        break
                    if worker.state in ("new", "backoff") and now >= worker.next_start_at:
                        worker.state = "starting"
                        action = ("start", worker)
                        break
                    if worker.state == "idle" and worker.proc is not None \
                            and worker.proc.poll() is not None:
                        # Died between jobs (OOM kill, a stray signal): replace it.
                        worker.state = "stopping"
                        worker.stop_reason = f"exited while idle ({_exit_text(worker.proc)})"
                        self.counters["crashes"] += 1
                        action = ("recycle", worker)
                        break
                if action is None:
                    self._cond.wait(0.5)
                    continue
            kind, worker = action
            if kind == "recycle":
                self._terminate_and_reap(worker, reason=worker.stop_reason or "recycle", count=True)
                with self._cond:
                    if self._closed:
                        worker.state = "closed"
                        return
                    self.counters["respawns"] += 1
                    worker.state = "starting"
            self._start_worker(worker)

    def _terminate_and_reap(self, worker: _Worker, *, reason: str, count: bool) -> None:
        """SIGTERM, ``kill_grace_ms``, SIGKILL, reap. Returns only once the process is gone."""
        proc = worker.proc
        if proc is not None:
            grace = self.config.kill_grace_ms / 1000.0
            if proc.poll() is None:
                try:
                    proc.send_signal(signal.SIGTERM)
                except OSError:
                    pass
                if count:
                    with self._cond:
                        self.counters["terminations"] += 1
                started = worker.stop_requested_at or time.monotonic()
                try:
                    proc.wait(timeout=max(0.0, started + grace - time.monotonic()))
                except subprocess.TimeoutExpired:
                    try:
                        proc.kill()
                    except OSError:
                        pass
                    if count:
                        with self._cond:
                            self.counters["kills"] += 1
                    while True:
                        try:
                            proc.wait(timeout=5.0)
                            break
                        except subprocess.TimeoutExpired:
                            # Unkillable for now (uninterruptible sleep): the slot stays out of
                            # service until the kernel lets the process go.
                            sys.stderr.write(f"frwhoop-inference: {self.config.name} worker "
                                             f"pid={proc.pid} not reaped yet after SIGKILL\n")
            else:
                proc.wait()
            exit_text = _exit_text(proc)
            with self._cond:
                self.last_exit = f"pid={proc.pid} {exit_text} reason={reason}"
            if count:
                sys.stderr.write(f"frwhoop-inference: {self.config.name} worker pid={proc.pid} "
                                 f"stopped ({reason}; {exit_text})\n")
        if worker.sock is not None:
            try:
                worker.sock.close()
            except OSError:
                pass
        with self._cond:
            worker.proc = None
            worker.sock = None
            worker.pid = None
            worker.stop_requested_at = None

    def _child_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env.update(self._extra_env)
        for name in MATH_THREAD_ENV:
            env[name] = str(self._math_threads)
        env.setdefault("KERAS_BACKEND", "torch")
        env["PYTHONUNBUFFERED"] = "1"
        # The package must import before the init frame (which carries sys.path) is read.
        package_parent = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        current = env.get("PYTHONPATH")
        env["PYTHONPATH"] = package_parent + (os.pathsep + current if current else "")
        return env

    def _start_worker(self, worker: _Worker) -> None:
        started = time.monotonic()
        started_wall = time.time()
        proc: subprocess.Popen | None = None
        parent_sock: socket.socket | None = None
        try:
            payload = self._init_payload()
            parent_sock, child_sock = socket.socketpair()
            try:
                proc = subprocess.Popen(
                    [self._python, "-m", "frwhoop_inference.execution", "--worker",
                     str(child_sock.fileno())],
                    pass_fds=(child_sock.fileno(),), env=self._child_env(),
                    stdin=subprocess.DEVNULL, stdout=2, stderr=None,
                    # A terminal SIGINT must not reach the workers; the parent stops them.
                    start_new_session=True, close_fds=True)
            finally:
                child_sock.close()
            with self._cond:
                worker.proc = proc
                worker.pid = proc.pid
                worker.started_wall = started_wall
                self.counters["starts"] += 1
            deadline = started + self.config.start_timeout_ms / 1000.0
            send_frame(parent_sock, ("init", payload), deadline=deadline)
            frame = recv_frame(parent_sock, deadline=deadline)
            if not (isinstance(frame, tuple) and len(frame) == 2 and frame[0] == "hello"
                    and isinstance(frame[1], dict)):
                raise FrameError(f"expected hello, got {type(frame).__name__}")
            hello = frame[1]
            if hello.get("fatal"):
                raise FrameError(f"worker could not warm up: {hello.get('fatal')}")
        except Exception as exc:  # noqa: BLE001 - every startup failure backs off, none is fatal
            failure = f"{type(exc).__name__}: {exc}"
            if proc is not None:
                worker.stop_requested_at = time.monotonic()
                worker.proc = proc
                self._terminate_and_reap(worker, reason=f"start failed: {failure}", count=False)
            elif parent_sock is not None:
                parent_sock.close()
            with self._cond:
                if self._closed:
                    # Shutdown interrupted the start: not a failure worth a retry.
                    worker.state = "closed"
                    self._cond.notify_all()
                    return
                worker.start_failures_in_row += 1
                backoff = min(60.0, 1.0 * (2 ** (worker.start_failures_in_row - 1)))
                worker.next_start_at = time.monotonic() + backoff
                worker.state = "backoff"
                self.counters["start_failures"] += 1
                self.last_start_error = failure[:500]
                self._cond.notify_all()
            sys.stderr.write(f"frwhoop-inference: {self.config.name} worker start failed "
                             f"({failure}); retrying in {backoff:.0f}s\n")
            return
        startup_s = time.monotonic() - started
        with self._cond:
            if self._closed:
                worker.sock = parent_sock
                closing = True
            else:
                closing = False
                worker.sock = parent_sock
                worker.hello = hello
                worker.state = "idle"
                worker.ready_wall = time.time()
                worker.startup_ms = int(round(startup_s * 1000))
                worker.start_failures_in_row = 0
                self._last_startup_s = startup_s
                self._ever_ready = True
                self._cond.notify_all()
        if closing:
            self._terminate_and_reap(worker, reason="shutdown", count=False)
            return
        sys.stderr.write(f"frwhoop-inference: {self.config.name} worker pid={worker.pid} ready "
                         f"in {startup_s:.1f}s (rss_kb={hello.get('rss_kb')})\n")
        if self._on_hello is not None:
            try:
                self._on_hello(hello)
            except Exception as exc:  # noqa: BLE001 - a callback bug must not stop supervision
                sys.stderr.write(f"frwhoop-inference: on_hello failed: {exc}\n")

    # -- observation --------------------------------------------------------------------

    def snapshot(self) -> dict[str, Any]:
        with self._cond:
            states = [w.state for w in self._workers]
            return {
                "capacity": len(self._workers),
                "ready": sum(1 for s in states if s in ("idle", "busy")),
                "idle": states.count("idle"),
                "active": states.count("busy"),
                "starting": sum(1 for s in states if s in ("new", "starting", "backoff")),
                "stopping": states.count("stopping"),
                "waiting": self._waiting,
                "max_waiting": self.config.max_waiting,
                "queue_wait_ms": self.config.queue_wait_ms,
                "start_wait_ms": self.config.start_wait_ms,
                "kill_grace_ms": self.config.kill_grace_ms,
                "started": self._started,
                "closed": self._closed,
                "counters": dict(self.counters),
                "last_start_error": self.last_start_error,
                "last_exit": self.last_exit,
                "workers": [w.to_wire() for w in self._workers],
            }

    def worker_pids(self) -> list[int]:
        with self._cond:
            return [w.pid for w in self._workers if w.pid is not None]


def _exit_text(proc: subprocess.Popen) -> str:
    code = proc.returncode
    if code is None:
        return "running"
    if code < 0:
        try:
            return f"signal {signal.Signals(-code).name}"
        except ValueError:
            return f"signal {-code}"
    return f"exit {code}"


# --------------------------------------------------------------------------
# Worker side (``python -m frwhoop_inference.execution --worker FD``)
# --------------------------------------------------------------------------


def _apply_math_thread_env(threads: int) -> None:
    for name in MATH_THREAD_ENV:
        os.environ[name] = str(threads)


def _cap_framework_threads(threads: int) -> dict[str, Any]:
    """Cap the frameworks that keep their own pools; report what is in force.

    Only frameworks that are already loaded are touched: importing one just to cap it
    would cost the memory the cap is meant to save."""
    report: dict[str, Any] = {}
    torch = sys.modules.get("torch")
    if torch is not None:
        try:
            torch.set_num_threads(threads)
        except Exception as exc:  # noqa: BLE001
            report["torch_intra_error"] = str(exc)
        try:
            torch.set_num_interop_threads(threads)
        except Exception as exc:  # noqa: BLE001 - only settable before inter-op work starts
            report["torch_interop_error"] = str(exc)
        try:
            report["torch"] = {"intra_op": int(torch.get_num_threads()),
                               "inter_op": int(torch.get_num_interop_threads())}
        except Exception:  # noqa: BLE001
            pass
    tf = sys.modules.get("tensorflow")
    if tf is not None:
        try:
            tf.config.threading.set_intra_op_parallelism_threads(threads)
            tf.config.threading.set_inter_op_parallelism_threads(threads)
            report["tensorflow"] = {"intra_op": threads, "inter_op": threads}
        except Exception as exc:  # noqa: BLE001 - only settable before TF initialises
            report["tensorflow_error"] = str(exc)
    return report


def _rss_kb() -> int | None:
    """Current resident set size of this process in KiB (peak where current is unknown)."""
    try:
        with open("/proc/self/statm", "r", encoding="ascii") as handle:
            pages = int(handle.read().split()[1])
        return pages * (os.sysconf("SC_PAGE_SIZE") // 1024)
    except (OSError, ValueError, IndexError):
        pass
    try:
        import resource

        peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return int(peak // 1024) if sys.platform == "darwin" else int(peak)
    except Exception:  # noqa: BLE001
        return None


class _InferJobs:
    """``infer`` jobs: one provider call against this process's own warm registry."""

    def __init__(self, registry: Any):
        self.registry = registry

    def warm(self, only: list[str] | None) -> dict[str, list]:
        """Call ``readiness()`` once per provider (this is what loads checkpoints).

        ``only`` limits warm-up to the providers the parent will dispatch; ``None`` warms and
        reports every provider (the parent then adopts this report as its readiness)."""
        readiness: dict[str, list] = {}
        for provider in self.registry.all():
            if only is not None and provider.provider_id not in only:
                continue
            try:
                ready, reason = provider.readiness()
            except Exception as exc:  # noqa: BLE001 - reported, never fatal
                ready, reason = False, f"dependency_missing: {type(exc).__name__}: {exc}"
            readiness[provider.provider_id] = [bool(ready), reason]
        return readiness

    def run(self, kind: str, payload: Mapping[str, Any]) -> Any:
        if kind != LANE_INFER:
            raise ValueError(f"infer worker cannot run {kind!r} jobs")
        provider = self.registry.get(payload["provider_id"])
        if provider is None:
            raise LookupError(f"provider {payload['provider_id']!r} is not in the worker registry")
        return provider.infer(payload["request"])


#: The sleep-features entry point a worker calls: ``compute(request, budget_ms=...)``.
DEFAULT_SLEEP_FEATURES_COMPUTE = "frwhoop_inference.features.compute:compute"


def _resolve(ref: str) -> Callable[..., Any]:
    module_name, _, attribute = ref.partition(":")
    if not module_name or not attribute:
        raise ValueError(f"expected 'module:callable', got {ref!r}")
    import importlib

    target: Any = importlib.import_module(module_name)
    for part in attribute.split("."):
        target = getattr(target, part)
    if not callable(target):
        raise TypeError(f"{ref!r} is not callable")
    return target


class _SleepFeatureJobs:
    """``sleep_features`` jobs: the deterministic enrichment document."""

    def __init__(self, budget_ms: int, compute_ref: str = DEFAULT_SLEEP_FEATURES_COMPUTE):
        self._compute = _resolve(compute_ref)
        self.budget_ms = int(budget_ms)

    def warm(self, only: list[str] | None) -> dict[str, list]:
        return {}

    def run(self, kind: str, payload: Mapping[str, Any]) -> Any:
        if kind != LANE_SLEEP_FEATURES:
            raise ValueError(f"sleep-features worker cannot run {kind!r} jobs")
        return self._compute(payload["request"], budget_ms=self.budget_ms)


def _error_reply(exc: BaseException) -> dict[str, Any]:
    from .contract import ContractError

    if isinstance(exc, ContractError):
        return {"kind": "contract", "code": exc.code, "message": exc.message,
                "http_status": exc.http_status, "field": exc.field}
    return {"kind": "exception", "type": type(exc).__name__, "message": str(exc)[:2000],
            "traceback": traceback.format_exc()[-4000:]}


def worker_main(fd: int) -> int:
    sock = socket.socket(fileno=fd)
    try:
        frame = recv_frame(sock)
    except FrameError:
        return 0
    if not (isinstance(frame, tuple) and len(frame) == 2 and frame[0] == "init"):
        return 2
    init = frame[1]
    started = time.monotonic()
    threads = int(init.get("math_threads") or 1)
    _apply_math_thread_env(threads)
    for entry in reversed(list(init.get("sys_path") or [])):
        if entry not in sys.path:
            sys.path.insert(0, entry)
    kind = init.get("kind")
    try:
        if kind == LANE_INFER:
            jobs: Any = _InferJobs(pickle.loads(init["registry"]))
        elif kind == LANE_SLEEP_FEATURES:
            jobs = _SleepFeatureJobs(init.get("budget_ms") or 3000,
                                     init.get("compute") or DEFAULT_SLEEP_FEATURES_COMPUTE)
        else:
            raise ValueError(f"unknown lane {kind!r}")
        warm = init.get("warm_providers")
        readiness = jobs.warm(None if warm is None else list(warm))
    except Exception as exc:  # noqa: BLE001 - reported to the parent, which backs off
        try:
            send_frame(sock, ("hello", {"pid": os.getpid(), "kind": kind,
                                        "fatal": f"{type(exc).__name__}: {exc}"[:1000]}))
        except FrameError:
            pass
        return 3
    hello = {
        "pid": os.getpid(),
        "kind": kind,
        "readiness": readiness,
        "startup_ms": int(round((time.monotonic() - started) * 1000)),
        "rss_kb": _rss_kb(),
        "python": sys.version.split()[0],
        "math_threads": {name: os.environ.get(name) for name in MATH_THREAD_ENV},
        "framework_threads": _cap_framework_threads(threads),
    }
    send_frame(sock, ("hello", hello))
    while True:
        try:
            frame = recv_frame(sock)
        except FrameError:
            return 0  # the parent is gone (or shutting down): nothing left to serve
        if not isinstance(frame, tuple) or not frame:
            return 2
        if frame[0] == "stop":
            return 0
        if frame[0] != "job" or len(frame) != 4:
            return 2
        _, job_id, job_kind, payload = frame
        try:
            reply: dict[str, Any] = {"ok": True, "value": jobs.run(job_kind, payload)}
        except Exception as exc:  # noqa: BLE001 - a provider fault is a reply, not a crash
            reply = {"ok": False, "error": _error_reply(exc)}
        try:
            encoded = encode_frame(("result", job_id, reply))
        except Exception as exc:  # noqa: BLE001 - an unsendable result is the job's fault
            encoded = encode_frame(("result", job_id, {"ok": False, "error": _error_reply(exc)}))
        try:
            send_encoded(sock, encoded)
        except FrameError:
            return 0  # the parent is gone


def _main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] != "--worker":
        sys.stderr.write("usage: python -m frwhoop_inference.execution --worker FD\n")
        return 2
    return worker_main(int(argv[1]))


if __name__ == "__main__":  # pragma: no cover - exercised through real worker processes
    raise SystemExit(_main(sys.argv[1:]))
