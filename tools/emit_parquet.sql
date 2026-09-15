-- Steps 2 and 3: bbox + Hilbert key, then emit the seven Parquet files.
-- Paths are relative to the repo root; sql_to_parquet.sh cd's there first.

LOAD spatial;

SET memory_limit = '8GB';
SET temp_directory = 'build/tmp';
SET preserve_insertion_order = true;

-- ---------------------------------------------------------------------------
-- Step 2: bbox and Hilbert key
-- ---------------------------------------------------------------------------

-- Hilbert bounds are the measured extent of the data rather than a hardcoded
-- box, so Alaska and Hawaii cannot fall outside it. The ordering only has to be
-- self-consistent across the seven files, which it is: one extent, one sort key.
CREATE OR REPLACE TABLE extent AS
SELECT {
  min_x: min(ST_XMin(geom_orig)), min_y: min(ST_YMin(geom_orig)),
  max_x: max(ST_XMax(geom_orig)), max_y: max(ST_YMax(geom_orig))
}::BOX_2D AS b
FROM staging;

.print '--- data extent (Hilbert bounds) ---'
SELECT b AS data_extent FROM extent;

-- bbox is ALWAYS taken from geom_orig, never from a simplified column.
-- Simplification can shrink an envelope, and the app's predicate is
-- `geom_orig && envelope(...)`; using the geom_orig bbox at every level of
-- detail is what makes each LOD return the same row set as PostGIS does.
CREATE OR REPLACE TABLE ordered AS
SELECT s.*,
       ST_XMin(s.geom_orig) AS xmin,
       ST_YMin(s.geom_orig) AS ymin,
       ST_XMax(s.geom_orig) AS xmax,
       ST_YMax(s.geom_orig) AS ymax,
       ST_Hilbert(s.geom_orig, e.b) AS h
FROM staging s, extent e;

-- ---------------------------------------------------------------------------
-- Step 3: emit
-- ---------------------------------------------------------------------------
-- `ORDER BY h` is repeated in every COPY rather than relying on `ordered`'s
-- physical scan order. Correctness never depends on it (every row carries
-- tract_id), but repeating it guarantees the row groups line up across files,
-- which is the entire point of the layout.

.print '--- writing tract_attrs.parquet ---'
COPY (
  SELECT tract_id, xmin, ymin, xmax, ymax,
         pct_white_alone, pct_black_alone, pct_aian_alone, pct_asian_alone,
         pct_nhpi_alone, pct_other_race_alone, pct_two_or_more_races,
         pct_hispanic_or_latino, pct_under_18, pct_18_to_39, pct_40_to_64,
         pct_65_plus, pct_couple_only_hh, pct_couple_with_children,
         pct_single_parent_with_children, pct_nonfamily_hh, pct_english_only,
         pct_spanish, pct_edu_hs_or_less, pct_edu_some_college_to_bachelors,
         pct_edu_masters_or_higher, pct_employed,
         pct_occ_management_business_science_arts, pct_occ_service,
         pct_occ_sales_office, pct_occ_natural_resources_construction_maintenance,
         pct_occ_production_transportation_material_moving, median_year_moved_in,
         median_household_income, pct_below_poverty, pct_public_assistance_income,
         pct_owner_occupied, pct_renter_occupied, median_house_value,
         median_gross_rent, pct_housing_cost_over_30pct,
         pct_units_1_detached_or_attached, pct_units_2_to_4, pct_units_5_or_more,
         pct_units_mobile_home, predominant_race, superclass, "class"
  FROM ordered ORDER BY h
) TO 'build/parquet/tract_attrs.parquet'
  (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 8192);

.print '--- writing tract_geom_orig.parquet ---'
COPY (SELECT tract_id, xmin, ymin, xmax, ymax, geom_orig AS geom FROM ordered ORDER BY h)
  TO 'build/parquet/tract_geom_orig.parquet'
  (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 1024);

.print '--- writing tract_geom_high.parquet ---'
COPY (SELECT tract_id, xmin, ymin, xmax, ymax, geom_high AS geom FROM ordered ORDER BY h)
  TO 'build/parquet/tract_geom_high.parquet'
  (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 4096);

.print '--- writing tract_geom_med.parquet ---'
COPY (SELECT tract_id, xmin, ymin, xmax, ymax, geom_med AS geom FROM ordered ORDER BY h)
  TO 'build/parquet/tract_geom_med.parquet'
  (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 8192);

.print '--- writing tract_geom_low.parquet ---'
COPY (SELECT tract_id, xmin, ymin, xmax, ymax, geom_low AS geom FROM ordered ORDER BY h)
  TO 'build/parquet/tract_geom_low.parquet'
  (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 8192);

.print '--- writing tract_geom_lowest.parquet ---'
COPY (SELECT tract_id, xmin, ymin, xmax, ymax, geom_lowest AS geom FROM ordered ORDER BY h)
  TO 'build/parquet/tract_geom_lowest.parquet'
  (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 8192);

