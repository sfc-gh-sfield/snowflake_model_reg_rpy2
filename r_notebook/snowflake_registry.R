# =============================================================================
# snowflake_registry.R - R Wrapper for Snowflake Model Registry
# =============================================================================
#
# PURPOSE:
#   Provides R-native functions to register, manage, and run inference on
#   R models using Snowflake's Model Registry. Under the hood, these functions
#   call the Python snowflake-ml-python SDK via reticulate, but the R user
#   never needs to write Python.
#
# USAGE:
#   source("snowflake_registry.R")
#
#   # Train your model in R as usual
#   model <- auto.arima(my_ts, seasonal = TRUE)
#
#   # Register to Snowflake Model Registry
#   mv <- sf_registry_log_model(
#     model,
#     model_name    = "MY_FORECAST_MODEL",
#     predict_fn    = "forecast",
#     predict_pkgs  = c("forecast"),
#     input_cols    = list(period = "integer"),
#     output_cols   = list(point_forecast = "double", lower_80 = "double",
#                          upper_80 = "double", lower_95 = "double",
#                          upper_95 = "double")
#   )
#
#   # Test locally
#   preds <- sf_registry_predict_local(model, input_df, predict_fn = "forecast",
#                                       predict_pkgs = c("forecast"))
#
#   # Run remote inference (via SPCS)
#   preds <- sf_registry_predict(model_name = "MY_FORECAST_MODEL",
#                                 input_data = data.frame(period = 1:12),
#                                 service_name = "my_svc")
#
# DEPENDENCIES:
#   - reticulate (R package)
#   - snowflake-ml-python (Python package, already in Workspace Notebooks)
#   - rpy2 (Python package, for the deployed model to call R)
#
# =============================================================================

# Global state: cached Python module reference and session
.sf_registry_env <- new.env(parent = emptyenv())
.sf_registry_env$bridge   <- NULL
.sf_registry_env$session  <- NULL
.sf_registry_env$initialized <- FALSE


# =============================================================================
# Initialization
# =============================================================================

#' Initialize the Snowflake Registry R wrapper
#'
#' Must be called once before using any other sf_registry_* function.
#' Sets up the reticulate bridge to the Python backend.
#'
#' @param session A Snowpark session object (from reticulate). If NULL,
#'   attempts to get the active session (works in Workspace Notebooks).
#' @param bridge_path Path to sf_registry_bridge.py. If NULL, looks in the
#'   same directory as this R script.
#' @return Invisible TRUE on success.
#' @export
sf_registry_init <- function(session = NULL, bridge_path = NULL) {
  if (!requireNamespace("reticulate", quietly = TRUE)) {
    stop("Package 'reticulate' is required. Install with: install.packages('reticulate')")
  }

  library(reticulate)

  # Find the bridge module
  if (is.null(bridge_path)) {
    # Try to locate relative to this script
    script_dir <- tryCatch({
      # Works when script is source()'d
      dirname(sys.frame(1)$ofile)
    }, error = function(e) {
      # Fallback: current working directory
      getwd()
    })
    bridge_path <- file.path(script_dir, "sf_registry_bridge.py")
  }

  if (!file.exists(bridge_path)) {
    stop(paste0(
      "Bridge module not found at: ", bridge_path, "\n",
      "Pass bridge_path argument or ensure sf_registry_bridge.py is in the same directory."
    ))
  }

  # Import the Python bridge module
  .sf_registry_env$bridge <- reticulate::import_from_path(
    "sf_registry_bridge",
    path = dirname(bridge_path)
  )

  # Get or set the Snowpark session
  if (is.null(session)) {
    tryCatch({
      .sf_registry_env$session <- .sf_registry_env$bridge$get_session()
    }, error = function(e) {
      message("Could not auto-detect Snowpark session. Pass session= explicitly.")
      message("Error: ", e$message)
    })
  } else {
    .sf_registry_env$session <- session
  }

  .sf_registry_env$initialized <- TRUE

  message("Snowflake Model Registry R wrapper initialized.")
  if (!is.null(.sf_registry_env$session)) {
    message("  Session: connected")
  } else {
    message("  Session: not connected (pass session to sf_registry_init or sf_registry_* functions)")
  }

  invisible(TRUE)
}


