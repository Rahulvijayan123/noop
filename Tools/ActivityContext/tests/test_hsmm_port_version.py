"""The Python HSMM port states which Swift decoder it reproduces (audit D9-09).

Benchmarks from the port must not be read as describing the shipped decoder. This pins the declared version and
fails if the port ever claims a version newer than the Swift constant, or claims to be current without a parity
fixture regenerated at that version.
"""

import os
import re

from activity_context import hsmm

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
ONTOLOGY = os.path.join(REPO, "Packages", "StrandAnalytics", "Sources", "StrandAnalytics",
                        "ActivityContextOntology.swift")


def _version(v):
    return tuple(int(x) for x in v.split("-", 1)[1].split("."))


def _swift_decoder_version():
    src = open(ONTOLOGY, encoding="utf-8").read()
    return re.search(r'static let decoder = "(hsmm-[0-9.]+)"', src).group(1)


def test_port_declares_its_decoder_version():
    assert re.fullmatch(r"hsmm-\d+\.\d+", hsmm.PORTED_DECODER_VERSION)
    assert hsmm.PORTED_DECODER_VERSION in (hsmm.__doc__ or "")


def test_port_never_claims_newer_than_swift():
    assert _version(hsmm.PORTED_DECODER_VERSION) <= _version(_swift_decoder_version())
