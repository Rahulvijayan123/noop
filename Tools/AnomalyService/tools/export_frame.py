"""Export one (user, device)'s minute frame with the service's own features.load, read-only, for tools/replay.py.

  PGPASSWORD=... python -I tools/export_frame.py --conninfo "host=... user=... dbname=postgres port=5432" \
      --user <uuid> --device <uuid> --from 2026-09-20 --out owner.npz

Every statement runs in a READ ONLY transaction (Database.read) and the session itself is set read-only first,
because a pooler may ignore PGOPTIONS. Reads are chunked (12 h) by primary-key range, exactly as the service reads.
The password comes from the environment (libpq PGPASSWORD) and is never printed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from frwhoop_anomaly import features  # noqa: E402
from frwhoop_anomaly.db import Database  # noqa: E402
from frwhoop_anomaly.state import UserState  # noqa: E402


class ReadOnlyDatabase(Database):
  def conn(self):
    fresh = self._conn is None or self._conn.closed or self._conn.broken
    c = super().conn()
    if fresh:
      c.execute("set default_transaction_read_only = on")
      c.execute("set statement_timeout = '60s'")
      assert c.execute("show default_transaction_read_only").fetchone()["default_transaction_read_only"] == "on"
    return c


def main() -> None:
  ap = argparse.ArgumentParser()
  ap.add_argument("--conninfo", required=True)
  ap.add_argument("--sslmode", default="require")
  ap.add_argument("--user", required=True)
  ap.add_argument("--device", required=True)
  ap.add_argument("--from", dest="since", required=True, help="UTC date")
  ap.add_argument("--to", dest="until", default=None, help="UTC date (default: now)")
  ap.add_argument("--chunk_hours", type=int, default=12)
  ap.add_argument("--out", required=True)
  a = ap.parse_args()
  db = ReadOnlyDatabase(a.conninfo, sslmode=a.sslmode)
  lo = int(dt.datetime.fromisoformat(a.since).replace(tzinfo=dt.timezone.utc).timestamp())
  hi = int(dt.datetime.fromisoformat(a.until).replace(tzinfo=dt.timezone.utc).timestamp()) if a.until else int(time.time())
  frame = None
  counters = []
  t = lo
  while t < hi:
    e = min(hi, t + a.chunk_hours * 3600)
    t0 = time.time()
    f = features.load(db, a.user, a.device, t, e)
    frame = UserState.merge(frame, f) if frame is not None else f
    counters.append({"from": t, "to": e, "s": round(time.time() - t0, 1), **{k: v for k, v in f.counters.items()
                                                                            if k != "rr"}, "rr": f.counters.get("rr")})
    print(f"{dt.datetime.fromtimestamp(t, dt.timezone.utc):%m-%d %H:%M} +{a.chunk_hours}h: "
          f"{int(np.sum(f.data['hr_n'] >= 30))} HR min, {counters[-1]['s']} s", flush=True)
    t = e
  db.close()
  arrays = {"minutes": frame.minutes, "context": np.asarray(frame.context).astype(str),
            "family": np.asarray(frame.family or "")}
  for k, v in frame.data.items():
    arrays["d_" + k] = np.asarray(v)
  np.savez_compressed(a.out, **arrays)
  ctx, n = np.unique(np.asarray(frame.context).astype(str), return_counts=True)
  print("saved", a.out, len(frame.minutes), "minutes;", dict(zip(ctx.tolist(), n.tolist())))
  cov = {k: round(float(np.mean(np.isfinite(frame.data[k]))), 3) for k in features.TARGETS + features.COVARIATES}
  print("finite fraction:", cov)


if __name__ == "__main__":
  main()
