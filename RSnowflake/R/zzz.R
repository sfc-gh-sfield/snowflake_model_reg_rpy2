.pkg_env <- new.env(parent = emptyenv())

.onLoad <- function(libname, pkgname) {
  op <- options()
  op_rsf <- list(
    RSnowflake.timeout            = 600L,
    RSnowflake.retry_max          = 3L,
    RSnowflake.result_format      = "json",
    RSnowflake.insert_batch_size  = 5000L,
    RSnowflake.verbose            = FALSE
  )
  toset <- !(names(op_rsf) %in% names(op))
  if (any(toset)) options(op_rsf[toset])

  .register_dbplyr_methods()

  invisible()
}
