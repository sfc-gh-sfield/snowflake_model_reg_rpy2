# Model Registry Wrappers
# =============================================================================
# Adapted from r_notebook/snowflake_registry.R with sfr_* naming convention.
#
# All functions accept either:
#   - An sfr_model_registry object (explicit db/schema targeting), OR
#   - An sfr_connection object (uses session's current db/schema)
# as the first argument (the `reg` parameter).

# =============================================================================
# Registry context object
# =============================================================================

#' Connect to the Model Registry
#'
#' Creates an `sfr_model_registry` object that targets a specific
#' database/schema for model operations. If you want the registry to use
#' the session's current database/schema, pass an `sfr_connection` directly
#' to registry functions instead.
#'
#' @param conn An `sfr_connection` object from [sfr_connect()].
#' @param database Character. Database for the Model Registry. Defaults to the
#'   connection's current database.
#' @param schema Character. Schema for the Model Registry. Defaults to the
#'   connection's current schema.
#'
#' @returns An `sfr_model_registry` object.
#'
#' @examples
#' \dontrun{
#' conn <- sfr_connect()
#'
#' # Option A: Explicit registry with target db/schema
#' reg <- sfr_model_registry(conn, database = "ML_DB", schema = "MODELS")
#' sfr_log_model(reg, model, "MY_MODEL", ...)
#'
#' # Option B: Use connection directly (session's current db/schema)
#' sfr_log_model(conn, model, "MY_MODEL", ...)
#' }
#'
#' @export
sfr_model_registry <- function(conn,
                               database = NULL,
                               schema = NULL) {
  validate_connection(conn)

  structure(
    list(
      conn = conn,
      database = database %||% conn$database,
      schema = schema %||% conn$schema
    ),
    class = c("sfr_model_registry", "list")
  )
}


#' @export
print.sfr_model_registry <- function(x, ...) {
  cli::cli_text(
    "<{.cls sfr_model_registry}> {.val {x$database %||% '<session default>'}}.{.val {x$schema %||% '<session default>'}}"
  )
  invisible(x)
}


# =============================================================================
# Internal: resolve registry context from either object type
# =============================================================================

#' Resolve session, database, schema from reg argument
#'
#' Accepts sfr_model_registry or sfr_connection and returns a list with
#' session, database_name, schema_name that can be passed to the Python bridge.
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @returns A list with `session`, `database_name`, `schema_name`.
#' @noRd
resolve_registry_context <- function(reg) {
  if (inherits(reg, "sfr_model_registry")) {
    list(
      session = reg$conn$session,
      database_name = reg$database,
      schema_name = reg$schema
    )
  } else if (inherits(reg, "sfr_connection")) {
    list(
      session = reg$session,
      database_name = NULL,
      schema_name = NULL
    )
  } else {
    cli::cli_abort(
      "{.arg reg} must be an {.cls sfr_model_registry} or {.cls sfr_connection} object."
    )
  }
}


# =============================================================================
# Log model
# =============================================================================

