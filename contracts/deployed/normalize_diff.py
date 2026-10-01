#!/usr/bin/env python3
"""Reproducible normalizer for the FRWHOOP deployed-vs-pinned RPC diff.

Compares the LIVE deployed definitions (captured from pg_get_functiondef into
contracts/deployed/public__<name>.sql) against the LATEST definition in the pinned
Whoop-Nara supabase migrations.

Normalization (see README section in DEPLOYED_VS_PINNED.md):
  * body: strip SQL comments, collapse whitespace runs to one space, trim lines
  * header: additionally lowercase, drop "OR REPLACE", normalize NULL::<type> -> null,
    type spellings (timestamptz, float8, varchar), punctuation spacing,
    "SET search_path TO ..." -> "SET search_path=...", strip quotes, drop the default
    "SECURITY INVOKER" (pg_get_functiondef never prints it), and substitute the deployed
    name for rename-created functions.

These are the canonicalization artifacts pg_get_functiondef introduces vs the migration
source; after removing them, the remaining text must match exactly for the function to be
behaviourally IDENTICAL.

Usage:
  python normalize_diff.py [--deployed-dir DIR] [--migrations-dir DIR] [--name NAME]
Runs all target RPCs by default. Emits verdicts and writes diffs/<name>.diff.
"""

import argparse
import difflib
import os
import re
import sys

TARGETS = """noop_commit_push_projection, noop_commit_push_projection_intake_core, noop_apply_projection_rows,
noop_project_append_batch, noop_project_append_batch_core, noop_projection_target, noop_projection_coordinate,
noop_claim_projection_debt, noop_fail_projection_debt, noop_commit_object_receipt, noop_claim_object_verification,
noop_finish_object_verification, noop_reserve_object_manifest, noop_reserve_push_batch, noop_push_save_ack,
noop_register_push_device, scoring_claim_one, scoring_finish_work, engine_publish_legacy_fenced,
claim_scoring_v2, publish_scoring_snapshot_v2, claim_scoring_archive_v2, complete_scoring_archive_v2,
renew_scoring_archive_v2, fail_scoring_archive_v2, engine_ingest_scored, server_scoring_for_day,
scoring_legacy_claim_one, scoring_legacy_seal_snapshot, scoring_legacy_finish_work""".replace("\n", "").split(",")
TARGETS = [t.strip() for t in TARGETS]

# Functions created in the pinned migrations by RENAME of an earlier function (no literal
# `create function public.<name>` ever exists). Their pinned definition is the body of the
# renamed original at rename time.
RENAME_CORES = {
    "noop_commit_push_projection_intake_core": (
        "20260918040000_production_projection_debt.sql", 153,
        "renamed from noop_commit_push_projection (only pre-rename def) at "
        "20260922120000_intake_service_contract.sql:237"),
    "noop_project_append_batch_core": (
        "20260921070000_production_append_stream_compatibility.sql", 130,
        "renamed from noop_project_append_batch (latest pre-rename def) at "
        "20260921111000_wearable_lifecycle.sql:89"),
}


def extract_function_block(mig_path, start_line):
    """Extract one complete SQL statement (CREATE FUNCTION ...) starting at 1-based start_line."""
    with open(mig_path, encoding="utf-8", errors="replace") as f:
        text = "\n".join(f.read().splitlines()[start_line - 1:])
    i, n = 0, len(text)
    state, depth, quote = "normal", 0, None
    while i < n:
        c = text[i]
        if state == "normal":
            if c == "'":
                state, i = "single", i + 1
            elif c == "$":
                m = re.match(r"\$[A-Za-z_0-9]*\$", text[i:])
                if m:
                    state, quote = "dollar", m.group(0)
                    i += len(quote)
                else:
                    i += 1
            elif c == "-" and i + 1 < n and text[i + 1] == "-":
                state, i = "linecomment", i + 2
            elif c == "/" and i + 1 < n and text[i + 1] == "*":
                state, i = "blockcomment", i + 2
            else:
                if c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                elif c == ";" and depth == 0:
                    return text[:i + 1].rstrip()
                i += 1
        elif state == "single":
            if c == "\\":
                i += 2
            elif c == "'" and i + 1 < n and text[i + 1] == "'":
                i += 2
            elif c == "'":
                state = "normal"
                i += 1
            else:
                i += 1
        elif state == "linecomment":
            if c == "\n":
                state = "normal"
            i += 1
        elif state == "blockcomment":
            if c == "*" and i + 1 < n and text[i + 1] == "/":
                state, i = "normal", i + 2
            else:
                i += 1
        elif state == "dollar":
            if c == "$":
                m = re.match(r"\$[A-Za-z_0-9]*\$", text[i:])
                if m and m.group(0) == quote:
                    state, i = "normal", i + len(quote)
                else:
                    i += 1
            else:
                i += 1
    return text.rstrip()


