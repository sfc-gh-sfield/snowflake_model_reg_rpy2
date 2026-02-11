# Output Formatting & Diagnostics
# =============================================================================
# Pure R implementations of workspace helpers. These work both in
# Workspace Notebooks and local R environments.

#' Print a data.frame cleanly
#'
#' Bypasses extra formatting that can cause issues in Workspace Notebooks.
#'
#' @param x A data.frame or other printable object.
#' @param ... Additional arguments passed to `print()`.
#'
#' @returns Invisibly returns `x`.
#'
#' @export
rprint <- function(x, ...) {
  if (is.data.frame(x)) {
    print.data.frame(x, ...)
  } else {
    print(x, ...)
  }
  invisible(x)
}


#' View the head of a data.frame
#'
#' @param x A data.frame.
#' @param n Integer. Number of rows to show. Default: 10.
#'
#' @returns Invisibly returns the first `n` rows.
#'
#' @export
rview <- function(x, n = 10L) {
  stopifnot(is.data.frame(x))
  head_df <- utils::head(x, n = n)
  rprint(head_df)
  cli::cli_text(cli::col_grey(
    "[Showing {nrow(head_df)} of {nrow(x)} rows x {ncol(x)} cols]"
  ))
  invisible(head_df)
}


#' Glimpse a data.frame
#'
#' Shows structure information similar to `dplyr::glimpse()` but without
#' requiring dplyr.
#'
#' @param x A data.frame.
#'
#' @returns Invisibly returns `x`.
#'
#' @export
rglimpse <- function(x) {
  stopifnot(is.data.frame(x))

  if (requireNamespace("dplyr", quietly = TRUE)) {
    dplyr::glimpse(x)
  } else {
    cli::cli_text("Rows: {.val {nrow(x)}}")
    cli::cli_text("Columns: {.val {ncol(x)}}")
    for (col_name in names(x)) {
      col <- x[[col_name]]
      type <- class(col)[1]
      preview <- paste(utils::head(col, 5), collapse = ", ")
      cli::cli_text("$ {.field {col_name}} <{type}> {preview}")
    }
  }
  invisible(x)
}


#' Print text cleanly
#'
#' A `cat()`-like function that avoids Workspace Notebook formatting issues.
#'
#' @param ... Objects to concatenate and print.
#'
#' @returns Invisibly returns `NULL`.
#'
#' @export
rcat <- function(...) {
  msg <- paste0(...)
  cat(msg, "\n")
  invisible(NULL)
}


#' Check the snowflakeR environment
#'
#' Runs diagnostics on R, Python, and Snowflake ML dependencies.
#'
#' @returns Invisibly returns a list of check results.
#'
#' @export
sfr_check_environment <- function() {
  checks <- list()

  # R version
  checks$r_version <- paste0(R.version$major, ".", R.version$minor)
  cli::cli_inform("R version: {.val {checks$r_version}}")

  # reticulate
  checks$reticulate <- requireNamespace("reticulate", quietly = TRUE)
  if (checks$reticulate) {
    cli::cli_inform(c("v" = "{.pkg reticulate} available"))
    checks$python <- tryCatch(
      reticulate::py_config()$python,
      error = function(e) NA_character_
    )
    if (!is.na(checks$python)) {
      cli::cli_inform("Python: {.path {checks$python}}")
    } else {
      cli::cli_warn("Python not configured")
    }
  } else {
    cli::cli_warn("{.pkg reticulate} not installed")
  }

  # snowflake-ml-python
  checks$snowflake_ml <- tryCatch(
    {
      reticulate::py_module_available("snowflake.ml")
    },
    error = function(e) FALSE
  )
  if (checks$snowflake_ml) {
    cli::cli_inform(c("v" = "{.pkg snowflake-ml-python} available"))
  } else {
    cli::cli_warn(c(
      "x" = "{.pkg snowflake-ml-python} not available",
      "i" = "Install with: {.code sfr_install_python_deps()}"
    ))
  }

  # snowflakeauth
  checks$snowflakeauth <- requireNamespace("snowflakeauth", quietly = TRUE)
  if (checks$snowflakeauth) {
    cli::cli_inform(c("v" = "{.pkg snowflakeauth} available"))
  } else {
    cli::cli_inform(c(
      "i" = "{.pkg snowflakeauth} not installed (optional, for connections.toml)"
    ))
  }

  invisible(checks)
}
