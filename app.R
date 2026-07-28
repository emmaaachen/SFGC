library(shiny)
library(RPostgres)
library(rpostgis)
library(DBI)
library(sf)
library(dplyr)
library(leaflet)
library(leafgl)
library(glue)
library(colourpicker)
library(bslib)
library(shinyTree)
library(shinyWidgets)
library(htmltools)

# ------------------------------------------------------------------------------
# general overview
# ------------------------------------------------------------------------------

# zoom-based simplification: geometries are simplified when zoom is lower
# viewport rendering: only geometries visible on the screen are rendered
# inputs: user can select the variable used for coloring the map, popup variables,
# and filters

# ------------------------------------------------------------------------------
# defines variables, lists, dictionaries, etc
# ------------------------------------------------------------------------------

# modify con for online database
con <- dbConnect(RPostgres::Postgres(), dbname = "postgres", host = "localhost",
                 port = 5432, user = "emmachen")

table_name <- "classified_tracts_levels"

geom_cols <- c(
  "geom_orig",
  "geom_high",
  "geom_med",
  "geom_low",
  "geom_lowest"
)

all_cols   <- dbListFields(con, table_name)
attr_cols <- setdiff(all_cols, geom_cols)

var_choices <- list(
  "category" = c("Superclass", "Class"),
  "race" = c("% white alone", "% black or african american alone", "% american indian and alaska native alone", 
             "% asian alone", "% native hawaiian and other pacific islander alone", "% some other race alone", 
             "% two or more races"),
  "age" = c("% under 18 years", "% 18 to 39 years", "% 40 to 64 years", "% 65+ years"),
  "household type" = c("% couple only household", "% couple with children", 
                       "% single parent with children", "% nonfamily households"),
  "language" = c("% english only", "% spanish"),
  "education" = c("% with high school or less", "% with some college, associate's, or bachelor's degree",
                  "% with master's degree or higher"),
  "occupation" = c("% in management, business, science, and arts occupations",
                   "% in service occupations", "% in sales and office occupations", "% in natural resources, construction, and maintenance",    
                   "% in production, transportation, and material moving"),
  "housing unit type" = c("% as 1, detached or attached", "% as 2 to 4", "% as 5 or more", "% as mobile home"),
  "housing costs" = c("Median house value", "Median gross rent",
                      "% spending over 30% of household income on housing"),
  "occupants" = c("% owner occupied", "% renter occupied"),
  "income" = c("Median household income", "% with income below poverty level", "% with public assistance income"),
  "other" = c("% hispanic or latino", "% employed", "Median year householder moved into unit")
)

categorical_vars <- c("Superclass", "Class")

superclass_labels <- c(
  A = "A. Mainstream America",
  B = "B. Affluent Professionals",
  C = "C. Multiracial Hispanic Communities",
  D = "D. Disinvested Black Neighborhoods",
  E = "E. High-Poverty Hispanic Enclaves"
)

class_labels <- c(
  A1 = "A1. White Middle-Class Suburbia",
  A2 = "A2. Low-Income Rural and Small-Town Communities",
  A3 = "A3. Young Urban Renters and Nonfamily Households",
  A4 = "A4. Economically Stressed Renters",
  A5 = "A5. Native American Tribal Communities",
  
  B1 = "B1. Affluent Suburban Families",
  B2 = "B2. High-Cost Asian-Diverse Neighborhoods",
  B3 = "B3. Elite Urban Professionals",
  
  C1 = "C1. Linguistically Concentrated Enclaves",
  C2 = "C2. Mixed Hispanic and Multiracial Communities",
  C3 = "C3. Hispanic Renters with Housing Cost Burden",
  
  D1 = "D1. High-Poverty Black Communities with Low Employment",
  D2 = "D2. Black Single-Parent Renter Neighborhoods",
  D3 = "D3. Black Communities with High Public Assistance",
  D4 = "D4. Severely Disadvantaged Black Communities",
  
  E1 = "E1. Established Low-English Hispanic Communities",
  E2 = "E2. High-Poverty Hispanic Communities",
  E3 = "E3. Severely Impoverished Hispanic Communities"
)

superclass_colors <- c(
  A = "#9DDBF7",
  B = "#00A170",
  C = "#F29B00",
  D = "#E65400",
  E = "#D974A9"
)

