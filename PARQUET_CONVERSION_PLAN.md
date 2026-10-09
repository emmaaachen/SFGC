# Convert `classified_tracts_levels.sql` to DuckDB-ready Parquet

## Context

`app.R` is a Shiny map of ~107k US census tracts. It talks to a local PostGIS database
(`app.R:30`) and, on every viewport change, issues one query per pan/zoom
(`build_query`, `app.R:152-237`) that selects the 43 attribute columns plus **one** of five
pre-simplified geometry columns, filtered by a bbox intersection against `geom_orig`
(`app.R:206-213`) and by user filters.

That requires everyone who runs the app to stand up Postgres + PostGIS and restore a 1.7 GB
dump. Moving the data to Parquet lets DuckDB read it directly — locally or over HTTP from
object storage — with no database server. The goal of this plan is **only the data
conversion**: produce a reproducible script that turns the dump into a set of Parquet tables
with the layout and statistics the app's query pattern needs. Rewiring `app.R` from RPostgres
to DuckDB is a follow-on, sketched at the end but not in scope here.

## What is actually in the dump (measured, not assumed)

- One table, one `COPY ... FROM stdin` block. Header ends at line 88; data is lines
  **89–107331**; `\.` on 107332; a `CREATE INDEX idx_orig` GiST statement follows.
- **107,243 data rows.** Rows are one per line — the WKB hex is never wrapped.
- 48 columns: 40 `double precision`, 3 `text` (`Predominant race`, `Superclass`, `Class`),
  and 5 `public.geometry`.
- Geometry is **hex EWKB with SRID 4326** (every value starts `0103000020E6100000` →
  polygon, SRID flag, 4326). No `MULTIPOLYGON` seen in samples — verify during conversion.
- **No GEOID, no tract name, no key of any kind.** Rows are identified only by position.
  This is the single most important constraint below.
- **Zero NULLs in all five geometry columns**, so the `{geom_name} IS NOT NULL` guard at
  `app.R:198` is a no-op. Don't carry it forward as if it mattered.
- Size distribution (decoded WKB bytes, full-file scan):

  | column | WKB total | avg/row |
  |---|---|---|
  | `geom_orig` | 737.3 MB | 7,209 B |
  | `geom_high` | 38.3 MB | 374 B |
  | `geom_med` | 16.1 MB | 157 B |
  | `geom_low` | 10.0 MB | 97 B |
  | `geom_lowest` | 8.8 MB | 86 B |
  | attributes | ~100 MB as text | — |

  `geom_orig` is 86% of the dataset. Splitting it into its own file so low-zoom queries
  never touch it is where nearly all of the win comes from.

- Data quirk worth flagging, not fixing: `Predominant race` holds `"0"`/`"1"`, not race
  names, and `app.R` never references it. Carry it through as text; don't try to interpret it.

## Toolchain

`duckdb v1.5.4`, `ogr2ogr` (GDAL 3.13.1), `psql`, `python3`, `Rscript` are all on PATH.
120 GB free on the volume. Two prerequisites:

1. **`INSTALL spatial;`** — the spatial extension is *not* currently installed
   (`~/.duckdb/extensions/v1.5.4/osx_arm64/spatial.duckdb_extension` is missing). Needs
   network once.
2. `INSTALL httpfs;` for the eventual remote reads.

`enable_geoparquet_conversion` is a real setting in this build, so DuckDB will write and read
GeoParquet metadata for `GEOMETRY` columns. There is **no page-index setting** in DuckDB
1.5 — pruning granularity is controlled entirely by `ROW_GROUP_SIZE`, which is why the sizes
below are chosen deliberately.

## Decisions taken (confirmed with user)

- **snake_case columns + a label lookup table.** `app.R`'s `var_choices`/`superclass_labels`/
  `class_labels` get rebuilt from the lookup table instead of hardcoding display strings.
- **Keep `geom_orig` at full precision.** No `ST_ReducePrecision`.
- **Target is remote (S3/HTTP) reads.** So: smaller row groups, and bbox columns duplicated
  into *every* geometry file so a viewport filter needs no join.

## Target layout — 7 Parquet files

All files are written in **identical Hilbert order** and share `tract_id`, so row groups line
up across files and any join is a merge on a clustered key.

```
tract_attrs.parquet        tract_id, xmin, ymin, xmax, ymax, <43 snake_case attrs>   ~10-20 MB
tract_columns.parquet      name, label, group_name, kind, ordinal                    ~4 KB
tract_geom_orig.parquet    tract_id, xmin, ymin, xmax, ymax, geom GEOMETRY        ~500-650 MB
tract_geom_high.parquet    same shape                                                 ~30 MB
tract_geom_med.parquet     same shape                                                 ~14 MB
tract_geom_low.parquet     same shape                                                  ~9 MB
tract_geom_lowest.parquet  same shape                                                  ~8 MB
```

### `tract_id`

