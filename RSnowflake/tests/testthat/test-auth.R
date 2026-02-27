test_that("sf_read_connections_toml returns NULL when file missing", {
  withr::with_envvar(c(SNOWFLAKE_HOME = tempdir()), {
    result <- sf_read_connections_toml("nonexistent")
    expect_null(result)
  })
})

test_that(".parse_toml_simple parses basic TOML", {
  tmp <- tempfile(fileext = ".toml")
  writeLines(c(
    "[default]",
    'account = "testaccount"',
    'user = "testuser"',
    "",
    "[profile2]",
    "database = 'mydb'",
    "# this is a comment",
    "warehouse = COMPUTE_WH"
  ), tmp)

  result <- .parse_toml_simple(tmp)
  expect_type(result, "list")
  expect_equal(result$default$account, "testaccount")
  expect_equal(result$default$user, "testuser")
  expect_equal(result$profile2$database, "mydb")
  expect_equal(result$profile2$warehouse, "COMPUTE_WH")
  unlink(tmp)
})

test_that("sf_read_connections_toml selects named profile", {
  tmp_dir <- tempfile()
  dir.create(tmp_dir, showWarnings = FALSE)
  writeLines(c(
    "[default]",
    'account = "defacct"',
    "[myprofile]",
    'account = "myacct"'
  ), file.path(tmp_dir, "connections.toml"))

  withr::with_envvar(c(SNOWFLAKE_HOME = tmp_dir), {
    result <- sf_read_connections_toml("myprofile")
    expect_equal(result$account, "myacct")

    result_def <- sf_read_connections_toml(NULL)
    expect_equal(result_def$account, "defacct")
  })
  unlink(tmp_dir, recursive = TRUE)
})

test_that("sf_auth_resolve uses SNOWFLAKE_TOKEN when available", {
  withr::with_envvar(c(SNOWFLAKE_TOKEN = "testtoken123", SNOWFLAKE_PAT = ""), {
    result <- sf_auth_resolve(account = "test", user = "user")
    expect_equal(result$type, "token")
    expect_equal(result$token, "testtoken123")
    expect_equal(result$token_type, "OAUTH")
  })
})

test_that("sf_auth_resolve uses SNOWFLAKE_PAT when available", {
  withr::with_envvar(c(SNOWFLAKE_TOKEN = "", SNOWFLAKE_PAT = "mypat"), {
    result <- sf_auth_resolve(account = "test", user = "user")
    expect_equal(result$type, "pat")
    expect_equal(result$token, "mypat")
  })
})

test_that("sf_auth_resolve errors when no credentials found", {
  withr::with_envvar(c(SNOWFLAKE_TOKEN = "", SNOWFLAKE_PAT = ""), {
    expect_error(
      sf_auth_resolve(account = "test", user = "user"),
      "No Snowflake credentials found"
    )
  })
})

test_that("sf_auth_resolve errors on JWT without key path", {
  withr::with_envvar(c(SNOWFLAKE_TOKEN = "", SNOWFLAKE_PAT = ""), {
    expect_error(
      sf_auth_resolve(
        account = "test", user = "user",
        authenticator = "SNOWFLAKE_JWT"
      ),
      "private_key_path"
    )
  })
})
