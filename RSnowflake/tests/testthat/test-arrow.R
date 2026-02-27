test_that(".maybe_gunzip decompresses gzip bytes", {
  original <- charToRaw("hello world")
  tf <- tempfile(fileext = ".gz")
  on.exit(unlink(tf), add = TRUE)
  gz_con <- gzfile(tf, "wb")
  writeBin(original, gz_con)
  close(gz_con)
  compressed <- readBin(tf, "raw", file.info(tf)$size)

  result <- .maybe_gunzip(compressed)
  expect_equal(result, original)
})

test_that(".maybe_gunzip passes through non-gzip bytes", {
  raw <- charToRaw("not gzip")
  expect_identical(.maybe_gunzip(raw), raw)
})

test_that(".maybe_gunzip handles empty input", {
  expect_identical(.maybe_gunzip(raw(0)), raw(0))
})

test_that(".arrow_raw_to_df converts nanoarrow example stream", {
  skip_if_not_installed("nanoarrow")
  ipc_bytes <- nanoarrow::example_ipc_stream()
  df <- .arrow_raw_to_df(ipc_bytes)
  expect_s3_class(df, "data.frame")
  expect_gt(nrow(df), 0)
  expect_gt(ncol(df), 0)
})

test_that(".arrow_raw_to_stream returns a nanoarrow stream", {
  skip_if_not_installed("nanoarrow")
  ipc_bytes <- nanoarrow::example_ipc_stream()
  stream <- .arrow_raw_to_stream(ipc_bytes)
  expect_true(inherits(stream, "nanoarrow_array_stream"))
})

test_that("sf_api_submit passes format argument through", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "db", schema = "sch",
    warehouse = "wh", role = "role",
    .auth = list(token = "tok", token_type = "KEYPAIR_JWT"),
    .state = .new_conn_state()
  )

  called_format <- NULL
  mockr::with_mock(
    .sf_api_request_with_refresh = function(con, method, url, body = NULL) {
      called_format <<- body$resultSetMetaData$format
      list(statementHandle = "h1", resultSetMetaData = list(
        numRows = 0L, rowType = list()
      ))
    },
    {
      sf_api_submit(con, "SELECT 1", format = "arrowv1")
      expect_equal(called_format, "arrowv1")

      sf_api_submit(con, "SELECT 1")
      expect_equal(called_format, "jsonv2")
    }
  )
})
