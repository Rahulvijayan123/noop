#!/usr/bin/env python
"""Bind the candidate-write RPC EXACTLY as the Swift worker binds it.

Two halves, both taken from
``Tools/CloudWorker/Sources/frwhoop-worker/CandidateStage.swift``:

1. SQL TEXT. The ``PhysiologyCandidateSQL.recordCandidate`` block is extracted
   VERBATIM from the Swift source at run time (between the ``static let
   recordCandidate = \"\"\"`` marker and the closing ``\"\"\"``), so the statement
   this script executes is the statement the worker compiles. If the Swift text
   changes, this script executes the new text; if the placeholder count or the
   NULL-encoding pattern changes, the script fails instead of silently binding
   something else.

2. PARAMETER ENCODING. ``PhysiologyCandidateSQL.recordCandidateParameters``
   encodes all 23 parameters as C strings, because ``PostgresClient`` sends every
   parameter as a zero-terminated C string and therefore cannot express SQL NULL.
   "Absent" is therefore the EMPTY STRING, and the SQL text's ``nullif($N::text,'')``
   turns it into a real SQL NULL while the call is bound. That is reproduced here:
   an absent optional value becomes ``''``, never ``NULL``. The exception is
   ``p_dependency_versions`` ($15), which must stay a jsonb OBJECT (the migration
   raises ``invalid_candidate_dependencies`` for NULL), so it is never nullif'd and
   is always encoded as at least ``{}``.

JSON encoding follows Swift's ``JSONEncoder`` with ``outputFormatting =
[.sortedKeys]``, including its escaping of the solidus (``nk/0.2.13`` ->
``nk\\/0.2.13``). Postgres parses the escaped form identically; mirroring it proves
the escaped payload survives the round trip.

Usage
-----
Build the record from a real sidecar response (mirrors ``CandidateStage.buildRecord``
+ ``recordCandidateParameters``) and write the bound SQL:

    python3 scripts/swift_record_call.py \
        --swift-source Tools/CloudWorker/Sources/frwhoop-worker/CandidateStage.swift \
        --from-response response.json \
        --user-id <uuid> --device-id <uuid> --period-day 2026-09-30 \
        --interval-start 2026-09-30T20:25:40Z --interval-end 2026-09-30T20:28:39Z \
        --input-revision 3 --provider-id production.runs.v1 \
        --provider-version 1.0.0 --config-version cfg-1 \
        --input-rows 60 --deduped-rows 60 \
        --override status=withheld --override withheldReason=insufficient_coverage \
        --out call.sql

Diagnostics mode (show the extracted SQL and the 23 encoded parameters, bind nothing):

    python3 scripts/swift_record_call.py --swift-source ... --dump
"""

from __future__ import annotations

import argparse
import json
import re
import sys

SQL_MARKER = "static let recordCandidate = \"\"\""
EXPECTED_PARAMS = 23
# Parameters the Swift SQL wraps in nullif(...) - everything optional, i.e. 16..23.
NULLIF_PARAMS = tuple(range(16, 24))
# $15 (p_dependency_versions) must NOT be nullif'd: NULL is rejected by the migration.
JSONB_OBJECT_PARAM = 15


def extract_sql(swift_source: str) -> str:
    start = swift_source.find(SQL_MARKER)
    if start < 0:
        raise SystemExit("could not find the recordCandidate SQL marker in the Swift source")
    start = swift_source.find("\"\"\"", start) + 3
    end = swift_source.find("\"\"\"", start)
    if end < 0:
        raise SystemExit("unterminated recordCandidate SQL block")
    return swift_source[start:end].strip()