A synthetic `INTEGER` = 1-based row number in the dump. There is no natural key, so this id
only has to be *internally consistent across the seven files* — which it is, because it is
assigned exactly once in the staging table and every output derives from that. DuckDB's
`preserve_insertion_order` is `true` in this build, so the staging table preserves dump order
and `row_number()` over it reproduces it. **Do not** re-derive `tract_id` per output file.

### bbox columns

Flat `DOUBLE` columns `xmin, ymin, xmax, ymax`, **always computed from `geom_orig`**, never
from the simplified geometry. Simplification can shrink an envelope slightly, and the app's
predicate is explicitly `geom_orig && envelope(...)` — using the `geom_orig` bbox everywhere
is what makes the Parquet query return the same row set as the Postgres one at every zoom.

Flat columns rather than a GeoParquet 1.1 `bbox` STRUCT: flat leaves are guaranteed to carry
Parquet min/max statistics and are unambiguously pushed down by DuckDB. The same four leaves
can be re-emitted as a `bbox` struct later if GeoPandas/GDAL bbox-covering interop is wanted.

### Row group sizing (tuned for HTTP range requests)

| file | `ROW_GROUP_SIZE` | groups | ≈ bytes/group |
|---|---|---|---|
| `tract_geom_orig` | 1024 | ~105 | ~5-7 MB |
| `tract_geom_high` | 4096 | ~27 | ~1.5 MB |
| `tract_geom_med/low/lowest` | 8192 | ~14 | < 1 MB |
| `tract_attrs` | 8192 | ~14 | ~1 MB |
| `tract_columns` | default | 1 | — |

Compression `ZSTD` throughout.

### Spatial ordering

Sort every file by `ST_Hilbert(geom_orig, {min_x: -180, min_y: 15, max_x: -64, max_y: 72}::BOX_2D)`.
The bounds must cover Alaska and Hawaii, not just CONUS — check the actual data extent first
and widen if Alaska tracts land on the far side of the antimeridian. Hilbert order clusters
spatially adjacent tracts into the same row group, which is the only reason the `xmin/xmax`
statistics prune anything.

## Conversion pipeline

One script pair, e.g. `tools/sql_to_parquet.sh` driving `tools/sql_to_parquet.sql`.

### Step 1 — stage the COPY block into a DuckDB table

Feed only the data lines to DuckDB and let it parse them as a headerless TSV. The Postgres
`COPY` text format maps cleanly onto `read_csv` with quoting and escaping switched off — this
is verified working against the real file:

```sh
sed -n '89,107331p' classified_tracts_levels.sql \
  | duckdb build/staging.duckdb -c ".read tools/sql_to_parquet.sql"
```

```sql
INSTALL spatial; LOAD spatial;

CREATE TABLE staging AS
SELECT
  row_number() OVER () AS tract_id,
  * REPLACE (
    ST_GeomFromHEXEWKB(geom_orig)   AS geom_orig,
    ST_GeomFromHEXEWKB(geom_high)   AS geom_high,
    ST_GeomFromHEXEWKB(geom_med)    AS geom_med,
    ST_GeomFromHEXEWKB(geom_low)    AS geom_low,
    ST_GeomFromHEXEWKB(geom_lowest) AS geom_lowest
  )
FROM read_csv(
  '/dev/stdin',
  delim = '\t', quote = '', escape = '', header = false,
  nullstr = '\N',
  columns = { ... 43 snake_case typed columns, then 5 geom columns as VARCHAR ... }
);
```

Notes:
- The explicit `columns` map is where the rename happens — one place, source order preserved.
- `nullstr='\N'` handles Postgres NULLs. The attribute columns *do* contain nulls even though
  the geometry columns don't.
- Hex→`GEOMETRY` at staging time halves the resident size. Expect `staging.duckdb` around
  0.9–1.1 GB; it is a build artifact and gets deleted at the end.
- Confirm `ST_GeomFromHEXEWKB` (not `ST_GeomFromHEXWKB`) — the values carry the SRID flag,
  and the plain HEXWKB reader will misparse the header.
- Also assert here that no geometry parsed to `NULL` and that
  `ST_GeometryType(geom_orig)` is only `POLYGON`/`MULTIPOLYGON`.

### Step 2 — add bbox and Hilbert key

```sql
CREATE TABLE ordered AS
SELECT *,
       ST_XMin(geom_orig) AS xmin, ST_YMin(geom_orig) AS ymin,
       ST_XMax(geom_orig) AS xmax, ST_YMax(geom_orig) AS ymax,
       ST_Hilbert(geom_orig, {min_x: -180, min_y: 15, max_x: -64, max_y: 72}::BOX_2D) AS h
FROM staging;
```

Print `min(xmin), min(ymin), max(xmax), max(ymax)` before committing to those Hilbert bounds.

### Step 3 — emit the seven files

Six `COPY (SELECT ... FROM ordered ORDER BY h) TO '...' (FORMAT PARQUET, COMPRESSION ZSTD,
ROW_GROUP_SIZE n)` statements, one per table, each selecting `tract_id`, the four bbox
columns, and either the attributes or its one geometry column.

