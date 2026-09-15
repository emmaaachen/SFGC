# Installs everything app.R needs. Run once, from the app directory:
#
#   Rscript install_deps.R          # or source() it in RStudio
#
# The data now lives in Parquet on S3 and is queried in place by DuckDB, so
# RPostgres/rpostgis are no longer needed; duckdb replaces them.

packages <- c(
  "shiny",
  "duckdb",        # queries the remote Parquet; needs >= 1.4 for read_parquet over S3
  "DBI",
  "sf",
  "dplyr",
  "leaflet",
  "leafgl",
  "glue",
  "colourpicker",
  "bslib",
  "shinyTree",
  "shinyWidgets",
  "htmltools"
)

missing <- setdiff(packages, rownames(installed.packages()))

if (length(missing) == 0) {
  message("All dependencies already installed.")
} else {
  message("Installing: ", paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
}

# duckdb pulls the httpfs extension on first use, which needs network access
# once; it is then cached under ~/.duckdb and shared with the DuckDB CLI.