def check_sql(sql: str) -> dict:
    placeholders = sorted({int(n) for n in re.findall(r"\$(\d+)", sql)})
    missing = [n for n in range(1, EXPECTED_PARAMS + 1) if n not in placeholders]
    extra = [n for n in placeholders if n > EXPECTED_PARAMS]
    nullif_present = {n for n in placeholders if re.search(rf"nullif\(\${n}\b", sql)}
    checks = {
        "placeholder_count": len(placeholders),
        "missing": missing,
        "extra": extra,
        "nullif_params": sorted(nullif_present),
    }
    problems = []
    if len(placeholders) != EXPECTED_PARAMS or missing or extra:
        problems.append(f"expected $1..${EXPECTED_PARAMS}, found {placeholders}")
    for n in NULLIF_PARAMS:
        if n not in nullif_present:
            problems.append(f"${n} is not nullif'd, so an absent value would not become SQL NULL")
    if JSONB_OBJECT_PARAM in nullif_present:
        problems.append(f"${JSONB_OBJECT_PARAM} (p_dependency_versions) must NOT be nullif'd")
    if problems:
        raise SystemExit("Swift recordCandidate SQL does not match the documented contract: "
                         + "; ".join(problems))
    return checks


def swift_json(value) -> str:
    """Swift JSONEncoder(.sortedKeys) shape, including the escaped solidus."""
    text = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return text.replace("/", "\\/")


def encode_parameters(record: dict) -> list[str]:
    """PhysiologyCandidateSQL.recordCandidateParameters, in the documented order."""
    def opt(key):
        value = record.get(key)
        return "" if value is None else value

    def json_opt(key):
        value = record.get(key)
        return "" if value is None else swift_json(value)

    dependencies = record.get("dependencyVersions") or {}
    if not isinstance(dependencies, dict):
        raise SystemExit("dependencyVersions must be an object")
    return [
        record["userId"],                                    # $1  p_user
        record["deviceId"],                                  # $2  p_device (text)
        record["metric"],                                    # $3  p_metric
        record["periodDay"],                                 # $4  p_period_day
        record["intervalStart"],                             # $5  p_interval_start_at
        record["intervalEnd"],                               # $6  p_interval_end_at
        record["inputSHA256"],                               # $7  p_input_sha256
        str(record["inputRevision"]),                        # $8  p_input_revision
        record["providerId"],                                # $9  p_provider_id
        record["providerVersion"],                           # $10 p_provider_version
        opt("adapterVersion"),                               # $11 p_adapter_version
        opt("preprocessingVersion"),                         # $12 p_preprocessing_version
        record["configVersion"],                             # $13 p_config_version
        record["status"],                                    # $14 p_status
        swift_json(dependencies),                            # $15 p_dependency_versions (never '')
        opt("withheldReason"),                               # $16
        opt("value"),                                        # $17
        opt("unit"),                                         # $18
        json_opt("stages"),                                  # $19
        opt("labelSpace"),                                   # $20
        json_opt("coverage"),                                # $21
        json_opt("diagnostics"),                             # $22
        opt("runtimeMS"),                                    # $23
    ]


def bind(sql: str, parameters: list[str]) -> str:
    """Substitute $N with a SQL literal. An empty parameter stays '' (-> NULL via nullif)."""
    literals = {index + 1: "'" + str(value).replace("'", "''") + "'"
                for index, value in enumerate(parameters)}

    def replace(match: re.Match) -> str:
        return literals[int(match.group(1))]

    bound = re.sub(r"\$(\d+)", replace, sql)
    if not bound.lstrip().lower().startswith("select "):
        raise SystemExit("the extracted Swift SQL is not a select statement")
    inner = bound.lstrip()[len("select "):]
    # coalesce() is how the harness distinguishes "row written" from "guard refused"
    # (the RPC returns NULL for off-mode / triple mismatch / stale revision / replay).
    return f"select coalesce((select {inner}), 'null') as candidate_id;"


