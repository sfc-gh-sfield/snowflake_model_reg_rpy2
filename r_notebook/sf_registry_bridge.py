"""
Snowflake Model Registry Bridge for R Models
=============================================

This Python module is the engine behind the R wrapper functions in snowflake_registry.R.
It provides:

1. Auto-generation of CustomModel wrapper classes for arbitrary R models
2. Model signature construction
3. Registry operations (log, list, predict, delete)

R users never import this directly - they use the R functions which call
this module via reticulate.

Architecture:
    R user code
        -> snowflake_registry.R  (user-facing R functions)
        -> reticulate bridge
        -> sf_registry_bridge.py  (this file - Python plumbing)
        -> snowflake.ml.registry  (Snowflake ML Python SDK)
"""

import uuid
import textwrap
from typing import Dict, List, Optional, Any

import pandas as pd


# =============================================================================
# CustomModel Wrapper Factory
# =============================================================================

def _build_wrapper_class(
    predict_function: str,
    predict_packages: List[str],
    predict_body: Optional[str] = None,
    input_cols: Optional[Dict[str, str]] = None,
    output_cols: Optional[Dict[str, str]] = None,
):
    """
    Dynamically build a CustomModel subclass that wraps an R model.
    
    This factory creates a class that:
    - Loads the R model from an .rds file at init time (lazily)
    - On predict(), transfers data to R, calls the specified R function, 
      and returns results as a pandas DataFrame
    
    Args:
        predict_function: R function name to call for inference (e.g. "forecast", "predict")
        predict_packages: R packages to load before calling predict
        predict_body: Optional custom R code for the predict body. 
                      If None, auto-generates based on predict_function.
        input_cols: Dict of {col_name: dtype} for input schema
        output_cols: Dict of {col_name: dtype} for output schema
    
    Returns:
        A CustomModel subclass ready for instantiation
    """
    from snowflake.ml.model import custom_model

    # Build the R code that will be executed for prediction
    if predict_body is not None:
        # User provided custom R prediction code
        r_predict_code = predict_body
    elif predict_function == "forecast":
        # Special handling for forecast::forecast() - common case
        r_predict_code = _build_forecast_r_code()
    elif predict_function == "predict":
        # Generic predict() - works for lm, glm, randomForest, etc.
        r_predict_code = _build_generic_predict_r_code(output_cols)
    else:
        # Fallback: call the function directly 
        r_predict_code = _build_custom_function_r_code(predict_function, output_cols)

    packages_to_load = list(predict_packages)

    class RModelWrapper(custom_model.CustomModel):
        """Auto-generated Python wrapper for an R model."""

        def __init__(self, context: custom_model.ModelContext):
            super().__init__(context)
            self._initialized = False
            self._r_model_name = f"r_model_{uuid.uuid4().hex[:8]}"

        def _ensure_initialized(self):
            if self._initialized:
                return

            import rpy2.robjects as ro
            from rpy2.robjects import pandas2ri
            from rpy2.robjects import numpy2ri
            from rpy2.robjects.conversion import localconverter

            combined = ro.default_converter + pandas2ri.converter + numpy2ri.converter

            with localconverter(combined):
                for pkg in packages_to_load:
                    ro.r(f'library({pkg})')

                model_path = self.context['model_rds']
                ro.r(f'{self._r_model_name} <- readRDS("{model_path}")')

            self._initialized = True

        @custom_model.inference_api
        def predict(self, X: pd.DataFrame) -> pd.DataFrame:
            self._ensure_initialized()

            import rpy2.robjects as ro
            from rpy2.robjects import pandas2ri
            from rpy2.robjects import numpy2ri
            from rpy2.robjects.conversion import localconverter
            from rpy2.rinterface_lib.embedded import RRuntimeError

            combined = ro.default_converter + pandas2ri.converter + numpy2ri.converter
            uid = uuid.uuid4().hex[:8]

            try:
                with localconverter(combined):
                    # Transfer input data to R
                    ro.globalenv[f"input_{uid}"] = X
                    
                    # Execute the R prediction code (uses self._r_model_name and input_{uid})
                    full_r_code = r_predict_code.replace("{{MODEL}}", self._r_model_name)
                    full_r_code = full_r_code.replace("{{INPUT}}", f"input_{uid}")
                    full_r_code = full_r_code.replace("{{UID}}", uid)
                    full_r_code = full_r_code.replace("{{N}}", f"nrow(input_{uid})")
                    
                    ro.r(full_r_code)

                    # Retrieve result
                    result_df = ro.conversion.rpy2py(ro.globalenv[f"result_{uid}"])

                    # Clean up R environment
                    ro.r(f'rm(list = ls(pattern = "_{uid}$"))')

                return result_df

            except RRuntimeError as e:
                try:
                    ro.r(f'rm(list = ls(pattern = "_{uid}$"))')
                except Exception:
                    pass
                raise RuntimeError(f"R execution error: {str(e)}")
            except Exception as e:
                try:
                    ro.r(f'rm(list = ls(pattern = "_{uid}$"))')
                except Exception:
                    pass
                raise RuntimeError(f"Prediction failed: {str(e)}")

    # Set a descriptive class name
    RModelWrapper.__name__ = f"RModelWrapper_{predict_function}"
    RModelWrapper.__qualname__ = RModelWrapper.__name__

    return RModelWrapper


