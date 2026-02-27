# dbplyr Backend for Snowflake
# =============================================================================
# Registers SnowflakeConnection as a dbplyr backend, inheriting all of
# dbplyr's built-in Snowflake SQL translations (paste0 -> CONCAT, IFF,
# ARRAY_TO_STRING, lubridate date functions, etc.).
#
# These S3 methods are registered lazily via .onLoad because the generics
# live in dbplyr (a Suggests dependency, not necessarily loaded).

dbplyr_edition.SnowflakeConnection <- function(con) 2L

sql_translation.SnowflakeConnection <- function(con) {
  rlang::check_installed("dbplyr", reason = "for dplyr integration")
  dbplyr::sql_translation(dbplyr::simulate_snowflake())
}

db_connection_describe.SnowflakeConnection <- function(con) {
  paste0(
    "Snowflake ", con@account,
    " [", con@database, ".", con@schema, "]"
  )
}

sql_query_save.SnowflakeConnection <- function(con, sql, name,
                                                temporary = TRUE, ...) {
  rlang::check_installed("dbplyr")
  tmp <- if (temporary) "TEMPORARY " else ""
  dbplyr::build_sql(
    "CREATE ", dbplyr::sql(tmp), "TABLE ", dbplyr::as.sql(name, con = con),
    " AS\n", sql,
    con = con
  )
}

#' Register dbplyr S3 methods (called from .onLoad)
#' @noRd
.register_dbplyr_methods <- function() {
  s3_register <- function(generic, class, method = NULL) {
    stopifnot(is.character(generic), length(generic) == 1L)
    stopifnot(is.character(class), length(class) == 1L)

    pieces <- strsplit(generic, "::")[[1L]]
    stopifnot(length(pieces) == 2L)
    package <- pieces[[1L]]
    name    <- pieces[[2L]]

    if (is.null(method)) {
      method <- get(paste0(name, ".", class), envir = parent.frame())
    }

    if (isNamespaceLoaded(package)) {
      registerS3method(name, class, method, envir = asNamespace(package))
    }

    setHook(
      packageEvent(package, "onLoad"),
      function(...) {
        registerS3method(name, class, method, envir = asNamespace(package))
      }
    )
  }

  s3_register("dbplyr::dbplyr_edition",       "SnowflakeConnection")
  s3_register("dbplyr::sql_translation",       "SnowflakeConnection")
  s3_register("dbplyr::db_connection_describe","SnowflakeConnection")
  s3_register("dbplyr::sql_query_save",        "SnowflakeConnection")
}
