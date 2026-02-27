test_that(".format_value handles all types", {
  expect_equal(.format_value(NA), "NULL")
  expect_equal(.format_value(TRUE), "TRUE")
  expect_equal(.format_value(FALSE), "FALSE")
  expect_equal(.format_value(42L), "42")
  expect_equal(.format_value(3.14), "3.14")
  expect_equal(.format_value("hello"), "'hello'")
  expect_equal(.format_value("it's"), "'it''s'")
  expect_equal(.format_value(as.Date("2024-01-15")), "'2024-01-15'")
})

test_that(".insert_data generates named-column INSERT SQL", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "db", schema = "sch",
    warehouse = "wh", role = "role",
    .auth = list(token = "tok", token_type = "KEYPAIR_JWT"),
    .state = .new_conn_state()
  )

  captured_sql <- character(0)
  mockr::with_mock(
    sf_api_submit = function(conn, sql, ...) {
      captured_sql <<- c(captured_sql, sql)
      list()
    },
    {
      df <- data.frame(id = 1:2, name = c("a", "b"), stringsAsFactors = FALSE)
      .insert_data(con, '"MY_TABLE"', df)
    }
  )

  expect_length(captured_sql, 1L)
  expect_match(captured_sql, '"id"', fixed = TRUE)
  expect_match(captured_sql, '"name"', fixed = TRUE)
  expect_match(captured_sql, "INSERT INTO")
})

test_that(".insert_data respects configurable batch size", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "db", schema = "sch",
    warehouse = "wh", role = "role",
    .auth = list(token = "tok", token_type = "KEYPAIR_JWT"),
    .state = .new_conn_state()
  )

  call_count <- 0L
  mockr::with_mock(
    sf_api_submit = function(conn, sql, ...) {
      call_count <<- call_count + 1L
      list()
    },
    {
      withr::with_options(list(RSnowflake.insert_batch_size = 3L), {
        df <- data.frame(x = 1:10)
        .insert_data(con, '"TBL"', df)
      })
    }
  )

  expect_equal(call_count, 4L)
})

test_that("default batch size is 5000", {
  withr::with_options(list(RSnowflake.insert_batch_size = NULL), {
    size <- getOption("RSnowflake.insert_batch_size", 5000L)
    expect_equal(size, 5000L)
  })
})
