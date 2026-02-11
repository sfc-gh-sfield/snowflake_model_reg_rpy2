# Unit tests for registry module
# =============================================================================

# -- sfr_model_registry constructor -------------------------------------------

test_that("sfr_model_registry validates connection", {
  expect_error(
    sfr_model_registry("not_a_conn"),
    "sfr_connection"
  )
})


test_that("sfr_model_registry creates correct S3 object", {
  mock_conn <- structure(
    list(
      session = NULL, account = "test", database = "DB",
      schema = "SC", warehouse = "WH", auth_method = "test",
      environment = "test", created_at = Sys.time()
    ),
    class = c("sfr_connection", "list")
  )

  mr <- sfr_model_registry(mock_conn)
  expect_s3_class(mr, "sfr_model_registry")
  expect_equal(mr$database, "DB")
  expect_equal(mr$schema, "SC")
  expect_identical(mr$conn, mock_conn)
})


test_that("sfr_model_registry overrides database/schema", {
  mock_conn <- structure(
    list(
      session = NULL, account = "test", database = "DB",
      schema = "SC", warehouse = "WH", auth_method = "test",
      environment = "test", created_at = Sys.time()
    ),
    class = c("sfr_connection", "list")
  )

  mr <- sfr_model_registry(mock_conn, database = "OTHER_DB", schema = "OTHER_SC")
  expect_equal(mr$database, "OTHER_DB")
  expect_equal(mr$schema, "OTHER_SC")
})


test_that("print.sfr_model_registry outputs expected format", {
  mock_conn <- structure(
    list(
      session = NULL, account = "test", database = "DB",
      schema = "SC", warehouse = "WH", auth_method = "test",
      environment = "test", created_at = Sys.time()
    ),
    class = c("sfr_connection", "list")
  )

  mr <- sfr_model_registry(mock_conn)
  expect_message(print(mr), "sfr_model_registry")
})


# -- resolve_registry_context -------------------------------------------------

test_that("resolve_registry_context works with sfr_model_registry", {
  mock_conn <- structure(
    list(
      session = "fake_session", account = "test", database = "DB",
      schema = "SC", warehouse = "WH", auth_method = "test",
      environment = "test", created_at = Sys.time()
    ),
    class = c("sfr_connection", "list")
  )

  mr <- sfr_model_registry(mock_conn, database = "ML_DB", schema = "MODELS")
  ctx <- resolve_registry_context(mr)

  expect_equal(ctx$session, "fake_session")
  expect_equal(ctx$database_name, "ML_DB")
  expect_equal(ctx$schema_name, "MODELS")
})


test_that("resolve_registry_context works with sfr_connection", {
  mock_conn <- structure(
    list(
      session = "fake_session", account = "test", database = "DB",
      schema = "SC", warehouse = "WH", auth_method = "test",
      environment = "test", created_at = Sys.time()
    ),
    class = c("sfr_connection", "list")
  )

  ctx <- resolve_registry_context(mock_conn)

  expect_equal(ctx$session, "fake_session")
  expect_null(ctx$database_name)
  expect_null(ctx$schema_name)
})


test_that("resolve_registry_context rejects invalid types", {
  expect_error(
    resolve_registry_context("not_valid"),
    "sfr_model_registry.*sfr_connection"
  )
  expect_error(
    resolve_registry_context(list()),
    "sfr_model_registry.*sfr_connection"
  )
})


# -- sfr_log_model validation -------------------------------------------------

test_that("sfr_log_model rejects invalid first arg", {
  model <- lm(mpg ~ wt, data = mtcars)
  expect_error(
    sfr_log_model("not_a_conn", model, model_name = "test"),
    "sfr_model_registry.*sfr_connection"
  )
})


test_that("sfr_log_model accepts sfr_connection (backward compat)", {
  mock_conn <- structure(
    list(
      session = NULL, account = "test", database = "DB",
      schema = "SC", warehouse = "WH", auth_method = "test",
      environment = "test", created_at = Sys.time()
    ),
    class = c("sfr_connection", "list")
  )

  # Will fail at the bridge call (NULL session), but should pass R validation
  model <- lm(mpg ~ wt, data = mtcars)
  expect_error(
    sfr_log_model(mock_conn, model, model_name = "test")
  )
})


# -- Other function validation ------------------------------------------------

test_that("sfr_show_models rejects invalid first arg", {
  expect_error(
    sfr_show_models("not_a_conn"),
    "sfr_model_registry.*sfr_connection"
  )
})


test_that("sfr_predict rejects invalid first arg", {
  expect_error(
    sfr_predict("not_a_conn", "model", data.frame(x = 1)),
    "sfr_model_registry.*sfr_connection"
  )
})


# -- S3 print methods ---------------------------------------------------------

test_that("sfr_model_version prints cleanly", {
  mv <- structure(
    list(
      model_name = "TEST_MODEL",
      version_name = "V1",
      py_model_version = NULL,
      py_registry = NULL,
      reg = NULL
    ),
    class = c("sfr_model_version", "list")
  )
  expect_message(print(mv), "sfr_model_version")
})


test_that("sfr_model prints cleanly", {
  m <- structure(
    list(
      name = "TEST_MODEL",
      comment = "A test model",
      versions = c("V1", "V2"),
      default_version = "V1",
      py_model = NULL,
      py_registry = NULL,
      reg = NULL
    ),
    class = c("sfr_model", "list")
  )
  expect_message(print(m), "sfr_model")
})