-- ---------------------------------------------------------------------------
-- Column label lookup, replacing the hardcoded var_choices / categorical_vars
-- lists in app.R:46-68. `label` is the dump column name verbatim so the UI reads
-- identically; `group_name` matches the var_choices grouping. predominant_race
-- is in the data but absent from var_choices, so its group is NULL rather than
-- an invented one.
-- ---------------------------------------------------------------------------

.print '--- writing tract_columns.parquet ---'
COPY (
  SELECT * FROM (VALUES
    ('pct_white_alone', '% white alone', 'race', 'numeric', 1),
    ('pct_black_alone', '% black or african american alone', 'race', 'numeric', 2),
    ('pct_aian_alone', '% american indian and alaska native alone', 'race', 'numeric', 3),
    ('pct_asian_alone', '% asian alone', 'race', 'numeric', 4),
    ('pct_nhpi_alone', '% native hawaiian and other pacific islander alone', 'race', 'numeric', 5),
    ('pct_other_race_alone', '% some other race alone', 'race', 'numeric', 6),
    ('pct_two_or_more_races', '% two or more races', 'race', 'numeric', 7),
    ('pct_hispanic_or_latino', '% hispanic or latino', 'other', 'numeric', 8),
    ('pct_under_18', '% under 18 years', 'age', 'numeric', 9),
    ('pct_18_to_39', '% 18 to 39 years', 'age', 'numeric', 10),
    ('pct_40_to_64', '% 40 to 64 years', 'age', 'numeric', 11),
    ('pct_65_plus', '% 65+ years', 'age', 'numeric', 12),
    ('pct_couple_only_hh', '% couple only household', 'household type', 'numeric', 13),
    ('pct_couple_with_children', '% couple with children', 'household type', 'numeric', 14),
    ('pct_single_parent_with_children', '% single parent with children', 'household type', 'numeric', 15),
    ('pct_nonfamily_hh', '% nonfamily households', 'household type', 'numeric', 16),
    ('pct_english_only', '% english only', 'language', 'numeric', 17),
    ('pct_spanish', '% spanish', 'language', 'numeric', 18),
    ('pct_edu_hs_or_less', '% with high school or less', 'education', 'numeric', 19),
    ('pct_edu_some_college_to_bachelors', '% with some college, associate''s, or bachelor''s degree', 'education', 'numeric', 20),
    ('pct_edu_masters_or_higher', '% with master''s degree or higher', 'education', 'numeric', 21),
    ('pct_employed', '% employed', 'other', 'numeric', 22),
    ('pct_occ_management_business_science_arts', '% in management, business, science, and arts occupations', 'occupation', 'numeric', 23),
    ('pct_occ_service', '% in service occupations', 'occupation', 'numeric', 24),
    ('pct_occ_sales_office', '% in sales and office occupations', 'occupation', 'numeric', 25),
    ('pct_occ_natural_resources_construction_maintenance', '% in natural resources, construction, and maintenance', 'occupation', 'numeric', 26),
    ('pct_occ_production_transportation_material_moving', '% in production, transportation, and material moving', 'occupation', 'numeric', 27),
    ('median_year_moved_in', 'Median year householder moved into unit', 'other', 'numeric', 28),
    ('median_household_income', 'Median household income', 'income', 'numeric', 29),
    ('pct_below_poverty', '% with income below poverty level', 'income', 'numeric', 30),
    ('pct_public_assistance_income', '% with public assistance income', 'income', 'numeric', 31),
    ('pct_owner_occupied', '% owner occupied', 'occupants', 'numeric', 32),
    ('pct_renter_occupied', '% renter occupied', 'occupants', 'numeric', 33),
    ('median_house_value', 'Median house value', 'housing costs', 'numeric', 34),
    ('median_gross_rent', 'Median gross rent', 'housing costs', 'numeric', 35),
    ('pct_housing_cost_over_30pct', '% spending over 30% of household income on housing', 'housing costs', 'numeric', 36),
    ('pct_units_1_detached_or_attached', '% as 1, detached or attached', 'housing unit type', 'numeric', 37),
    ('pct_units_2_to_4', '% as 2 to 4', 'housing unit type', 'numeric', 38),
    ('pct_units_5_or_more', '% as 5 or more', 'housing unit type', 'numeric', 39),
    ('pct_units_mobile_home', '% as mobile home', 'housing unit type', 'numeric', 40),
    ('predominant_race', 'Predominant race', NULL, 'categorical', 41),
    ('superclass', 'Superclass', 'category', 'categorical', 42),
    ('class', 'Class', 'category', 'categorical', 43)
  ) AS t(name, label, group_name, kind, ordinal)
) TO 'build/parquet/tract_columns.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);