#' Check if the wrapper is initialized, and initialize if not
#' @keywords internal
.ensure_init <- function() {
  if (!.sf_registry_env$initialized) {
    message("Auto-initializing Snowflake Registry wrapper...")
    sf_registry_init()
  }
}


#' Get the Python bridge module
#' @keywords internal
.get_bridge <- function() {
  .ensure_init()
  if (is.null(.sf_registry_env$bridge)) {
    stop("Bridge module not loaded. Call sf_registry_init() first.")
  }
  .sf_registry_env$bridge
}


#' Get the Snowpark session
#' @keywords internal
.get_session <- function(session = NULL) {
  if (!is.null(session)) return(session)
  .ensure_init()
  if (is.null(.sf_registry_env$session)) {
    stop("No Snowpark session available. Pass session= argument.")
  }
  .sf_registry_env$session
}


# =============================================================================
# Model Registration
# =============================================================================

#' Register an R model to the Snowflake Model Registry
#'
#' Saves the R model to a temporary .rds file, then creates a Python
#' CustomModel wrapper (auto-generated) that uses rpy2 to call R for
#' inference. The wrapped model is logged to the Snowflake Model Registry.
#'
#' @param model An R model object (anything that can be saveRDS'd and
#'   used with the specified predict function).
#' @param model_name Name for the model in the registry. Must be a valid
#'   Snowflake identifier.
#' @param version_name Optional version name. If NULL, auto-generated.
#' @param predict_fn R function name used for inference. Common values:
#'   "forecast" (forecast package), "predict" (base R / most models).
#'   Default: "predict".
#' @param predict_pkgs Character vector of R package names needed for
#'   inference (e.g., c("forecast", "randomForest")).
#' @param predict_body Optional custom R code for prediction. Advanced usage.
#'   If provided, overrides predict_fn. Use template variables:
#'   \code{{{MODEL}}} (R model object), \code{{{INPUT}}} (input data.frame),
#'   \code{{{UID}}} (unique ID), \code{{{N}}} (number of input rows).
#'   Must assign result to \code{result_{{UID}}}.
#' @param input_cols Named list mapping input column names to types.
#'   Types: "integer", "double", "string", "boolean".
#'   Example: list(period = "integer")
#' @param output_cols Named list mapping output column names to types.
#'   Example: list(point_forecast = "double", lower_80 = "double")
#' @param conda_dependencies Character vector of conda packages.
#'   Default includes r-base and rpy2.
#' @param pip_requirements Character vector of pip packages (optional).
#' @param target_platforms Character vector: "WAREHOUSE",
#'   "SNOWPARK_CONTAINER_SERVICES", or both. Default: "SNOWPARK_CONTAINER_SERVICES".
#' @param comment Description of the model.
#' @param metrics Named list of metrics to attach.
#'   Example: list(rmse = 0.42, r_squared = 0.95)
#' @param database_name Database for the registry. Default: session's current.
#' @param schema_name Schema for the registry. Default: session's current.
#' @param sample_input Optional data.frame of sample input data.
#' @param options Additional options list (passed to log_model).
#' @param session Snowpark session (default: auto-detected).
#'
#' @return A list with model_name, version_name, model_version (Python obj),
#'   and registry (Python obj).
#'
#' @examples
#' \dontrun{
#' # Time series model
#' library(forecast)
#' model <- auto.arima(AirPassengers)
#' mv <- sf_registry_log_model(
#'   model,
#'   model_name   = "AIR_PASSENGERS_FORECAST",
#'   predict_fn   = "forecast",
#'   predict_pkgs = c("forecast"),
#'   input_cols   = list(period = "integer"),
#'   output_cols  = list(point_forecast = "double", lower_80 = "double",
#'                       upper_80 = "double", lower_95 = "double",
#'                       upper_95 = "double"),
#'   comment      = "ARIMA model for air passenger forecasting"
#' )
#'
#' # Linear model
#' model <- lm(mpg ~ wt + hp, data = mtcars)
#' mv <- sf_registry_log_model(
#'   model,
#'   model_name   = "MTCARS_MPG_MODEL",
#'   predict_fn   = "predict",
#'   input_cols   = list(wt = "double", hp = "double"),
#'   output_cols  = list(prediction = "double"),
#'   comment      = "Linear regression for MPG prediction"
#' )
#' }
#' @export
sf_registry_log_model <- function(
  model,
  model_name,
  version_name      = NULL,
  predict_fn        = "predict",
  predict_pkgs      = character(0),
  predict_body      = NULL,
  input_cols        = NULL,
  output_cols       = NULL,
  conda_dependencies = NULL,
  pip_requirements  = NULL,
  target_platforms  = "SNOWPARK_CONTAINER_SERVICES",
  comment           = NULL,
  metrics           = NULL,
  database_name     = NULL,
  schema_name       = NULL,
  sample_input      = NULL,
  options           = NULL,
  session           = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  # Save model to a temp .rds file
  model_path <- tempfile(fileext = ".rds")
  saveRDS(model, file = model_path)
  message("Model saved to temp file: ", model_path,
          " (", file.size(model_path), " bytes)")

  # Convert R lists to Python dicts via reticulate
  py_input_cols  <- if (!is.null(input_cols))  reticulate::dict(input_cols)  else NULL
  py_output_cols <- if (!is.null(output_cols)) reticulate::dict(output_cols) else NULL
  py_metrics     <- if (!is.null(metrics))     reticulate::dict(metrics)     else NULL
  py_options     <- if (!is.null(options))     reticulate::dict(options)     else NULL

  # Convert R vectors to Python lists
  py_predict_pkgs  <- as.list(predict_pkgs)
  py_target        <- as.list(target_platforms)
  py_conda         <- if (!is.null(conda_dependencies)) as.list(conda_dependencies) else NULL
  py_pip           <- if (!is.null(pip_requirements))    as.list(pip_requirements)   else NULL

  # Convert sample_input to pandas DataFrame
  py_sample <- if (!is.null(sample_input)) reticulate::r_to_py(sample_input) else NULL

  # Call the Python bridge
  result <- bridge$registry_log_model(
    session            = session,
    model_rds_path     = model_path,
    model_name         = model_name,
    version_name       = version_name,
    predict_function   = predict_fn,
    predict_packages   = py_predict_pkgs,
    predict_body       = predict_body,
    input_cols         = py_input_cols,
    output_cols        = py_output_cols,
    conda_dependencies = py_conda,
    pip_requirements   = py_pip,
    target_platforms   = py_target,
    comment            = comment,
    metrics            = py_metrics,
    database_name      = database_name,
    schema_name        = schema_name,
    options            = py_options,
    sample_input       = py_sample
  )

  message("\nModel registered successfully!")
  message("  Name:    ", result$model_name)
  message("  Version: ", result$version_name)

  invisible(result)
}


