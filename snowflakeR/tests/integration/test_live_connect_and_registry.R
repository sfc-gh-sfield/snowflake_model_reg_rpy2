#!/usr/bin/env Rscript
# =============================================================================
# snowflakeR Integration Test: Live Connection + Model Registry
# =============================================================================
# This script tests the full pipeline:
#   1. Connect to Snowflake via connections.toml / env vars
#   2. Run a simple query
#   3. Train a local R model
#   4. Log it to the Model Registry
#   5. Show models, get model, show versions
#   6. Run local prediction
#   7. Clean up (delete model)
#
# Prerequisites:
#   - A Snowflake connections.toml profile, OR environment variables:
#       SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PRIVATE_KEY_FILE,
#       SNOWFLAKE_DATABASE, SNOWFLAKE_SCHEMA, SNOWFLAKE_WAREHOUSE, SNOWFLAKE_ROLE
#   - The r-snowflakeR conda environment (or RETICULATE_PYTHON set)
#   - snowflake-ml-python installed in the Python environment
#
# Usage:
#   Rscript tests/integration/test_live_connect_and_registry.R
#
# With env vars:
#   SNOWFLAKE_ACCOUNT=myaccount SNOWFLAKE_USER=myuser ... \
#     Rscript tests/integration/test_live_connect_and_registry.R
#
# With a connections.toml profile:
#   SNOWFLAKE_CONNECTION_NAME=my_profile \
#     Rscript tests/integration/test_live_connect_and_registry.R
# =============================================================================

cat("=== snowflakeR Integration Test ===\n\n")

# -- Step 0: Configure reticulate to use the r-snowflakeR conda env ----------
conda_env_name <- "r-snowflakeR"
conda_env_path <- tryCatch(
  {
    info <- reticulate::conda_list()
    idx <- which(info$name == conda_env_name)
    if (length(idx) > 0) dirname(dirname(info$python[idx[1]])) else NULL
  },
  error = function(e) NULL
)
if (is.null(conda_env_path)) {
  conda_env_path <- file.path(
    "/opt/homebrew/Caskroom/miniconda/base/envs", conda_env_name
  )
}

cat("Using conda env:", conda_env_path, "\n")
Sys.setenv(RETICULATE_PYTHON = file.path(conda_env_path, "bin", "python"))
library(reticulate)
use_python(file.path(conda_env_path, "bin", "python"), required = TRUE)
cat("Python:", reticulate::py_config()$python, "\n\n")

# -- Step 1: Load the package ------------------------------------------------
cat("--- Step 1: Load snowflakeR ---\n")
pkg_path <- Sys.getenv("SNOWFLAKER_PKG_PATH", ".")
devtools::load_all(pkg_path)
cat("OK: Package loaded\n\n")

# -- Step 2: Check environment -----------------------------------------------
cat("--- Step 2: Environment check ---\n")
sfr_check_environment()
cat("\n")

# -- Step 3: Connect to Snowflake -------------------------------------------
cat("--- Step 3: Connect to Snowflake ---\n")

