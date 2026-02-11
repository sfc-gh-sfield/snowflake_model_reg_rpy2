# Connection & Session Management
# =============================================================================
# Foundation module: all other modules depend on a connection object.
# Integrates with snowflakeauth (optional) for connections.toml support.

# -----------------------------------------------------------------------------
# Internal: Python bridge lazy loader
# -----------------------------------------------------------------------------

#' Get the Python bridge module for a given submodule
#'
#' Lazy-loads the Python bridge from `inst/python/` on first call.
#'
#' @param module_name Base name of the Python module (without `.py`)
#' @returns A Python module object (via reticulate)
#' @noRd
get_bridge_module <- function(module_name) {
  cache_key <- paste0("bridge_", module_name)
  if (!is.null(.pkg_env[[cache_key]])) {
    return(.pkg_env[[cache_key]])
  }

  python_dir <- system.file("python", package = "snowflakeR")
  if (!nzchar(python_dir)) {
    cli::cli_abort(c(
      "Cannot find {.path inst/python/} directory in {.pkg snowflakeR}.",
      "i" = "This suggests the package is not installed correctly."
    ))
  }

  mod <- reticulate::import_from_path(module_name, path = python_dir)
  .pkg_env[[cache_key]] <- mod
  mod
}


# -----------------------------------------------------------------------------
# Exported: Connection
# -----------------------------------------------------------------------------

#' Connect to Snowflake
#'
#' Creates a connection to Snowflake, returning an `sfr_connection` object.
#' Supports multiple authentication methods:
#'
#' - **Auto-detect:** In Workspace Notebooks, wraps the active Snowpark session.
#'   Locally, reads `connections.toml` / `config.toml` (via `snowflakeauth` if
#'   installed) or uses explicit parameters.
#' - **Named connection:** Pass `name` to select a connection from
#'   `connections.toml`.
#' - **Explicit parameters:** Pass `account`, `user`, `authenticator`, etc.
#'
#' @param name Character. Named connection from `connections.toml`. If `NULL`,
#'   uses the default connection.
#' @param account Character. Snowflake account identifier.
#' @param user Character. Snowflake username.
#' @param warehouse Character. Default warehouse.
#' @param database Character. Default database.
#' @param schema Character. Default schema.
#' @param role Character. Role to use.
#' @param authenticator Character. Authentication method (e.g.,
#'   `"externalbrowser"`, `"snowflake"`, `"oauth"`).
#' @param private_key_file Character. Path to PEM-encoded private key for
#'   key-pair authentication.
#' @param ... Additional connection parameters passed to Snowpark session
#'   builder or `snowflakeauth::snowflake_connection()`.
#' @param .use_snowflakeauth Logical. Whether to use `snowflakeauth` for
#'   credential resolution when available. Default: `TRUE`.
#'
#' @returns An `sfr_connection` object (S3 class).
#'
#' @examples
#' \dontrun{
#' # Default connection from connections.toml
#' conn <- sfr_connect()
#'
#' # Named connection
#' conn <- sfr_connect(name = "production")
#'
#' # Explicit parameters
#' conn <- sfr_connect(
#'   account = "xy12345.us-east-1",
#'   user = "MYUSER",
#'   authenticator = "externalbrowser"
#' )
#' }
#'
#' @export
sfr_connect <- function(name = NULL,
                        account = NULL,
                        user = NULL,
                        warehouse = NULL,
                        database = NULL,
                        schema = NULL,
                        role = NULL,
                        authenticator = NULL,
                        private_key_file = NULL,
                        ...,
                        .use_snowflakeauth = TRUE) {
  # Attempt Workspace Notebook auto-detect first
  session <- tryCatch(
    {
      bridge <- get_bridge_module("sfr_connect_bridge")
      bridge$get_active_session()
    },
    error = function(e) NULL
  )

  if (!is.null(session)) {
    # Workspace Notebook environment
    env_type <- "workspace"
    auth_method <- "session_token"
    cli::cli_inform("Connected via active Workspace Notebook session.")
  } else {
    # Local environment - build session from parameters
    env_type <- "local"

    # Try snowflakeauth first
    sf_conn <- NULL
    if (.use_snowflakeauth &&
        requireNamespace("snowflakeauth", quietly = TRUE)) {
      sf_conn <- tryCatch(
        snowflakeauth::snowflake_connection(
          name = name,
          account = account,
          user = user,
          warehouse = warehouse,
          database = database,
          schema = schema,
          role = role,
          authenticator = authenticator,
          private_key_file = private_key_file,
          ...
        ),
        error = function(e) NULL
      )
    }

    if (!is.null(sf_conn)) {
      # Extract params from snowflakeauth connection
      account <- account %||% sf_conn$account
      user <- user %||% sf_conn$user
      warehouse <- warehouse %||% sf_conn$warehouse
      database <- database %||% sf_conn$database
      schema <- schema %||% sf_conn$schema
      role <- role %||% sf_conn$role
      auth_method <- sf_conn$authenticator %||% "snowflake"
    } else {
      auth_method <- authenticator %||% "snowflake"
    }

    # Validate minimum required params
    if (is.null(account)) {
      cli::cli_abort(c(
        "A Snowflake {.arg account} is required.",
        "i" = "Provide it directly, via {.file connections.toml}, or set",
        " " = "{.envvar SNOWFLAKE_ACCOUNT}."
      ))
    }

    # Create Snowpark session via Python bridge
    bridge <- get_bridge_module("sfr_connect_bridge")
    session <- bridge$create_session(
      account = account,
      user = user,
      warehouse = warehouse,
      database = database,
      schema = schema,
      role = role,
      authenticator = auth_method,
      private_key_file = private_key_file
    )

    cli::cli_inform("Connected to Snowflake account {.val {account}}.")
  }

  structure(
    list(
      session = session,
      account = account,
      user = user,
      database = database,
      schema = schema,
      warehouse = warehouse,
      role = role,
      auth_method = auth_method,
      environment = env_type,
      created_at = Sys.time()
    ),
    class = c("sfr_connection", "list")
  )
}


