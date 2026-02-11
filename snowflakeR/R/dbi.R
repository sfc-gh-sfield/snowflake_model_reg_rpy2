# DBI Methods — Minimum Viable Implementation
# =============================================================================
# Implements the core DBI generics so that sfr_connection objects work with
# standard R database tooling (dbplyr, RStudio connection pane, etc.).
#
# We don't formally subclass DBI::DBIDriver/DBIConnection/DBIResult because
# DBI is only in Suggests (not Imports). Instead, we provide S4 methods that
# register when DBI is available.

# -----------------------------------------------------------------------------
# S3-based helpers that always work (no DBI dependency)
# -----------------------------------------------------------------------------

#' Disconnect a Snowflake connection
#'
#' Closes the underlying Snowpark session.
#'
#' @param conn An `sfr_connection` object.
#'
#' @returns Invisibly returns `TRUE`.
#'
#' @export
sfr_disconnect <- function(conn) {
  validate_connection(conn)
  tryCatch(
    conn$session$close(),
    error = function(e) {
      cli::cli_warn("Session close failed: {conditionMessage(e)}")
    }
  )
  cli::cli_inform("Disconnected.")
  invisible(TRUE)
}


#' List tables in the current database/schema
#'
#' @param conn An `sfr_connection` object.
#' @param database Character. Database to query. Default: connection's current.
#' @param schema Character. Schema to query. Default: connection's current.
#'
#' @returns A character vector of table names.
#'
#' @export
sfr_list_tables <- function(conn, database = NULL, schema = NULL) {
  validate_connection(conn)
  db <- database %||% conn$database
  sc <- schema %||% conn$schema

  if (is.null(db) || is.null(sc)) {
    cli::cli_abort("Both {.arg database} and {.arg schema} are required.")
  }

  sql <- sprintf(
    "SHOW TABLES IN %s.%s",
    db, sc
  )
  result <- conn$session$sql(sql)$to_pandas()
  df <- as.data.frame(result)

  if (nrow(df) == 0) return(character(0))

  # SHOW TABLES returns a 'name' column
  name_col <- if ("name" %in% names(df)) "name" else names(df)[2]
  as.character(df[[name_col]])
}


#' List columns/fields of a table
#'
#' @param conn An `sfr_connection` object.
#' @param table_name Character. Name of the table.
#'
#' @returns A data.frame with column names and types.
#'
#' @export
sfr_list_fields <- function(conn, table_name) {
  validate_connection(conn)
  stopifnot(is.character(table_name), length(table_name) == 1L)

  sql <- sprintf("DESCRIBE TABLE %s", table_name)
  result <- conn$session$sql(sql)$to_pandas()
  df <- as.data.frame(result)
  names(df) <- tolower(names(df))
  df
}


#' Check if a table exists
#'
#' @param conn An `sfr_connection` object.
#' @param table_name Character. Name of the table.
#'
#' @returns Logical.
#'
#' @export
sfr_table_exists <- function(conn, table_name) {
  validate_connection(conn)
  stopifnot(is.character(table_name), length(table_name) == 1L)

  tables <- tryCatch(
    sfr_list_tables(conn),
    error = function(e) character(0)
  )

  toupper(table_name) %in% toupper(tables)
}


#' Read an entire table into a data.frame
#'
#' @param conn An `sfr_connection` object.
#' @param table_name Character. Name of the table.
#' @param limit Integer. Maximum rows to return. Default: no limit.
#'
#' @returns A data.frame.
#'
#' @export
sfr_read_table <- function(conn, table_name, limit = NULL) {
  validate_connection(conn)
  stopifnot(is.character(table_name), length(table_name) == 1L)

  sql <- sprintf("SELECT * FROM %s", table_name)
  if (!is.null(limit)) {
    sql <- paste(sql, "LIMIT", as.integer(limit))
  }
  sfr_query(conn, sql)
}


#' Write a data.frame to a Snowflake table
#'
#' @param conn An `sfr_connection` object.
#' @param table_name Character. Name of the target table.
#' @param value A data.frame to write.
#' @param overwrite Logical. If `TRUE`, replaces the table. If `FALSE`
#'   (default), appends or creates.
#'
#' @returns Invisibly returns `TRUE`.
#'
#' @export
sfr_write_table <- function(conn, table_name, value, overwrite = FALSE) {
  validate_connection(conn)
  stopifnot(is.data.frame(value))

  py_df <- reticulate::r_to_py(value)
  sp_df <- conn$session$create_dataframe(py_df)

  mode <- if (overwrite) "overwrite" else "append"
  sp_df$write$mode(mode)$save_as_table(table_name)

  cli::cli_inform("Wrote {nrow(value)} rows to {.val {table_name}}.")
  invisible(TRUE)
}


# -----------------------------------------------------------------------------
# DBI generics registration (only when DBI is loaded)
# -----------------------------------------------------------------------------
# S3 methods for DBI generics are registered in .onLoad() in zzz.R
# when the DBI package is available. This avoids a hard dependency on DBI
# while still enabling standard R database tooling.

# Internal DBI method implementations (not exported directly)
# These are registered as S3 methods for DBI generics in .onLoad()

#' @noRd
dbGetQuery.sfr_connection <- function(conn, statement, ...) {
  sfr_query(conn, statement)
}

#' @noRd
dbExecute.sfr_connection <- function(conn, statement, ...) {
  sfr_execute(conn, statement)
}

#' @noRd
dbListTables.sfr_connection <- function(conn, ...) {
  sfr_list_tables(conn, ...)
}

#' @noRd
dbListFields.sfr_connection <- function(conn, name, ...) {
  fields <- sfr_list_fields(conn, name)
  as.character(fields$name)
}

#' @noRd
dbExistsTable.sfr_connection <- function(conn, name, ...) {
  sfr_table_exists(conn, name)
}

#' @noRd
dbDisconnect.sfr_connection <- function(conn, ...) {
  sfr_disconnect(conn)
}

#' @noRd
dbReadTable.sfr_connection <- function(conn, name, ...) {
  sfr_read_table(conn, name)
}

#' @noRd
dbWriteTable.sfr_connection <- function(conn, name, value, ...,
                                        overwrite = FALSE) {
  sfr_write_table(conn, name, value, overwrite = overwrite)
}
