"""Offline signature engine: `nara-signatures evaluate ...` on a WhoopStore SQLite file (opened read-only)."""
from __future__ import annotations

import argparse
import collections
import json
import sqlite3
import sys
import time
from pathlib import Path

from . import engine
from .evidence import Evidence, parse_events
from .inject import parse_spec, plant
from .report import clean, validate
from .timeline import load_whoop_sqlite

MAX_DAYS = 120
LOOKBACK_DAYS = 30


def _recording_span(path, device):
  conn = sqlite3.connect("file:" + str(path) + "?mode=ro", uri=True)
  try:
    lo, hi = conn.execute('select min(ts), max(ts) from "hrSample" where "deviceId" = ?', (device,)).fetchone()
  finally:
    conn.close()
  if lo is None:
    raise SystemExit(f"No heart-rate samples for device {device!r}.")
  return float(lo), float(hi) + 60


def evaluate(args):
  t_start = time.perf_counter()
  items = json.loads(Path(args.events).read_text()) if args.events else []
  events = parse_events(items)
  obs = json.loads(Path(args.observations).read_text()) if args.observations else []
  observations = [(float(o["start"]), float(o["end"]), float(o.get("available_at", o["end"]))) for o in obs]
  rec_lo, rec_hi = _recording_span(args.sqlite, args.device)
  hi = rec_hi if args.to is None else float(args.to)
  first = min([e.start for e in events] + [o[0] for o in observations], default=None)
  lo = rec_lo if first is None else max(rec_lo, first - LOOKBACK_DAYS * 86400)
  if args.from_ is not None:
    lo = float(args.from_)
  lo = max(lo, hi - MAX_DAYS * 86400)
  t0 = time.perf_counter()
  tl = load_whoop_sqlite(args.sqlite, args.device, lo, hi, args.tz_offset_s)
  load_s = time.perf_counter() - t0
  truth = None
  type_id = args.type_id
  if args.inject:
    spec = parse_spec(args.inject)
    if type_id:
      spec.type_id = type_id          # planted events belong to the analysed type
    tl, planted, truth = plant(tl, spec, avoid=[(e.start, e.end) for e in events])
    events = events + planted
    type_id = type_id or spec.type_id
  if not type_id:
    counts = collections.Counter(e.type_id for e in events)
    if not counts:
      raise SystemExit("No events: pass --events and/or --inject.")
    type_id = sorted(counts, key=lambda t: (-counts[t], t))[0]
  ev = Evidence(type_id=type_id, events=[e for e in events if e.type_id == type_id],
                other_events=[e for e in events if e.type_id != type_id], observations=observations,
                owner=args.owner)
  incumbent = None if args.incumbent_cutoff is None else {"training_cutoff": float(args.incumbent_cutoff)}
  report, diagnostics, fwd = engine.run(tl, ev, normalization=args.normalization, generated_at=args.generated_at,
                                        forward_eval=not args.no_forward, incumbent=incumbent)
  problems = validate(report)
  out = dict(report)
  out["forward_evaluation"] = clean(fwd) if fwd is not None else None
  diagnostics["timings"]["load_s"] = round(load_s, 3)
  diagnostics["timings"]["cli_total_s"] = round(time.perf_counter() - t_start, 3)
  out["diagnostics"] = diagnostics
  if truth is not None:
    out["injection"] = {"spec": args.inject, "events": truth}
  if problems:
    out["schema_problems"] = problems
  text = json.dumps(out, indent=1, allow_nan=False, ensure_ascii=False)
  if args.out == "-":
    sys.stdout.write(text + "\n")
  else:
    Path(args.out).write_text(text + "\n")
  print(f"status={report['status']} events={report['evidence']['events']} "
        f"days={report['evidence']['event_days']} d={report['detectability']['d']} "
        f"minutes={len(tl)} runtime={diagnostics['timings']['cli_total_s']}s", file=sys.stderr)
  return 1 if problems else 0


def main(argv=None):
  parser = argparse.ArgumentParser(prog="nara-signatures")
  sub = parser.add_subparsers(dest="command", required=True)
  p = sub.add_parser("evaluate", help="run the signature engine on a WhoopStore SQLite recording")
  p.add_argument("--sqlite", required=True, help="WhoopStore whoop.sqlite (opened read-only)")
  p.add_argument("--device", required=True)
  p.add_argument("--events", help="JSON list of {id, type_id, start, end, onset_uncertainty_min}")
  p.add_argument("--observations", help="JSON list of {start, end} observation periods")
  p.add_argument("--type-id", help="event type to analyse (default: the planted type, else the most frequent)")
  p.add_argument("--tz-offset-s", type=int, default=0)
  p.add_argument("--normalization", choices=("raw", "context", "context+response"), default="context")
  p.add_argument("--inject", help="planted positive controls, e.g. 'n=8,hr=12,dur=10,unc=5,seed=1'")
  p.add_argument("--from", dest="from_", type=float)
  p.add_argument("--to", type=float)
  p.add_argument("--owner", default="local")
  p.add_argument("--generated-at", type=int)
  p.add_argument("--no-forward", action="store_true")
  p.add_argument("--incumbent-cutoff", type=float, help="training cutoff of a promoted detector (champion/challenger)")
  p.add_argument("--out", required=True)
  args = parser.parse_args(argv)
  if args.command == "evaluate":
    return evaluate(args)
  return 2


if __name__ == "__main__":
  sys.exit(main())