def _build_forecast_r_code() -> str:
    """
    Build R code for forecast::forecast() prediction.
    
    This handles the common case of time series forecasting where:
    - Input is N rows (one per forecast period)
    - Output has point_forecast, lower_80, upper_80, lower_95, upper_95
    """
    return textwrap.dedent("""\
        pred_{{UID}} <- forecast({{MODEL}}, h = {{N}})
        mean_{{UID}} <- as.numeric(pred_{{UID}}$mean)
        lower_{{UID}} <- as.matrix(pred_{{UID}}$lower)
        upper_{{UID}} <- as.matrix(pred_{{UID}}$upper)
        
        result_{{UID}} <- data.frame(
            period         = seq_len({{N}}),
            point_forecast = mean_{{UID}},
            lower_80       = lower_{{UID}}[, 1],
            upper_80       = upper_{{UID}}[, 1],
            lower_95       = lower_{{UID}}[, 2],
            upper_95       = upper_{{UID}}[, 2]
        )
    """)


def _build_generic_predict_r_code(output_cols: Optional[Dict[str, str]] = None) -> str:
    """
    Build R code for generic predict() call.
    
    Works for lm, glm, randomForest, xgboost, etc.
    """
    return textwrap.dedent("""\
        pred_{{UID}} <- predict({{MODEL}}, newdata = {{INPUT}})
        
        if (is.matrix(pred_{{UID}})) {
            result_{{UID}} <- as.data.frame(pred_{{UID}})
        } else {
            result_{{UID}} <- data.frame(prediction = as.numeric(pred_{{UID}}))
        }
    """)


def _build_custom_function_r_code(
    func_name: str,
    output_cols: Optional[Dict[str, str]] = None,
) -> str:
    """
    Build R code for an arbitrary R function call.
    """
    return textwrap.dedent(f"""\
        pred_{{{{UID}}}} <- {func_name}({{{{MODEL}}}}, {{{{INPUT}}}})
        
        if (is.data.frame(pred_{{{{UID}}}})) {{
            result_{{{{UID}}}} <- pred_{{{{UID}}}}
        }} else if (is.matrix(pred_{{{{UID}}}})) {{
            result_{{{{UID}}}} <- as.data.frame(pred_{{{{UID}}}})
        }} else {{
            result_{{{{UID}}}} <- data.frame(prediction = as.numeric(pred_{{{{UID}}}}))
        }}
    """)


def _build_forecast_with_xreg_r_code() -> str:
    """
    Build R code for forecast with exogenous regressors (ARIMAX, etc).
    
    Input DataFrame columns are used as xreg matrix.
    """
    return textwrap.dedent("""\
        # Build xreg matrix from input columns
        xreg_{{UID}} <- as.matrix({{INPUT}})
        
        pred_{{UID}} <- forecast({{MODEL}}, xreg = xreg_{{UID}}, h = {{N}})
        mean_{{UID}} <- as.numeric(pred_{{UID}}$mean)
        lower_{{UID}} <- as.matrix(pred_{{UID}}$lower)
        upper_{{UID}} <- as.matrix(pred_{{UID}}$upper)
        
        result_{{UID}} <- data.frame(
            point_forecast = mean_{{UID}},
            lower_80       = lower_{{UID}}[, 1],
            upper_80       = upper_{{UID}}[, 1],
            lower_95       = lower_{{UID}}[, 2],
            upper_95       = upper_{{UID}}[, 2]
        )
    """)