#' Print an sfr_connection object
#'
#' @param x An `sfr_connection` object.
#' @param ... Ignored.
#' @returns Invisibly returns `x`.
#' @export
print.sfr_connection <- function(x, ...) {
  name_label <- x$account %||% "unknown"
  env_label <- x$environment %||% "unknown"
  cli::cli_text("<{.cls sfr_connection}> [{env_label}]")
  fields <- list(
    account = x$account,
    user = x$user,
    database = x$database,
    schema = x$schema,
    warehouse = x$warehouse,
    role = x$role,
    auth_method = x$auth_method,
    environment = x$environment,
    created_at = format(x$created_at, "%Y-%m-%d %H:%M:%S")
  )
  fields <- Filter(Negate(is.null), fields)
  labels <- lapply(names(fields), function(n) cli::format_inline("{.field {n}}"))
  items <- lapply(fields, function(v) cli::format_inline("{.val {v}}"))
  cli::cli_dl(items, labels = labels)
  invisible(x)
}


#' Check if an object is an sfr_connection
#'
#' @param x Object to test.
#' @returns Logical.
#' @noRd
is_sfr_connection <- function(x) {
  inherits(x, "sfr_connection")
}


#' Validate that conn is an sfr_connection
#'
#' @param conn Object to validate.
#' @noRd
validate_connection <- function(conn) {
  if (!is_sfr_connection(conn)) {
    cli::cli_abort(
      "{.arg conn} must be an {.cls sfr_connection} object from {.fn sfr_connect}."
    )
  }
}


#' Check connection status
#'
#' @param conn An `sfr_connection` object.
#' @returns Invisibly returns `TRUE` if the connection is active.
#'
#' @export
sfr_status <- function(conn) {
  validate_connection(conn)
  # TODO: implement actual session health check

  cli::cli_inform(c(
    "v" = "Connection active ({.val {conn$environment}} environment)",
    "i" = "Account: {.val {conn$account}}",
    "i" = "Database: {.val {conn$database %||% '<not set>'}}",
    "i" = "Warehouse: {.val {conn$warehouse %||% '<not set>'}}"
  ))
  invisible(TRUE)
}


#' Switch warehouse, database, or schema
#'
#' @param conn An `sfr_connection` object.
#' @param warehouse Character. New warehouse name.
#' @param database Character. New database name.
#' @param schema Character. New schema name.
#' @returns The modified `sfr_connection` object (invisibly).
#'
#' @export
sfr_use <- function(conn, warehouse = NULL, database = NULL, schema = NULL) {
  validate_connection(conn)
  session <- conn$session

  if (!is.null(warehouse)) {
    session$sql(paste0("USE WAREHOUSE ", warehouse))$collect()
    conn$warehouse <- warehouse
  }
  if (!is.null(database)) {
    session$sql(paste0("USE DATABASE ", database))$collect()
    conn$database <- database
  }
  if (!is.null(schema)) {
    session$sql(paste0("USE SCHEMA ", schema))$collect()
    conn$schema <- schema
  }

  invisible(conn)
}


#' Check if a Snowflake connection can be established
#'
#' Useful for `@examplesIf` and test guards.
#'
#' @param ... Arguments passed to [sfr_connect()].
#' @returns Logical.
#' @export
sfr_has_connection <- function(...) {
  tryCatch(
    {
      sfr_connect(...)
      TRUE
    },
    error = function(e) FALSE
  )
}
