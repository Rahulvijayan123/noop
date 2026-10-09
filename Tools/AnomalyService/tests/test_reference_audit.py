"""tools/reference_audit.py: lists the stored reference windows the current context rules exclude; --apply removes
exactly those (after a backup) and nothing else."""
import glob
import importlib.util
import os

import numpy as np

from frwhoop_anomaly import features as F
from frwhoop_anomaly.state import UserState

from test_context_hygiene import owner_1007_frame
from test_service import DID, UID

spec = importlib.util.spec_from_file_location(
  "reference_audit", os.path.join(os.path.dirname(__file__), "..", "tools", "reference_audit.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def seed(tmp_path):
  old, _, pdt = owner_1007_frame()
  st = UserState(str(tmp_path), UID, DID)
  st.save_frame(old)                       # the minute cache as the pre-fix service wrote it
  starts = [pdt("19:00"), pdt("20:00"), pdt("23:30"), pdt("01:00", 8)]
  st.append_ref("stub", "rest", np.arange(len(starts) * 5, dtype=float).reshape(len(starts), 5), starts=starts)
  st.append_ref("stub", "rest", np.full((1, 5), 9.0))                     # a row with no recorded start
  return st, pdt


def test_audit_lists_the_1007_late_window_and_changes_nothing(tmp_path, capsys):
  st, pdt = seed(tmp_path)
  before = {p: open(p, "rb").read() for p in glob.glob(os.path.join(st.dir, "*"))}
  res = audit.main(["--state", str(tmp_path)])
  rep = res["users"][0]["files"]["stub/rest"]
  assert rep["rows"] == 5 and rep["not_checked"] == 1
  assert [(e["start"], e["reason"]) for e in rep["excluded"]] == [(pdt("23:30"), "recovery")]
  assert res["users"][0]["sessions"] and '"recovery"' in capsys.readouterr().out
  assert {p: open(p, "rb").read() for p in glob.glob(os.path.join(st.dir, "*"))} == before


def test_apply_removes_only_the_excluded_rows_after_a_backup(tmp_path):
  st, pdt = seed(tmp_path)
  ref0, t0 = st.load_ref("stub", "rest"), st.load_ref_starts("stub", "rest")
  res = audit.main(["--state", str(tmp_path), "--user", UID, "--device", DID, "--apply"])
  assert res["users"][0]["rewritten"] == ["stub/rest"]
  ref, t = st.load_ref("stub", "rest"), st.load_ref_starts("stub", "rest")
  assert len(ref) == 4 and pdt("23:30") not in t.tolist()
  keep = [k for k in range(5) if k != 2]
  assert np.array_equal(ref, ref0[keep]) and np.array_equal(t, t0[keep], equal_nan=True)
  backups = glob.glob(os.path.join(st.dir, "ref-backup-*", "ref_stub_rest*.npy"))
  assert len(backups) == 2
  assert audit.main(["--state", str(tmp_path)])["users"][0]["files"]["stub/rest"]["excluded"] == []


def test_recontext_heals_a_pre_fix_cache_and_is_idempotent():
  old, new, pdt = owner_1007_frame()
  healed = F.recontext(old)
  # The same minutes count as rest as under the fixed merge (a stored "recovery" may stay where the fixed merge
  # says "unknown": both are not rest).
  restful = lambda f: [c in ("still", "asleep") for c in f.context]
  assert restful(healed) == restful(new)
  assert sum(a != b for a, b in zip(healed.context, new.context)) < 10
  assert list(F.recontext(new).context) == list(new.context)
  gap = F.MinuteFrame(minutes=np.arange(3) * 60, data={k: np.full(3, np.nan) for k in old.data},
                      context=np.array(["unknown"] * 3, dtype=object), family=None, counters={})
  assert list(F.recontext(gap).context) == ["unknown"] * 3                # a cache gap is not "off"
