#!/usr/bin/env bash
#
# Convert classified_tracts_levels.sql (a pg_dump of the PostGIS table) into the
# seven DuckDB-ready Parquet files described in PARQUET_CONVERSION_PLAN.md.
#
#   tools/sql_to_parquet.sh              full run
#   tools/sql_to_parquet.sh --emit-only  skip staging, reuse build/staging.duckdb
#
# Staging is the slow part (~1.7 GB streamed and parsed), so --emit-only exists
# to iterate on the output layout without repeating it.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

EMIT_ONLY=false
[ "${1:-}" = "--emit-only" ] && EMIT_ONLY=true

cd "$REPO_ROOT"
mkdir -p "$PARQUET_DIR" "$BUILD_DIR/tmp"

# ---------------------------------------------------------------------------
# Prerequisites, probed before streaming 1.7 GB rather than after
# ---------------------------------------------------------------------------

log "checking prerequisites"
command -v duckdb >/dev/null || die "duckdb is not on PATH"
[ -f "$DUMP" ] || die "missing dump: $DUMP"

duckdb -c "INSTALL spatial;" >/dev/null 2>&1 \
  || die "could not install the DuckDB spatial extension (needs network once)"

for fn in st_geomfromhexwkb st_hilbert; do
  found=$(duck_scalar ":memory:" \
    "LOAD spatial; SELECT count(*) FROM duckdb_functions() WHERE lower(function_name) = '$fn';")
  [ "$found" -gt 0 ] || die "the spatial extension has no $fn; the SQL needs updating"
done
log "  duckdb $(duckdb --version | awk '{print $1}'), spatial ok"

# ---------------------------------------------------------------------------
# Step 1: stage
# ---------------------------------------------------------------------------

if [ "$EMIT_ONLY" = false ]; then
  rm -f "$STAGING_DB" "$STAGING_DB.wal"
  log "staging the COPY block into $STAGING_DB (several minutes)"

  # Emit only the data region, located by content rather than by line number,
  # with a 1-based tract_id prepended. Assigning the id here rather than with
  # row_number() makes it a property of the data instead of a property of
  # DuckDB's insertion-order settings.
  awk '
    f && /^\\\.$/ { exit }
    f            { printf "%d\t%s\n", ++n, $0 }
    /^COPY public\.classified_tracts_levels /{ f = 1 }
  ' "$DUMP" \
  | duckdb "$STAGING_DB" -bail -c ".read tools/sql_to_parquet.sql"

  log "  staged"
fi

[ -f "$STAGING_DB" ] || die "no staging database; run without --emit-only first"

# ---------------------------------------------------------------------------
# Staging assertions
# ---------------------------------------------------------------------------

log "asserting staged data"

assert_eq() { # label expected sql
  local got
  got=$(duck_scalar "$STAGING_DB" "LOAD spatial; $3")
  [ "$got" = "$2" ] || die "$1: expected $2, got $got"
  log "  ok: $1 = $got"
}

assert_eq "row count"          "$EXPECTED_ROWS" "SELECT count(*) FROM staging;"
assert_eq "distinct tract_id"  "$EXPECTED_ROWS" "SELECT count(DISTINCT tract_id) FROM staging;"
assert_eq "tract_id is 1..n"   "true" \
  "SELECT min(tract_id) = 1 AND max(tract_id) = $EXPECTED_ROWS FROM staging;"
assert_eq "no null geometries" "0" \
  "SELECT count(*) FROM staging WHERE geom_orig IS NULL OR geom_high IS NULL
     OR geom_med IS NULL OR geom_low IS NULL OR geom_lowest IS NULL;"
assert_eq "polygon types only" "0" \
  "SELECT count(*) FROM staging
    WHERE ST_GeometryType(geom_orig) NOT IN ('POLYGON', 'MULTIPOLYGON');"

log "  geometry types present:"
duckdb "$STAGING_DB" -c \
  "LOAD spatial;
   SELECT ST_GeometryType(geom_orig) AS type, count(*) AS n FROM staging GROUP BY 1 ORDER BY 2 DESC;"

# ---------------------------------------------------------------------------
# Steps 2 and 3: bbox, Hilbert, emit
# ---------------------------------------------------------------------------

log "emitting Parquet into $PARQUET_DIR"
duckdb "$STAGING_DB" -bail -c ".read tools/emit_parquet.sql"

log "output:"
ls -lh "$PARQUET_DIR"

log "done. Next: tools/verify_parquet.sh, then tools/upload_parquet.sh"