#' Log an R model to the Snowflake Model Registry
#'
#' Saves the R model to an `.rds` file, auto-generates a Python `CustomModel`
#' wrapper (using rpy2), and registers it in the Snowflake Model Registry.
#'
#' @param reg An `sfr_model_registry` object from [sfr_model_registry()], or
#'   an `sfr_connection` object from [sfr_connect()] (uses session defaults).
#' @param model An R model object (anything that can be `saveRDS()`'d).
#' @param model_name Character. Name for the model in the registry.
#' @param version_name Character. Optional version name (auto-generated if
#'   `NULL`).
#' @param predict_fn Character. R function name for inference. Default:
#'   `"predict"`.
#' @param predict_pkgs Character vector. R packages needed at inference time.
#' @param predict_body Character. Optional custom R code for prediction
#'   (advanced). Use template variables `{{MODEL}}`, `{{INPUT}}`, `{{UID}}`,
#'   `{{N}}`.
#' @param input_cols Named list mapping input column names to types.
#'   Valid types: `"integer"`, `"double"`, `"string"`, `"boolean"`.
#' @param output_cols Named list mapping output column names to types.
#' @param conda_deps Character vector. Conda packages for the model
#'   environment. Defaults include `r-base` and `rpy2`.
#' @param pip_requirements Character vector. Additional pip packages.
#' @param target_platforms Character. One of `"SNOWPARK_CONTAINER_SERVICES"`,
#'   `"WAREHOUSE"`, or both. Default: `"SNOWPARK_CONTAINER_SERVICES"`.
#' @param comment Character. Description of the model.
#' @param metrics Named list. Metrics to attach to the model version.
#' @param sample_input A data.frame. Optional sample input for signature
#'   validation.
#' @param ... Additional arguments passed to the underlying Python
#'   `Registry.log_model()`.
#'
#' @returns An `sfr_model_version` object.
#'
#' @seealso [sfr_predict_local()], [sfr_predict()], [sfr_show_models()]
#'
#' @examples
#' \dontrun{
#' conn <- sfr_connect()
#' model <- lm(mpg ~ wt, data = mtcars)
#' mv <- sfr_log_model(conn, model, model_name = "MTCARS_MPG",
#'                     input_cols = list(wt = "double"),
#'                     output_cols = list(prediction = "double"))
#' }
#'
#' @export
sfr_log_model <- function(reg,
                          model,
                          model_name,
                          version_name = NULL,
                          predict_fn = "predict",
                          predict_pkgs = character(0),
                          predict_body = NULL,
                          input_cols = NULL,
                          output_cols = NULL,
                          conda_deps = NULL,
                          pip_requirements = NULL,
                          target_platforms = "SNOWPARK_CONTAINER_SERVICES",
                          comment = NULL,
                          metrics = NULL,
                          sample_input = NULL,
                          ...) {
  ctx <- resolve_registry_context(reg)

  # Save model to temp .rds file
  model_path <- tempfile(fileext = ".rds")
  saveRDS(model, model_path)

  # Convert R types to Python-friendly types
  py_predict_pkgs <- as.list(predict_pkgs)
  py_input_cols <- if (!is.null(input_cols)) as.list(input_cols) else NULL
  py_output_cols <- if (!is.null(output_cols)) as.list(output_cols) else NULL
  py_conda <- if (!is.null(conda_deps)) as.list(conda_deps) else NULL
  py_pip <- if (!is.null(pip_requirements)) as.list(pip_requirements) else NULL
  py_target <- as.list(target_platforms)
  py_metrics <- if (!is.null(metrics)) as.list(metrics) else NULL
  py_sample <- if (!is.null(sample_input)) {
    reticulate::r_to_py(sample_input)
  } else {
    NULL
  }

  bridge <- get_bridge_module("sfr_registry_bridge")
  result <- bridge$registry_log_model(
    session = ctx$session,
    model_rds_path = model_path,
    model_name = model_name,
    version_name = version_name,
    predict_function = predict_fn,
    predict_packages = py_predict_pkgs,
    predict_body = predict_body,
    input_cols = py_input_cols,
    output_cols = py_output_cols,
    conda_dependencies = py_conda,
    pip_requirements = py_pip,
    target_platforms = py_target,
    comment = comment,
    metrics = py_metrics,
    sample_input = py_sample,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )

  cli::cli_inform(c(
    "v" = "Model {.val {result$model_name}} version {.val {result$version_name}} registered."
  ))

  structure(
    list(
      model_name = result$model_name,
      version_name = result$version_name,
      py_model_version = result$model_version,
      py_registry = result$registry,
      reg = reg
    ),
    class = c("sfr_model_version", "list")
  )
}


#' @export
print.sfr_model_version <- function(x, ...) {
  cli::cli_text("<{.cls sfr_model_version}>")
  cli::cli_dl(list(
    model = cli::format_inline("{.val {x$model_name}}"),
    version = cli::format_inline("{.val {x$version_name}}")
  ))
  invisible(x)
}


# =============================================================================
# Local predict (pure R, no bridge)
# =============================================================================

