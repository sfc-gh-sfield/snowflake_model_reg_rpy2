# SQL Execution & dbplyr Integration
# =============================================================================

#' Execute a SQL query and return results
#'
#' Runs a SQL query against Snowflake and returns the result as an R
#' data.frame.
#'
#' @param conn An `sfr_connection` object from [sfr_connect()].
#' @param sql Character. SQL query string.
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
sfr_query <- function(conn, sql) {
  validate_connection(conn)
  stopifnot(is.character(sql), length(sql) == 1L)

  result <- conn$session$sql(sql)$to_pandas()
  df <- as.data.frame(result)

  # Lowercase column names for R friendliness
  names(df) <- tolower(names(df))
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
