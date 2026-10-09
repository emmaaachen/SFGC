-- Round-trip check: compare Parquet against the raw dump text for the sample
-- rows that verify_parquet.sh extracted into build/sample.tsv (tract_id already
-- prepended, so each line is 49 tab-separated fields).
--
-- The dump lines are split positionally rather than re-declaring the 49-column
-- map from sql_to_parquet.sql, so this check stays an independent read of the
-- source instead of a copy of the conversion's own assumptions. Column identity
-- comes from tract_columns.ordinal, which is the artifact being checked.

LOAD spatial;

CREATE OR REPLACE MACRO verdict(ok) AS CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END;

CREATE OR REPLACE VIEW cols AS SELECT * FROM 'build/parquet/tract_columns.parquet';

-- Read whole lines: delim is chr(1), which cannot occur in the dump.
CREATE OR REPLACE TABLE src AS
SELECT parts[1]::INTEGER AS tract_id,
       parts[2:44]  AS attr_txt,   -- 43 attributes, dump order
       parts[45:49] AS geom_hex    -- orig, high, med, low, lowest
FROM (
  SELECT str_split(line, chr(9)) AS parts
  FROM read_csv('build/sample.tsv', delim = chr(1), quote = '', escape = '',
                header = false, max_line_size = 16777216,
                columns = {'line': 'VARCHAR'})
);

.print ''
.print '--- sample shape (every line must have 49 fields) ---'
SELECT count(*) AS sampled,
       min(len(attr_txt)) AS min_attrs, max(len(attr_txt)) AS max_attrs,
       verdict(min(len(attr_txt)) = 43 AND max(len(attr_txt)) = 43
               AND min(len(geom_hex)) = 5 AND max(len(geom_hex)) = 5) AS result
FROM src;

-- ---------------------------------------------------------------------------
-- Attributes: dump text vs Parquet value, compared numerically for numeric
-- columns and textually for the three text columns.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE src_long AS
SELECT s.tract_id, i AS ordinal, nullif(s.attr_txt[i], '\N') AS txt
FROM src s, range(1, 44) t(i);

CREATE OR REPLACE VIEW pq_wide AS
SELECT * FROM 'build/parquet/tract_attrs.parquet'
WHERE tract_id IN (SELECT tract_id FROM src);

-- Long form via JSON rather than UNPIVOT: UNPIVOT drops null values, which
-- would silently shrink the comparison (the attribute columns do contain
-- nulls). json_keys and '$.*' keep column order and preserve nulls.
CREATE OR REPLACE TABLE pq_long AS
SELECT tract_id, name, val FROM (
  SELECT tract_id,
         unnest(json_keys(to_json(pq_wide))) AS name,
         unnest(json_extract_string(to_json(pq_wide), '$.*')) AS val
  FROM pq_wide
) WHERE name NOT IN ('tract_id', 'xmin', 'ymin', 'xmax', 'ymax');

CREATE OR REPLACE TABLE compared AS
SELECT s.tract_id, c.ordinal, c.name, c.kind, s.txt AS dump_value, p.val AS parquet_value,
       CASE WHEN c.kind = 'numeric'
            THEN s.txt::DOUBLE IS NOT DISTINCT FROM p.val::DOUBLE
            ELSE s.txt IS NOT DISTINCT FROM p.val END AS ok
FROM src_long s
JOIN cols c ON c.ordinal = s.ordinal
JOIN pq_long p ON p.tract_id = s.tract_id AND p.name = c.name;

.print ''
.print '--- attribute round-trip (20 tracts x 43 columns = 860 values) ---'
SELECT count(*) AS values_compared,
       count(*) FILTER (WHERE NOT ok) AS mismatches,
       verdict(count(*) = (SELECT count(*) FROM src) * 43
               AND count(*) FILTER (WHERE NOT ok) = 0) AS result
FROM compared;

.print '--- any mismatches (empty means clean) ---'
SELECT tract_id, name, dump_value, parquet_value FROM compared WHERE NOT ok LIMIT 20;

.print '--- nulls in the sample: must be null on both sides ---'
SELECT count(*) AS null_values,
       count(*) FILTER (WHERE dump_value IS NULL AND parquet_value IS NULL) AS agreeing,
       verdict(count(*) = count(*) FILTER (WHERE dump_value IS NULL AND parquet_value IS NULL))
         AS result
FROM compared WHERE dump_value IS NULL OR parquet_value IS NULL;

-- ---------------------------------------------------------------------------
-- Geometry: vertex counts per level of detail, decoded straight from the dump
-- hex and compared with what is in each Parquet file.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE src_geom AS
SELECT tract_id,
       ['geom_orig','geom_high','geom_med','geom_low','geom_lowest'][i] AS lod,
       ST_NPoints(ST_GeomFromHEXWKB(geom_hex[i])) AS dump_npoints
FROM src, range(1, 6) t(i);

CREATE OR REPLACE TABLE pq_geom AS
SELECT regexp_extract(filename, 'tract_(geom_[a-z]+)\.parquet$', 1) AS lod,
       tract_id, ST_NPoints(geom) AS parquet_npoints
FROM read_parquet('build/parquet/tract_geom_*.parquet', filename = true)
WHERE tract_id IN (SELECT tract_id FROM src);

.print ''
.print '--- geometry vertex-count round-trip, per LOD ---'
SELECT s.lod,
       count(*) AS tracts,
       sum(s.dump_npoints) AS dump_vertices,
       sum(p.parquet_npoints) AS parquet_vertices,
       count(*) FILTER (WHERE s.dump_npoints IS DISTINCT FROM p.parquet_npoints) AS mismatches,
       verdict(count(*) = (SELECT count(*) FROM src)
               AND count(*) FILTER (WHERE s.dump_npoints IS DISTINCT FROM p.parquet_npoints) = 0)
         AS result
FROM src_geom s JOIN pq_geom p ON p.lod = s.lod AND p.tract_id = s.tract_id
GROUP BY s.lod ORDER BY s.lod;

.print ''
.print '--- geometry is bit-identical to the dump (WKB comparison, geom_orig) ---'
SELECT count(*) AS tracts,
       count(*) FILTER (WHERE NOT same) AS mismatches,
       verdict(count(*) FILTER (WHERE NOT same) = 0) AS result
FROM (
  SELECT ST_AsWKB(ST_GeomFromHEXWKB(s.geom_hex[1])) = ST_AsWKB(g.geom) AS same
  FROM src s
  JOIN read_parquet('build/parquet/tract_geom_orig.parquet') g USING (tract_id)
);
