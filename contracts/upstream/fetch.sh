#!/bin/sh
# Re-fetch the pinned upstream Supabase contract snapshot.
# Usage:  fetch.sh <upstream-repo-path> <revision>
# Reads manifest-paths.txt (same directory as this script) and writes each file
# under the current checkout, preserving upstream relative paths (supabase/...).
# The path list is generated from MANIFEST.md and matches it exactly.
set -e

UP="${1:?usage: fetch.sh <upstream-repo> <revision>}"
REV="${2:?usage: fetch.sh <upstream-repo> <revision>}"

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PATHS="$HERE/manifest-paths.txt"

if [ ! -f "$PATHS" ]; then
  echo "manifest-paths.txt not found next to fetch.sh: $PATHS" >&2
  exit 1
fi

# Fail fast if the requested revision does not exist upstream.
if ! git -C "$UP" cat-file -e "$REV^{commit}" 2>/dev/null; then
  echo "revision not found in $UP: $REV" >&2
  exit 1
fi

count=0
while IFS= read -r p || [ -n "$p" ]; do
  [ -n "$p" ] || continue
  out="$HERE/$p"
  mkdir -p "$(dirname -- "$out")"
  git -C "$UP" show "$REV:$p" > "$out"
  count=$((count + 1))
done < "$PATHS"

echo "fetched $count files at $REV into $HERE"