class_colors <- c(
  A1 = "#d7edf7",
  A2 = "#bee6f7",
  A3 = "#9DDBF7",
  A4 = "#5bb9e3",
  A5 = "#2e9fd1",
  
  B1 = "#04c98d",
  B2 = "#00A170",
  B3 = "#016144",
  
  C1 = "#f7b339",
  C2 = "#F29B00",
  C3 = "#bf7a00",
  
  D1 = "#eb874d",
  D2 = "#eb6b21",
  D3 = "#E65400",
  D4 = "#bd4602",
  
  E1 = "#e69cc3",
  E2 = "#D974A9",
  E3 = "#a13d71"
)

# ------------------------------------------------------------------------------
# functions
# ------------------------------------------------------------------------------

# matches zoom level to resolution
zoom_to_geom <- function(zoom) {
  dplyr::case_when(
    zoom <= 4  ~ "geom_lowest",
    zoom <= 6  ~ "geom_low",
    zoom <= 8  ~ "geom_med",
    zoom <= 10 ~ "geom_high",
    TRUE       ~ "geom_orig"
  )
}

# builds query based on viewport and filters
build_query <- function(
    bounds = NULL,
    geom_name,
    filters = list()
) {  
  filter_clauses <- character()
  
  for (f in filters) {
    
    col <- DBI::dbQuoteIdentifier(con, f$variable)
    
    # range for numeric columns
    if (f$type == "numeric") {
      
      min_val <- suppressWarnings(as.numeric(f$min))
      max_val <- suppressWarnings(as.numeric(f$max))
      
      if (anyNA(c(min_val, max_val))) next
      
      filter_clauses <- c(
        filter_clauses,
        glue(
          "{col} BETWEEN {min_val} AND {max_val}"
        )
      )
      
      # categories for categorical columns
    } else if (f$type == "categorical") {
      
      if (length(f$values) == 0) next
      
      values <- DBI::dbQuoteString(con, f$values)
      
      filter_clauses <- c(
        filter_clauses,
        glue(
          "{col} IN ({paste(values, collapse=', ')})"
        )
      )
      
    }
    
  }
  
  # conditions/where clause: not null, within bounds, and within filter range/categories
  conditions <- c(
    glue("{geom_name} IS NOT NULL") # some might be null at certain zoom/simplification levels
  )
  
  if (!is.null(bounds)) {
    
    conditions <- c(
      conditions,
      glue("
      geom_orig && ST_MakeEnvelope(
        {bounds$west},
        {bounds$south},
        {bounds$east},
        {bounds$north},
        4326
      )
    ")
    )
    
  }
  
  conditions <- c(
    conditions,
    filter_clauses
  )
  
  where_clause <- glue(
    "WHERE {paste(conditions, collapse = '\nAND ')}"
  )
  
  cols <- paste(DBI::dbQuoteIdentifier(con, attr_cols), collapse = ", ")
  
  # complete query
  glue("
    SELECT
      {cols},
      {geom_name} AS geometry
    FROM {DBI::dbQuoteIdentifier(con, table_name)}
    {where_clause}
  ")
}

# ------------------------------------------------------------------------------
# Filter module: ui and server for filtering. Implemented in main server
# ------------------------------------------------------------------------------

# outputs filter variables and their ranges as well as removal button for each
filterRowUI <- function(id) {
  ns <- NS(id)
  
  div(
    class = "filter-row",
    selectInput(
      ns("var"),
      "Filter variable",
      choices = var_choices
    ),
    uiOutput(ns("rangeUI")),
    actionButton(ns("remove"), "Remove filter", class = "btn-sm btn-outline-danger"),
    hr()
  )
}

# ------- server outputs filter options and stores user selection --------------
filterRowServer <- function(id, full_data) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    # determines filter options based on variable type
    output$rangeUI <- renderUI({
      
      var_i <- input$var
      req(var_i)
      
      df <- full_data()
      
      # categorical options
      if (var_i %in% categorical_vars) {
        
        colors <- if (var_i == "Superclass") superclass_colors else class_colors
        
        levels_i <- sort(unique(stats::na.omit(as.character(sf::st_drop_geometry(df)[[var_i]]))))
        
        pickerInput(
          inputId = ns("range"),
          label = sprintf("Values for %s", var_i),
          choices = levels_i,
          selected = levels_i,
          multiple = TRUE,
          options = list(
            `actions-box` = TRUE,
            `select-all-text` = "Select All",
            `deselect-all-text` = "Deselect All",
            `live-search` = TRUE
          ),
          choicesOpt = list(
            content = lapply(levels_i, function(x) {
              HTML(sprintf(
                "<span style='display:inline-flex;align-items:center;'>
     <span class='filter-color-box' style='background:%s;'></span>
     %s
   </span>",
                colors[x],
                x
              ))
            })
          )
        )
        
        # numeric options (range)
      } else {
        
        vals <- suppressWarnings(as.numeric(sf::st_drop_geometry(df)[[var_i]]))
        vals <- vals[is.finite(vals)]
        
        if (length(vals) == 0) {
          return(tags$p(sprintf("No numeric data available for '%s'.", var_i)))
        }
        
        lo <- floor(min(vals))
        hi <- ceiling(max(vals))
        
        # sliderInput requires a strictly positive range
        if (lo == hi) hi <- lo + 1
        
        sliderInput(
          inputId = ns("range"),
          label = sprintf("Range for %s", var_i),
          min = lo,
          max = hi,
          value = c(lo, hi)
        )
      }
    })
    
    # removes filters when remove is selected
    remove_signal <- reactiveVal(FALSE)
    observeEvent(input$remove, {
      remove_signal(TRUE)
    })
    
    # combines filter variables and their values for filtering in main UI
    filter_spec <- reactive({
      
      var_i   <- input$var
      value_i <- input$range
      
      if (is.null(var_i) || is.null(value_i)) return(NULL)
      
      if (var_i %in% categorical_vars) {
        
        if (!is.character(value_i)) return(NULL)
        
        list(
          variable = var_i,
          type = "categorical",
          values = value_i
        )
        
      } else {
        
        value_i <- suppressWarnings(as.numeric(value_i))
        
        if (length(value_i) != 2 || anyNA(value_i)) return(NULL)
        
        list(
          variable = var_i,
          type = "numeric",
          min = value_i[1],
          max = value_i[2]
        )
      }
    })
    
    list(
      filter_spec   = filter_spec,
      remove_signal = remove_signal
    )
  })
}

