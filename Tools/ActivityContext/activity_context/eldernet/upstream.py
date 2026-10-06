"""The upstream ElderNet source, obtained by the operator and imported verified (ELDERNET.md §1, NOTICE.md).

Nara's repository contains **no University of Oxford source code**. The model architecture (upstream
``models.py``) and the offline bout rules (upstream ``gait_quality/detection.py`` / ``quality.py``) are imported
at run time from a checkout of ``yonbrand/gait-quality`` at :data:`UPSTREAM_COMMIT` that the operator obtains
at install time, exactly like the weights, under the University of Oxford Academic Use Licence::

    python -m activity_context.eldernet.upstream fetch --dest <dir>                     # GitHub raw, pinned commit
    python -m activity_context.eldernet.upstream fetch --dest <dir> --from-git <clone>  # git archive of a clone
    python -m activity_context.eldernet.upstream verify [--dir <dir>]
    python -m activity_context.eldernet.upstream manifest

A full clone checked out at the pinned commit works as is. The directory is ``--upstream-dir`` or
``$ELDERNET_UPSTREAM_DIR`` (never guessed). Nothing is ever downloaded at serve time.

Every upstream file this package executes is in :data:`SOURCE_MANIFEST` with its sha256 and size, and is read
once, checked, and compiled **from the verified bytes** (no second read, so what runs is what was checked). The
modules live in private module objects that never enter ``sys.modules``; their ``import`` statements resolve
only to the other verified upstream modules or to ordinary third-party packages, and an import of any other
upstream-internal module (``utils``, ``regularity``, ``gait_quality.config`` …) fails loudly instead of picking
up whatever happens to be on ``sys.path``. ``LICENSE.md`` must be present and verified before anything runs.

One upstream function is not run: ``models.weight_init`` (called by the ``Resnet`` / ``LinearLayers``
constructors) imports upstream ``utils.py`` (pingouin, seaborn, ``matplotlib.use('TkAgg')``) and re-seeds the
global Python / NumPy / torch RNGs. The adapter replaces that one name in its private copy of the module with a
no-op before constructing a model; every parameter and buffer is then overwritten by the strict checkpoint load
(``model.load_strict``), so the initial values never reach an output. No upstream source is modified.

A missing directory or file is ``model_missing``; a size / sha256 mismatch is ``weights_mismatch`` (the wire has
no separate kind; the message names the upstream file). :class:`~.weights.WeightsError` either way.
"""

from __future__ import annotations

import argparse
import builtins
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import types
from dataclasses import dataclass
from typing import Callable, Dict, Mapping, Optional, Sequence, Tuple

from . import UPSTREAM_COMMIT
from .weights import RAW_BASE, WeightsError

UPSTREAM_DIR_ENV = "ELDERNET_UPSTREAM_DIR"
PRIVATE_PACKAGE = "_nara_eldernet_upstream_" + UPSTREAM_COMMIT[:7]


@dataclass(frozen=True)
class SourceFile:
    path: str            # path inside the upstream repository (posix)
    sha256: str
    size: int
    role: str            # import | licence | config | example

    @property
    def url(self) -> str:
        return RAW_BASE + self.path