def build_record_from_response(args) -> dict:
    """CandidateStage.buildRecord() for the success path, then the record fields."""
    with open(args.from_response, "r", encoding="utf-8") as handle:
        response = json.load(handle)

    diagnostics = {
        "attempts": 1,
        "client_elapsed_ms": response.get("runtime_ms"),
        "transport": "ok",
        "input_rows": args.input_rows,
        "deduped_rows": args.deduped_rows,
        "mode": "shadow",
    }
    if response.get("runtime_ms") is not None:
        diagnostics["provider_runtime_ms"] = response["runtime_ms"]

    result = response.get("result") or {}
    versions = response.get("versions") or {}
    dependencies = {}
    if versions.get("dependency"):
        dependencies["dependency"] = versions["dependency"]
    if versions.get("model"):
        dependencies["model"] = versions["model"]

    status = response.get("status") or "error"
    withheld_reason = response.get("withheld_reason")
    value = result.get("value")
    unit = result.get("unit")
    stages = result.get("stages")
    label_space = result.get("label_space")

    record = {
        "userId": args.user_id,
        "deviceId": args.device_id,
        "metric": response.get("metric") or "hrv",
        "periodDay": args.period_day,
        "intervalStart": args.interval_start,
        "intervalEnd": args.interval_end,
        "inputSHA256": (response.get("input") or {}).get("sha256") or "",
        "inputRevision": int(args.input_revision),
        # The SELECTED triple, verbatim: the RPC drops the row otherwise.
        "providerId": args.provider_id,
        "providerVersion": args.provider_version,
        "adapterVersion": versions.get("adapter") or "unknown",
        "preprocessingVersion": versions.get("preprocessing") or "unknown",
        "configVersion": args.config_version,
        "dependencyVersions": dependencies,
        "status": status,
        "withheldReason": withheld_reason,
        "value": value,
        "unit": unit,
        "stages": stages,
        "labelSpace": label_space,
        "coverage": response.get("coverage"),
        "diagnostics": diagnostics,
        "runtimeMS": response.get("runtime_ms"),
    }
    return record


def apply_overrides(record: dict, overrides: list[str]) -> dict:
    for item in overrides:
        if "=" not in item:
            raise SystemExit(f"--override needs key=value, got {item!r}")
        key, raw = item.split("=", 1)
        if raw == "null":
            value = None
        else:
            try:
                value = json.loads(raw)
            except json.JSONDecodeError:
                value = raw
        if isinstance(value, str) and re.fullmatch(r"-?\d+", value):
            value = int(value)
        record[key] = value
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift-source", required=True)
    parser.add_argument("--from-response", help="a real /v1/infer response body")
    parser.add_argument("--record", help="a JSON record instead of --from-response")
    parser.add_argument("--override", action="append", default=[])
    parser.add_argument("--out")
    parser.add_argument("--dump", action="store_true")
    parser.add_argument("--user-id", default="")
    parser.add_argument("--device-id", default="")
    parser.add_argument("--period-day", default="")
    parser.add_argument("--interval-start", default="")
    parser.add_argument("--interval-end", default="")
    parser.add_argument("--input-revision", default="1")
    parser.add_argument("--provider-id", default="")
    parser.add_argument("--provider-version", default="")
    parser.add_argument("--config-version", default="")
    parser.add_argument("--input-rows", type=int, default=0)
    parser.add_argument("--deduped-rows", type=int, default=0)
    args = parser.parse_args()

    with open(args.swift_source, "r", encoding="utf-8") as handle:
        swift_source = handle.read()
    sql = extract_sql(swift_source)
    checks = check_sql(sql)

    if args.dump:
        print("--- SQL extracted verbatim from CandidateStage.swift ---")
        print(sql)
        print("--- contract checks ---")
        print(json.dumps(checks, indent=1))
        if args.from_response or args.record:
            record = (build_record_from_response(args) if args.from_response
                      else json.load(open(args.record, encoding="utf-8")))
            record = apply_overrides(record, args.override)
            for index, value in enumerate(encode_parameters(record), start=1):
                print(f"  ${index:<2} {value!r}")
        return 0

    if args.record:
        with open(args.record, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    elif args.from_response:
        record = build_record_from_response(args)
    else:
        raise SystemExit("one of --from-response, --record or --dump is required")
    record = apply_overrides(record, args.override)

    parameters = encode_parameters(record)
    statement = bind(sql, parameters)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(statement + "\n")
        print(f"bound SQL written: {args.out}")
        print(f"contract checks: {json.dumps(checks)}")
    else:
        print(statement)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
