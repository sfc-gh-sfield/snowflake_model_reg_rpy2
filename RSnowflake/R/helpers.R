# Workspace Notebook Output Helpers
# =============================================================================
# Workspace Notebooks add extra whitespace between R output lines.
# These functions capture output as a single string and write it at once.

#' Print a data.frame cleanly in Workspace Notebooks
#'
#' Captures all output lines and writes them as a single block, avoiding the
#' extra whitespace that Workspace Notebooks insert between lines.
#'
#' @param x A data.frame or other printable object.
#' @param width Integer. Print width in characters. Default: 200.
#' @param ... Additional arguments passed to `print()`.
#' @returns Invisibly returns `x`.
#' @export
rprint <- function(x, width = 200L, ...) {
  old_width <- getOption("width")
  on.exit(options(width = old_width), add = TRUE)
  options(width = width)
  writeLines(capture.output(print(x, ...)))
  invisible(x)
}

#' View the head of a data.frame cleanly
#'
#' @param x A data.frame.
#' @param n Integer. Number of rows to show. Default: 10.
#' @param width Integer. Print width in characters. Default: 200.
#' @returns Invisibly returns the first `n` rows.
#' @export
rview <- function(x, n = 10L, width = 200L) {
  stopifnot(is.data.frame(x))
  head_df <- utils::head(x, n = n)
  rprint(head_df, width = width)
  cat(sprintf("[Showing %d of %d rows x %d cols]\n",
              nrow(head_df), nrow(x), ncol(x)))
  invisible(head_df)
}

#' Glimpse a data.frame structure
#'
#' @param x A data.frame.
#' @returns Invisibly returns `x`.
#' @export
rglimpse <- function(x) {
  stopifnot(is.data.frame(x))
  if (requireNamespace("dplyr", quietly = TRUE)) {
    writeLines(capture.output(dplyr::glimpse(x)))
  } else {
    writeLines(capture.output(str(x)))
  }
  invisible(x)
}

#' Clean replacement for cat() in Workspace Notebooks
#'
#' Builds the full string first, then outputs with `writeLines()` to avoid
#' the extra line breaks that Workspace Notebooks add.
#'
#' @param ... Objects to concatenate and print.
#' @param sep Separator between arguments. Default: "".
#' @returns Invisibly returns `NULL`.
#' @export
rcat <- function(..., sep = "") {
  args <- list(...)
  output <- paste(sapply(args, as.character), collapse = sep)
  writeLines(output)
  invisible(NULL)
}
