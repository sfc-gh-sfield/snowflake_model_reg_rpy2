# Authentication Resolution
# =============================================================================

#' Resolve authentication for a Snowflake connection
#'
#' Determines the auth method and returns a list with `type`, `token`, and
#' `token_type` (the value for the X-Snowflake-Authorization-Token-Type header).
#'
#' Priority order:
#' 1. Explicit bearer token (the `token` parameter)
#' 2. Programmatic Access Token (SNOWFLAKE_PAT env var)
#' 3. Key-pair JWT (private_key_path + account + user)
#' 4. Workspace session token (SNOWFLAKE_TOKEN env var or token file) --
#'    last resort; SPCS tokens are rejected by the SQL API for non-blessed
#'    clients (HTTP 401, code 395092).
#'
#' @param account Account identifier.
#' @param user Username.
#' @param token Explicit bearer token.
#' @param private_key_path Path to PEM private key file.
#' @param authenticator Auth method string.
#' @returns A list with `type` ("jwt", "pat", "token") and `token` (the bearer string).
#' @noRd
sf_auth_resolve <- function(account, user = NULL, token = NULL,
                            private_key_path = NULL,
                            authenticator = NULL) {
  # Priority 1: Explicit bearer token
  if (!is.null(token) && nzchar(token)) {
    return(list(
      type = "token",
      token = token,
      token_type = "PROGRAMMATIC_ACCESS_TOKEN"
    ))
  }

  # Priority 2: Programmatic Access Token (PAT) -- preferred in Workspace
  pat <- Sys.getenv("SNOWFLAKE_PAT", "")
  if (nzchar(pat)) {
    return(list(
      type = "pat",
      token = pat,
      token_type = "PROGRAMMATIC_ACCESS_TOKEN"
    ))
  }

  # Priority 3: Key-pair JWT
  auth_lower <- tolower(authenticator %||% "")
  if (!is.null(private_key_path) || auth_lower == "snowflake_jwt") {
    if (is.null(private_key_path) || !nzchar(private_key_path)) {
      cli_abort(c(
        "Key-pair auth requires {.arg private_key_path}.",
        "i" = "Set {.field private_key_path} in your connections.toml profile."
      ))
    }
    if (is.null(account) || !nzchar(account)) {
      cli_abort("Key-pair auth requires {.arg account}.")
    }
    if (is.null(user) || !nzchar(user)) {
      cli_abort("Key-pair auth requires {.arg user}.")
    }
    jwt <- sf_generate_jwt(account, user, private_key_path)
    return(list(
      type = "jwt",
      token = jwt,
      token_type = "KEYPAIR_JWT",
      account = account,
      user = user,
      private_key_path = private_key_path,
      generated_at = Sys.time()
    ))
  }

  # Priority 4: Workspace session token (SPCS) -- may be rejected by SQL API
  ws_token <- .read_workspace_token()
  if (is.null(token) && nzchar(ws_token)) {
    return(list(
      type = "token",
      token = ws_token,
      token_type = "OAUTH"
    ))
  }

  cli_abort(c(
    "No Snowflake credentials found.",
    "i" = "In Workspace Notebooks, create a PAT first (see setup cells).",
    "i" = "Otherwise provide {.arg token}, set {.envvar SNOWFLAKE_PAT},",
    " " = "or configure key-pair auth in {.file connections.toml}."
  ))
}


# ---------------------------------------------------------------------------
# Workspace Notebook helpers
# ---------------------------------------------------------------------------

#' Read the session token from env var or /snowflake/session/token file
#' @returns Token string (possibly empty).
#' @noRd
.read_workspace_token <- function() {
  tok <- Sys.getenv("SNOWFLAKE_TOKEN", "")
  if (nzchar(tok)) return(tok)

  token_file <- "/snowflake/session/token"
  if (file.exists(token_file)) {
    tok <- trimws(paste(readLines(token_file, warn = FALSE), collapse = ""))
  }
  tok
}

