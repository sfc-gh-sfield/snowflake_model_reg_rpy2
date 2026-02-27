# Arrow Result Support (via nanoarrow)
# =============================================================================
# The Snowflake SQL API v2 only returns JSON responses.  Arrow transport is
# not supported on the public REST API.  We provide DBI Arrow methods
# (dbGetQueryArrow, dbFetchArrow, etc.) by fetching JSON data through the
# normal path, then converting R data.frames to nanoarrow array streams on
# the client side.  This gives users the standard DBI Arrow interface while
# working within the constraints of SQL API v2.
#
# All nanoarrow calls are guarded with rlang::check_installed() since
# nanoarrow is in Suggests.


#' Fetch all JSON partitions and return as a nanoarrow_array_stream
#'
#' @param con SnowflakeConnection.
#' @param resp_body Initial response body from sf_api_submit (contains first
#'   partition inline).
#' @param meta Metadata from sf_parse_metadata().
#' @returns A nanoarrow_array_stream.
#' @noRd
sf_fetch_all_as_arrow_stream <- function(con, resp_body, meta) {
  rlang::check_installed("nanoarrow", reason = "for Arrow result format")

  handle   <- meta$statement_handle
  n_parts  <- max(meta$num_partitions, 1L)

  frames <- vector("list", n_parts)
  for (i in seq_len(n_parts)) {
    if (i == 1L) {
      parsed <- sf_parse_response(resp_body)
      frames[[i]] <- parsed$data
    } else {
      part_resp <- sf_api_fetch_partition(con, handle, i - 1L)
      part_parsed <- sf_parse_response(part_resp)
      frames[[i]] <- part_parsed$data
    }
  }

  combined <- if (length(frames) == 1L) {
    frames[[1L]]
  } else {
    do.call(rbind, frames)
  }

  if (is.null(combined) || nrow(combined) == 0L) {
    combined <- .empty_df_from_meta(meta)
  }

  nanoarrow::as_nanoarrow_array_stream(combined)
}


#' Fetch a single JSON partition and return as a nanoarrow_array_stream
#'
#' @param con SnowflakeConnection.
#' @param resp_body Initial response body (for partition 0).
#' @param meta Metadata from sf_parse_metadata().
#' @param partition 0-based partition index.
#' @returns A nanoarrow_array_stream.
#' @noRd
sf_fetch_partition_as_arrow_stream <- function(con, resp_body, meta, partition) {
  rlang::check_installed("nanoarrow", reason = "for Arrow result format")

  if (partition == 0L) {
    parsed <- sf_parse_response(resp_body)
    df <- parsed$data
  } else {
    part_resp <- sf_api_fetch_partition(con, meta$statement_handle, partition)
    part_parsed <- sf_parse_response(part_resp)
    df <- part_parsed$data
  }

  if (is.null(df) || nrow(df) == 0L) {
    df <- .empty_df_from_meta(meta)
  }

  nanoarrow::as_nanoarrow_array_stream(df)
}