# =============================================================================
# Local Testing
# =============================================================================

#' Test an R model locally using the same wrapper that would run in Snowflake
#'
#' Saves the model to a temp .rds file and runs prediction through the
#' same Python CustomModel wrapper logic used in the registry. This lets
#' you verify that predictions work correctly before registering.
#'
#' @param model R model object.
#' @param input_data A data.frame with input features.
#' @param predict_fn R function name for inference (default: "predict").
#' @param predict_pkgs R packages needed for inference.
#' @param predict_body Optional custom R prediction code.
#' @param input_cols Named list of input column types (optional for local test).
#' @param output_cols Named list of output column types (optional for local test).
#' @return A data.frame with predictions.
#'
#' @examples
#' \dontrun{
#' library(forecast)
#' model <- auto.arima(AirPassengers)
#' preds <- sf_registry_predict_local(
#'   model,
#'   input_data   = data.frame(period = 1:12),
#'   predict_fn   = "forecast",
#'   predict_pkgs = c("forecast")
#' )
#' print(preds)
#' }
#' @export
sf_registry_predict_local <- function(
  model,
  input_data,
  predict_fn    = "predict",
  predict_pkgs  = character(0),
  predict_body  = NULL,
  input_cols    = NULL,
  output_cols   = NULL
) {
  bridge <- .get_bridge()

  # Save model to temp .rds
  model_path <- tempfile(fileext = ".rds")
  saveRDS(model, file = model_path)

  # Convert to Python types
  py_input  <- reticulate::r_to_py(input_data)
  py_pkgs   <- as.list(predict_pkgs)
  py_in_cols  <- if (!is.null(input_cols))  reticulate::dict(input_cols)  else NULL
  py_out_cols <- if (!is.null(output_cols)) reticulate::dict(output_cols) else NULL

  # Call bridge
  result <- bridge$registry_predict_local(
    model_rds_path     = model_path,
    input_data         = py_input,
    predict_function   = predict_fn,
    predict_packages   = py_pkgs,
    predict_body       = predict_body,
    input_cols         = py_in_cols,
    output_cols        = py_out_cols
  )

  # Convert back to R data.frame
  as.data.frame(result)
}


