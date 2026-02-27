test_that("sf_type_to_r maps fixed types correctly", {
  expect_equal(sf_type_to_r("fixed", 0L), "integer")
  expect_equal(sf_type_to_r("fixed", 2L), "double")
})

test_that("sf_type_to_r maps common types", {
  expect_equal(sf_type_to_r("text"), "character")
  expect_equal(sf_type_to_r("real"), "double")
  expect_equal(sf_type_to_r("float"), "double")
  expect_equal(sf_type_to_r("boolean"), "logical")
  expect_equal(sf_type_to_r("date"), "double")
  expect_equal(sf_type_to_r("timestamp_ntz"), "double")
  expect_equal(sf_type_to_r("timestamp_ltz"), "double")
  expect_equal(sf_type_to_r("timestamp_tz"), "double")
  expect_equal(sf_type_to_r("time"), "double")
  expect_equal(sf_type_to_r("variant"), "character")
  expect_equal(sf_type_to_r("array"), "character")
  expect_equal(sf_type_to_r("object"), "character")
})

test_that("sf_type_to_r returns character for unknown types", {
  expect_equal(sf_type_to_r("somethingelse"), "character")
})

test_that("sf_convert_column handles integer fixed", {
  x <- c("1", "2", NA, "42")
  result <- sf_convert_column(x, "fixed", 0L)
  expect_type(result, "integer")
  expect_equal(result, c(1L, 2L, NA, 42L))
})

test_that("sf_convert_column handles decimal fixed", {
  x <- c("1.5", "2.7", NA)
  result <- sf_convert_column(x, "fixed", 2L)
  expect_type(result, "double")
  expect_equal(result, c(1.5, 2.7, NA))
})

test_that("sf_convert_column handles booleans", {
  x <- c("true", "false", NA, "1", "0")
  result <- sf_convert_column(x, "boolean")
  expect_equal(result, c(TRUE, FALSE, NA, TRUE, FALSE))
})

test_that("sf_convert_column handles text passthrough", {
  x <- c("hello", "world", NA)
  result <- sf_convert_column(x, "text")
  expect_equal(result, c("hello", "world", NA))
})

test_that("sf_convert_column handles dates as epoch days", {
  x <- c("0", "19723", NA)
  result <- sf_convert_column(x, "date")
  expect_s3_class(result, "Date")
  expect_equal(result[1], as.Date("1970-01-01"))
  expect_true(is.na(result[3]))
})

test_that("sf_convert_column handles real/float", {
  x <- c("3.14", "2.72", NA)
  result <- sf_convert_column(x, "real")
  expect_type(result, "double")
  expect_equal(result, c(3.14, 2.72, NA))
})

test_that("r_to_sf_type maps R types to Snowflake types", {
  expect_equal(r_to_sf_type(1L), "NUMBER(10, 0)")
  expect_equal(r_to_sf_type(1.0), "DOUBLE")
  expect_equal(r_to_sf_type("a"), "TEXT")
  expect_equal(r_to_sf_type(TRUE), "BOOLEAN")
  expect_equal(r_to_sf_type(Sys.Date()), "DATE")
  expect_equal(r_to_sf_type(Sys.time()), "TIMESTAMP_NTZ")
  expect_equal(r_to_sf_type(as.raw(0)), "BINARY")
})

test_that("integer overflow falls back to double", {
  big <- as.character(.Machine$integer.max + 1)
  result <- sf_convert_column(c(big), "fixed", 0L)
  expect_type(result, "double")
})
