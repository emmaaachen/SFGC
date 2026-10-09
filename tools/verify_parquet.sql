-- Local verification of build/parquet/. Paths are relative to the repo root.
-- Every check has a `result` column reading PASS or FAIL.
--
-- The five geometry files share one schema, so they are read as a single
-- globbed relation with filename = true and grouped by level of detail. That
-- avoids passing a correlated column as a table-function argument, which
-- DuckDB does not allow.

LOAD spatial;
SET parquet_metadata_cache = true;

CREATE OR REPLACE MACRO verdict(ok) AS CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END;

CREATE OR REPLACE VIEW attrs AS SELECT * FROM 'build/parquet/tract_attrs.parquet';
CREATE OR REPLACE VIEW cols  AS SELECT * FROM 'build/parquet/tract_columns.parquet';

CREATE OR REPLACE VIEW geoms AS
SELECT regexp_extract(filename, 'tract_(geom_[a-z]+)\.parquet$', 1) AS lod, *
FROM read_parquet('build/parquet/tract_geom_*.parquet', filename = true);

-- Chicago viewport, used for the pruning checks below.
CREATE OR REPLACE MACRO vp_west()  AS -87.94;
CREATE OR REPLACE MACRO vp_south() AS  41.64;
CREATE OR REPLACE MACRO vp_east()  AS -87.52;
CREATE OR REPLACE MACRO vp_north() AS  42.02;

-- ---------------------------------------------------------------------------
.print ''
.print '=== 1. row counts (expect 107243 per data file, 43 lookup rows) ==='
-- ---------------------------------------------------------------------------
SELECT 'tract_attrs' AS file, count(*) AS n, verdict(count(*) = 107243) AS result FROM attrs
UNION ALL
SELECT lod, count(*), verdict(count(*) = 107243) FROM geoms GROUP BY lod
UNION ALL
SELECT 'tract_columns', count(*), verdict(count(*) = 43) FROM cols
ORDER BY file;

-- ---------------------------------------------------------------------------
.print ''
.print '=== 2. key integrity: tract_id matches tract_attrs both ways ==='
-- ---------------------------------------------------------------------------
WITH per_lod AS (
  SELECT lod,
         count(DISTINCT tract_id) AS distinct_ids,
         count(*) FILTER (WHERE a.tract_id IS NULL) AS extra_in_geom
  FROM geoms g LEFT JOIN attrs a USING (tract_id)
  GROUP BY lod
),
missing AS (
  SELECT lod, count(*) AS missing_from_geom
  FROM (SELECT DISTINCT lod FROM geoms) l CROSS JOIN attrs a
  WHERE NOT EXISTS (SELECT 1 FROM geoms g
                     WHERE g.lod = l.lod AND g.tract_id = a.tract_id)
  GROUP BY lod
)
SELECT p.lod, p.distinct_ids, p.extra_in_geom,
       coalesce(m.missing_from_geom, 0) AS missing_from_geom,
       verdict(p.distinct_ids = 107243 AND p.extra_in_geom = 0
               AND coalesce(m.missing_from_geom, 0) = 0) AS result
FROM per_lod p LEFT JOIN missing m USING (lod) ORDER BY lod;

-- ---------------------------------------------------------------------------
.print ''
.print '=== 3. geometry: no nulls, polygons only, lon/lat in degree range ==='
-- ---------------------------------------------------------------------------
-- DuckDB GEOMETRY carries no SRID, so there is no ST_SRID to assert. The CRS
-- claim is checked by ogrinfo in verify_parquet.sh, which reads the GeoParquet
-- metadata; the range check here only confirms the values are degrees.
SELECT lod,
       count(*) FILTER (WHERE geom IS NULL) AS null_geoms,
       string_agg(DISTINCT ST_GeometryType(geom)::VARCHAR, ', ') AS types,
       count(*) FILTER (WHERE NOT (xmin BETWEEN -180 AND 180 AND xmax BETWEEN -180 AND 180
                              AND ymin BETWEEN  -90 AND  90 AND ymax BETWEEN  -90 AND  90))
         AS out_of_range,
       verdict(count(*) FILTER (WHERE geom IS NULL) = 0
           AND bool_and(ST_GeometryType(geom) IN ('POLYGON', 'MULTIPOLYGON'))
           AND count(*) FILTER (WHERE NOT (xmin BETWEEN -180 AND 180 AND xmax BETWEEN -180 AND 180
                                      AND ymin BETWEEN  -90 AND  90 AND ymax BETWEEN  -90 AND  90))
               = 0) AS result
FROM geoms GROUP BY lod ORDER BY lod;

-- ---------------------------------------------------------------------------
.print ''
.print '=== 4a. bbox identical to tract_attrs for the same tract_id ==='
-- ---------------------------------------------------------------------------
SELECT g.lod,
       count(*) FILTER (WHERE g.xmin IS DISTINCT FROM a.xmin OR g.ymin IS DISTINCT FROM a.ymin
                           OR g.xmax IS DISTINCT FROM a.xmax OR g.ymax IS DISTINCT FROM a.ymax)
         AS mismatches,
       verdict(count(*) FILTER (WHERE g.xmin IS DISTINCT FROM a.xmin OR g.ymin IS DISTINCT FROM a.ymin
                                   OR g.xmax IS DISTINCT FROM a.xmax OR g.ymax IS DISTINCT FROM a.ymax)
               = 0) AS result
