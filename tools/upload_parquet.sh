#!/usr/bin/env bash
#
# Upload build/parquet/ to the Taiga S3 gateway and read it back over HTTP.
# Credentials, endpoint and bucket come from .env (never echoed).
#
#   tools/upload_parquet.sh              upload, then verify
#   tools/upload_parquet.sh --verify-only  skip the upload

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

VERIFY_ONLY=false
[ "${1:-}" = "--verify-only" ] && VERIFY_ONLY=true

cd "$REPO_ROOT"
load_env

PREFIX="sfgc/parquet"
DEST="s3://$BUCKET_NAME/$PREFIX/"

command -v aws >/dev/null || die "aws CLI is not on PATH"
[ -d "$PARQUET_DIR" ] || die "no $PARQUET_DIR; run tools/sql_to_parquet.sh first"

aws_s3() { aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"; }

log "endpoint $AWS_ENDPOINT_URL  bucket $BUCKET_NAME  region $AWS_DEFAULT_REGION"
aws_s3 s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null \
  || die "cannot reach bucket '$BUCKET_NAME' — check the credentials in .env"

# ---------------------------------------------------------------------------
if [ "$VERIFY_ONLY" = false ]; then
log "uploading to $DEST"
# ---------------------------------------------------------------------------
# tract_geom_orig.parquet is ~500 MB and goes as a multipart upload. A 64 MB
# chunk keeps the part count low for the gateway; the throwaway config file
# keeps the setting out of the user's ~/.aws/config.
UPLOAD_CFG="$BUILD_DIR/aws-upload.cfg"
cat > "$UPLOAD_CFG" <<'CFG'
[default]
s3 =
    multipart_threshold = 64MB
    multipart_chunksize = 64MB
CFG

AWS_CONFIG_FILE="$UPLOAD_CFG" aws_s3 s3 sync "$PARQUET_DIR/" "$DEST" --no-progress
rm -f "$UPLOAD_CFG"
log "  upload finished"
fi

# ---------------------------------------------------------------------------
log "comparing remote sizes against local"
# ---------------------------------------------------------------------------
fail=0
while read -r size key; do
  base=$(basename "$key")
  local_size=$(stat -f %z "$PARQUET_DIR/$base" 2>/dev/null || echo missing)
  if [ "$size" = "$local_size" ]; then
    printf '  PASS  %-28s %s bytes\n' "$base" "$size"
  else
    printf '  FAIL  %-28s remote %s vs local %s\n' "$base" "$size" "$local_size"
    fail=1
  fi
done < <(aws_s3 s3 ls "$DEST" | awk '{print $3, $4}')

n_remote=$(aws_s3 s3 ls "$DEST" | wc -l | tr -d ' ')
n_local=$(ls -1 "$PARQUET_DIR"/*.parquet | wc -l | tr -d ' ')
[ "$n_remote" = "$n_local" ] || { printf '  FAIL  %s remote objects vs %s local files\n' "$n_remote" "$n_local"; fail=1; }
[ "$fail" = 0 ] || die "remote objects do not match local files"

# ---------------------------------------------------------------------------
log "reading the Parquet back over HTTP with DuckDB httpfs"
# ---------------------------------------------------------------------------
# The secret goes into a mode-600 scratch file rather than the command line, so
# it never reaches the process list or the log.
REMOTE_SQL="$BUILD_DIR/remote_check.sql"
umask 077
cat > "$REMOTE_SQL" <<SQL
INSTALL httpfs; LOAD httpfs;
INSTALL spatial; LOAD spatial;

-- URL_STYLE 'path' is required: the gateway is Versity, not AWS.
CREATE OR REPLACE SECRET taiga (
  TYPE s3, PROVIDER config,
  KEY_ID '$AWS_ACCESS_KEY_ID', SECRET '$AWS_SECRET_ACCESS_KEY',
  ENDPOINT '$(s3_endpoint_hostport)', URL_STYLE 'path',
  USE_SSL true, REGION '$AWS_DEFAULT_REGION'
);

SET parquet_metadata_cache = true;   -- fetch each footer once per session
SET prefetch_all_parquet_files = false;

CREATE OR REPLACE MACRO verdict(ok) AS CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END;

.print '--- remote row counts ---'
SELECT 'tract_attrs' AS file, count(*) AS n, verdict(count(*) = $EXPECTED_ROWS) AS result
  FROM read_parquet('s3://$BUCKET_NAME/$PREFIX/tract_attrs.parquet')
UNION ALL
SELECT regexp_extract(filename, 'tract_(geom_[a-z]+)\.parquet\$', 1), count(*),
       verdict(count(*) = $EXPECTED_ROWS)
  FROM read_parquet('s3://$BUCKET_NAME/$PREFIX/tract_geom_*.parquet', filename = true)
  GROUP BY 1
UNION ALL
SELECT 'tract_columns', count(*), verdict(count(*) = 43)
  FROM read_parquet('s3://$BUCKET_NAME/$PREFIX/tract_columns.parquet')
ORDER BY file;

.print ''
.print '--- a real viewport query, remote (Chicago, geom_med joined to attrs) ---'
SELECT count(*) AS tracts,
       count(DISTINCT superclass) AS superclasses,
       round(avg(median_household_income)) AS avg_median_income,
       sum(ST_NPoints(geom)) AS vertices
FROM read_parquet('s3://$BUCKET_NAME/$PREFIX/tract_geom_med.parquet') g
JOIN read_parquet('s3://$BUCKET_NAME/$PREFIX/tract_attrs.parquet') a USING (tract_id)
WHERE g.xmin <= -87.52 AND g.xmax >= -87.94
  AND g.ymin <=  42.02 AND g.ymax >=  41.64;

.print ''
.print '--- the heavy one: geom_orig for the same viewport ---'
SELECT count(*) AS tracts, sum(ST_NPoints(geom)) AS vertices
FROM read_parquet('s3://$BUCKET_NAME/$PREFIX/tract_geom_orig.parquet')
WHERE xmin <= -87.52 AND xmax >= -87.94 AND ymin <= 42.02 AND ymax >= 41.64;
SQL

duckdb :memory: -bail -c ".read $REMOTE_SQL"
rm -f "$REMOTE_SQL"

log ""
log "published to $DEST"