# sha256 / size of the blobs at UPSTREAM_COMMIT (``git show <commit>:<path>``, measured 2026-10-06).
SOURCE_MANIFEST: Dict[str, SourceFile] = {f.path: f for f in (
    SourceFile("LICENSE.md", "0285754f68db29a0b0e66b7be206e6159e81edaf373aaa5b45fc6cca0b282da2", 6380, "licence"),
    SourceFile("models.py", "a6238da0aa9f7b77a7834c72f8914a84de4240d7d1b67590dd4abc79bbb5d46e", 25450, "import"),
    SourceFile("gait_quality/__init__.py", "8d0484872af57088b7332cf4434f765375c6a85c62fd32926ace45722f146c22", 321,
               "import"),
    SourceFile("gait_quality/detection.py", "127582c25cb0c2487bf5ac8910922e49b0633579b4a3123f09c2e938de74c076",
               12453, "import"),
    SourceFile("gait_quality/quality.py", "4bfbebc972377099f45da067166b5af4b7f36b4da7a0baaa2b9b67d76141c7a7", 8641,
               "import"),
    # Not executed: the architecture settings Nara's QUALITY_HEADS must equal (checked by the tests).
    SourceFile("pipelines/config.yaml", "3914f570fb2febabf05b8fe1aad9a2116e2cdb9d1a385b4626c099c8e12671e1", 3622,
               "config"),
)}
# Optional (``fetch --with-examples``): upstream's committed toy example (CC BY 4.0 Mobilise-D data and upstream's
# expected outputs) for the golden fixture and the parity tests. Data, never executed.
EXAMPLE_MANIFEST: Dict[str, SourceFile] = {f.path: f for f in (
    SourceFile("examples/toy_wrist.csv.gz", "a11e40422187cdcbb7a1ba375dfdf8ae5d66e669df0aa0a19cd046dbedb9400b",
               1142465, "example"),
    SourceFile("examples/expected/toy_wrist_windows.csv",
               "d16be67f1c97b51bde514c88618a1a0e05879ca25abc9cfd14ddf5f6c4cce656", 44472, "example"),
    SourceFile("examples/expected/toy_wrist_bouts.csv",
               "ab4c647af5ca7d294d9a6f33f98bfae56f0a779d336be577ca6a2f394e71ce68", 825, "example"),
    SourceFile("examples/expected/summary.csv", "78f9ba268c38939e60a70a5e42840fe863fae6b0c1af6bb21767b7dd53164126",
               1091, "example"),
)}

# Upstream module name -> (file, upstream modules it imports at module level). Load order follows the deps.
MODULES: Dict[str, Tuple[str, Tuple[str, ...]]] = {
    "models": ("models.py", ()),
    "gait_quality": ("gait_quality/__init__.py", ()),
    "gait_quality.detection": ("gait_quality/detection.py", ("gait_quality",)),
    "gait_quality.quality": ("gait_quality/quality.py", ("gait_quality", "gait_quality.detection")),
}
# Top-level names of upstream's own modules; an import of one outside MODULES is refused (never sys.path).
UPSTREAM_TOP_LEVEL = frozenset({"models", "utils", "regularity", "constants", "inference", "final_training",
                                "hyperparameter_tuning", "gait_quality", "pipelines", "dataset", "data_parsing",
                                "RUSH", "conf", "tests", "tutorials", "examples"})


def upstream_dir(explicit: Optional[str] = None) -> str:
    """The explicit directory, else ``$ELDERNET_UPSTREAM_DIR``; "" when neither is set (never a guess)."""
    return (explicit or os.environ.get(UPSTREAM_DIR_ENV, "")).strip()


def _require_dir(directory: Optional[str]) -> str:
    d = upstream_dir(directory)
    if not d:
        raise WeightsError("model_missing", f"no upstream ElderNet source directory: set ${UPSTREAM_DIR_ENV} or pass "
                           f"--upstream-dir (fetch with: python -m activity_context.eldernet.upstream fetch --dest "
                           f"<dir>)")
    if not os.path.isdir(d):
        raise WeightsError("model_missing", f"upstream source directory {d} does not exist")
    return os.path.realpath(d)


def read_verified(directory: str, sf: SourceFile) -> bytes:
    """The file's bytes, or WeightsError (model_missing / weights_mismatch). One read: hash what is returned."""
    path = os.path.join(directory, *sf.path.split("/"))
    if not os.path.isfile(path):
        raise WeightsError("model_missing", f"upstream {sf.path}: {path} not found")
    with open(path, "rb") as f:
        data = f.read(sf.size + 1)
    if len(data) != sf.size:
        raise WeightsError("weights_mismatch", f"upstream {sf.path}: {len(data)}{'+' if len(data) > sf.size else ''} "
                           f"bytes, pinned {sf.size} (not the {UPSTREAM_COMMIT[:7]} source)")
    digest = hashlib.sha256(data).hexdigest()
    if digest != sf.sha256:
        raise WeightsError("weights_mismatch", f"upstream {sf.path}: sha256 {digest[:16]}… != pinned "
                           f"{sf.sha256[:16]}… (not the {UPSTREAM_COMMIT[:7]} source)")
    return data


def verify(directory: Optional[str] = None, manifest: Mapping[str, SourceFile] = SOURCE_MANIFEST) -> Dict[str, str]:
    """path -> sha256 for every manifest file in the directory (raises on the first problem)."""
    d = _require_dir(directory)
    return {p: hashlib.sha256(read_verified(d, sf)).hexdigest() for p, sf in manifest.items()}


