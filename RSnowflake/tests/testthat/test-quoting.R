test_that("dbQuoteIdentifier quotes plain names", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteIdentifier(con, "my_table")
  expect_s4_class(result, "SQL")
  expect_equal(as.character(result), '"my_table"')
})

test_that("dbQuoteIdentifier doesn't double-quote", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteIdentifier(con, '"already_quoted"')
  expect_equal(as.character(result), '"already_quoted"')
})

test_that("dbQuoteIdentifier escapes embedded double quotes", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteIdentifier(con, 'has"quote')
  expect_equal(as.character(result), '"has""quote"')
})

test_that("dbQuoteString quotes strings", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteString(con, "hello")
  expect_s4_class(result, "SQL")
  expect_equal(as.character(result), "'hello'")
})

test_that("dbQuoteString escapes single quotes", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteString(con, "it's")
  expect_equal(as.character(result), "'it''s'")
})

test_that("dbQuoteString handles NA correctly", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteString(con, NA_character_)
  expect_equal(as.character(result), "NULL")
})

test_that("dbQuoteString handles vector with mixed NA", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteString(con, c("hello", NA, "world"))
  expect_equal(as.character(result), c("'hello'", "NULL", "'world'"))
})

test_that("dbQuoteString passes SQL through", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  s <- SQL("SELECT 1")
  result <- dbQuoteString(con, s)
  expect_identical(result, s)
})

test_that("dbQuoteLiteral handles integers", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteLiteral(con, 42L)
  expect_equal(as.character(result), "42")
})

test_that("dbQuoteLiteral handles NA integer", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteLiteral(con, NA_integer_)
  expect_equal(as.character(result), "NULL")
})

test_that("dbQuoteLiteral handles dates", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteLiteral(con, as.Date("2024-06-15"))
  expect_match(as.character(result), "2024-06-15.*DATE")
})

test_that("dbQuoteLiteral handles logicals", {
  con <- new("SnowflakeConnection",
    account = "test", user = "user", database = "", schema = "",
    warehouse = "", role = "", .auth = list(), .state = .new_conn_state()
  )
  result <- dbQuoteLiteral(con, TRUE)
  expect_equal(as.character(result), "TRUE")

  result <- dbQuoteLiteral(con, FALSE)
  expect_equal(as.character(result), "FALSE")
})
