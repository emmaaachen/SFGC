# Parquet conversion

Turns `classified_tracts_levels.sql` (a 1.7 GB pg_dump of the PostGIS table) into
seven DuckDB-ready Parquet files and publishes them to S3, so the app no longer
needs a Postgres + PostGIS server. Implements `PARQUET_CONVERSION_PLAN.md`.

## Running it

```sh
tools/sql_to_parquet.sh     # dump -> build/parquet/  (~1 min)
tools/verify_parquet.sh     # correctness suite       (~1 min)
tools/upload_parquet.sh     # publish + read back     (~2 min)
```

`tools/sql_to_parquet.sh --emit-only` reuses an existing `build/staging.duckdb`
to iterate on the output layout without re-parsing the dump.
`tools/verify_parquet.sh --quick` skips the dump round-trip.
`tools/upload_parquet.sh --verify-only` re-checks S3 without re-uploading.

Requires `duckdb` (spatial + httpfs extensions, installed on first run), `aws`,
and `ogrinfo` for the GeoParquet interop check. Credentials, endpoint and bucket
come from `.env`, which is gitignored and never echoed.

## Output

Published to `s3://private/sfgc/parquet/`, 107,243 rows per data file:

| file | size | row groups |
|---|---|---|
| `tract_attrs.parquet` | 12.9 MB | 14 |
| `tract_columns.parquet` | 2.2 KB | 1 |
| `tract_geom_orig.parquet` | 525.7 MB | 53 |
| `tract_geom_high.parquet` | 27.8 MB | 27 |
| `tract_geom_med.parquet` | 12.7 MB | 14 |
| `tract_geom_low.parquet` | 8.8 MB | 14 |
| `tract_geom_lowest.parquet` | 8.0 MB | 14 |

Every file carries `tract_id` plus flat `xmin, ymin, xmax, ymax` columns, is
sorted in identical Hilbert order, and is ZSTD compressed. `tract_id` is the
1-based row number in the dump — there is no natural key in the source, so it is
only meaningful across these seven files.

The bbox columns are **always** computed from `geom_orig`, never from the
simplified geometry. That is what makes a viewport filter return the same row set
at every level of detail, matching PostGIS's `geom_orig && ST_MakeEnvelope(...)`.
Verified: all five LODs return exactly 1,045 tracts for the Chicago viewport.

## Querying it

```sql
INSTALL httpfs; LOAD httpfs; INSTALL spatial; LOAD spatial;

-- URL_STYLE 'path' is required: the gateway is Versity, not AWS.
CREATE SECRET taiga (
  TYPE s3, PROVIDER config,
  KEY_ID '…', SECRET '…',
  ENDPOINT 'taiga-dtn-s3.ncsa.illinois.edu:51019',
  URL_STYLE 'path', USE_SSL true, REGION 'us-east-1'
);
SET parquet_metadata_cache = true;      -- one footer fetch per session
SET prefetch_all_parquet_files = false; -- leave off, it defeats the pruning

SELECT a.*, g.geom
FROM read_parquet('s3://private/sfgc/parquet/tract_geom_med.parquet') g
JOIN read_parquet('s3://private/sfgc/parquet/tract_attrs.parquet') a USING (tract_id)
WHERE g.xmin <= :east AND g.xmax >= :west
  AND g.ymin <= :north AND g.ymax >= :south;
```

The four bbox comparisons replace `geom_orig && ST_MakeEnvelope(...)`; they are
definitionally equivalent, since PostGIS's `&&` is itself a bbox test.

`tract_columns.parquet` (`name, label, group_name, kind, ordinal`) replaces the
hardcoded `var_choices` and `categorical_vars` lists at `app.R:46-68`. `label`
is the original dump column name, so the UI reads identically.

## Measured behaviour

A metro-scale viewport against `tract_geom_orig.parquet` touches **2 of 53 row
groups — 9.1 MB instead of 525.6 MB** (58x). Over HTTP that query runs in ~4.5 s
versus ~20.3 s for a full scan. Smaller viewports at high zoom, which is the only
time the app uses `geom_orig`, touch a single row group.

## Notes where reality differed from PARQUET_CONVERSION_PLAN.md

- **`ST_GeomFromHEXEWKB` does not exist** in spatial for DuckDB 1.5.4. Only
  `ST_GeomFromHEXWKB`, which reads the EWKB SRID flag correctly and drops the
  SRID. Verified bit-identical WKB round-trip against the dump.
- **`ROW_GROUP_SIZE 1024` is clamped to 2048**, DuckDB's vector size, so
  `tract_geom_orig` has 53 row groups rather than the ~105 the plan assumed.
  Measured cost is still single-digit MB per viewport, so the optional split into
  16 Hilbert-range files is not needed.
- **Hilbert bounds are measured, not hardcoded.** The data extent is
  `BOX(-179.147 17.881, 179.778 71.390)` — Aleutian tracts really do cross the
  antimeridian, so the plan's `{-180, 15, -64, 72}` box would have clipped them.
- **`max_line_size` must be raised.** The widest dump row is 4,098,580 bytes,
  over DuckDB's 2 MB default; the script uses 16 MB.
- **DuckDB `GEOMETRY` carries no SRID**, so the plan's `ST_SRID = 4326` assertion
  is not expressible. The CRS is instead checked through the GeoParquet metadata
  with `ogrinfo`, which reports `EPSG:4326`.
- **The PostGIS round-trip could not be run** — the local server is down. It is
  also unnecessary: `&&` is a bbox test, so the four-comparison form is
  definitionally equivalent. The round-trip against the dump text runs instead.

## Not done here

Rewiring `app.R` from RPostgres to DuckDB is out of scope; see the follow-on
section of `PARQUET_CONVERSION_PLAN.md`. Note that `st_read(con, query=)`
(`app.R:944`, `app.R:1118`) has no DuckDB equivalent and becomes a fetch plus
`sf::st_as_sf(df, wkb = "geom", crs = 4326)`.
