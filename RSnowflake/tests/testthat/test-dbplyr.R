test_that("dbplyr_edition returns 2 for SnowflakeConnection", {
  skip_if_not_installed("dbplyr")
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "mydb", schema = "public",
    warehouse = "wh", role = "role", .auth = list(), .state = .new_conn_state()
  )
  expect_equal(dbplyr_edition.SnowflakeConnection(con), 2L)
})

test_that("sql_translation returns Snowflake translations", {
  skip_if_not_installed("dbplyr")
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "mydb", schema = "public",
    warehouse = "wh", role = "role", .auth = list(), .state = .new_conn_state()
  )
  trans <- sql_translation.SnowflakeConnection(con)
  expect_s3_class(trans, "sql_variant")
})

test_that("db_connection_describe formats correctly", {
  skip_if_not_installed("dbplyr")
  con <- new("SnowflakeConnection",
    account = "acme", user = "user", database = "analytics",
    schema = "raw", warehouse = "wh", role = "role",
    .auth = list(), .state = .new_conn_state()
  )
  desc <- db_connection_describe.SnowflakeConnection(con)
  expect_match(desc, "Snowflake acme")
  expect_match(desc, "analytics.raw")
})

test_that("sql_query_save generates CREATE TABLE AS", {
  skip_if_not_installed("dbplyr")
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "mydb", schema = "public",
    warehouse = "wh", role = "role", .auth = list(), .state = .new_conn_state()
  )
  sql <- sql_query_save.SnowflakeConnection(
    con, dbplyr::sql("SELECT 1"), dbplyr::ident("my_tbl"), temporary = TRUE
  )
  expect_match(as.character(sql), "CREATE TEMPORARY TABLE")
})

test_that("Snowflake paste0 translates to ARRAY_TO_STRING", {
  skip_if_not_installed("dbplyr")
  skip_if_not_installed("dplyr")
  lf <- dbplyr::lazy_frame(a = "x", b = "y", con = dbplyr::simulate_snowflake())
  out <- dbplyr::sql_render(dplyr::mutate(lf, c = paste0(a, b)))
  expect_match(as.character(out), "ARRAY_TO_STRING", fixed = TRUE)
})