# =============================================================================
# Model Signature Construction
# =============================================================================

# Map from R-friendly type names to Snowflake ML DataType
_DTYPE_MAP = {
    "integer":  "INT64",
    "int":      "INT64",
    "int64":    "INT64",
    "double":   "DOUBLE",
    "float":    "DOUBLE",
    "float64":  "DOUBLE",
    "numeric":  "DOUBLE",
    "string":   "STRING",
    "character":"STRING",
    "boolean":  "BOOL",
    "logical":  "BOOL",
    "bool":     "BOOL",
}


def _build_signature(
    input_cols: Dict[str, str],
    output_cols: Dict[str, str],
) -> Any:
    """
    Construct a ModelSignature from column name -> type dicts.
    
    Args:
        input_cols:  {"col_name": "dtype", ...}  e.g. {"period": "integer"}
        output_cols: {"col_name": "dtype", ...}
    
    Returns:
        ModelSignature object
    """
    from snowflake.ml.model.model_signature import ModelSignature, FeatureSpec, DataType

    def _specs(cols: Dict[str, str]) -> List:
        specs = []
        for name, dtype_str in cols.items():
            dtype_key = dtype_str.lower().strip()
            if dtype_key not in _DTYPE_MAP:
                raise ValueError(
                    f"Unknown dtype '{dtype_str}' for column '{name}'. "
                    f"Valid types: {list(_DTYPE_MAP.keys())}"
                )
            dt = getattr(DataType, _DTYPE_MAP[dtype_key])
            specs.append(FeatureSpec(name=name, dtype=dt))
        return specs

    return ModelSignature(
        inputs=_specs(input_cols),
        outputs=_specs(output_cols),
    )


# =============================================================================
# Registry Operations  (called from R via reticulate)
# =============================================================================

def registry_log_model(
    session,
    model_rds_path: str,
    model_name: str,
    version_name: Optional[str] = None,
    predict_function: str = "predict",
    predict_packages: Optional[List[str]] = None,
    predict_body: Optional[str] = None,
    input_cols: Optional[Dict[str, str]] = None,
    output_cols: Optional[Dict[str, str]] = None,
    conda_dependencies: Optional[List[str]] = None,
    pip_requirements: Optional[List[str]] = None,
    target_platforms: Optional[List[str]] = None,
    comment: Optional[str] = None,
    metrics: Optional[Dict[str, Any]] = None,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
    options: Optional[Dict[str, Any]] = None,
    sample_input: Optional[pd.DataFrame] = None,
) -> Dict[str, Any]:
    """
    Log an R model to the Snowflake Model Registry.
    
    This is the main function called from R's sf_registry_log_model().
    
    Args:
        session: Snowpark session
        model_rds_path: Path to the .rds file containing the R model
        model_name: Name for the model in the registry
        version_name: Optional version name (auto-generated if not specified)
        predict_function: R function to use for inference ("predict", "forecast", etc.)
        predict_packages: R packages needed for inference
        predict_body: Optional custom R code for prediction (advanced)
        input_cols: Dict mapping input column names to types
        output_cols: Dict mapping output column names to types
        conda_dependencies: Conda packages for the model environment
        pip_requirements: Pip packages for the model environment
        target_platforms: ["WAREHOUSE"], ["SNOWPARK_CONTAINER_SERVICES"], or both
        comment: Model description
        metrics: Dict of metrics to attach to the model version
        database_name: Database for the registry (default: session's current)
        schema_name: Schema for the registry (default: session's current)
        options: Additional options dict for log_model
        sample_input: Sample input DataFrame for signature validation
    
    Returns:
        Dict with model_name, version_name, and status
    """
    from snowflake.ml.registry import Registry
    from snowflake.ml.model import custom_model

    # Defaults
    if predict_packages is None:
        predict_packages = []
    if target_platforms is None:
        target_platforms = ["SNOWPARK_CONTAINER_SERVICES"]
    if conda_dependencies is None:
        conda_dependencies = ["r-base>=4.1", "rpy2>=3.5"]

    # Ensure rpy2 is in conda dependencies
    has_rpy2 = any("rpy2" in dep for dep in conda_dependencies)
    if not has_rpy2:
        conda_dependencies.append("rpy2>=3.5")

    # Ensure r-base is in conda dependencies
    has_rbase = any("r-base" in dep for dep in conda_dependencies)
    if not has_rbase:
        conda_dependencies.insert(0, "r-base>=4.1")

    # Build the wrapper class
    WrapperClass = _build_wrapper_class(
        predict_function=predict_function,
        predict_packages=predict_packages,
        predict_body=predict_body,
        input_cols=input_cols,
        output_cols=output_cols,
    )

    # Create model context with the RDS file
    model_context = custom_model.ModelContext(
        model_rds=model_rds_path
    )

    # Instantiate the wrapper
    model_wrapper = WrapperClass(model_context)

    # Build signature if column specs provided
    signatures = None
    if input_cols and output_cols:
        sig = _build_signature(input_cols, output_cols)
        signatures = {"predict": sig}

    # Build sample input if not provided but input_cols are specified
    if sample_input is None and input_cols:
        sample_rows = {
            name: [1] if dtype.lower() in ("integer", "int", "int64")
                  else [1.0] if dtype.lower() in ("double", "float", "float64", "numeric")
                  else ["a"] if dtype.lower() in ("string", "character")
                  else [True]
            for name, dtype in input_cols.items()
        }
        sample_input = pd.DataFrame(sample_rows)

    # Open registry
    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)

    # Build log_model kwargs
    log_kwargs = {
        "model": model_wrapper,
        "model_name": model_name,
        "conda_dependencies": conda_dependencies,
        "target_platforms": target_platforms,
    }

    if version_name:
        log_kwargs["version_name"] = version_name
    if signatures:
        log_kwargs["signatures"] = signatures
    if sample_input is not None:
        log_kwargs["sample_input_data"] = sample_input
    if comment:
        log_kwargs["comment"] = comment
    if metrics:
        log_kwargs["metrics"] = metrics
    if pip_requirements:
        log_kwargs["pip_requirements"] = pip_requirements
    if options:
        log_kwargs["options"] = options

    # Log the model
    mv = reg.log_model(**log_kwargs)

    return {
        "success": True,
        "model_name": mv.model_name,
        "version_name": mv.version_name,
        "model_version": mv,
        "registry": reg,
    }


