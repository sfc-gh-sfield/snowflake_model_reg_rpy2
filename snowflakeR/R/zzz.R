# Package load/attach hooks
# Following CRAN rules: no side effects on load, no Python init here

# Internal package environment for caching bridge modules, sessions, etc.
.pkg_env <- new.env(parent = emptyenv())

.onLoad <- function(libname, pkgname) {
  # Set default options (user can override)
  op <- options()
  op_sfr <- list(
    snowflakeR.python_env = "r-snowflakeR",
    snowflakeR.verbose = FALSE,
    snowflakeR.print_width = 200L
  )
  toset <- !(names(op_sfr) %in% names(op))
  if (any(toset)) options(op_sfr[toset])

  # Register DBI S3 methods when DBI is available
  # This allows sfr_connection to work with dbGetQuery(), dbplyr, etc.
  if (requireNamespace("DBI", quietly = TRUE)) {
    register_dbi_method <- function(generic, method) {
      registerS3method(generic, "sfr_connection", method,
                       envir = asNamespace("DBI"))
    }
    register_dbi_method("dbGetQuery", dbGetQuery.sfr_connection)
    register_dbi_method("dbExecute", dbExecute.sfr_connection)
    register_dbi_method("dbListTables", dbListTables.sfr_connection)
    register_dbi_method("dbListFields", dbListFields.sfr_connection)
    register_dbi_method("dbExistsTable", dbExistsTable.sfr_connection)
    register_dbi_method("dbDisconnect", dbDisconnect.sfr_connection)
    register_dbi_method("dbReadTable", dbReadTable.sfr_connection)
    register_dbi_method("dbWriteTable", dbWriteTable.sfr_connection)
  }

  invisible()
}

.onAttach <- function(libname, pkgname) {
  packageStartupMessage(
    "snowflakeR ", utils::packageVersion("snowflakeR"),
    " - R interface to the Snowflake ML platform"
  )
}