`tract_columns.parquet` is written from an inline `VALUES` list. Its `group_name` values come
straight from the existing `var_choices` list at `app.R:46-66` (`category`, `race`, `age`,
`household type`, `language`, `education`, `occupation`, `housing unit type`,
`housing costs`, `occupants`, `income`, `other`) and `kind` is `numeric` or `categorical`,
matching `categorical_vars` at `app.R:68`. `label` is the original dump column name verbatim,
so the UI reads identically to today. `predominant_race` gets `group_name = NULL` — it is in
the data but absent from `var_choices`, and the lookup table should record that rather than
inventing a home for it.

Proposed naming (43 rows, dump order):

```
pct_white_alone, pct_black_alone, pct_aian_alone, pct_asian_alone, pct_nhpi_alone,
pct_other_race_alone, pct_two_or_more_races, pct_hispanic_or_latino,
pct_under_18, pct_18_to_39, pct_40_to_64, pct_65_plus,
pct_couple_only_hh, pct_couple_with_children, pct_single_parent_with_children,
pct_nonfamily_hh, pct_english_only, pct_spanish,
pct_edu_hs_or_less, pct_edu_some_college_to_bachelors, pct_edu_masters_or_higher,
pct_employed, pct_occ_management_business_science_arts, pct_occ_service,
pct_occ_sales_office, pct_occ_natural_resources_construction_maintenance,
pct_occ_production_transportation_material_moving,
median_year_moved_in, median_household_income, pct_below_poverty,
pct_public_assistance_income, pct_owner_occupied, pct_renter_occupied,
median_house_value, median_gross_rent, pct_housing_cost_over_30pct,
pct_units_1_detached_or_attached, pct_units_2_to_4, pct_units_5_or_more,
pct_units_mobile_home, predominant_race, superclass, class
```

### Step 4 — clean up

Delete `build/staging.duckdb`. Add `build/` and `*.parquet` to `.gitignore` — the current
`.gitignore` already excludes `classified_tracts_levels.sql`, but the 2.3 GB
`classified_tracts_levels.geojson` is currently untracked and unignored; it should be ignored
too. Note that `classified_tracts_levels.geojson.gz` and `.sql.gz` show as deleted in the
working tree; that deletion is unrelated to this work and should be resolved separately.

## Verification

1. **Counts** — `SELECT count(*)` on each of the six data files must equal **107,243**.
2. **Key integrity** — for each geometry file, `tract_id` set-differences against
   `tract_attrs` in both directions must be empty; `count(DISTINCT tract_id) = 107243`.
3. **Geometry validity** — `count(*) WHERE geom IS NULL` is 0 in all five geometry files;
   `SELECT DISTINCT ST_GeometryType(geom)` is only polygon types; `ST_SRID` (or the
   GeoParquet CRS metadata) reports 4326.
4. **Round-trip against the source** — pick ~20 `tract_id`s, pull the same rows out of the
   dump with `sed -n '<line>p'`, and compare attribute values and `ST_NPoints(geom_orig)`.
5. **Round-trip against Postgres** (if the local database is still up): run
   `build_query(bounds = <fixed bbox>, geom_name = "geom_med")` against PostGIS and the
   equivalent DuckDB query — `xmin <= east AND xmax >= west AND ymin <= north AND ymax >= south`
   — and diff the returned row sets. This is the check that the bbox-from-`geom_orig`
   decision actually reproduces `&&` semantics.
6. **Pruning actually works** — this is the whole point of the layout, so measure it:
   `EXPLAIN ANALYZE` a tight viewport bbox against `tract_geom_orig.parquet` and confirm the
   scan touches a handful of row groups, not 105. A metro-scale bbox should read single-digit
   MB, not 600 MB.
7. **Remote behaviour** — with the files on S3/HTTP and `httpfs` loaded, run the same
   viewport query and check bytes fetched. Leave `prefetch_all_parquet_files` off;
   `parquet_metadata_cache` on so the footer is fetched once per session.
8. **Interop** — `ogrinfo tract_geom_med.parquet` should recognise it as a spatial layer,
   confirming the GeoParquet metadata was written rather than a bare BLOB.

## Follow-on, not in this plan

Rewiring `app.R` to DuckDB: replace the `dbConnect(RPostgres::Postgres(), ...)` at `app.R:30`
with a DuckDB connection, point `build_query` at `read_parquet` on the LOD chosen by
`zoom_to_geom` (`app.R:141-149`) joined to `tract_attrs` on `tract_id`, swap
`ST_MakeEnvelope`/`&&` for the four bbox comparisons, drop the dead `IS NOT NULL` clause, and
rebuild `var_choices` and the label vectors from `tract_columns.parquet`. `st_read(con, query=)`
(`app.R:944`, `app.R:1118`) has no DuckDB equivalent and becomes a fetch plus
`sf::st_as_sf(df, wkb = "geom", crs = 4326)`.

One optional refinement if remote `geom_orig` reads still feel heavy: split
`tract_geom_orig.parquet` into ~16 files by Hilbert range so whole files can be skipped.
Row-group pruning inside a single Hilbert-sorted file should make this unnecessary — measure
step 6/7 before adding the complexity.
