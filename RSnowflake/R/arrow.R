# Arrow IPC Result Parsing
# =============================================================================
# Provides functions to submit queries in Arrow format, fetch binary Arrow IPC
# partitions, and convert them to R data.frames via nanoarrow.  All nanoarrow
# calls are guarded with rlang::check_installed() since it is in Suggests.

#' Submit a SQL statement and request Arrow-format results
#'
#' Identical to sf_api_submit() but sets format = "arrowv1" so that partition
#' downloads return Arrow IPC stream bytes instead of JSON arrays.
#' @inheritParams sf_api_submit
#' @returns Parsed JSON metadata response (list).
#' @noRd
sf_api_submit_arrow <- function(con, sql, bindings = NULL, async = FALSE) {
  sf_api_submit(con, sql, bindings = bindings, async = async,
                format = "arrowv1")
}


#' Fetch all Arrow partitions and combine into a data.frame
#'
#' @param con SnowflakeConnection.
#' @param meta Metadata list from sf_parse_metadata().
#' @returns A data.frame.
#' @noRd
sf_fetch_all_arrow <- function(con, meta) {
  rlang::check_installed("nanoarrow", reason = "for Arrow result format")

  handle     <- meta$statement_handle
  n_parts    <- max(meta$num_partitions, 1L)

  parts <- vector("list", n_parts)
  for (i in seq_len(n_parts)) {
    raw_bytes <- sf_api_fetch_partition_arrow(con, handle, i - 1L)
    parts[[i]] <- .arrow_raw_to_df(raw_bytes)
  }

  if (length(parts) == 0L) return(.empty_df_from_meta(meta))
  if (length(parts) == 1L) return(parts[[1L]])
  do.call(rbind, parts)
}


#' Fetch all Arrow partitions and return as a nanoarrow_array_stream
#'
#' @param con SnowflakeConnection.
#' @param meta Metadata list from sf_parse_metadata().
#' @returns A nanoarrow_array_stream.
#' @noRd
sf_fetch_all_arrow_stream <- function(con, meta) {
  rlang::check_installed("nanoarrow", reason = "for Arrow result format")

  handle  <- meta$statement_handle
  n_parts <- max(meta$num_partitions, 1L)

  streams <- vector("list", n_parts)
  for (i in seq_len(n_parts)) {
    raw_bytes <- sf_api_fetch_partition_arrow(con, handle, i - 1L)
    streams[[i]] <- .arrow_raw_to_stream(raw_bytes)
  }

  if (length(streams) == 1L) return(streams[[1L]])
  nanoarrow::basic_array_stream(
    do.call(c, lapply(streams, function(s) {
      batches <- list()
      while (TRUE) {
        batch <- nanoarrow::nanoarrow_pointer_move(s)
        if (is.null(batch)) break
        batches <- c(batches, list(batch))
      }
      batches
    }))
  )
}


#' Convert raw Arrow IPC bytes to a data.frame
#'
#' Handles gzip decompression if the response is compressed.
#' @param raw_bytes Raw vector from sf_api_fetch_partition_arrow().
#' @returns A data.frame.
#' @noRd
.arrow_raw_to_df <- function(raw_bytes) {
  raw_bytes <- .maybe_gunzip(raw_bytes)
  stream <- nanoarrow::read_nanoarrow(raw_bytes)
  as.data.frame(stream)
}


#' Convert raw Arrow IPC bytes to a nanoarrow_array_stream
#' @noRd
.arrow_raw_to_stream <- function(raw_bytes) {
  raw_bytes <- .maybe_gunzip(raw_bytes)
  nanoarrow::read_nanoarrow(raw_bytes)
}


#' Decompress gzip if the raw bytes start with the gzip magic number
#' @noRd
.maybe_gunzip <- function(raw_bytes) {
  if (length(raw_bytes) >= 2L &&
      raw_bytes[1L] == as.raw(0x1f) &&
      raw_bytes[2L] == as.raw(0x8b)) {
    memDecompress(raw_bytes, type = "gzip")
  } else {
    raw_bytes
  }
}
