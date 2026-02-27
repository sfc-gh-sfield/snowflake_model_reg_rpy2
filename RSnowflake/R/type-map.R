# Snowflake <-> R Type Mapping
# =============================================================================

#' Map a Snowflake type name to the base R vector mode
#'
#' Used to pre-allocate empty columns and determine conversion strategy.
#'
#' @param sf_type Lowercase Snowflake type string (from resultSetMetaData).
#' @param scale Integer scale (for fixed-point types).
#' @returns R mode string: "integer", "double", "character", "logical".
#' @noRd
sf_type_to_r <- function(sf_type, scale = 0L) {
  switch(sf_type,
    "fixed" = if (scale == 0L) "integer" else "double",
    "real"  = , "float" = "double",
    "text"  = "character",
    "boolean" = "logical",
    "date"  = "double",
    "time"  = "double",
    "timestamp_ntz" = , "timestamp_ltz" = , "timestamp_tz" = "double",
    "binary"    = "character",
    "variant"   = , "array" = , "object" = "character",
    "geography" = , "geometry" = "character",
    "vector"    = "character",
    "character"
  )
}


#' Convert a character vector of JSON values to the appropriate R type
#'
#' @param x Character vector (may contain NA).
#' @param sf_type Lowercase Snowflake type string.
#' @param scale Integer scale.
#' @returns Typed R vector.
#' @noRd
sf_convert_column <- function(x, sf_type, scale = 0L) {
  switch(sf_type,
    "fixed" = .convert_fixed(x, scale),
    "real"  = , "float" = as.double(x),
    "boolean" = .convert_boolean(x),
    "date"    = .convert_date(x),
    "time"    = .convert_time(x),
    "timestamp_ntz" = .convert_timestamp(x, tz = "UTC"),
    "timestamp_ltz" = .convert_timestamp(x, tz = Sys.timezone()),
    "timestamp_tz"  = .convert_timestamp_tz(x),
    "text" = x,
    x
  )
}


# ---------------------------------------------------------------------------
# Type conversion helpers
# ---------------------------------------------------------------------------

.convert_fixed <- function(x, scale) {
  if (scale == 0L) {
    # Integer -- watch for overflow
    nums <- suppressWarnings(as.numeric(x))
    int_max <- .Machine$integer.max
    if (any(!is.na(nums) & (nums > int_max | nums < -int_max))) {
      return(nums)
    }
    as.integer(x)
  } else {
    as.double(x)
  }
}

.convert_boolean <- function(x) {
  out <- rep(NA, length(x))
  out[!is.na(x) & x == "true"]  <- TRUE
  out[!is.na(x) & x == "false"] <- FALSE
  # SQL API also returns "1"/"0" for booleans in some contexts
  out[!is.na(x) & x == "1"] <- TRUE
  out[!is.na(x) & x == "0"] <- FALSE
  as.logical(out)
}

.convert_date <- function(x) {
  # SQL API v2 returns dates as epoch-day integers (days since 1970-01-01)
  nums <- suppressWarnings(as.numeric(x))
  if (all(is.na(nums) | abs(nums) < 1e6)) {
    as.Date(nums, origin = "1970-01-01")
  } else {
    # Fallback: ISO string
    as.Date(x)
  }
}

.convert_time <- function(x) {
  # SQL API v2 returns time as nanoseconds since midnight
  nanos <- suppressWarnings(as.numeric(x))
  secs <- nanos / 1e9
  if (requireNamespace("hms", quietly = TRUE)) {
    hms::as_hms(secs)
  } else {
    secs
  }
}

.convert_timestamp <- function(x, tz = "UTC") {
  # SQL API v2 returns timestamps as epoch strings with fractional seconds,
  # OR as nanoseconds-since-epoch. The format depends on TIMESTAMP_OUTPUT_FORMAT.
  nums <- suppressWarnings(as.numeric(x))
  if (all(is.na(nums))) return(rep(as.POSIXct(NA), length(x)))

  # Heuristic: if values > 1e15, they are nanoseconds; if > 1e12, milliseconds
  max_val <- max(abs(nums), na.rm = TRUE)
  epoch_secs <- if (max_val > 1e15) {
    nums / 1e9
  } else if (max_val > 1e12) {
    nums / 1e3
  } else {
    nums
  }

  as.POSIXct(epoch_secs, origin = "1970-01-01", tz = tz)
}

.convert_timestamp_tz <- function(x) {
  # TIMESTAMP_TZ values come as "epoch tz_offset_minutes" pairs
  # e.g. "1609459200.000000000 1440" (epoch + offset in minutes from UTC base)
  # Or they may be epoch seconds. Handle both.
  .convert_timestamp(x, tz = "UTC")
}


# ---------------------------------------------------------------------------
# R -> Snowflake type mapping (for dbDataType / dbWriteTable)
# ---------------------------------------------------------------------------

#' Map an R object to a Snowflake SQL type string
#' @noRd
r_to_sf_type <- function(obj) {
  if (inherits(obj, "Date"))          return("DATE")
  if (inherits(obj, "POSIXct"))       return("TIMESTAMP_NTZ")
  if (inherits(obj, "POSIXlt"))       return("TIMESTAMP_NTZ")
  if (inherits(obj, "difftime"))      return("TIME")
  if (inherits(obj, "hms"))           return("TIME")
  if (inherits(obj, "blob"))          return("BINARY")
  if (inherits(obj, "integer64"))     return("NUMBER(19, 0)")
  if (is.integer(obj))                return("NUMBER(10, 0)")
  if (is.double(obj))                 return("DOUBLE")
  if (is.logical(obj))                return("BOOLEAN")
  if (is.character(obj))              return("TEXT")
  if (is.raw(obj))                    return("BINARY")
  "TEXT"
}