#' Test an R model locally
#'
#' Calls the R predict function directly on the model, exactly as the
#' registered model would behave inside Snowflake. Use this to verify
#' predictions before registering.
#'
#' **Note:** This runs entirely in R (no Python bridge). The Python bridge
#' with rpy2 is only used when the model executes inside Snowflake (SPCS).
#' Calling reticulate -> Python -> rpy2 -> R from within R would cause a
#' dual-runtime segfault.
#'
#' @param model An R model object.
#' @param new_data A data.frame with input data.
#' @param predict_fn Character. R function name for inference. Default:
#'   `"predict"`.
#' @param predict_pkgs Character vector. R packages to load before prediction.
#' @param predict_body Character. Optional custom R code. Use template
#'   variables `{{MODEL}}`, `{{INPUT}}`, `{{UID}}`, `{{N}}` (same as used
#'   in the Python bridge).
#' @param input_cols Named list. Input column schema (for validation only).
#' @param output_cols Named list. Output column schema (for validation only).
#'
#' @returns A data.frame with predictions.
#'
#' @seealso [sfr_log_model()]
#'
#' @examples
#' \dontrun{
#' model <- lm(mpg ~ wt, data = mtcars)
#' preds <- sfr_predict_local(model, data.frame(wt = c(2.5, 3.0, 3.5)))
#' }
#'
#' @export
sfr_predict_local <- function(model,
                              new_data,
                              predict_fn = "predict",
                              predict_pkgs = character(0),
                              predict_body = NULL,
                              input_cols = NULL,
                              output_cols = NULL) {
  stopifnot(is.data.frame(new_data))

  # Load any required packages
  for (pkg in predict_pkgs) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      cli::cli_abort("Package {.pkg {pkg}} is required but not installed.")
    }
    library(pkg, character.only = TRUE)
  }

  if (!is.null(predict_body)) {
    # Execute custom R code template (same syntax as the Python bridge)
    uid <- paste0(sample(c(0:9, letters[1:6]), 8, replace = TRUE), collapse = "")
    model_name <- paste0("r_model_", uid)

    # Set up environment
    assign(model_name, model, envir = .GlobalEnv)
    assign(paste0("input_", uid), new_data, envir = .GlobalEnv)

    code <- predict_body
    code <- gsub("\\{\\{MODEL\\}\\}", model_name, code)
    code <- gsub("\\{\\{INPUT\\}\\}", paste0("input_", uid), code)
    code <- gsub("\\{\\{UID\\}\\}", uid, code)
    code <- gsub("\\{\\{N\\}\\}", as.character(nrow(new_data)), code)

    tryCatch(
      {
        eval(parse(text = code), envir = .GlobalEnv)
        result <- get(paste0("result_", uid), envir = .GlobalEnv)
      },
      finally = {
        # Clean up global env
        rm_pattern <- paste0("_", uid, "$")
        to_rm <- grep(rm_pattern, ls(envir = .GlobalEnv), value = TRUE)
        rm(list = c(to_rm, model_name), envir = .GlobalEnv)
      }
    )
    return(as.data.frame(result))
  }

  # Standard predict path
  fn <- match.fun(predict_fn)
  pred <- fn(model, newdata = new_data)

  if (is.data.frame(pred)) {
    return(pred)
  } else if (is.matrix(pred)) {
    return(as.data.frame(pred))
  } else {
    return(data.frame(prediction = as.numeric(pred)))
  }
}


# =============================================================================
# Remote predict
# =============================================================================

#' Run remote inference with a registered model
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character. Name of the registered model.
#' @param new_data A data.frame with input data.
#' @param version_name Character. Version to use (default: model's default).
#' @param service_name Character. SPCS service name for container inference.
#' @param ... Additional arguments.
#'
#' @returns A data.frame with predictions.
#'
#' @export
sfr_predict <- function(reg,
                        model_name,
                        new_data,
                        version_name = NULL,
                        service_name = NULL,
                        ...) {
  ctx <- resolve_registry_context(reg)

  bridge <- get_bridge_module("sfr_registry_bridge")
  py_input <- reticulate::r_to_py(new_data)

  result <- bridge$registry_predict(
    session = ctx$session,
    model_name = model_name,
    version_name = version_name,
    input_data = py_input,
    service_name = service_name,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )

  .bridge_dict_to_df(result)
}


# =============================================================================
# List / get / delete models
# =============================================================================

#' List models in the registry
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#'
#' @returns A data.frame listing registered models.
#'
#' @export
sfr_show_models <- function(reg) {
  ctx <- resolve_registry_context(reg)
  bridge <- get_bridge_module("sfr_registry_bridge")
  result <- bridge$registry_show_models(
    session = ctx$session,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )
  .bridge_dict_to_df(result)
}


#' Get a model reference from the registry
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character. Name of the model.
#'
#' @returns An `sfr_model` object.
#'
#' @export
sfr_get_model <- function(reg, model_name) {
  ctx <- resolve_registry_context(reg)
  bridge <- get_bridge_module("sfr_registry_bridge")
  info <- bridge$registry_get_model(
    session = ctx$session,
    model_name = model_name,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )

  structure(
    list(
      name = info$name,
      comment = info$comment,
      versions = as.character(info$versions),
      default_version = info$default_version,
      py_model = info$model,
      py_registry = info$registry,
      reg = reg
    ),
    class = c("sfr_model", "list")
  )
}


#' @export
print.sfr_model <- function(x, ...) {
  cli::cli_text("<{.cls sfr_model}> {.val {x$name}}")
  cli::cli_dl(list(
    versions = cli::format_inline("{.val {x$versions}}"),
    default = cli::format_inline("{.val {x$default_version %||% 'none'}}")
  ))
  if (!is.null(x$comment) && nzchar(x$comment)) {
    cli::cli_text("  {.emph {x$comment}}")
  }
  invisible(x)
}


#' Show versions of a model
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character. Name of the model.
#'
#' @returns A data.frame with version information.
#'
#' @export
sfr_show_model_versions <- function(reg, model_name) {
  ctx <- resolve_registry_context(reg)
  bridge <- get_bridge_module("sfr_registry_bridge")
  result <- bridge$registry_show_versions(
    session = ctx$session,
    model_name = model_name,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )
  .bridge_dict_to_df(result)
}


