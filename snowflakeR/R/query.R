# SQL Execution & dbplyr Integration
# =============================================================================

#' Execute a SQL query and return results
#'
#' Runs a SQL query against Snowflake and returns the result as an R
#' data.frame. The entire pandas/numpy conversion is done on the Python
#' side (via JSON round-trip) to avoid NumPy 1.x/2.x ABI issues that
#' can cause reticulate to fail when converting numpy-backed DataFrames.
#'
#' Column names are lowercased by default for R friendliness. Use
#' `.keep_case = TRUE` to preserve original Snowflake casing (needed
#' for DBI/dbplyr compatibility).
#'
#' @param conn An `sfr_connection` object from [sfr_connect()].
#' @param sql Character. SQL query string.
#' @param .keep_case Logical. If `TRUE`, preserve original column name
#'   casing from Snowflake. Default: `FALSE` (lowercase).
#'
#' @returns A data.frame with query results.
#'
#' @examples
#' \dontrun{
#' conn <- sfr_connect()
#' result <- sfr_query(conn, "SELECT CURRENT_TIMESTAMP() AS now")
#' }
#'
#' @export
sfr_query <- function(conn, sql, .keep_case = FALSE) {
  validate_connection(conn)
  stopifnot(is.character(sql), length(sql) == 1L)

  # Run query and convert entirely on Python side (avoids numpy ABI issues)
  bridge <- get_bridge_module("sfr_connect_bridge")
  result <- bridge$query_to_dict(conn$session, sql)

  cols <- result$columns

  if (result$nrows == 0L) {
    df <- data.frame(matrix(ncol = length(cols), nrow = 0))
    names(df) <- if (.keep_case) cols else tolower(cols)
    return(df)
  }

  df <- as.data.frame(result$data, stringsAsFactors = FALSE)

  # Replace NA sentinel strings with proper R NA values
  na_sentinel <- "NA_SENTINEL_"
  for (col in names(df)) {
    if (is.character(df[[col]])) {
      df[[col]][df[[col]] == na_sentinel] <- NA_character_
    }
  }

  # Try to convert character columns to numeric where appropriate
  for (col in names(df)) {
    if (is.character(df[[col]])) {
      non_na <- df[[col]][!is.na(df[[col]])]
      if (length(non_na) > 0) {
        num_vals <- suppressWarnings(as.numeric(non_na))
        if (!any(is.na(num_vals))) {
          df[[col]] <- as.numeric(df[[col]])
        }
      }
    }
  }

  # Lowercase column names for R friendliness (unless DBI/dbplyr needs original casing)
  if (!.keep_case) {
    names(df) <- tolower(names(df))
  }
  df
}


#' Execute a SQL statement for side effects
#'
#' Runs DDL, DML, or other SQL that doesn't return a result set.
#'
#' @param conn An `sfr_connection` object from [sfr_connect()].
#' @param sql Character. SQL statement string.
#'
#' @returns Invisibly returns `TRUE` on success.
#'
#' @examples
#' \dontrun{
#' conn <- sfr_connect()
#' sfr_execute(conn, "CREATE TABLE test_table (id INT, name STRING)")
#' }
#'
#' @export
sfr_execute <- function(conn, sql) {
  validate_connection(conn)
  stopifnot(is.character(sql), length(sql) == 1L)

  conn$session$sql(sql)$collect()
  invisible(TRUE)
}