# What the serve verifies before it builds a head: the licence and the one module it executes (the architecture).
SERVE_FILES: Tuple[str, ...] = ("LICENSE.md", "models.py")


def source_hashes(files: Sequence[str] = SERVE_FILES) -> Dict[str, str]:
    """path -> pinned sha256 of the upstream files the serve verifies (ping ``upstream_source``)."""
    return {p: SOURCE_MANIFEST[p].sha256 for p in files}


# ---------------------------------------------------------------------------
# Verified import into private modules
# ---------------------------------------------------------------------------

_CACHE: Dict[Tuple[str, str], types.ModuleType] = {}


def _skip_weight_init(module, *args, **kwargs) -> None:
    """Stands in for upstream ``models.weight_init`` (module docstring): parameters come from the checkpoint."""
    return None


def _import_hook(mapping: Mapping[str, types.ModuleType]) -> Callable:
    real = builtins.__import__

    def _import(name, globals=None, locals=None, fromlist=(), level=0):
        if level == 0:
            if name in mapping:
                return mapping[name] if fromlist else mapping[name.split(".")[0]]
            if name.split(".")[0] in UPSTREAM_TOP_LEVEL:
                raise ImportError(f"upstream module {name!r} is not part of Nara's verified ElderNet source set "
                                  f"({sorted(MODULES)})")
        return real(name, globals, locals, fromlist, level)
    return _import


def _load(name: str, d: str) -> types.ModuleType:
    key = (d, name)
    if key in _CACHE:
        return _CACHE[key]
    read_verified(d, SOURCE_MANIFEST["LICENSE.md"])           # the licence travels with the code it governs
    rel, deps = MODULES[name]
    mapping = {dep: _load(dep, d) for dep in deps}
    source = read_verified(d, SOURCE_MANIFEST[rel])
    mod = types.ModuleType(f"{PRIVATE_PACKAGE}.{name}")
    mod.__file__ = os.path.join(d, *rel.split("/"))
    if rel.endswith("__init__.py"):
        mod.__path__ = []                                      # a package object, without a search path
        mod.__package__ = mod.__name__
    else:
        mod.__package__ = mod.__name__.rpartition(".")[0]
    mod.__dict__["__builtins__"] = dict(vars(builtins), __import__=_import_hook(mapping))
    if "." in name:                                            # gait_quality.detection is an attribute of the package
        setattr(mapping[name.rpartition(".")[0]], name.rpartition(".")[2], mod)
    exec(compile(source, mod.__file__, "exec", dont_inherit=True), mod.__dict__)
    if name == "models":
        if not callable(mod.__dict__.get("weight_init")):
            raise WeightsError("weights_mismatch", "upstream models.py has no weight_init (unexpected source)")
        mod.weight_init = _skip_weight_init
    _CACHE[key] = mod
    return mod


def load_module(name: str, directory: Optional[str] = None) -> types.ModuleType:
    """The verified upstream module ``name`` (a key of :data:`MODULES`) from the operator's checkout."""
    if name not in MODULES:
        raise KeyError(f"{name!r} is not an upstream module Nara imports ({sorted(MODULES)})")
    return _load(name, _require_dir(directory))


def models(directory: Optional[str] = None) -> types.ModuleType:
    """Upstream ``models.py`` (ElderNet, Resnet, …): the serve path; needs only torch / numpy."""
    return load_module("models", directory)


def detection(directory: Optional[str] = None) -> types.ModuleType:
    """Upstream ``gait_quality/detection.py`` (offline bout rules)."""
    return load_module("gait_quality.detection", directory)


def quality(directory: Optional[str] = None) -> types.ModuleType:
    """Upstream ``gait_quality/quality.py`` (offline bout summaries; imports pandas — never the serve)."""
    return load_module("gait_quality.quality", directory)


# ---------------------------------------------------------------------------
# Fetch (operator, install time; never the serve)
# ---------------------------------------------------------------------------

def _safe_dest(dest: str, rel: str) -> str:
    out = os.path.realpath(os.path.join(dest, *rel.split("/")))
    root = os.path.realpath(dest)
    if os.path.commonpath([root, out]) != root:
        raise WeightsError("weights_mismatch", f"refusing to write {rel!r} outside {dest}")
    return out