#' Get a specific model version
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character. Name of the model.
#' @param version_name Character. Version to retrieve.
#'
#' @returns An `sfr_model_version` object.
#'
#' @export
sfr_get_model_version <- function(reg, model_name, version_name) {
  ctx <- resolve_registry_context(reg)
  model <- sfr_get_model(reg, model_name)
  py_mv <- model$py_model$version(version_name)

  structure(
    list(
      model_name = model_name,
      version_name = version_name,
      py_model_version = py_mv,
      py_registry = model$py_registry,
      reg = reg
    ),
    class = c("sfr_model_version", "list")
  )
}


#' Delete a model from the registry
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character. Name of the model to delete.
#'
#' @returns Invisibly returns `TRUE`.
#'
#' @export
sfr_delete_model <- function(reg, model_name) {
  ctx <- resolve_registry_context(reg)
  bridge <- get_bridge_module("sfr_registry_bridge")
  bridge$registry_delete_model(
    session = ctx$session,
    model_name = model_name,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )
  cli::cli_inform("Model {.val {model_name}} deleted.")
  invisible(TRUE)
}


# =============================================================================
# Metrics
# =============================================================================

#' Set a metric on a model version
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character.
#' @param version_name Character.
#' @param metric_name Character. Name of the metric.
#' @param metric_value Numeric or character. Value of the metric.
#'
#' @returns Invisibly returns `TRUE`.
#'
#' @export
sfr_set_model_metric <- function(reg, model_name, version_name,
                                 metric_name, metric_value) {
  ctx <- resolve_registry_context(reg)
  bridge <- get_bridge_module("sfr_registry_bridge")
  bridge$registry_set_metric(
    session = ctx$session,
    model_name = model_name,
    version_name = version_name,
    metric_name = metric_name,
    metric_value = metric_value,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )
  invisible(TRUE)
}


#' Show metrics for a model version
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character.
#' @param version_name Character.
#'
#' @returns A named list of metrics.
#'
#' @export
sfr_show_model_metrics <- function(reg, model_name, version_name) {
  ctx <- resolve_registry_context(reg)
  bridge <- get_bridge_module("sfr_registry_bridge")
  result <- bridge$registry_show_metrics(
    session = ctx$session,
    model_name = model_name,
    version_name = version_name,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )
  as.list(result)
}


#' Set the default version of a model
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character.
#' @param version_name Character.
#'
#' @returns Invisibly returns `TRUE`.
#'
#' @export
sfr_set_default_model_version <- function(reg, model_name, version_name) {
  ctx <- resolve_registry_context(reg)
  bridge <- get_bridge_module("sfr_registry_bridge")
  bridge$registry_set_default_version(
    session = ctx$session,
    model_name = model_name,
    version_name = version_name,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )
  cli::cli_inform(
    "Default version for {.val {model_name}} set to {.val {version_name}}."
  )
  invisible(TRUE)
}


# =============================================================================
# Deploy / undeploy
# =============================================================================

#' Deploy a model as an SPCS service
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character.
#' @param version_name Character.
#' @param service_name Character. Name for the SPCS service.
#' @param compute_pool Character. Compute pool to use.
#' @param image_repo Character. Image repository.
#' @param max_instances Integer. Max service instances. Default: 1.
#'
#' @returns Invisibly returns a list with deployment info.
#'
#' @export
sfr_deploy_model <- function(reg, model_name, version_name,
                             service_name, compute_pool, image_repo,
                             max_instances = 1L) {
  ctx <- resolve_registry_context(reg)
  bridge <- get_bridge_module("sfr_registry_bridge")
  result <- bridge$registry_create_service(
    session = ctx$session,
    model_name = model_name,
    version_name = version_name,
    service_name = service_name,
    compute_pool = compute_pool,
    image_repo = image_repo,
    max_instances = as.integer(max_instances),
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )
  cli::cli_inform(c(
    "v" = "Service {.val {service_name}} deployed for {.val {model_name}}/{.val {version_name}}."
  ))
  invisible(as.list(result))
}


#' Undeploy a model service
#'
#' @param reg An `sfr_model_registry` or `sfr_connection` object.
#' @param model_name Character.
#' @param version_name Character.
#' @param service_name Character.
#'
#' @returns Invisibly returns `TRUE`.
#'
#' @export
sfr_undeploy_model <- function(reg, model_name, version_name, service_name) {
  ctx <- resolve_registry_context(reg)
  bridge <- get_bridge_module("sfr_registry_bridge")
  bridge$registry_delete_service(
    session = ctx$session,
    model_name = model_name,
    version_name = version_name,
    service_name = service_name,
    database_name = ctx$database_name,
    schema_name = ctx$schema_name
  )
  cli::cli_inform("Service {.val {service_name}} removed.")
  invisible(TRUE)
}
