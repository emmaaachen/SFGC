#!/usr/bin/env bash
# Shared helpers for the Parquet conversion scripts.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
PARQUET_DIR="$BUILD_DIR/parquet"
DUMP="$REPO_ROOT/classified_tracts_levels.sql"
STAGING_DB="$BUILD_DIR/staging.duckdb"

EXPECTED_ROWS=107243

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# .env uses "KEY = value" with spaces, so it cannot be sourced.
load_env() {
  local env_file="$REPO_ROOT/.env" line key val
  [ -f "$env_file" ] || die "missing $env_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    val=$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$key" ] && export "$key=$val"
  done < "$env_file"
  # The Versity gateway pins us-east-1: other regions are rejected with HTTP 400.
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
  [ -n "${AWS_ENDPOINT_URL:-}" ]      || die ".env has no AWS_ENDPOINT_URL"
  [ -n "${AWS_ACCESS_KEY_ID:-}" ]     || die ".env has no AWS_ACCESS_KEY_ID"
  [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || die ".env has no AWS_SECRET_ACCESS_KEY"
  [ -n "${BUCKET_NAME:-}" ]           || die ".env has no BUCKET_NAME"
}

# Endpoint without the scheme, which is what DuckDB's S3 secret wants.
s3_endpoint_hostport() {
  printf '%s' "${AWS_ENDPOINT_URL#*://}" | sed 's#/$##'
}

# Run a scalar query against a DuckDB database and echo the single value.
duck_scalar() {
  local db="$1" sql="$2"
  duckdb "$db" -noheader -list -c "$sql"
}