# =============================================================================
# Remote Inference
# =============================================================================

#' Run inference on a registered model (via warehouse or SPCS)
#'
#' @param model_name Name of the registered model.
#' @param input_data A data.frame with input features.
#' @param version_name Version to use (default: model's default version).
#' @param function_name Method name to call (default: "predict").
#' @param service_name SPCS service name (required for SPCS inference).
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return A data.frame with predictions.
#'
#' @examples
#' \dontrun{
#' preds <- sf_registry_predict(
#'   model_name   = "MY_FORECAST_MODEL",
#'   input_data   = data.frame(period = 1:12),
#'   service_name = "my_forecast_svc"
#' )
#' }
#' @export
sf_registry_predict <- function(
  model_name,
  input_data,
  version_name   = NULL,
  function_name  = "predict",
  service_name   = NULL,
  database_name  = NULL,
  schema_name    = NULL,
  session        = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  py_input <- reticulate::r_to_py(input_data)

  result <- bridge$registry_predict(
    session        = session,
    model_name     = model_name,
    version_name   = version_name,
    input_data     = py_input,
    function_name  = function_name,
    service_name   = service_name,
    database_name  = database_name,
    schema_name    = schema_name
  )

  as.data.frame(result)
}


# =============================================================================
# Model & Version Management
# =============================================================================

#' List models in the registry
#'
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return A data.frame with model information.
#' @export
sf_registry_show_models <- function(
  database_name = NULL,
  schema_name   = NULL,
  session       = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  result <- bridge$registry_show_models(
    session       = session,
    database_name = database_name,
    schema_name   = schema_name
  )

  as.data.frame(result)
}


#' Get information about a specific model
#'
#' @param model_name Name of the model.
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return A list with model metadata, versions, default version, etc.
#' @export
sf_registry_get_model <- function(
  model_name,
  database_name = NULL,
  schema_name   = NULL,
  session       = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  bridge$registry_get_model(
    session       = session,
    model_name    = model_name,
    database_name = database_name,
    schema_name   = schema_name
  )
}


#' Show versions of a model
#'
#' @param model_name Name of the model.
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return A data.frame with version information.
#' @export
sf_registry_show_versions <- function(
  model_name,
  database_name = NULL,
  schema_name   = NULL,
  session       = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  result <- bridge$registry_show_versions(
    session       = session,
    model_name    = model_name,
    database_name = database_name,
    schema_name   = schema_name
  )

  as.data.frame(result)
}


#' Delete a model (and all its versions) from the registry
#'
#' @param model_name Name of the model to delete.
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return TRUE on success.
#' @export
sf_registry_delete_model <- function(
  model_name,
  database_name = NULL,
  schema_name   = NULL,
  session       = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  bridge$registry_delete_model(
    session       = session,
    model_name    = model_name,
    database_name = database_name,
    schema_name   = schema_name
  )

  message("Model deleted: ", model_name)
  invisible(TRUE)
}


#' Delete a specific version of a model
#'
#' @param model_name Name of the model.
#' @param version_name Version to delete.
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return TRUE on success.
#' @export
sf_registry_delete_version <- function(
  model_name,
  version_name,
  database_name = NULL,
  schema_name   = NULL,
  session       = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  bridge$registry_delete_version(
    session       = session,
    model_name    = model_name,
    version_name  = version_name,
    database_name = database_name,
    schema_name   = schema_name
  )

  message("Version deleted: ", model_name, "/", version_name)
  invisible(TRUE)
}


