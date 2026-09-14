#!/usr/bin/env bash
#
# Verify build/parquet/ against the source dump and against the layout the app
# needs. Run after tools/sql_to_parquet.sh.
#
#   tools/verify_parquet.sh            full suite
#   tools/verify_parquet.sh --quick    skip the dump round-trip (which rescans 1.7 GB)

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

QUICK=false
[ "${1:-}" = "--quick" ] && QUICK=true

cd "$REPO_ROOT"
[ -f "$PARQUET_DIR/tract_attrs.parquet" ] || die "no Parquet output; run tools/sql_to_parquet.sh first"

SAMPLE_N=20

# ---------------------------------------------------------------------------
log "SQL verification suite"
# ---------------------------------------------------------------------------
duckdb :memory: -bail -c ".read tools/verify_parquet.sql"

# ---------------------------------------------------------------------------
log ""
log "GeoParquet interop (ogrinfo must see a spatial layer, not a BLOB column)"
# ---------------------------------------------------------------------------
if command -v ogrinfo >/dev/null; then
  for f in "$PARQUET_DIR"/tract_geom_*.parquet; do
    if ogrinfo -so -al "$f" 2>/dev/null | grep -qi 'Geometry: *Polygon'; then
      printf '  PASS  %-28s %s\n' "$(basename "$f")" \
        "$(ogrinfo -so -al "$f" 2>/dev/null | grep -i -m1 'Geometry:' | tr -s ' ')"
    else
      printf '  FAIL  %-28s ogrinfo did not report a polygon layer\n' "$(basename "$f")"
    fi
  done
  printf '  CRS:  %s\n' \
    "$(ogrinfo -so -al "$PARQUET_DIR/tract_geom_med.parquet" 2>/dev/null \
       | grep -m1 -E 'ID\["(EPSG|OGC)"' | sed 's/^ *//')"
else
  echo "  SKIP  ogrinfo not on PATH"
fi

# ---------------------------------------------------------------------------
if [ "$QUICK" = false ]; then
log ""
log "round-trip against the source dump ($SAMPLE_N random tracts)"
# ---------------------------------------------------------------------------
# Pull the sampled rows straight out of the dump text and re-parse them with the
# same column spec, then compare every attribute and the geometry vertex counts
# against what actually landed in Parquet.

IDS=$(duck_scalar :memory: \
  "SELECT string_agg(tract_id, ',') FROM (
     SELECT tract_id FROM '$PARQUET_DIR/tract_attrs.parquet'
     USING SAMPLE $SAMPLE_N ROWS (reservoir, 20260910));")
[ -n "$IDS" ] || die "could not sample tract_ids"
log "  sampled tract_ids: $IDS"

# tract_id N is dump line 88 + N (data starts at line 89).
awk -v ids="$IDS" '
  BEGIN { n = split(ids, a, ","); for (i = 1; i <= n; i++) want[a[i] + 88] = a[i] }
  NR in want { printf "%d\t%s\n", want[NR], $0; if (++hit == n) exit }
' "$DUMP" > "$BUILD_DIR/sample.tsv"

got=$(wc -l < "$BUILD_DIR/sample.tsv" | tr -d ' ')
[ "$got" = "$SAMPLE_N" ] || die "extracted $got dump lines, expected $SAMPLE_N"

duckdb :memory: -bail -c ".read tools/roundtrip.sql"
rm -f "$BUILD_DIR/sample.tsv"
fi

log ""
log "verification complete"