#' Detect whether we are running inside a Snowflake Workspace Notebook
#' @noRd
.is_workspace <- function() {
  nzchar(Sys.getenv("SNOWFLAKE_HOST", "")) ||
    file.exists("/snowflake/session/token")
}

#' Resolve the Snowflake account identifier in a Workspace Notebook
#' @noRd
.resolve_workspace_account <- function() {
  acct <- Sys.getenv("SNOWFLAKE_ACCOUNT", "")
  if (nzchar(acct)) return(acct)

  host <- Sys.getenv("SNOWFLAKE_HOST", "")
  if (nzchar(host)) {
    return(sub("\\.snowflakecomputing\\.com$", "", host))
  }

  if (requireNamespace("reticulate", quietly = TRUE)) {
    acct <- tryCatch({
      ctx <- reticulate::import("snowflake.snowpark.context")
      session <- ctx$get_active_session()
      gsub('"', '', session$get_current_account())
    }, error = function(e) NULL)
    if (!is.null(acct) && nzchar(acct)) return(acct)
  }

  cli_abort(c(
    "Cannot determine Snowflake account in Workspace Notebook.",
    "i" = "Set {.envvar SNOWFLAKE_ACCOUNT} or pass {.arg account} explicitly."
  ))
}


# ---------------------------------------------------------------------------
# connections.toml reader
# ---------------------------------------------------------------------------

#' Read a connection profile from connections.toml
#'
#' @param name Profile name, or NULL for default.
#' @returns Named list of connection parameters, or NULL.
#' @noRd
sf_read_connections_toml <- function(name = NULL) {
  toml_dir <- Sys.getenv("SNOWFLAKE_HOME",
                          file.path(Sys.getenv("HOME"), ".snowflake"))
  toml_file <- file.path(toml_dir, "connections.toml")
  if (!file.exists(toml_file)) return(NULL)

  toml <- tryCatch(
    {
      if (requireNamespace("RcppTOML", quietly = TRUE)) {
        RcppTOML::parseTOML(toml_file)
      } else {
        .parse_toml_simple(toml_file)
      }
    },
    error = function(e) NULL
  )
  if (is.null(toml) || length(toml) == 0L) return(NULL)

  if (!is.null(name) && name %in% names(toml)) {
    return(toml[[name]])
  }
  if ("default" %in% names(toml)) {
    return(toml[["default"]])
  }
  if (length(toml) == 1L) {
    return(toml[[1L]])
  }

  first <- names(toml)[[1L]]
  cli_inform(c(
    "i" = "Using first profile {.val {first}} from {.file connections.toml}.",
    "i" = "Pass {.arg name} to select a specific profile."
  ))
  toml[[1L]]
}

#' Minimal TOML parser for simple key=value sections
#'
#' Handles the subset of TOML we need: `[section]` headers and
#' `key = "value"` pairs. No nested tables, no arrays.
#' @noRd
.parse_toml_simple <- function(path) {
  lines <- readLines(path, warn = FALSE)
  result <- list()
  current_section <- NULL

  for (line in lines) {
    line <- trimws(line)
    if (!nzchar(line) || startsWith(line, "#")) next

    # Section header
    m <- regmatches(line, regexpr("^\\[([^]]+)\\]$", line))
    if (length(m) == 1L && nzchar(m)) {
      current_section <- gsub("^\\[|\\]$", "", m)
      result[[current_section]] <- list()
      next
    }

    # key = value
    if (!is.null(current_section) && grepl("=", line, fixed = TRUE)) {
      parts <- strsplit(line, "=", fixed = TRUE)[[1L]]
      key <- trimws(parts[1L])
      val <- trimws(paste(parts[-1L], collapse = "="))
      val <- gsub('^"|"$', "", val)
      val <- gsub("^'|'$", "", val)
      result[[current_section]][[key]] <- val
    }
  }
  result
}
