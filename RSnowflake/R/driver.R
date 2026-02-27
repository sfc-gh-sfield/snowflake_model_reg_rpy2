# SnowflakeDriver S4 Class
# =============================================================================

#' SnowflakeDriver
#'
#' An S4 class representing the Snowflake DBI driver.
#'
#' @param dbObj A [SnowflakeDriver-class] object.
#' @param object A [SnowflakeDriver-class] object (for `show`).
#' @export
setClass("SnowflakeDriver", contains = "DBIDriver")

#' Create a SnowflakeDriver instance
#'
#' @returns A SnowflakeDriver singleton.
#' @export
#' @examples
#' \dontrun{
#' drv <- Snowflake()
#' con <- dbConnect(drv, account = "myaccount", name = "default")
#' }
Snowflake <- function() {
  new("SnowflakeDriver")
}

#' @rdname SnowflakeDriver-class
#' @export
setMethod("dbGetInfo", "SnowflakeDriver", function(dbObj, ...) {
  list(
    driver.version = utils::packageVersion("RSnowflake"),
    client.version = utils::packageVersion("RSnowflake"),
    max.connections = Inf
  )
})

#' @rdname SnowflakeDriver-class
#' @export
setMethod("dbIsValid", "SnowflakeDriver", function(dbObj, ...) {
  TRUE
})

#' @rdname SnowflakeDriver-class
#' @export
setMethod("dbUnloadDriver", "SnowflakeDriver", function(drv, ...) {
  invisible(TRUE)
})

#' @rdname SnowflakeDriver-class
#' @export
setMethod("show", "SnowflakeDriver", function(object) {
  cat("<SnowflakeDriver>\n")
})

#' @rdname SnowflakeDriver-class
#' @param obj An R object to map to a Snowflake SQL type.
#' @export
setMethod("dbDataType", "SnowflakeDriver", function(dbObj, obj, ...) {
  r_to_sf_type(obj)
})

#' @rdname SnowflakeDriver-class
#' @param drv A SnowflakeDriver, or missing (uses default).
#' @param account Snowflake account identifier (e.g. "myaccount").
#' @param user Snowflake username.
#' @param token Explicit bearer token (PAT or session token).
#' @param private_key_path Path to PEM private key for JWT auth.
#' @param authenticator Auth method ("SNOWFLAKE_JWT", "OAUTH", etc.).
#' @param database Default database.
#' @param schema Default schema.
#' @param warehouse Default warehouse.
#' @param role Default role.
#' @param name Profile name from connections.toml.
#' @param ... Additional arguments (ignored).
#' @export
setMethod("dbConnect", "SnowflakeDriver",
  function(drv, account = NULL, user = NULL, token = NULL,
           private_key_path = NULL, authenticator = NULL,
           database = "", schema = "", warehouse = "", role = "",
           name = NULL, ...) {

    # Workspace Notebook auto-detection (env var, token file, or host)
    if (is.null(token) && is.null(account) && .is_workspace()) {
      account <- .resolve_workspace_account()
    }

    # Resolve parameters from connections.toml if not given explicitly
    if (is.null(account)) {
      profile <- sf_read_connections_toml(name)
      if (!is.null(profile)) {
        account          <- account %||% profile$account
        user             <- user %||% profile$user
        authenticator    <- authenticator %||% profile$authenticator
        private_key_path <- private_key_path %||% profile$private_key_path
        database         <- if (nzchar(database)) database else (profile$database %||% "")
        schema           <- if (nzchar(schema)) schema else (profile$schema %||% "")
        warehouse        <- if (nzchar(warehouse)) warehouse else (profile$warehouse %||% "")
        role             <- if (nzchar(role)) role else (profile$role %||% "")
      }
    }

    if (is.null(account) || !nzchar(account)) {
      cli_abort(c(
        "x" = "Snowflake {.arg account} is required.",
        "i" = "Pass {.arg account} directly or configure {.file connections.toml}."
      ))
    }

    auth <- sf_auth_resolve(
      account = account,
      user = user,
      token = token,
      private_key_path = private_key_path,
      authenticator = authenticator
    )

    con <- new("SnowflakeConnection",
      account   = account,
      user      = user %||% "",
      database  = database %||% "",
      schema    = schema %||% "",
      warehouse = warehouse %||% "",
      role      = role %||% "",
      .auth     = auth,
      .state    = .new_conn_state()
    )

    # Validate the connection by querying the current session
    tryCatch({
      resp <- sf_api_submit(con, "SELECT CURRENT_VERSION() AS version")
      con@.state$session_info <- resp
      cli_inform(c(
        "v" = "Connected to Snowflake account {.val {account}}.",
        "i" = "Database: {.val {database}}, Warehouse: {.val {warehouse}}"
      ))
    }, error = function(e) {
      cli_abort(c(
        "x" = "Failed to connect to Snowflake account {.val {account}}.",
        "x" = conditionMessage(e)
      ))
    })

    .on_connection_opened(con)
    con
  }
)

#' @rdname SnowflakeDriver-class
#' @export
setMethod("dbCanConnect", "SnowflakeDriver",
  function(drv, ...) {
    tryCatch({
      con <- dbConnect(drv, ...)
      dbDisconnect(con)
      TRUE
    }, error = function(e) FALSE)
  }
)

#' Connect to Snowflake using a profile name
#'
#' Convenience wrapper around `dbConnect(Snowflake(), name = ...)`.
#'
#' @param name Profile name from connections.toml.
#' @param ... Additional arguments passed to dbConnect.
#' @returns A SnowflakeConnection.
#' @export
sf_connect <- function(name = NULL, ...) {
  dbConnect(Snowflake(), name = name, ...)
}