FROM geoms g JOIN attrs a USING (tract_id) GROUP BY g.lod ORDER BY g.lod;

.print ''
.print '=== 4b. every simplified envelope sits inside the stored bbox ==='
-- This is what guarantees the app returns the same row set at every zoom: the
-- bbox (always from geom_orig) must bound the geometry actually drawn.
SELECT lod,
       count(*) FILTER (WHERE ST_XMin(geom) < xmin - 1e-9 OR ST_XMax(geom) > xmax + 1e-9
                           OR ST_YMin(geom) < ymin - 1e-9 OR ST_YMax(geom) > ymax + 1e-9)
         AS escapes,
       verdict(count(*) FILTER (WHERE ST_XMin(geom) < xmin - 1e-9 OR ST_XMax(geom) > xmax + 1e-9
                                   OR ST_YMin(geom) < ymin - 1e-9 OR ST_YMax(geom) > ymax + 1e-9)
               = 0) AS result
FROM geoms GROUP BY lod ORDER BY lod;

-- ---------------------------------------------------------------------------
.print ''
.print '=== 5. tract_columns sanity ==='
-- ---------------------------------------------------------------------------
SELECT 'ordinals are 1..43' AS check,
       verdict(count(*) = 43 AND min(ordinal) = 1 AND max(ordinal) = 43
               AND count(DISTINCT ordinal) = 43) AS result FROM cols
UNION ALL
SELECT 'names unique', verdict(count(DISTINCT name) = 43) FROM cols
UNION ALL
SELECT 'kinds are numeric/categorical', verdict(bool_and(kind IN ('numeric','categorical'))) FROM cols
UNION ALL
SELECT 'only predominant_race is ungrouped',
       verdict(count(*) FILTER (WHERE group_name IS NULL) = 1
               AND bool_and(name = 'predominant_race') FILTER (WHERE group_name IS NULL)) FROM cols
UNION ALL
SELECT 'names cover tract_attrs exactly',
       verdict((SELECT count(*) FROM (
                  (SELECT name FROM cols
                   EXCEPT
                   SELECT column_name FROM (DESCRIBE SELECT * FROM attrs)
                    WHERE column_name NOT IN ('tract_id','xmin','ymin','xmax','ymax'))
                  UNION ALL
                  (SELECT column_name FROM (DESCRIBE SELECT * FROM attrs)
                    WHERE column_name NOT IN ('tract_id','xmin','ymin','xmax','ymax')
                   EXCEPT
                   SELECT name FROM cols)
               )) = 0);

.print ''
.print '--- group membership (should mirror var_choices, app.R:46-66) ---'
SELECT coalesce(group_name, '(ungrouped)') AS group_name, count(*) AS n,
       string_agg(name, ', ' ORDER BY ordinal) AS members
FROM cols GROUP BY group_name ORDER BY min(ordinal);

-- ---------------------------------------------------------------------------
.print ''
.print '=== 6. row-group pruning on a metro viewport (Chicago) ==='
-- ---------------------------------------------------------------------------
-- The whole justification for Hilbert ordering plus small row groups: a tight
-- bbox should touch a handful of row groups, not all of them.
.print '--- row groups and file sizes ---'
SELECT regexp_extract(file_name, '([a-z_]+)\.parquet$', 1) AS file,
       count(DISTINCT row_group_id) AS row_groups
FROM parquet_metadata('build/parquet/tract_*.parquet')
GROUP BY file ORDER BY file;

.print '--- geom_orig row groups whose bbox stats overlap the viewport ---'
WITH stats AS (
  SELECT row_group_id,
         max(stats_min::DOUBLE) FILTER (WHERE path_in_schema = 'xmin') AS g_xmin,
         max(stats_max::DOUBLE) FILTER (WHERE path_in_schema = 'xmax') AS g_xmax,
         max(stats_min::DOUBLE) FILTER (WHERE path_in_schema = 'ymin') AS g_ymin,
         max(stats_max::DOUBLE) FILTER (WHERE path_in_schema = 'ymax') AS g_ymax
  FROM parquet_metadata('build/parquet/tract_geom_orig.parquet')
  WHERE path_in_schema IN ('xmin','xmax','ymin','ymax')
  GROUP BY row_group_id
)
SELECT count(*) AS total_row_groups,
       count(*) FILTER (WHERE g_xmin <= vp_east() AND g_xmax >= vp_west()
                          AND g_ymin <= vp_north() AND g_ymax >= vp_south()) AS overlapping,
       round(100.0 * count(*) FILTER (WHERE g_xmin <= vp_east() AND g_xmax >= vp_west()
                                        AND g_ymin <= vp_north() AND g_ymax >= vp_south())
             / count(*), 1) AS pct_scanned,
       verdict(count(*) FILTER (WHERE g_xmin <= vp_east() AND g_xmax >= vp_west()
                                  AND g_ymin <= vp_north() AND g_ymax >= vp_south())
               < count(*) / 4) AS result
FROM stats;

.print '--- rows returned for that viewport, per LOD (must be identical) ---'
SELECT lod, count(*) AS rows_in_viewport
FROM geoms
WHERE xmin <= vp_east() AND xmax >= vp_west()
  AND ymin <= vp_north() AND ymax >= vp_south()
GROUP BY lod ORDER BY lod;