def _write_verified(dest: str, sf: SourceFile, data: bytes) -> None:
    if len(data) != sf.size or hashlib.sha256(data).hexdigest() != sf.sha256:
        raise WeightsError("weights_mismatch", f"upstream {sf.path}: fetched bytes do not match the pinned sha256")
    path = _safe_dest(dest, sf.path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def fetch(dest: str, with_examples: bool = False, from_git: Optional[str] = None, retries: int = 5) -> Dict[str, str]:
    """Put every pinned file into ``dest`` (skipping ones already verified), then verify the lot."""
    files = dict(SOURCE_MANIFEST)
    if with_examples:
        files.update(EXAMPLE_MANIFEST)
    os.makedirs(dest, exist_ok=True)
    todo = []
    for p, sf in files.items():
        try:
            read_verified(dest, sf)
            print(f"  {p}: present, sha256 ok", file=sys.stderr)
        except WeightsError:
            todo.append(sf)
    if todo and from_git:
        cmd = ["git", "-C", from_git, "archive", "--format=tar", UPSTREAM_COMMIT, "--"] + [sf.path for sf in todo]
        tar = subprocess.run(cmd, capture_output=True, check=False)
        if tar.returncode != 0:
            raise WeightsError("model_missing", f"git archive failed: {tar.stderr.decode(errors='replace').strip()}")
        wanted = {sf.path: sf for sf in todo}
        with tarfile.open(fileobj=io.BytesIO(tar.stdout), mode="r:") as tf:
            for member in tf:
                if member.name in wanted and member.isfile():
                    _write_verified(dest, wanted.pop(member.name), tf.extractfile(member).read())
        if wanted:
            raise WeightsError("model_missing", f"not in {from_git} at {UPSTREAM_COMMIT[:7]}: {sorted(wanted)}")
    elif todo:
        from ..fetch_artifacts import download
        for sf in todo:
            path = _safe_dest(dest, sf.path)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            print(f"  {sf.path}: downloading {sf.size} B from {sf.url}", file=sys.stderr)
            download(sf.url, path, sf.sha256, sf.size, retries=retries)
    return verify(dest, files)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ElderNet upstream source (University of Oxford Academic Use Licence): "
                                             "fetch / verify / manifest")
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch", help="fetch the pinned upstream source files, sha256-verified")
    f.add_argument("--dest", default=None, help=f"target directory (default ${UPSTREAM_DIR_ENV})")
    f.add_argument("--from-git", default=None, help="a local clone to `git archive` the pinned commit from (offline)")
    f.add_argument("--with-examples", action="store_true", help="also the toy example (golden / parity tests)")
    v = sub.add_parser("verify", help="verify a directory against the pinned source manifest")
    v.add_argument("--dir", default=None, help=f"upstream source directory (default ${UPSTREAM_DIR_ENV})")
    v.add_argument("--with-examples", action="store_true")
    sub.add_parser("manifest", help="print the pinned source manifest as JSON")
    args = ap.parse_args(argv)
    if args.cmd == "manifest":
        print(json.dumps({"upstream_commit": UPSTREAM_COMMIT, "files": {
            p: {"sha256": sf.sha256, "size": sf.size, "role": sf.role, "url": sf.url}
            for p, sf in {**SOURCE_MANIFEST, **EXAMPLE_MANIFEST}.items()}}, indent=2))
        return 0
    print("[eldernet.upstream] University of Oxford SSL-wearables Academic Use Licence (upstream LICENSE.md): "
          "internal academic, non-commercial research only.", file=sys.stderr)
    try:
        if args.cmd == "fetch":
            dest = upstream_dir(args.dest)
            if not dest:
                ap.error(f"--dest or ${UPSTREAM_DIR_ENV} is required")
            fetch(dest, with_examples=args.with_examples, from_git=args.from_git)
        else:
            files = {**SOURCE_MANIFEST, **(EXAMPLE_MANIFEST if args.with_examples else {})}
            for p in verify(args.dir, files):
                print(f"  {p}: ok", file=sys.stderr)
    except WeightsError as exc:
        print(f"[eldernet.upstream] {exc.kind}: {exc.message}", file=sys.stderr)
        return 2
    return 0


__all__ = ["UPSTREAM_DIR_ENV", "PRIVATE_PACKAGE", "SourceFile", "SOURCE_MANIFEST", "EXAMPLE_MANIFEST", "MODULES",
           "SERVE_FILES", "upstream_dir", "read_verified", "verify", "source_hashes", "load_module", "models", "detection", "quality",
           "fetch", "main"]


if __name__ == "__main__":
    sys.exit(main())
