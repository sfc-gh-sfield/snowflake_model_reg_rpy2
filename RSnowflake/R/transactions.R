# Transaction Support
# =============================================================================
# The SQL API v2 (/api/v2/statements) is stateless per-request and does not
# support multi-statement transactions (BEGIN/COMMIT/ROLLBACK are rejected
# with code 391911). Session-based transactions require the internal
# /queries/v1/ endpoint, which will be added in a future release.

.txn_not_supported <- function() {
  cli_abort(c(
    "Transactions are not yet supported via the SQL API v2.",
    "i" = "The Snowflake SQL API v2 is stateless per-request.",
    "i" = "Session-based transaction support will be added in a future release."
  ))
}

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbBegin", "SnowflakeConnection", function(conn, ...) {
  .check_valid(conn)
  .txn_not_supported()
})

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbCommit", "SnowflakeConnection", function(conn, ...) {
  .check_valid(conn)
  .txn_not_supported()
})

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbRollback", "SnowflakeConnection", function(conn, ...) {
  .check_valid(conn)
  .txn_not_supported()
})

#' @rdname SnowflakeConnection-class
#' @param code Code to execute within the transaction.
#' @export
setMethod("dbWithTransaction", "SnowflakeConnection",
  function(conn, code, ...) {
    .check_valid(conn)
    .txn_not_supported()
  }
)
