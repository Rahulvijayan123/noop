#!/bin/bash
# Install, build, select and roll back worker releases on the host (deploy/README.md).
#
#   release-host.sh [--root DIR] install TARBALL     extract into a fresh releases/<id> (never over a tree)
#   release-host.sh [--root DIR] build ID [--skip-tests] [--keep-test-build]
#                                                    swift build + swift test there, record BUILD.json,
#                                                    check the binary's own identity, make it read-only
#   release-host.sh [--root DIR] switch ID           point current at releases/<id> atomically
#   release-host.sh [--root DIR] rollback            switch back to the previous release
#   release-host.sh [--root DIR] status              current, previous, releases, measured identity
#
# DIR defaults to /opt/noop. A release directory is immutable once built: the worker unit runs
# /opt/noop/current/Tools/CloudWorker/.build/release/frwhoop-worker, so a switch takes effect on
# the next restart, and the previous release stays on disk for rollback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT=/opt/noop
SKIP_TESTS=0
KEEP_TEST_BUILD=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a directory}"; shift ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --keep-test-build) KEEP_TEST_BUILD=1 ;;
    -h|--help) sed -n '3,15p' "$SCRIPT_DIR/release-host.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}
ROOT="$(mkdir -p "$ROOT" && cd "$ROOT" && pwd -P)"
RELEASES="$ROOT/releases"
SQLITE_DIR="${FRWHOOP_SQLITE_DIR:-/opt/sqlite}"
UNIT_DIR="${FRWHOOP_SYSTEMD_DIR:-/etc/systemd/system}"

die() { echo "release-host: $*" >&2; exit 1; }

valid_id() {
  [[ "$1" =~ ^[0-9a-f]{40}(-dirty-[0-9a-f]{12})?$ ]]
}

json_get() {  # FILE KEY[.KEY...]
  python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value.get(key) if isinstance(value, dict) else None
print("" if value is None else (json.dumps(value) if isinstance(value, (dict, list, bool)) else value))
PY
}

sha256_of() {
  python3 - "$1" <<'PY'
import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for block in iter(lambda: handle.read(1 << 20), b""):
        digest.update(block)
print(digest.hexdigest())
PY
}

# Replace LINK with a symlink to TARGET atomically (symlink to a temporary name, then rename).
switch_link() {
  python3 - "$1" "$2" <<'PY'
import os, sys, time
target, link = sys.argv[1], sys.argv[2]
temporary = os.path.join(os.path.dirname(link), ".%s.tmp-%d-%d" % (os.path.basename(link), os.getpid(), time.time_ns()))
os.symlink(target, temporary)
os.replace(temporary, link)
fd = os.open(os.path.dirname(link), os.O_RDONLY)
os.fsync(fd)
os.close(fd)
PY
}

link_id() {  # the release id a link (current/previous) selects, or nothing
  local link="$ROOT/$1"
  [ -L "$link" ] || return 0
  local target
  target="$(readlink "$link")"
  basename "$target"
}

cmd_install() {
  local tarball="${1:?install needs a tarball}"
  [ -f "$tarball" ] || die "no such tarball: $tarball"
  if [ -f "$tarball.sha256" ]; then
    local want have
    want="$(cut -d' ' -f1 < "$tarball.sha256")"
    have="$(sha256_of "$tarball")"
    [ "$want" = "$have" ] || die "tarball sha256 $have != $tarball.sha256 ($want)"
    echo "tarball sha256 verified: $have"
  else
    echo "note: no $tarball.sha256 beside the tarball; relying on the stamped file list only"
  fi
  mkdir -p "$RELEASES"
  local incoming
  incoming="$(mktemp -d "$RELEASES/.incoming.XXXXXX")"
  # mktemp makes it 0700; the service users (frwhoop, frwhoop-inf) run code from this tree.
  chmod 0755 "$incoming"
  if ! tar xzf "$tarball" -C "$incoming" --strip-components=1 --no-same-owner; then
    rm -rf "$incoming"
    die "could not extract $tarball"
  fi
  local id
  id="$(json_get "$incoming/RELEASE.json" release_id 2>/dev/null || true)"
  if ! valid_id "$id"; then
    rm -rf "$incoming"
    die "the tarball has no valid RELEASE.json release_id"
  fi
  if [ -e "$RELEASES/$id" ]; then
    rm -rf "$incoming"
    die "releases/$id already exists; a release is never extracted over an existing tree"
  fi
  if ! python3 "$incoming/deploy/package_release.py" verify "$incoming"; then
    rm -rf "$incoming"
    die "the extracted files do not match their stamp"
  fi
  mv "$incoming" "$RELEASES/$id"
  echo "installed releases/$id ($(json_get "$RELEASES/$id/RELEASE.json" dirty | sed 's/true/DIRTY/;s/false/clean/'))"
  echo "next: $RELEASES/$id/deploy/release-host.sh --root $ROOT build $id"
}

