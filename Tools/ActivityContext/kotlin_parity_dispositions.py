#!/usr/bin/env python3
"""List, and optionally record, the Swift-only parity debt a branch adds to the ActivityContext decoder.

The ActivityContext decoder (Packages/StrandAnalytics/Sources/StrandAnalytics/ActivityContext*.swift and
ActivityDecoderPersonalization.swift) has no Kotlin twin: Android only extracts and stores IMU features
(ImuFeatureExtractor.kt, Whoop5RawImu.kt, ImuSessionFileStore.kt) and never decodes activity context. Every
declaration a decoder channel adds is therefore one-sided by construction, and Tools/PARITY_GOVERNANCE.md
requires an exact typed disposition for each one.

This helper computes exactly what `Tools/parity_ratchet.py` will demand, with the ratchet's own functions:
it materializes the exact base tree, derives both semantic authorities, and diffs the unpaired sets. It
never touches the twin map or the compact baseline (only the guarded `--refresh-derived` flow may), and it
only appends brand-new `platform_specific` entries to Tools/parity_dispositions.json when asked with
`--write` and an explicit `--channel` rationale. It refuses to write if any new one-sided identity falls
outside the ActivityContext decoder files, so unrelated debt cannot be waived through it.

It also lists what NO disposition can satisfy (new ledger findings such as `test-only-callsite`, and
removed pairs): those need a source-level remedy.

Usage, from the repository root:

    python3 Tools/ActivityContext/kotlin_parity_dispositions.py --base nara/main            # dry run
    python3 Tools/ActivityContext/kotlin_parity_dispositions.py --base nara/main \\
        --channel eldernet --write                                                       # record
    python3 Tools/parity_ratchet.py --base nara/main --offline                           # verify
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))

import parity_ledger  # noqa: E402
import parity_ratchet  # noqa: E402

REGISTRY = ROOT / "Tools/parity_dispositions.json"

# Only these files may receive a disposition through this helper: the Swift ActivityContext decoder.
DECODER_GLOBS = (
    "Packages/StrandAnalytics/Sources/StrandAnalytics/ActivityContext*.swift",
    "Packages/StrandAnalytics/Sources/StrandAnalytics/ActivityDecoder*.swift",
    "Packages/StrandAnalytics/Sources/StrandAnalytics/GaitQuality*.swift",
)

_NO_TWIN = (
    "The ActivityContext decoder has no Kotlin twin: Android never decodes ActivityContext (it only "
    "extracts and stores IMU features in ImuFeatureExtractor.kt, Whoop5RawImu.kt and "
    "ImuSessionFileStore.kt), and this Swift package is what the cloud worker and the offline replay run."
)
RATIONALES = {
    "inertia1": (
        "Inertia-1 motion-heads evidence channel of the Swift ActivityContext decoder (off by default; "
        "shadow/candidate in the worker only; Tools/ActivityContext/INERTIA1.md section 7). " + _NO_TWIN
    ),
    "eldernet": (
        "ElderNet gait-quality evidence channel of the Swift ActivityContext decoder (off by default; "
        "shadow/candidate in the worker only; Tools/ActivityContext/ELDERNET.md section 5). " + _NO_TWIN
    ),
}

_SETS = (
    ("unpaired_files", "add-unpaired-file"),
    ("unpaired_functions", "add-unpaired-function"),
    ("unpaired_properties", "add-unpaired-property"),
    ("unpaired_constants", "add-unpaired-constant"),
)


def _path_of(identity: str) -> str:
    return identity.split("\0", 1)[1].split("::", 1)[0]


def _in_decoder(identity: str) -> bool:
    return identity.startswith("swift\0") and any(
        fnmatch.fnmatchcase(_path_of(identity), pattern) for pattern in DECODER_GLOBS
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="nara/main", help="exact base ref (this fork's main is nara/main)")
    parser.add_argument("--channel", choices=sorted(RATIONALES), help="rationale for the entries written")
    parser.add_argument("--write", action="store_true", help="append the missing dispositions to the registry")
    parser.add_argument("--skip-findings", action="store_true", help="skip the (slow) ledger-finding diff")
    args = parser.parse_args(argv)
    if args.write and not args.channel:
        parser.error("--write needs an explicit --channel rationale")

    base = parity_ratchet.resolve_base(ROOT, args.base)
    registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
    parity_ratchet._validate_dispositions(registry, str(REGISTRY.relative_to(ROOT)), ROOT)
    recorded = {(item["kind"], item["identity"]) for item in registry["dispositions"]}

    base_registry = parity_ratchet._read_base(ROOT, base, parity_ratchet.DISPOSITIONS_PATH) or {
        "schema_version": 1, "dispositions": []}
    current_sets = parity_ledger.semantic_authority(ROOT)
    with parity_ratchet._base_tree(ROOT, base) as base_root:
        base_sets = parity_ledger.semantic_authority(base_root)
        base_findings: set[str] = set()
        if not args.skip_findings:  # scanned exactly as the ratchet scans the base
            base_map = parity_ledger.build_compact_twin_map(base_root)
            base_map["exemptions"] = base_registry["dispositions"]
            base_findings = {item.identity for item in parity_ledger.scan(base_root, base_map).findings}
    current_findings: set[str] = set()
    if not args.skip_findings:
        current_map = parity_ledger.build_compact_twin_map(ROOT)
        current_map["exemptions"] = registry["dispositions"]
        current_findings = {item.identity for item in parity_ledger.scan(ROOT, current_map).findings}

    required = parity_ratchet._required_v3_exemptions(base_sets, current_sets, base_findings, current_findings)
    one_sided = sorted(key for key in required if key[0].startswith("add-unpaired-"))
    unwaivable = sorted(key for key in required if not key[0].startswith("add-unpaired-"))
    missing = [key for key in one_sided if key not in recorded]
    outside = [key for key in missing if not _in_decoder(key[1])]
    to_write = [key for key in missing if _in_decoder(key[1])]

    print(f"base {args.base} = {base}")
    print(f"new one-sided identities vs base: {len(one_sided)} {dict(Counter(kind for kind, _ in one_sided))}")
    print(f"  already dispositioned: {len(one_sided) - len(missing)}")
    print(f"  missing, in the ActivityContext decoder: {len(to_write)}")
    for kind, identity in to_write:
        print(f"    {kind} {identity.replace(chr(0), ' ')}")
    print(f"  missing, OUTSIDE the decoder (not handled here; needs its own review): {len(outside)}")
    for kind, identity in outside:
        print(f"    {kind} {identity.replace(chr(0), ' ')}")
    if args.skip_findings:
        print("ledger-finding diff skipped (--skip-findings)")
    else:
        print(f"new findings / removed pairs (no disposition can satisfy these; fix at source): {len(unwaivable)}")
        for kind, identity in unwaivable:
            print(f"    {kind} {identity.replace(chr(0), ' ')}")

    if not args.write:
        return 1 if missing else 0
    if outside:
        print("REFUSED: new one-sided identities outside the decoder need their own reviewed dispositions")
        return 2
    rationale = RATIONALES[args.channel]
    for kind, identity in to_write:
        registry["dispositions"].append({
            "type": "platform_specific",
            "kind": kind,
            "identity": identity,
            "identity_sha256": parity_ledger._canonical_sha256(identity),
            "platform": "swift",
            "rationale": rationale,
        })
    parity_ratchet._validate_dispositions(registry, str(REGISTRY.relative_to(ROOT)), ROOT)
    REGISTRY.write_text(json.dumps(registry, indent=2) + "\n", encoding="utf-8")
    print(f"WROTE {len(to_write)} platform_specific dispositions ({args.channel}) to {REGISTRY.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
