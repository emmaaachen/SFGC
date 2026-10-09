# SFGC: Socially Fair Geodemographic Clustering of US Neighborhoods

An interactive Shiny map of roughly 107,000 US census tracts, each assigned to a
socially fair geodemographic cluster. Tracts are coloured by their **Superclass**
(5 groups, A–E) or **Class** (18 sub-groups, A1–E3), and the user can explore the
43 demographic, housing and income variables behind the classification.

## What the app does

- **Map** – a Leaflet map rendered with WebGL (`leafgl`), coloured by Superclass or
  Class, with a legend.
- **Popups** – click a tract to see any variables you selected in the popup tree
  (race, age, household type, language, education, occupation, income, housing
  unit type, housing costs, occupants, and more).
- **Filters** – add numeric range filters or categorical filters on any variable,
  then press *Reload* to re-query. Filter widgets don't trigger a re-query on
  every edit.
- **Zoom-based level of detail** – low zoom levels draw heavily simplified
  geometry; only tracts inside the current viewport are fetched.
- **About page** – a navbar tab with a static background map.

## Architecture

All of the app lives in [app.R](app.R) (a single-file Shiny app using
`navbarPage`). It is organised in the following layers.

### 1. Data source (`app.R` top)

- `load_dot_env()` reads `.env` next to the app, but never overrides variables
  already set in the environment, so a deployment can use real env vars and ship
  no `.env`.
- A single shared in-memory DuckDB connection (`con`) is opened at startup and
  closed with `onStop`. It loads the `httpfs` extension and creates an S3 secret
  (path-style URLs, since the gateway is Versity rather than AWS).
- `enable_geoparquet_conversion = false` makes DuckDB return geometry as raw WKB,
  so `sf` parses it directly and **no spatial extension is needed at runtime**.
  `parquet_metadata_cache = true` fetches each Parquet footer once;
  `prefetch_all_parquet_files = false` preserves row-group pruning.
- `parquet_src(name)` builds the `read_parquet('s3://…')` expression for a file.

### 2. Metadata from the data

`tract_columns.parquet` maps each snake_case column to its display label, UI group
and kind (`numeric` / `categorical`). At startup the app builds `var_choices`,
`categorical_vars` and the column-name lookup from it, rather than hardcoding
them. Superclass/Class labels and colour palettes are defined in `app.R`.

### 3. Query layer

| Function | Role |
|---|---|
| `zoom_to_geom(zoom)` | Maps zoom to a geometry LOD: ≤4 `lowest`, ≤6 `low`, ≤8 `med`, ≤10 `high`, otherwise `orig` |
| `build_query(bounds, geom_name, filters)` | Builds the SQL: joins the chosen `tract_geom_*` file to `tract_attrs` on `tract_id`, with a bbox predicate from the viewport and `WHERE` clauses from the filters. Columns are aliased back to display labels |
| `read_sf_query(query)` | Runs the query and converts the WKB column into an `sf` data frame (CRS 4326) |
| `var_stats` | One aggregate over `tract_attrs` at startup giving the min/max and category levels used by the filter widgets |

### 4. UI and server

- **Filter module** (`filterRowUI` / `filterRowServer`) – one row per filter, with
  a slider or checkbox group chosen by the variable's kind, plus a remove button.
- **Server** – the viewport and zoom are debounced. A reactive picks the LOD,
  `build_query` runs against DuckDB, and the result goes into `layer_state()`.
  Observers redraw the polygons with `addGlPolygons` through `leafletProxy`,
  which is why changing the colour variable is cheap.
  Map clicks are resolved to a tract with an `sf::st_intersects` point test and
  shown as a popup.

## Data lake setup

There is no database server. The data is stored as **Parquet on S3** (NCSA Taiga
gateway) and queried in place by DuckDB over HTTP range requests.

### Layout

Published under `s3://<bucket>/sfgc/parquet/`, 107,243 rows per data file:

| File | Contents | Size |
|---|---|---|
| `tract_attrs.parquet` | `tract_id`, bbox, 43 snake_case attributes | 12.9 MB |
| `tract_columns.parquet` | `name, label, group_name, kind, ordinal` lookup | 2 KB |
| `tract_geom_orig.parquet` | full-resolution geometry | 526 MB |
| `tract_geom_high.parquet` | simplified | 28 MB |
| `tract_geom_med.parquet` | simplified | 13 MB |
| `tract_geom_low.parquet` | simplified | 9 MB |
| `tract_geom_lowest.parquet` | simplified | 8 MB |

Design choices that make remote reads cheap:

- **Geometry is split by LOD**, so low-zoom queries never touch the 526 MB
  full-resolution file.
- **Identical Hilbert ordering in every file**, so spatially adjacent tracts share
  row groups and bbox statistics actually prune.
- **Flat `xmin, ymin, xmax, ymax` columns** in every file, always computed from
  `geom_orig`, so a viewport filter needs no join and returns the same tracts at
  every LOD.
- **`tract_id`** is a synthetic 1-based row number from the original dump (the
  source has no natural key). It is only meaningful across these seven files.
- ZSTD compression, with row-group sizes tuned for range requests.

A metro-sized viewport against `tract_geom_orig.parquet` reads 2 of 53 row groups
(~9 MB instead of 526 MB).

### Building the lake from the source dump

The conversion scripts are in [tools/](tools/) (details in
[tools/README.md](tools/README.md); design in
[PARQUET_CONVERSION_PLAN.md](PARQUET_CONVERSION_PLAN.md)).

```bash
tools/sql_to_parquet.sh     # pg_dump -> build/parquet/   (~1 min)
tools/verify_parquet.sh     # correctness suite           (~1 min)
tools/upload_parquet.sh     # publish to S3 and read back (~2 min)
```

This needs the `duckdb` CLI (spatial and httpfs extensions), the `aws` CLI, and
`ogrinfo`. The source `classified_tracts_levels.sql` (1.7 GB) is gitignored.

## Running the app

1. Install the R dependencies:

   ```bash
   Rscript install_deps.R
   ```

2. Configure S3 access:

   ```bash
   cp .env.example .env   # then fill in the values
   ```

   | Variable | Purpose |
   |---|---|
   | `AWS_ENDPOINT_URL` | S3 gateway, e.g. `https://taiga-dtn-s3.ncsa.illinois.edu:51019` |
   | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | credentials |
   | `BUCKET_NAME` | bucket holding the Parquet files |
   | `PARQUET_PREFIX` | optional, default `sfgc/parquet` |
   | `AWS_DEFAULT_REGION` | optional, default `us-east-1` |

3. Start the app:

   ```bash
   Rscript -e 'shiny::runApp(".")'
   ```

   The first run needs network access so DuckDB can install `httpfs`.

R packages: `shiny`, `duckdb` (>= 1.5), `DBI`, `sf`, `dplyr`, `leaflet`, `leafgl`,
`glue`, `colourpicker`, `bslib`, `shinyTree`, `shinyWidgets`, `htmltools`.

## Repository contents

| Path | Purpose |
|---|---|
| `app.R` | The Shiny app |
| `install_deps.R` | Installs the R dependencies |
| `.env.example` | Template for S3 configuration |
| `tools/` | Dump-to-Parquet conversion, verification and upload scripts |
| `PARQUET_CONVERSION_PLAN.md` | Design notes for the Parquet layout |
