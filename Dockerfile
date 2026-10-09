# SFGC Shiny app. The data lives in Parquet on S3 and is read in place by
# DuckDB, so the image holds only R, the packages and app.R.
#
#   docker build -t sfgc .
#   docker run --rm -p 3838:3838 --env-file .env sfgc
#
# S3 settings (AWS_ENDPOINT_URL, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# BUCKET_NAME, ...) come from the environment at run time; no .env is baked in.

FROM rocker/r-ver:4.5.2

# rocker's versioned tags freeze CRAN at the date the next R release came out,
# which is too old here: leafgl < 0.2.4 breaks addGlPolygons on a
# leafletProxy. Pin a newer Posit Package Manager snapshot instead (still
# prebuilt Ubuntu noble binaries). Bump the date to pick up package updates.
ARG P3M_SNAPSHOT=2026-10-08
RUN echo "options(repos = c(CRAN = 'https://p3m.dev/cran/__linux__/noble/${P3M_SNAPSHOT}'))" \
      >> /usr/local/lib/R/etc/Rprofile.site

# Runtime libraries for sf (GDAL, GEOS, PROJ, udunits); the binary R packages
# link against these.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libgdal-dev libgeos-dev libproj-dev libudunits2-dev \
      libssl-dev libcurl4-openssl-dev libxml2-dev \
 && rm -rf /var/lib/apt/lists/*

# Same package list as install_deps.R. That script pins repos to CRAN, which
# would compile everything from source, so install2.r is used here instead
# with rocker's default binary repo. --error fails the build on any failure.
RUN install2.r --error --skipinstalled --ncpus -1 \
      shiny duckdb DBI sf dplyr leaflet leafgl glue colourpicker bslib \
      shinyTree shinyWidgets htmltools \
 && rm -rf /tmp/downloaded_packages

RUN useradd --create-home --uid 1000 shiny
USER shiny
WORKDIR /home/shiny/app

# app.R runs INSTALL httpfs at startup. Fetch it now into ~/.duckdb so the
# container needs no outbound access to the DuckDB extension repository.
RUN Rscript -e 'con <- DBI::dbConnect(duckdb::duckdb()); DBI::dbExecute(con, "INSTALL httpfs"); DBI::dbExecute(con, "LOAD httpfs"); DBI::dbDisconnect(con, shutdown = TRUE)'

COPY --chown=shiny:shiny app.R .

EXPOSE 3838
CMD ["Rscript", "-e", "shiny::runApp('.', host = '0.0.0.0', port = 3838, launch.browser = FALSE)"]
