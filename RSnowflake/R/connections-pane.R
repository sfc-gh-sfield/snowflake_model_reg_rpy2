# RStudio / Positron Connections Pane Integration
# =============================================================================
# Notifies the IDE when a SnowflakeConnection is opened or closed so it
# appears in the Connections Pane.  These hooks are no-ops when running
# outside an IDE that supports the connections contract.

#' Notify the IDE that a Snowflake connection was opened
#' @noRd
.on_connection_opened <- function(conn) {
  observer <- getOption("connectionObserver")
  if (is.null(observer)) return(invisible())

  tryCatch({
    observer$connectionOpened(
      type        = "Snowflake",
      displayName = paste0(conn@account, " [", conn@database, "]"),
      host        = paste0(conn@account, ".snowflakecomputing.com"),
      connectCode = .connect_code(conn),
      disconnect  = function() { dbDisconnect(conn) },
      listObjectTypes = function() {
        list(
          database = list(
            icon = "catalog",
            contains = list(
              schema = list(
                icon = "schema",
                contains = list(
                  table = list(icon = "table", contains = "data")
                )
              )
            )
          )
        )
      },
      listObjects = function(catalog = NULL, schema = NULL, ...) {
        .pane_list_objects(conn, catalog, schema)
      },
      listColumns = function(catalog = NULL, schema = NULL, table = NULL, ...) {
        .pane_list_columns(conn, catalog, schema, table)
      },
      previewObject = function(rowLimit, catalog = NULL, schema = NULL,
                               table = NULL, ...) {
        .pane_preview(conn, catalog, schema, table, rowLimit)
      },
      connectionObject = conn
    )
  }, error = function(e) {
    invisible()
  })
}

#' Notify the IDE that a Snowflake connection was closed
#' @noRd
.on_connection_closed <- function(conn) {
  observer <- getOption("connectionObserver")
  if (is.null(observer)) return(invisible())

  tryCatch({
    observer$connectionClosed(
      type = "Snowflake",
      host = paste0(conn@account, ".snowflakecomputing.com")
    )
  }, error = function(e) {
    invisible()
  })
}

#' Generate dbConnect() code for the Connections Pane "Connect" button
#' @noRd
.connect_code <- function(conn) {
  parts <- c('library(RSnowflake)')
  args <- character(0)
  if (nzchar(conn@account))   args <- c(args, paste0('account = "', conn@account, '"'))
  if (nzchar(conn@database))  args <- c(args, paste0('database = "', conn@database, '"'))
  if (nzchar(conn@schema))    args <- c(args, paste0('schema = "', conn@schema, '"'))
  if (nzchar(conn@warehouse)) args <- c(args, paste0('warehouse = "', conn@warehouse, '"'))
  parts <- c(parts, paste0("con <- dbConnect(Snowflake(), ", paste(args, collapse = ", "), ")"))
  paste(parts, collapse = "\n")
}

#' List objects for the Connections Pane hierarchy
#' @noRd
.pane_list_objects <- function(conn, catalog, schema) {
  if (is.null(catalog)) {
    resp <- sf_api_submit(conn, "SHOW DATABASES")
    parsed <- sf_parse_response(resp)
    if (nrow(parsed$data) == 0L) return(data.frame(name = character(0), type = character(0)))
    name_col <- which(tolower(parsed$meta$columns$name) == "name")
    return(data.frame(name = parsed$data[[name_col]], type = "database"))
  }
  if (is.null(schema)) {
    qdb <- dbQuoteIdentifier(conn, catalog)
    resp <- sf_api_submit(conn, paste0("SHOW SCHEMAS IN DATABASE ", qdb))
    parsed <- sf_parse_response(resp)
    if (nrow(parsed$data) == 0L) return(data.frame(name = character(0), type = character(0)))
    name_col <- which(tolower(parsed$meta$columns$name) == "name")
    return(data.frame(name = parsed$data[[name_col]], type = "schema"))
  }
  qdb <- dbQuoteIdentifier(conn, catalog)
  qsch <- dbQuoteIdentifier(conn, schema)
  resp <- sf_api_submit(conn, paste0("SHOW TABLES IN SCHEMA ", qdb, ".", qsch))
  parsed <- sf_parse_response(resp)
  if (nrow(parsed$data) == 0L) return(data.frame(name = character(0), type = character(0)))
  name_col <- which(tolower(parsed$meta$columns$name) == "name")
  data.frame(name = parsed$data[[name_col]], type = "table")
}

#' List columns for the Connections Pane column preview
#' @noRd
.pane_list_columns <- function(conn, catalog, schema, table) {
  fqn <- paste0(
    dbQuoteIdentifier(conn, catalog), ".",
    dbQuoteIdentifier(conn, schema), ".",
    dbQuoteIdentifier(conn, table)
  )
  resp <- sf_api_submit(conn, paste0("SHOW COLUMNS IN TABLE ", fqn))
  parsed <- sf_parse_response(resp)
  if (nrow(parsed$data) == 0L) {
    return(data.frame(name = character(0), type = character(0)))
  }
  name_col <- which(tolower(parsed$meta$columns$name) == "column_name")
  type_col <- which(tolower(parsed$meta$columns$name) == "data_type")
  if (length(name_col) == 0L) {
    return(data.frame(name = character(0), type = character(0)))
  }
  data.frame(
    name = parsed$data[[name_col]],
    type = if (length(type_col) > 0L) parsed$data[[type_col]] else "unknown"
  )
}

#' Preview table data for the Connections Pane
#' @noRd
.pane_preview <- function(conn, catalog, schema, table, rowLimit = 100L) {
  fqn <- paste0(
    dbQuoteIdentifier(conn, catalog), ".",
    dbQuoteIdentifier(conn, schema), ".",
    dbQuoteIdentifier(conn, table)
  )
  dbGetQuery(conn, paste0("SELECT * FROM ", fqn, " LIMIT ", as.integer(rowLimit)))
}