cmd_build() {
  local id="${1:?build needs a release id}"
  valid_id "$id" || die "not a release id: $id"
  local rel="$RELEASES/$id"
  [ -d "$rel" ] || die "no release $rel"
  [ ! -e "$rel/BUILD.json" ] || die "releases/$id is already built (BUILD.json exists); releases are immutable"
  python3 "$rel/deploy/package_release.py" verify "$rel" || die "releases/$id does not match its stamp"
  local package="$rel/Tools/CloudWorker"
  local flags=(-Xcc "-I$SQLITE_DIR" -Xlinker "-L$SQLITE_DIR")
  local logs="$RELEASES/.logs/$id"
  mkdir -p "$logs"
  export LD_LIBRARY_PATH="$SQLITE_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

  echo "== swift build -c release (releases/$id) =="
  swift build -c release --package-path "$package" "${flags[@]}"
  local bin
  bin="$(swift build -c release --package-path "$package" "${flags[@]}" --show-bin-path)/frwhoop-worker"
  [ -x "$bin" ] || die "no executable at $bin"
  bin="$(cd "$(dirname "$bin")" && pwd -P)/frwhoop-worker"

  local tests=skipped summary="" rc=0
  if [ "$SKIP_TESTS" = 0 ]; then
    echo "== swift test (log: $logs/swift-test.log) =="
    set +e
    swift test --package-path "$package" "${flags[@]}" 2>&1 | tee "$logs/swift-test.log"
    rc=${PIPESTATUS[0]}
    set -e
    summary="$(grep -E "Executed [0-9]+ tests?" "$logs/swift-test.log" | tail -1 | sed 's/^[[:space:]]*//')"
    [ "$rc" = 0 ] || die "swift test failed (exit $rc): $summary"
    tests=passed
  fi

  local sha
  sha="$(sha256_of "$bin")"
  python3 - "$rel" "$id" "$bin" "$sha" "$tests" "$summary" "$logs/swift-test.log" \
    "$(swift --version 2>&1 | head -1)" "$(uname -sm)" "$SQLITE_DIR" <<'PY'
import hashlib, json, os, sys
from datetime import datetime, timezone
rel, rid, binary, sha, tests, summary, log, swift, platform, sqlite = sys.argv[1:11]
def digest(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()
stamp = json.load(open(os.path.join(rel, "RELEASE.json")))
document = {
    "schema": "nara-release-build/1",
    "release_id": rid,
    "release_stamp_sha256": digest(os.path.join(rel, "RELEASE.json")),
    "release_files_sha256": stamp["files"]["sha256"],
    "built_at_utc": datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "swift_version": swift,
    "platform": platform,
    "sqlite_dir": sqlite,
    "executables": {"frwhoop-worker": {"path": os.path.relpath(binary, rel), "sha256": sha,
                                       "size_bytes": os.path.getsize(binary)}},
    "tests": {"status": tests, "summary": summary or None, "log": log if tests != "skipped" else None},
}
with open(os.path.join(rel, "BUILD.json"), "w") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

  echo "== identity measured by the binary itself =="
  local identity
  if ! identity="$(FRWHOOP_RELEASE_STAMP="$rel/RELEASE.json" "$bin" --print-identity)"; then
    rm -f "$rel/BUILD.json"
    die "$bin --print-identity failed"
  fi
  echo "$identity"
  if ! printf '%s' "$identity" | python3 -c '
import json, sys
identity = json.load(sys.stdin)
executable = identity.get("executable") or {}
sys.exit(0 if identity.get("matches_release") is True and executable.get("sha256") == sys.argv[1] else 1)
' "$sha"; then
    rm -f "$rel/BUILD.json"
    die "the running binary does not measure as the recorded build (matches_release is not true)"
  fi

  if [ "$KEEP_TEST_BUILD" = 0 ]; then
    # The test build is several GB and never runs in production.
    local debug
    debug="$(swift build -c debug --package-path "$package" "${flags[@]}" --show-bin-path 2>/dev/null || true)"
    [ -n "$debug" ] && [ -d "$debug" ] && rm -rf "$debug"
  fi
  # Readable and traversable by the service users, writable by nobody.
  chmod -R a+rX,a-w "$rel"
  echo "built releases/$id: frwhoop-worker sha256 $sha (tests: $tests${summary:+, $summary})"
  echo "next: $rel/deploy/release-host.sh --root $ROOT switch $id"
}

cmd_switch() {
  local id="${1:?switch needs a release id}"
  valid_id "$id" || die "not a release id: $id"
  local rel="$RELEASES/$id"
  [ -f "$rel/BUILD.json" ] || die "releases/$id is not built (no BUILD.json); run build first"
  if [ -e "$ROOT/current" ] && [ ! -L "$ROOT/current" ]; then
    die "$ROOT/current exists and is not a symlink; move it aside"
  fi
  local binary want have
  binary="$rel/$(json_get "$rel/BUILD.json" executables.frwhoop-worker.path)"
  want="$(json_get "$rel/BUILD.json" executables.frwhoop-worker.sha256)"
  [ -f "$binary" ] || die "the built executable $binary is gone"
  have="$(sha256_of "$binary")"
  [ "$want" = "$have" ] || die "the executable changed since it was built ($have != $want)"
  python3 "$rel/deploy/package_release.py" verify "$rel" > /dev/null || die "releases/$id no longer matches its stamp"
  local before
  before="$(link_id current)"
  switch_link "releases/$id" "$ROOT/current"
  if [ -n "$before" ] && [ "$before" != "$id" ]; then
    switch_link "releases/$before" "$ROOT/previous"
  fi
  echo "current -> releases/$id (previous: ${before:-none})"
  local installed="$UNIT_DIR/frwhoop-worker.service"
  if [ -f "$installed" ] && ! cmp -s "$rel/deploy/frwhoop-worker.service" "$installed"; then
    echo "note: the installed unit differs from this release's; install it first:"
    echo "  install -m 644 $rel/deploy/frwhoop-worker.service $installed && systemctl daemon-reload"
  fi
  echo "now: systemctl restart frwhoop-worker   (the switch takes effect on restart)"
}

cmd_rollback() {
  local previous
  previous="$(link_id previous)"
  [ -n "$previous" ] || die "no previous release recorded under $ROOT"
  cmd_switch "$previous"
}

cmd_status() {
  local current previous
  current="$(link_id current)"
  previous="$(link_id previous)"
  echo "root:     $ROOT"
  echo "current:  ${current:-none}"
  echo "previous: ${previous:-none}"
  if [ -d "$RELEASES" ]; then
    local dir id state
    for dir in "$RELEASES"/*/; do
      [ -d "$dir" ] || continue
      id="$(basename "$dir")"
      state="installed"
      [ -f "$dir/BUILD.json" ] && state="built $(json_get "$dir/BUILD.json" built_at_utc)"
      echo "  $id  $state$([ "$id" = "$current" ] && echo '  <- current')"
    done
  fi
  if [ -n "$current" ] && [ -f "$RELEASES/$current/BUILD.json" ]; then
    local binary="$RELEASES/$current/$(json_get "$RELEASES/$current/BUILD.json" executables.frwhoop-worker.path)"
    [ -x "$binary" ] && { echo "identity of the current binary:"; "$binary" --print-identity; }
  fi
  return 0
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  build) shift; cmd_build "$@" ;;
  switch) shift; cmd_switch "$@" ;;
  rollback) shift; cmd_rollback ;;
  status) shift; cmd_status ;;
  *) sed -n '3,15p' "$SCRIPT_DIR/release-host.sh" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