#' Set the default version of a model
#'
#' @param model_name Name of the model.
#' @param version_name Version to set as default.
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return TRUE on success.
#' @export
sf_registry_set_default <- function(
  model_name,
  version_name,
  database_name = NULL,
  schema_name   = NULL,
  session       = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  bridge$registry_set_default_version(
    session       = session,
    model_name    = model_name,
    version_name  = version_name,
    database_name = database_name,
    schema_name   = schema_name
  )

  message("Default version set: ", model_name, " -> ", version_name)
  invisible(TRUE)
}


# =============================================================================
# Metrics
# =============================================================================

#' Set a metric on a model version
#'
#' @param model_name Name of the model.
#' @param version_name Version to set the metric on.
#' @param metric_name Name of the metric.
#' @param metric_value Value of the metric (scalar, list, or named list).
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return TRUE on success.
#' @export
sf_registry_set_metric <- function(
  model_name,
  version_name,
  metric_name,
  metric_value,
  database_name = NULL,
  schema_name   = NULL,
  session       = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  # Convert R value for Python
  py_value <- if (is.list(metric_value)) {
    reticulate::dict(metric_value)
  } else {
    metric_value
  }

  bridge$registry_set_metric(
    session       = session,
    model_name    = model_name,
    version_name  = version_name,
    metric_name   = metric_name,
    metric_value  = py_value,
    database_name = database_name,
    schema_name   = schema_name
  )

  invisible(TRUE)
}


#' Get metrics for a model version
#'
#' @param model_name Name of the model.
#' @param version_name Version to get metrics for.
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return A named list of metrics.
#' @export
sf_registry_show_metrics <- function(
  model_name,
  version_name,
  database_name = NULL,
  schema_name   = NULL,
  session       = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  bridge$registry_show_metrics(
    session       = session,
    model_name    = model_name,
    version_name  = version_name,
    database_name = database_name,
    schema_name   = schema_name
  )
}


# =============================================================================
# SPCS Service Management
# =============================================================================

#' Deploy a model version as an SPCS service
#'
#' @param model_name Name of the model.
#' @param version_name Version to deploy.
#' @param service_name Name for the SPCS service.
#' @param compute_pool Compute pool to use.
#' @param image_repo Image repository for the container.
#' @param ingress_enabled Enable ingress (default: TRUE).
#' @param max_instances Max service instances (default: 1).
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return A list with deployment info.
#' @export
sf_registry_create_service <- function(
  model_name,
  version_name,
  service_name,
  compute_pool,
  image_repo,
  ingress_enabled = TRUE,
  max_instances   = 1L,
  database_name   = NULL,
  schema_name     = NULL,
  session         = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  result <- bridge$registry_create_service(
    session         = session,
    model_name      = model_name,
    version_name    = version_name,
    service_name    = service_name,
    compute_pool    = compute_pool,
    image_repo      = image_repo,
    ingress_enabled = ingress_enabled,
    max_instances   = as.integer(max_instances),
    database_name   = database_name,
    schema_name     = schema_name
  )

  message("Service deployment started: ", service_name)
  message("  Compute pool: ", compute_pool)
  message("  Model: ", model_name, "/", version_name)

  invisible(result)
}


#' Delete an SPCS service
#'
#' @param model_name Name of the model.
#' @param version_name Version the service is for.
#' @param service_name Name of the service to delete.
#' @param database_name Registry database.
#' @param schema_name Registry schema.
#' @param session Snowpark session.
#' @return TRUE on success.
#' @export
sf_registry_delete_service <- function(
  model_name,
  version_name,
  service_name,
  database_name = NULL,
  schema_name   = NULL,
  session       = NULL
) {
  bridge  <- .get_bridge()
  session <- .get_session(session)

  bridge$registry_delete_service(
    session       = session,
    model_name    = model_name,
    version_name  = version_name,
    service_name  = service_name,
    database_name = database_name,
    schema_name   = schema_name
  )

  message("Service deleted: ", service_name)
  invisible(TRUE)
}


# =============================================================================
# Convenience Helpers
# =============================================================================

