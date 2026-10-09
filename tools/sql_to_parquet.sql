-- Step 1: stage the pg_dump COPY block into DuckDB.
--
-- Reads the data region of classified_tracts_levels.sql from stdin, one row per
-- line, with a 1-based tract_id already prepended by the awk in sql_to_parquet.sh.
-- The Postgres COPY text format is a TSV with quoting and escaping switched off.
--
-- The explicit `columns` map below is the single place where the dump's display
-- column names become snake_case, in dump order. Keep it in sync with the
-- tract_columns VALUES list in emit_parquet.sql.

INSTALL spatial;
LOAD spatial;

SET memory_limit = '8GB';
SET preserve_insertion_order = true;

CREATE OR REPLACE TABLE staging AS
SELECT * REPLACE (
    -- spatial 1.5.4 has no ST_GeomFromHEXEWKB; ST_GeomFromHEXWKB reads the
    -- EWKB SRID flag (0x20000000) correctly and drops the SRID, which is what
    -- we want since DuckDB's GEOMETRY type does not carry one.
    ST_GeomFromHEXWKB(geom_orig)   AS geom_orig,
    ST_GeomFromHEXWKB(geom_high)   AS geom_high,
    ST_GeomFromHEXWKB(geom_med)    AS geom_med,
    ST_GeomFromHEXWKB(geom_low)    AS geom_low,
    ST_GeomFromHEXWKB(geom_lowest) AS geom_lowest
  )
FROM read_csv(
  '/dev/stdin',
  delim = '\t', quote = '', escape = '', header = false, nullstr = '\N',
  -- The widest row is 4,098,580 bytes (one tract's geom_orig hex), well over
  -- the 2 MB default. 16 MB leaves room without pretending to know a bound.
  max_line_size = 16777216,
  columns = {
    'tract_id':                                           'INTEGER',
    'pct_white_alone':                                    'DOUBLE',
    'pct_black_alone':                                    'DOUBLE',
    'pct_aian_alone':                                     'DOUBLE',
    'pct_asian_alone':                                    'DOUBLE',
    'pct_nhpi_alone':                                     'DOUBLE',
    'pct_other_race_alone':                               'DOUBLE',
    'pct_two_or_more_races':                              'DOUBLE',
    'pct_hispanic_or_latino':                             'DOUBLE',
    'pct_under_18':                                       'DOUBLE',
    'pct_18_to_39':                                       'DOUBLE',
    'pct_40_to_64':                                       'DOUBLE',
    'pct_65_plus':                                        'DOUBLE',
    'pct_couple_only_hh':                                 'DOUBLE',
    'pct_couple_with_children':                           'DOUBLE',
    'pct_single_parent_with_children':                    'DOUBLE',
    'pct_nonfamily_hh':                                   'DOUBLE',
    'pct_english_only':                                   'DOUBLE',
    'pct_spanish':                                        'DOUBLE',
    'pct_edu_hs_or_less':                                 'DOUBLE',
    'pct_edu_some_college_to_bachelors':                  'DOUBLE',
    'pct_edu_masters_or_higher':                          'DOUBLE',
    'pct_employed':                                       'DOUBLE',
    'pct_occ_management_business_science_arts':           'DOUBLE',
    'pct_occ_service':                                    'DOUBLE',
    'pct_occ_sales_office':                               'DOUBLE',
    'pct_occ_natural_resources_construction_maintenance': 'DOUBLE',
    'pct_occ_production_transportation_material_moving':  'DOUBLE',
    'median_year_moved_in':                               'DOUBLE',
    'median_household_income':                            'DOUBLE',
    'pct_below_poverty':                                  'DOUBLE',
    'pct_public_assistance_income':                       'DOUBLE',
    'pct_owner_occupied':                                 'DOUBLE',
    'pct_renter_occupied':                                'DOUBLE',
    'median_house_value':                                 'DOUBLE',
    'median_gross_rent':                                  'DOUBLE',
    'pct_housing_cost_over_30pct':                        'DOUBLE',
    'pct_units_1_detached_or_attached':                   'DOUBLE',
    'pct_units_2_to_4':                                   'DOUBLE',
    'pct_units_5_or_more':                                'DOUBLE',
    'pct_units_mobile_home':                              'DOUBLE',
    'predominant_race':                                   'VARCHAR',
    'superclass':                                         'VARCHAR',
    'class':                                              'VARCHAR',
    'geom_orig':                                          'VARCHAR',
    'geom_high':                                          'VARCHAR',
    'geom_med':                                           'VARCHAR',
    'geom_low':                                           'VARCHAR',
    'geom_lowest':                                        'VARCHAR'
  }
);