# ------------------------------------------------------------------------------
# main ui
# ------------------------------------------------------------------------------

ui <- navbarPage(
  
  title = "Socially Fair Geodemographic Clustering of US Neighborhoods",
  id = "main_nav",
  collapsible = TRUE,
  fluid = TRUE,
  
  header = tagList(
    tags$script(HTML("
  Shiny.addCustomMessageHandler('map_invalidate_size', function(id) {
    var widget = HTMLWidgets.find('#' + id);
    if (widget) {
      var map = widget.getMap();
      if (map) map.invalidateSize();
    }
  });
  
  // watches for changes in navbar height and updates
  function updateNavbarHeight() {
    var navbar = document.querySelector('.navbar');
    if (!navbar) return;
    var h = Math.ceil(navbar.getBoundingClientRect().height);
    if (h > 0) {
      document.documentElement.style.setProperty('--navbar-h', h + 'px');
    }
    ['map', 'map_bg'].forEach(function(id) {
      var widget = HTMLWidgets.find('#' + id);
      if (widget) {
        var map = widget.getMap();
        if (map) map.invalidateSize();
      }
    });
  }

  window.addEventListener('load', updateNavbarHeight);
  window.addEventListener('resize', updateNavbarHeight);
  $(document).on('shiny:connected shiny:visualchange', updateNavbarHeight);

  if (window.ResizeObserver) {
    document.addEventListener('DOMContentLoaded', function() {
      var navbar = document.querySelector('.navbar');
      if (navbar) {
        var ro = new ResizeObserver(function() { updateNavbarHeight(); });
        ro.observe(navbar);
      }
    });
  }
")),
    tags$head(
      tags$link(
        rel = "stylesheet",
        href = "https://fonts.googleapis.com/css2?family=Montserrat:wght@400;600;700&display=swap"
      ),
      tags$style(HTML("
        :root {
          /* fallback */
          --navbar-h: 50px;
        }

        html, body {
          width: 100%;
          height: 100%;
          margin: 0;
        }

        /* removes default padding/margins */
        body {
          overflow: hidden;
        }

        .container-fluid {
          padding-left: 10;
          padding-right: 0;
        }
        
        /* ---------------------- navbar ------------------------------------ */
        /* navbar format */
        .navbar {
          margin-bottom: 0;
          min-height: 70px;
          height: auto;
        }
        
        .navbar-default {
          background-color: black;
          border-color: black;
        }

        .navbar-default .navbar-header,
        .navbar-default .navbar-collapse {
          min-height: 70px;
          height: auto;
          overflow: visible;
        }
        
        /* navbar layout */
        .navbar > .container,
        .navbar > .container-fluid {
          display: flex;
          flex-wrap: wrap;
          align-items: flex-end;
        }
        
        /* title block */
        .navbar-header {
          flex: 1 1 auto;
          min-width: 250px;
          float: none;
          align-self: flex-end;
        }
        
        
        /* navigation block */
        .navbar-collapse {
          flex: 0 1 auto;
          float: none;
          padding-left: 0;
          align-self: flex-end
        }
        
        .navbar-nav {
          float: none;
          display: flex;
          flex-wrap: wrap;
          justify-content: flex-end;
          align-items: flex-end;
          margin: 0 8px 0 auto;
        }
        
        /* place tabs on new line when theres no space */
        @media (max-width: 1200px) {
          .navbar-collapse {
            flex: 1 0 100%;
          }
        
          .navbar-nav {
            justify-content: flex-start;
            margin-top: 10px;
          }
        }
        
        /* app title */
        .navbar-default .navbar-brand {
        
          display: block;
          float: none;
          
          color: white !important;
          font-size: 35px;
          font-weight: 700;
        
          /* allow wrapping */
          white-space: normal;
          word-break: break-word;
        
          height: auto;
          line-height: 1.2;
          padding: 12px 25px 12px 15px;
        
          max-width: 100%;
          overflow: visible;
          text-overflow: clip;
        }
        
        .app-title {
          color: white;
          font-family: 'Montserrat', sans-serif;
          font-size: 35px;
          font-weight: 700;
          line-height: 1.2;
        }
        
        /* tabs */
        .navbar-default .navbar-nav {
          margin-top: 8px;
        }

        .navbar-default .navbar-nav > li > a {
          color: white !important;
          background-color: #7a7f85;
          border-radius: 6px 6px 0 0;
          margin-left: 8px;
          padding: 10px 18px;
          font-size: 17px;
          font-weight: 600;
        }

        .navbar-default .navbar-nav > li > a:hover {
          background-color: #8b9096;
        }

        .navbar-default .navbar-nav > .active > a,
        .navbar-default .navbar-nav > .active > a:hover,
        .navbar-default .navbar-nav > .active > a:focus {
          background-color: white;
          color: #444 !important;
        }
           
        /* ------------------ content --------------------------------------- */
        /* positions all content below navbar (height updated from JS) */
        .container-fluid > .tab-content {
          position: absolute;
          top: var(--navbar-h, 50px);
          left: 0;
          right: 0;
          bottom: 0;
          padding: 0;
          transition: top 0.15s ease;
        }

        .container-fluid > .tab-content > .tab-pane {
          height: 100%;
        }

        .page-wrap {
          position: absolute;
          inset: 0;
        }

        /* ----------------- background page -------------------------------- */
        /* formatting and positioning (center of page-wrap) */
        .background-text-panel {
          position: absolute;
          top: 50%;
          left: 50%;
          transform: translate(-50%, -50%);
          width: 80vw;
          height: 80vh;
          max-width: calc(100% - 60px);
          max-height: calc(100% - 60px);
          overflow-y: auto;
          z-index: 1000;

          background: rgba(255,255,255,0.85);
          backdrop-filter: blur(8px);
          -webkit-backdrop-filter: blur(8px);
          border-radius: 10px;
          padding: 25px 30px;
          box-shadow: 0 4px 16px rgba(0,0,0,.25);

          font-family: 'Montserrat', sans-serif;
          font-size: 14px;
          line-height: 1.6em;
          color: black;
        }

        .background-text-panel h3 {
          font-weight: 700;
          margin-top: 0;
        }

        .background-text-panel h4 {
          font-weight: 600;
        }

        /* background map */
        #map_bg {
          pointer-events: none;
        }

        /* -------------------------- map page ------------------------------ */
        #map {
          position: absolute;
          inset: 0;
        }

        /* left side panel containing controls and legend (positioning relative 
        to page-wrap */
        .left-overlay {
          position: absolute;
          top: 20px;
          left: 20px;
          width: 340px;
          height: calc(100% - 40px);
          display: flex;
          flex-direction: column;
          gap: 15px;
          z-index: 1000;
          pointer-events: none;
        }

        /* --------------- controls (colorvar, popups, filter) -------------- */
        /* panel height automatically accomodates legend */
        #controls {
          flex: 1 1 0;
          min-height: 0;
          overflow-y: auto;
          pointer-events: auto;
          background: rgba(255,255,255,0.70);
          backdrop-filter: blur(8px);
          -webkit-backdrop-filter: blur(8px);
          border-radius: 10px;
          padding: 15px;
          box-shadow: 0 4px 16px rgba(0,0,0,.25);
          font-family: 'Montserrat', sans-serif;
          font-size: 12px;
        }
        
        /* wrap popup options text */
        #popup_tree .jstree-anchor {
          white-space: normal !important;
          height: auto !important;
          line-height: 1.3em;
          display: inline-block;
          vertical-align: top;
          padding-right:20px;
        }

        #popup_tree .jstree-node {
          margin-bottom:4px;
        }

        #popup_tree .jstree-icon.jstree-themeicon {
          display: none !important;
        }

        /* global styling for controls */
        #controls,
        #controls button,
        #controls input,
        #controls select,
        #controls .btn,
        #controls .form-control,
        #controls .bootstrap-select,
        #controls .dropdown-menu,
        #controls .dropdown-item {
          font-family: 'Montserrat', sans-serif;
          font-size: 12px;
        }

        #controls .btn {
          border-radius: 6px;
          padding: 6px 12px;
        }

        #controls .selectize-input,
        #controls .selectize-dropdown,
        #controls .form-select {
          font-family: 'Montserrat', sans-serif;
          font-size: 12px;
        }

        #controls .bootstrap-select .dropdown-toggle,
        #controls .bootstrap-select .dropdown-menu {
          font-family: 'Montserrat', sans-serif;
          font-size: 12px;
        }

        .bootstrap-select .dropdown-menu li a span.text span {
          width: 12px !important;
          height: 12px !important;
          display: inline-block !important;
          margin-right: 8px !important;
          vertical-align: middle;
        }

        .bootstrap-select .filter-option-inner-inner {
          font-family: 'Montserrat', sans-serif;
          font-size: 12px;
        }

        #controls label,
        #controls h6,
        #controls p {
          font-family: 'Montserrat', sans-serif;
          font-size: 12px;
        }

        .filter-color-box {
          display: inline-block;
          width: 12px;
          height: 12px;
          margin-right: 8px;
          vertical-align: middle;
          flex-shrink: 0;
        }

        /* ---------------------- legend ------------------------------------ */
        .leaflet-control.legend {
          background: transparent !important;
          border: none !important;
          box-shadow: none !important;
          margin: 0 !important;
          padding: 0 !important;
          width: 340px;
          box-sizing: border-box;
        }

        #legend_panel {
          width: 100%;
          box-sizing: border-box;
          background: rgba(255,255,255,0.70);
          backdrop-filter: blur(8px);
          -webkit-backdrop-filter: blur(8px);
          border-radius: 10px;
          padding: 15px;
          box-shadow: 0 4px 16px rgba(0,0,0,.25);
          font-family: 'Montserrat', sans-serif;
          font-size: 12px;
          overflow: visible;
          line-height: 1em
        }

        .legend-title {
          font-weight: 600;
          margin-bottom: 10px;
        }

        .legend-items {
          background: transparent;
        }

        .legend-color {
          width: 12px;
          height: 12px;
          flex-shrink: 0;
          margin-right: 8px;
        }
      "))
    )
  ),
  
  # -------------------------- map page ----------------------------------------
  tabPanel(
    "Map",
    
    div(
      class = "page-wrap",
      
      leafletOutput("map", width = "100%", height = "100%"),
      
      div(
        class = "left-overlay",
        
        div(
          id = "controls",
          
          tabsetPanel(
            
            tabPanel(
              "Coloring",
              br(),
              
              selectInput(
                "color_var",
                "Color map by",
                choices = c("Superclass", "Class"),
                selected = "Superclass"
              )
            ),
            
            tabPanel(
              "Popups",
              br(),
              
              shinyTree(
                "popup_tree",
                checkbox = TRUE,
                search = TRUE
              )
            ),
            
            tabPanel(
              "Filters",
              br(),
              
              uiOutput("noFiltersMsg"),
              
              div(id = "filterInsertPoint"),
              
              actionButton("addFilter", "Add filter"),
              
              actionButton(
                "applyFilters",
                "Reload"
              )
            )
          )
        ),
        
        uiOutput("legend_panel")
      )
    )
  ),
  
  # ------------------------------ about page ----------------------------------
  tabPanel(
    "About",
    
    div(
      class = "page-wrap",
      
      leafletOutput("map_bg", width = "100%", height = "100%"),
      
      div(
        class = "background-text-panel",
        
        h3("About"),
        br(),
        p("This interactive map visualizes a national geodemographic classification of the United
          States. The classification groups census tracts across the contiguous United States into 5
          superclasses and 18 classes based on multivariate sociodemographic data from the
          American Community Survey, using a fairness-aware clustering method called socially-
          fair geodemographic clustering (SFGC) that explicitly accounts for equitable
          representation across racial groups."),
        br(),
        p("This map is a product of the Geospatial Computing and Society Lab at the University of
          Illinois Urbana-Champaign. It was developed by Emma Chen under the supervision of PI
          Yue Lin, and supported by the Illinois Geographical Society Research Grant and the
          National Center for Supercomputing Applications’ Students Pushing Innovation (SPIN)
          program.")
      )
    )
  )
)

# ------------------------------------------------------------------------------
# main server
# ------------------------------------------------------------------------------

server <- function(input, output, session) {
  
  observeEvent(input$main_nav, {
    if (input$main_nav == "Map") {
      session$sendCustomMessage("map_invalidate_size", "map")
    }
  })
  
  # background map for about page, interaction disabled
  output$map_bg <- renderLeaflet({
    leaflet(options = leafletOptions(
      zoomControl = FALSE, dragging = FALSE, scrollWheelZoom = FALSE,
      doubleClickZoom = FALSE, boxZoom = FALSE, keyboard = FALSE, touchZoom = FALSE
    )) %>%
      addTiles() %>%
      setView(-110, 39, zoom = 4)
  })
  
  # connects to database
  session$onSessionEnded(function() {
    if (DBI::dbIsValid(con)) dbDisconnect(con)
  })
  
  # defines map and default conditions
  default_bounds <- list(north = 50, south = 25, east = -57, west = -125)
  default_zoom   <- 4
  
  output$map <- renderLeaflet({
    leaflet(
      options = leafletOptions(
        zoomControl = FALSE,
        maxZoom = 14
      )
    ) %>%
      addTiles() %>%
      setView(-110, 39, zoom = default_zoom)
  })
  
  # full table (not restricted to viewport) for filtering and popups
  full_data <- reactive({
    geom_name <- geom_bucket()
    q <- build_query(bounds = NULL, geom_name = geom_name)
    st_read(con, query = q, quiet = TRUE)
  })
  
  # holds the currently-drawn data to avoid recomputing on every redraw
  layer_state <- reactiveVal(NULL)
  
  # sets map coloring based on superclass/class
  palette_state <- reactive({
    var_i <- input$color_var
    if (is.null(var_i)) var_i <- "Superclass"
    if (var_i == "Superclass") {
      list(
        pal = colorFactor(superclass_colors, names(superclass_colors), na.color = "transparent"),
        dom = names(superclass_colors)
      )
    } else {
      list(
        pal = colorFactor(class_colors, names(class_colors), na.color = "transparent"),
        dom = names(class_colors)
      )
    }
  })
  
  # legend panel
  output$legend_panel <- renderUI({
    p <- palette_state()
    var_i <- input$color_var
    if (is.null(var_i)) var_i <- "Superclass"
    legend_labels <- if (var_i == "Superclass") {
      superclass_labels[as.character(p$dom)]
    } else {
      class_labels[as.character(p$dom)]
    }
    legend_labels <- unname(legend_labels)
    div(
      id = "legend_panel",
      tags$div(class = "legend-title", ifelse(var_i == "Superclass", "Superclass", "Class")),
      tags$div(
        class = "legend-items",
        lapply(seq_along(legend_labels), function(i) {
          tags$div(
            style = "display:flex; align-items:flex-start; margin-bottom:6px;",
            tags$span(class = "legend-color", style = paste0("background:", unname(p$pal(p$dom))[i], ";")),
            tags$span(legend_labels[i])
          )
        })
      )
    )
  })
  
  # ----------------------- updates resolution based on zoom -------------------
  # updates parameters when bounds/zoom are modified (debounced by 500)
  view_params <- reactive({
    bounds <- input$map_bounds
    zoom   <- input$map_zoom
    if (is.null(bounds)) bounds <- default_bounds
    if (is.null(zoom))   zoom   <- default_zoom
    list(bounds = bounds, zoom = zoom)
  })
  view_params_d <- debounce(view_params, 1000)
  
  # tracks the bucket/level of zoom and resolution, only changes when zoom changes,
  # not when panning
  geom_bucket <- reactiveVal(zoom_to_geom(default_zoom))
  
  observe({
    vp <- view_params_d()
    new_bucket <- zoom_to_geom(vp$zoom)
    if (!identical(new_bucket, isolate(geom_bucket()))) {
      geom_bucket(new_bucket)
    }
  })
  
  # -------------------------------------------------------------------------
  # Filter row management
  #
  # `filter_ids`     : character vector of currently-live module ids, in the
  #                    order they were added.
  # `filter_returns` : reactiveValues environment mapping id -> the list
  #                    returned by filterRowServer(id, ...), i.e.
  #                    list(filter_spec = <reactive>, remove_signal = <reactive>)
  #
  # Adding a filter creates a brand-new id, inserts that row's UI via
  # insertUI(), and spins up its own moduleServer() call -- existing rows'
  # inputs/outputs/reactives are completely untouched.
  #
  # Removing a filter (row's own "Remove" button, or "clear filter(s)")
  # only ever targets that row's DOM node (removeUI by id-scoped selector)
  # and drops that id from filter_ids()/filter_returns -- again, without
  # touching any other row.
  # -------------------------------------------------------------------------
  
  # all applied  filter variables
  filter_ids     <- reactiveVal(character(0))
  # details from filterRowServer ie specs and remove_signal
  filter_returns <- reactiveValues()
  # number of filter variables applied
  filter_counter <- reactiveVal(0)
  
  output$noFiltersMsg <- renderUI({
    if (length(filter_ids()) == 0) {
      tags$p("No filters applied.")
    }
  })
  
  remove_filter <- function(id) {
    removeUI(selector = paste0("#filterRow_", id))
    filter_ids(setdiff(filter_ids(), id))
    filter_returns[[id]] <- NULL
  }
  
  # when filter is added, increases counter and updates ui
  observeEvent(input$addFilter, {
    
    filter_counter(filter_counter() + 1)
    id <- paste0("f", filter_counter())
    
    insertUI(
      selector = "#filterInsertPoint",
      where = "beforeEnd",
      ui = div(id = paste0("filterRow_", id), filterRowUI(id))
    )
    
    mod <- filterRowServer(id, full_data)
    filter_returns[[id]] <- mod
    filter_ids(c(filter_ids(), id))
    
    # watches for this row's own remove button
    observeEvent(mod$remove_signal(), {
      if (isTRUE(mod$remove_signal())) {
        remove_filter(id)
      }
    }, ignoreInit = TRUE)
    
  })
  
  # compiles filter_spec for each row, skipping those with no values
  # (this is a plain reactive so that dragging a slider / editing a picker
  # does *not*, by itself, trigger a reload -- it's only read below when the
  # user explicitly clicks "Reload")
  filters <- reactive({
    ids <- filter_ids()
    if (length(ids) == 0) return(list())
    
    specs <- lapply(ids, function(id) filter_returns[[id]]$filter_spec())
    Filter(Negate(is.null), specs)
  })
  
  # the filter set actually baked into the map query -- only updated when
  # the "Reload" button is clicked, so in-progress edits to filter rows
  # (choosing a variable, dragging a slider, picking categories) never fire
  # a query on their own
  applied_filters <- reactiveVal(list())
  
  observeEvent(input$applyFilters, {
    applied_filters(filters())
  })
  
  # filters dataset -- reacts to viewport/zoom changes (for panning/zoom
  # simplification) and to applied_filters() (only set via the Reload
  # button above), but NOT to live edits of the filter widgets themselves
  filtered_data <- observe({
    
    vp <- view_params_d()
    gb <- geom_bucket()
    fl <- applied_filters()
    
    q <- build_query(
      bounds = vp$bounds,
      geom_name = gb,
      filters = fl
    )
    
    df <- tryCatch(
      st_read(con, query = q, quiet = TRUE),
      error = function(e) {
        showNotification(
          paste("Couldn't load map data:", conditionMessage(e)),
          type = "error"
        )
        NULL
      }
    )
    
    req(df)
    
    layer_state(df)
    
  })
  
  # ------------------------- popups -------------------------------------------
  
  # renders popup options (nested in categories)
  output$popup_tree <- renderTree({
    
    tree <- lapply(names(var_choices), function(cat) {
      
      vars <- var_choices[[cat]]
      
      x <- as.list(rep("", length(vars)))
      names(x) <- vars
      
      selected <- cat == "category"
      
      lapply(x, function(y) structure(y, stselected = selected))
    })
    
    names(tree) <- names(var_choices)
    
    tree
  })
  
  all_popup_vars <- unlist(var_choices, use.names = FALSE)
  
  # stores all selected popup variables
  popup_vars <- reactive({
    sel <- shinyTree::get_selected(input$popup_tree, format = "names")
    sel <- unique(intersect(unlist(sel, use.names = FALSE), all_popup_vars))
    
    if (length(sel) == 0) return(character(0))
    
    sel
  })
  
  # builds popup html for a single row
  build_popup_html_single <- function(row, vars) {
    
    if (length(vars) == 0) {
      return("No popup variables selected.")
    }
    
    pieces <- vapply(vars, function(v) {
      val <- row[[v]]
      
      if (v == "Superclass") val <- unname(superclass_labels[as.character(val)])
      if (v == "Class")      val <- unname(class_labels[as.character(val)])
      
      sprintf("<strong>%s:</strong> %s", v, htmltools::htmlEscape(val))
    }, character(1))
    
    paste(pieces, collapse = "<br/>")
  }
  
  # calls build_popup_html_single when a geometry is clicked
  observeEvent(input$map_glify_click, {
    
    ev <- input$map_glify_click
    req(ev)
    
    df <- layer_state()
    req(df)
    if (nrow(df) == 0) return(invisible(NULL))
    
    pt <- sf::st_sfc(sf::st_point(c(ev$lng, ev$lat)), crs = sf::st_crs(df))
    
    old_s2 <- sf::sf_use_s2()
    sf::sf_use_s2(FALSE)
    on.exit(sf::sf_use_s2(old_s2), add = TRUE)
    
    hit <- suppressWarnings(sf::st_intersects(pt, df, sparse = FALSE)[1, ])
    idx <- which(hit)[1]
    
    req(!is.na(idx))
    
    row <- as.list(sf::st_drop_geometry(df)[idx, , drop = FALSE])
    
    popup_html <- build_popup_html_single(row, popup_vars())
    
    leafletProxy("map") %>%
      clearPopups() %>%
      addPopups(lng = ev$lng, lat = ev$lat, popup = popup_html)
  })
  
  # --------- renders geometries and implements all elements -------------------
  observeEvent(layer_state(), {
    
    df <- layer_state()
    
    req(df)
    req(nrow(df) > 0)
    
    var <- isolate(input$color_var %||% "Superclass")
    
    p <- palette_state()
    
    df$fill_color <- p$pal(df[[var]])
    
    leafletProxy("map") %>%
      clearGroup("polys") %>%
      addGlPolygons(
        data = df,
        fillColor = ~fill_color,
        fillOpacity = 0.7,
        weight = 1,
        color = "gray",
        layerId = ~seq_len(nrow(df)),
        group = "polys"
      )
    
  }, ignoreNULL = FALSE)
  
  observeEvent(input$color_var, {
    
    df <- layer_state()
    
    req(df)
    req(nrow(df) > 0)
    
    p <- palette_state()
    
    df$fill_color <- p$pal(df[[input$color_var]])
    
    leafletProxy("map") %>%
      clearGroup("polys") %>%
      addGlPolygons(
        data = df,
        fillColor = ~fill_color,
        fillOpacity = 0.7,
        weight = 1,
        color = "gray",
        layerId = ~seq_len(nrow(df)),
        group = "polys"
      )
    
  })
}

shinyApp(ui, server)