#' List available prediction templates
#'
#' Shows the built-in R code templates that can be used for common model types.
#'
#' @return A named list of template names -> R code strings.
#' @export
sf_registry_list_templates <- function() {
  bridge <- .get_bridge()
  templates <- bridge$list_predict_templates()
  
  message("Available prediction templates:")
  for (name in names(templates)) {
    message("  - ", name)
  }
  
  invisible(templates)
}


#' Helper to set up Snowflake schema and stages for models
#'
#' @param database Database name.
#' @param schema Schema name.
#' @param stage_name Stage name for model artifacts (default: "ML_ARTIFACTS_STAGE").
#' @param warehouse Warehouse to use.
#' @param session Snowpark session.
#' @export
sf_registry_setup <- function(
  database,
  schema,
  stage_name = "ML_ARTIFACTS_STAGE",
  warehouse  = NULL,
  session    = NULL
) {
  session <- .get_session(session)

  # Import snowpark for SQL execution
  py_session <- session

  if (!is.null(warehouse)) {
    py_session$sql(paste0("USE WAREHOUSE ", warehouse))$collect()
    message("Using warehouse: ", warehouse)
  }

  py_session$sql(paste0("CREATE SCHEMA IF NOT EXISTS ", database, ".", schema))$collect()
  py_session$sql(paste0("USE SCHEMA ", database, ".", schema))$collect()
  message("Using schema: ", database, ".", schema)

  py_session$sql(paste0(
    "CREATE STAGE IF NOT EXISTS ", stage_name,
    " COMMENT = 'Stage for R model artifacts'"
  ))$collect()
  message("Artifacts stage: ", stage_name)

  invisible(TRUE)
}


#' Quick summary: print the state of the registry wrapper
#' @export
sf_registry_status <- function() {
  cat("Snowflake Model Registry R Wrapper\n")
  cat("==================================\n")
  cat("Initialized: ", .sf_registry_env$initialized, "\n")
  cat("Bridge:      ", if (!is.null(.sf_registry_env$bridge)) "loaded" else "not loaded", "\n")
  cat("Session:     ", if (!is.null(.sf_registry_env$session)) "connected" else "not connected", "\n")
  
  if (!is.null(.sf_registry_env$session)) {
    tryCatch({
      sess <- .sf_registry_env$session
      cat("  Account:   ", sess$get_current_account(), "\n")
      cat("  User:      ", sess$get_current_user(), "\n")
      cat("  Warehouse: ", sess$get_current_warehouse(), "\n")
    }, error = function(e) {
      cat("  (could not query session details)\n")
    })
  }
  
  invisible(NULL)
}


# =============================================================================
# Print a usage guide
# =============================================================================

#' Print usage guide for the Snowflake Registry R wrapper
#' @export
sf_registry_help <- function() {
  writeLines("
=================================================================
  Snowflake Model Registry - R Wrapper Functions
=================================================================

  SETUP:
    sf_registry_init()              Initialize the wrapper
    sf_registry_setup(db, schema)   Create schema & stages
    sf_registry_status()            Show connection status

  REGISTER MODELS:
    sf_registry_log_model(          Register an R model
      model, model_name,
      predict_fn, predict_pkgs,
      input_cols, output_cols, ...)

  LOCAL TESTING:
    sf_registry_predict_local(      Test model locally
      model, input_data,
      predict_fn, predict_pkgs)

  REMOTE INFERENCE:
    sf_registry_predict(            Run inference on registered model
      model_name, input_data,
      service_name = ...)

  MODEL MANAGEMENT:
    sf_registry_show_models()       List all models
    sf_registry_get_model(name)     Get model details
    sf_registry_show_versions(name) Show versions
    sf_registry_delete_model(name)  Delete model
    sf_registry_delete_version(..)  Delete version
    sf_registry_set_default(..)     Set default version

  METRICS:
    sf_registry_set_metric(..)      Set a metric on a version
    sf_registry_show_metrics(..)    Get metrics for a version

  SPCS DEPLOYMENT:
    sf_registry_create_service(..)  Deploy model as SPCS service
    sf_registry_delete_service(..)  Delete SPCS service

  TEMPLATES:
    sf_registry_list_templates()    Show built-in predict templates

  HELP:
    sf_registry_help()              Show this guide
=================================================================
")
}