def find_defs(migrations_dir, name):
    """All `create function public.<name>(` definition lines across migrations."""
    pat = re.compile(
        r"create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?" + re.escape(name) + r"\s*\(",
        re.IGNORECASE)
    hits = []
    for fn in sorted(os.listdir(migrations_dir)):
        if not fn.endswith(".sql"):
            continue
        mp = os.path.join(migrations_dir, fn)
        with open(mp, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f, 1):
                if pat.search(line):
                    hits.append((fn, i))
    return hits


def pinned_block(migrations_dir, name):
    """Return (file, line, block, kind, note) for the latest pinned definition."""
    if name in RENAME_CORES:
        fn, ln, note = RENAME_CORES[name]
        mp = os.path.join(migrations_dir, fn)
        return fn, ln, extract_function_block(mp, ln), "rename", note
    hits = find_defs(migrations_dir, name)
    if not hits:
        return None, None, None, "not_found", ""
    fn, ln = sorted(hits)[-1]
    mp = os.path.join(migrations_dir, fn)
    return fn, ln, extract_function_block(mp, ln), "create", f"{len(hits)} definition(s); latest by filename"


def extract_body(sql):
    m = re.search(r"\bAS\s+(\$[A-Za-z_0-9]*\$)", sql, re.IGNORECASE)
    if not m:
        return None
    tag, start = m.group(1), m.end()
    close = sql.find(tag, start)
    if close == -1:
        return None
    return sql[start:close]


def extract_header(sql):
    m = re.search(r"\bAS\s+(\$[A-Za-z_0-9]*\$)", sql, re.IGNORECASE)
    return sql[:m.start()] if m else sql


def norm_ws(sql):
    return " ".join(re.sub(r"\s+", " ", l).rstrip() for l in sql.splitlines() if l.strip())


def strip_comments(sql):
    sql = re.sub(r"--[^\n]*", "", sql)
    return re.sub(r"/\*.*?\*/", "", sql, flags=re.S)


def canonicalize(sql, override_name=None):
    h = norm_ws(strip_comments(extract_header(sql))).lower()
    if override_name:
        h = re.sub(r"\bfunction\s+[\w.]+\s*\(", "function " + override_name + "(", h, count=1)
    h = re.sub(r"\bcreate\s+or\s+replace\s+function\b", "create function", h)
    h = h.replace("timestamp with time zone", "timestamptz")
    h = h.replace("timestamp without time zone", "timestamp")
    h = h.replace("double precision", "float8")
    h = h.replace("character varying", "varchar")
    h = re.sub(r"\(\s+", "(", h)
    h = re.sub(r"\s*,\s*", ",", h)
    h = re.sub(r"\s*=\s*", "=", h)
    h = re.sub(r"\s*:\s*", ":", h)
    h = re.sub(r"\s*\)", ")", h)
    h = re.sub(r"null::\w+", "null", h)
    h = re.sub(r"\bpublic\.", "", h)
    h = re.sub(r"search_path\s+to\s*", "search_path=", h)
    h = h.replace("'pg_catalog','public'", "pg_catalog,public")
    h = re.sub(r"['\"]", "", h)
    h = re.sub(r"\bsecurity\s+invoker\b", "", h)
    h = norm_ws(h)
    b = extract_body(sql)
    b = norm_ws(strip_comments(b)) if b is not None else ""
    return h + "\n" + b


def load_deployed(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return "\n".join(l for l in f.read().splitlines() if not l.startswith("--")).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--deployed-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--migrations-dir",
                    default="/Volumes/External SSD/Nara Whoop App V2/Whoop-Nara/supabase/migrations")
    ap.add_argument("--name", default=None)
    args = ap.parse_args()

    names = [args.name] if args.name else TARGETS
    diffs_dir = os.path.join(args.deployed_dir, "diffs")
    os.makedirs(diffs_dir, exist_ok=True)

    for name in names:
        deployed_path = os.path.join(args.deployed_dir, f"public__{name}.sql")
        deployed = load_deployed(deployed_path)
        pfile, pline, pblock, pkind, pnote = pinned_block(args.migrations_dir, name)
        override = name if name in RENAME_CORES else None
        dc = canonicalize(deployed, override_name=override)
        pc = canonicalize(pblock, override_name=override) if pblock else ""
        verdict = "IDENTICAL" if dc == pc else "DIVERGENT"
        if pkind == "not_found":
            verdict = "NOT_FOUND_IN_PINNED"
        # write diff file (normalized unified diff)
        ud = "\n".join(difflib.unified_diff(pc.splitlines(), dc.splitlines(),
                                            "pinned:" + (pfile or "?"), "deployed", lineterm=""))
        with open(os.path.join(diffs_dir, f"{name}.diff"), "w") as f:
            f.write(f"# normalize_diff.py --name {name}\n")
            f.write(f"# pinned latest def: {pfile or 'NONE'}:{pline or '?'} ({pkind}) {pnote}\n")
            f.write(f"# verdict: {verdict}\n")
            f.write(ud + "\n")
        print(f"{name:45s} {verdict:18s} pinned {pfile}:{pline} ({pkind})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
