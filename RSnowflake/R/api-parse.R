# SQL API v2 JSON Result Parsing
# =============================================================================

#' Parse a SQL API v2 response into column metadata and R data.frame
#'
#' @param resp_body Parsed JSON body from sf_api_submit / sf_api_fetch_partition.
#' @returns A list with `meta` (column info) and `data` (data.frame).
#' @noRd
sf_parse_response <- function(resp_body) {
  meta <- sf_parse_metadata(resp_body)

  raw_data <- resp_body$data
  if (is.null(raw_data) || length(raw_data) == 0L) {
    df <- .empty_df_from_meta(meta)
    return(list(meta = meta, data = df))
  }

  df <- .json_data_to_df(raw_data, meta)
  list(meta = meta, data = df)
}


#' Extract column metadata from resultSetMetaData
#'
#' @param resp_body Parsed JSON body.
#' @returns A list with `num_rows`, `num_partitions`, `columns` (data.frame
#'   of name, type, nullable, scale, precision, length).
#' @noRd
sf_parse_metadata <- function(resp_body) {
  rsmd <- resp_body$resultSetMetaData
  if (is.null(rsmd)) {
    return(list(
      num_rows = 0L,
      num_partitions = 0L,
      statement_handle = resp_body$statementHandle %||% "",
      columns = data.frame(
        name = character(0), type = character(0),
        nullable = logical(0), scale = integer(0),
        stringsAsFactors = FALSE
      )
    ))
  }

  row_types <- rsmd$rowType
  if (is.null(row_types)) row_types <- list()

  cols <- data.frame(
    name     = vapply(row_types, function(x) x$name %||% "", character(1)),
    type     = vapply(row_types, function(x) tolower(x$type %||% "text"), character(1)),
    nullable = vapply(row_types, function(x) isTRUE(x$nullable), logical(1)),
    scale    = vapply(row_types, function(x) as.integer(x$scale %||% 0L), integer(1)),
    precision = vapply(row_types, function(x) as.integer(x$precision %||% 0L), integer(1)),
    stringsAsFactors = FALSE
  )

  n_partitions <- 0L
  part_info <- rsmd$partitionInfo
  if (!is.null(part_info)) {
    n_partitions <- length(part_info)
  }

  list(
    num_rows         = as.integer(rsmd$numRows %||% 0L),
    num_partitions   = n_partitions,
    statement_handle = resp_body$statementHandle %||% "",
    statement_status_url = resp_body$statementStatusUrl %||% "",
    columns          = cols
  )
}


#' Convert the data array from JSON response into an R data.frame
#'
#' The SQL API v2 returns data as a list of row arrays, where each
#' value is a string (or null). We convert to the appropriate R type
#' based on column metadata.
#'
#' @param raw_data List of row arrays.
#' @param meta Metadata from sf_parse_metadata().
#' @returns A data.frame.
#' @noRd
.json_data_to_df <- function(raw_data, meta) {
  col_info <- meta$columns
  ncols <- nrow(col_info)

  if (ncols == 0L) return(data.frame())

  # Pre-allocate column vectors
  nrows <- length(raw_data)
  columns <- vector("list", ncols)
  names(columns) <- col_info$name

  for (j in seq_len(ncols)) {
    sf_type <- col_info$type[j]
    scale   <- col_info$scale[j]

    raw_col <- vapply(raw_data, function(row) {
      val <- row[[j]]
      if (is.null(val)) NA_character_ else as.character(val)
    }, character(1))

    columns[[j]] <- sf_convert_column(raw_col, sf_type, scale)
  }

  as.data.frame(columns, stringsAsFactors = FALSE, check.names = FALSE)
}


#' Create an empty data.frame with the right column names and types
#' @noRd
.empty_df_from_meta <- function(meta) {
  col_info <- meta$columns
  if (nrow(col_info) == 0L) return(data.frame())

  columns <- vector("list", nrow(col_info))
  names(columns) <- col_info$name

  for (j in seq_len(nrow(col_info))) {
    r_type <- sf_type_to_r(col_info$type[j], col_info$scale[j])
    columns[[j]] <- vector(r_type, 0L)
  }

  as.data.frame(columns, stringsAsFactors = FALSE, check.names = FALSE)
}