def registry_show_models(
    session,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> pd.DataFrame:
    """
    List models in the registry.
    
    Returns:
        pandas DataFrame with model information
    """
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    return reg.show_models()


def registry_get_model(
    session,
    model_name: str,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Get a model reference from the registry.
    
    Returns:
        Dict with model object and metadata
    """
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    m = reg.get_model(model_name)

    return {
        "model": m,
        "name": model_name,
        "comment": m.comment,
        "versions": [v.version_name for v in m.versions()],
        "default_version": m.default.version_name if m.default else None,
        "registry": reg,
    }


def registry_show_versions(
    session,
    model_name: str,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> pd.DataFrame:
    """
    Show versions of a model.
    
    Returns:
        pandas DataFrame with version information
    """
    info = registry_get_model(session, model_name, database_name, schema_name)
    return info["model"].show_versions()


def registry_predict(
    session,
    model_name: str,
    version_name: Optional[str] = None,
    input_data: Optional[pd.DataFrame] = None,
    function_name: str = "predict",
    service_name: Optional[str] = None,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> pd.DataFrame:
    """
    Run inference using a registered model.
    
    Args:
        session: Snowpark session
        model_name: Name of the model
        version_name: Version to use (default: model's default version)
        input_data: pandas DataFrame with input data
        function_name: Method name to call (default: "predict")
        service_name: SPCS service name for container inference
        database_name: Registry database
        schema_name: Registry schema
    
    Returns:
        pandas DataFrame with predictions
    """
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    m = reg.get_model(model_name)

    if version_name:
        mv = m.version(version_name)
    else:
        mv = m.default

    # Create Snowpark DataFrame from input
    sp_df = session.create_dataframe(input_data)

    # Build run kwargs
    run_kwargs = {"function_name": function_name}
    if service_name:
        run_kwargs["service_name"] = service_name

    # Run inference
    result = mv.run(sp_df, **run_kwargs)

    # Convert to pandas
    result_df = result.to_pandas()

    # Lowercase column names for R friendliness
    result_df.columns = [c.lower() for c in result_df.columns]

    return result_df


def registry_predict_local(
    model_rds_path: str,
    input_data: pd.DataFrame,
    predict_function: str = "predict",
    predict_packages: Optional[List[str]] = None,
    predict_body: Optional[str] = None,
    input_cols: Optional[Dict[str, str]] = None,
    output_cols: Optional[Dict[str, str]] = None,
) -> pd.DataFrame:
    """
    Test an R model locally (without deploying to Snowflake).
    
    Uses the same wrapper logic that would be used in the registry,
    so you can verify predictions match before registering.
    
    Args:
        model_rds_path: Path to the .rds file
        input_data: pandas DataFrame with input
        predict_function: R function for inference
        predict_packages: R packages to load
        predict_body: Custom R prediction code
        input_cols: Input column schema
        output_cols: Output column schema
    
    Returns:
        pandas DataFrame with predictions
    """
    from snowflake.ml.model import custom_model

    if predict_packages is None:
        predict_packages = []

    WrapperClass = _build_wrapper_class(
        predict_function=predict_function,
        predict_packages=predict_packages,
        predict_body=predict_body,
        input_cols=input_cols,
        output_cols=output_cols,
    )

    ctx = custom_model.ModelContext(model_rds=model_rds_path)
    wrapper = WrapperClass(ctx)

    return wrapper.predict(input_data)


def registry_delete_model(
    session,
    model_name: str,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> bool:
    """Delete a model from the registry."""
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    reg.delete_model(model_name)
    return True


def registry_delete_version(
    session,
    model_name: str,
    version_name: str,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> bool:
    """Delete a specific version of a model."""
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    m = reg.get_model(model_name)
    m.delete_version(version_name)
    return True


def registry_set_metric(
    session,
    model_name: str,
    version_name: str,
    metric_name: str,
    metric_value: Any,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> bool:
    """Set a metric on a model version."""
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    m = reg.get_model(model_name)
    mv = m.version(version_name)
    mv.set_metric(metric_name, metric_value)
    return True


def registry_show_metrics(
    session,
    model_name: str,
    version_name: str,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> Dict[str, Any]:
    """Get metrics for a model version."""
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    m = reg.get_model(model_name)
    mv = m.version(version_name)
    return mv.show_metrics()


def registry_set_default_version(
    session,
    model_name: str,
    version_name: str,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> bool:
    """Set the default version of a model."""
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    m = reg.get_model(model_name)
    m.default = version_name
    return True


# =============================================================================
# SPCS Service Management (called from R)
# =============================================================================

def registry_create_service(
    session,
    model_name: str,
    version_name: str,
    service_name: str,
    compute_pool: str,
    image_repo: str,
    ingress_enabled: bool = True,
    max_instances: int = 1,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Deploy a model version as an SPCS service.
    
    Returns:
        Dict with service deployment info
    """
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    m = reg.get_model(model_name)
    mv = m.version(version_name)

    mv.create_service(
        service_name=service_name,
        service_compute_pool=compute_pool,
        image_repo=image_repo,
        ingress_enabled=ingress_enabled,
        max_instances=max_instances,
    )

    return {
        "success": True,
        "service_name": service_name,
        "compute_pool": compute_pool,
        "model_name": model_name,
        "version_name": version_name,
    }


def registry_delete_service(
    session,
    model_name: str,
    version_name: str,
    service_name: str,
    database_name: Optional[str] = None,
    schema_name: Optional[str] = None,
) -> bool:
    """Delete an SPCS service for a model version."""
    from snowflake.ml.registry import Registry

    reg_kwargs = {"session": session}
    if database_name:
        reg_kwargs["database_name"] = database_name
    if schema_name:
        reg_kwargs["schema_name"] = schema_name

    reg = Registry(**reg_kwargs)
    m = reg.get_model(model_name)
    mv = m.version(version_name)
    mv.delete_service(service_name)
    return True


# =============================================================================
# Snowpark Session Helper
# =============================================================================

def get_session():
    """Get the current Snowpark session (works in Workspace Notebooks)."""
    from snowflake.snowpark.context import get_active_session
    return get_active_session()


# =============================================================================
# Convenience: Built-in predict templates
# =============================================================================

# These are R code templates that users can reference by name
PREDICT_TEMPLATES = {
    "forecast": _build_forecast_r_code(),
    "forecast_xreg": _build_forecast_with_xreg_r_code(),
    "predict": _build_generic_predict_r_code(),
}


def list_predict_templates() -> Dict[str, str]:
    """Return available prediction code templates."""
    return {k: v for k, v in PREDICT_TEMPLATES.items()}