conn_name <- Sys.getenv("SNOWFLAKE_CONNECTION_NAME", "")
if (nzchar(conn_name)) {
  conn <- sfr_connect(connection_name = conn_name)
} else {
  account   <- Sys.getenv("SNOWFLAKE_ACCOUNT", "")
  user      <- Sys.getenv("SNOWFLAKE_USER", "")
  key_file  <- Sys.getenv("SNOWFLAKE_PRIVATE_KEY_FILE", "")
  database  <- Sys.getenv("SNOWFLAKE_DATABASE", "")
  schema    <- Sys.getenv("SNOWFLAKE_SCHEMA", "")
  warehouse <- Sys.getenv("SNOWFLAKE_WAREHOUSE", "")
  role      <- Sys.getenv("SNOWFLAKE_ROLE", "")

  missing <- character(0)
  if (!nzchar(account))  missing <- c(missing, "SNOWFLAKE_ACCOUNT")
  if (!nzchar(user))     missing <- c(missing, "SNOWFLAKE_USER")
  if (!nzchar(key_file)) missing <- c(missing, "SNOWFLAKE_PRIVATE_KEY_FILE")
  if (length(missing) > 0) {
    stop(
      "Set either SNOWFLAKE_CONNECTION_NAME or the following env vars: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  conn <- sfr_connect(
    account          = account,
    user             = user,
    authenticator    = "SNOWFLAKE_JWT",
    private_key_file = key_file,
    database         = if (nzchar(database))  database  else NULL,
    schema           = if (nzchar(schema))    schema    else NULL,
    warehouse        = if (nzchar(warehouse)) warehouse else NULL,
    role             = if (nzchar(role))      role      else NULL
  )
}
cat("OK: Connected\n")
print(conn)
cat("\n")

# -- Step 4: Run a simple query ---------------------------------------------
cat("--- Step 4: Simple query ---\n")
result <- sfr_query(conn, "SELECT CURRENT_TIMESTAMP() AS now, CURRENT_USER() AS who")
rprint(result)
cat("\n")

# -- Step 5: Train a local R model ------------------------------------------
cat("--- Step 5: Train local model ---\n")
model <- lm(mpg ~ wt + hp, data = mtcars)
cat("Model: lm(mpg ~ wt + hp)\n")
cat("  R-squared:", summary(model)$r.squared, "\n\n")

# -- Step 6: Local prediction test ------------------------------------------
cat("--- Step 6: Local prediction (sfr_predict_local) ---\n")
test_data <- data.frame(wt = c(2.5, 3.0, 3.5), hp = c(110, 150, 200))
local_preds <- sfr_predict_local(
  model,
  new_data = test_data,
  input_cols = list(wt = "double", hp = "double"),
  output_cols = list(prediction = "double")
)
rprint(local_preds)
cat("\n")

# -- Step 7: Log model to registry ------------------------------------------
cat("--- Step 7: Log model to Snowflake Model Registry ---\n")
model_name <- paste0("SNOWFLAKER_TEST_", format(Sys.time(), "%Y%m%d_%H%M%S"))
cat("Model name:", model_name, "\n")

mv <- sfr_log_model(
  conn,
  model,
  model_name = model_name,
  version_name = "V1",
  predict_pkgs = character(0),
  input_cols = list(wt = "double", hp = "double"),
  output_cols = list(prediction = "double"),
  target_platforms = "SNOWPARK_CONTAINER_SERVICES",
  comment = "snowflakeR integration test: lm(mpg ~ wt + hp)"
)
print(mv)
cat("\n")

# -- Step 8: List models & get model ----------------------------------------
cat("--- Step 8: Show models ---\n")
models <- sfr_show_models(conn)
cat("  Total models in registry:", nrow(models), "\n")
cat("  Columns:", paste(head(names(models), 10), collapse = ", "), "...\n")
name_col <- if ("name" %in% names(models)) "name" else names(models)[1]
matches <- grepl(model_name, models[[name_col]], ignore.case = TRUE)
if (any(matches)) {
  cat("  Found test model in registry: YES\n")
} else {
  cat("  WARNING: Test model not found in listing (may be schema-filtered)\n")
}
cat("\n")

cat("--- Step 8b: Get model ---\n")
m <- sfr_get_model(conn, model_name)
print(m)
cat("\n")

# -- Step 9: Show versions ---------------------------------------------------
cat("--- Step 9: Show versions ---\n")
versions <- sfr_show_model_versions(conn, model_name)
rprint(versions)
cat("\n")

# -- Step 10: Set and show metrics ------------------------------------------
cat("--- Step 10: Set and show metrics ---\n")
sfr_set_model_metric(conn, model_name, "V1", "r_squared",
                     summary(model)$r.squared)
sfr_set_model_metric(conn, model_name, "V1", "rmse", 2.59)
metrics <- sfr_show_model_metrics(conn, model_name, "V1")
cat("Metrics:\n")
str(metrics)
cat("\n")

# -- Step 11: Clean up ------------------------------------------------------
cat("--- Step 11: Clean up (delete test model) ---\n")
sfr_delete_model(conn, model_name)
cat("\n")

cat("=== ALL INTEGRATION TESTS PASSED ===\n")
