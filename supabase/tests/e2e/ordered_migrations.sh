#!/bin/bash
# Print the migration files in an order that applies cleanly to an empty database, one path per line.
#
# `supabase/migrations` is lexicographic, and applying it that way to an *empty* database fails at
# 20260918040000 (production_projection_debt), which alters `object_manifests.durability_receipt` before
# 20260921060000 (production_intake_durability) has created it. Production never hit this because its history
# was built incrementally. The migration files are immutable once applied, so rather than renaming one, the
# test harnesses apply this order: lexicographic, with the intake-durability migration placed immediately
# after production_scoring_durability, the migration it extends.
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)/migrations}"
EARLY="20260921060000_production_intake_durability.sql"
ANCHOR="20260918010000_production_scoring_durability.sql"

for f in "$DIR"/*.sql; do
  name="$(basename "$f")"
  [ "$name" = "$EARLY" ] && continue
  echo "$f"
  [ "$name" = "$ANCHOR" ] && echo "$DIR/$EARLY"
done
exit 0
