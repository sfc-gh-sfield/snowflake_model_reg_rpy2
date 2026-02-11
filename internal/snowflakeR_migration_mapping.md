# snowflakeR Migration Mapping: Old Functions → Package Functions

**Date:** February 2026
**Purpose:** Track all name/API changes when migrating existing code into the `snowflakeR` package. Use this to update existing notebooks (`r_notebook/`) once the package is functional.

---

## Source: `r_notebook/snowflake_registry.R`

| Old Function | New Function (`snowflakeR`) | Changes |
| ------------ | --------------------------- | ------- |
| `sf_registry_log_model()` | `sfr_log_model()` | Prefix shortened; `conn` added as first arg; `session` param removed |
| `sf_registry_predict_local()` | `sfr_predict_local()` | Prefix shortened |
| `sf_registry_predict()` | `sfr_predict()` | Prefix shortened; `conn` as first arg |
| `sf_registry_show_models()` | `sfr_show_models()` | Prefix shortened; `conn` as first arg |
| `sf_registry_get_model()` | `sfr_get_model()` | Prefix shortened; `conn` as first arg |
| `sf_registry_delete_model()` | `sfr_delete_model()` | Prefix shortened; `conn` as first arg |
| `sf_registry_show_versions()` | `sfr_show_model_versions()` | Prefix shortened; disambiguated with `_model_` |
| `sf_registry_show_metrics()` | `sfr_show_model_metrics()` | Prefix shortened; disambiguated with `_model_` |
| `sf_registry_set_metric()` | `sfr_set_model_metric()` | Prefix shortened; disambiguated with `_model_` |
| `sf_registry_set_default_version()` | `sfr_set_default_model_version()` | Prefix shortened; disambiguated |
| `sf_registry_deploy_model()` | `sfr_deploy_model()` | Prefix shortened; `conn` as first arg |
| `sf_registry_undeploy_model()` | `sfr_undeploy_model()` | Prefix shortened; `conn` as first arg |
| (new) | `sfr_get_model_version()` | New function for getting specific version |

## Source: `r_notebook/sf_registry_bridge.py`

| Old Module/Function | New Location | Changes |
| ------------------- | ------------ | ------- |
| `sf_registry_bridge.py` | `inst/python/sfr_registry_bridge.py` | Renamed with `sfr_` prefix |
| `registry_log_model()` | `registry_log_model()` | No change (internal Python API) |
| `registry_predict_local()` | `registry_predict_local()` | No change |
| `registry_show_models()` | `registry_show_models()` | No change |
| `_build_wrapper_class()` | `_build_wrapper_class()` | No change |

## Source: `r_notebook/r_helpers.py`

| Old Function | New Location | Changes |
| ------------ | ------------ | ------- |
| `detect_environment()` | `inst/python/sfr_connect_bridge.py` | Moved to connection bridge |
| `get_snowpark_session()` | `inst/python/sfr_connect_bridge.py` | Moved to connection bridge |
| `create_pat()` / `get_pat()` | `R/workspace.R` → `sfr_create_pat()` | Rewritten as R function + Python bridge |
| `rprint()` | `R/helpers.R` → `rprint()` | Rewritten as pure R; no prefix (utility) |
| `rview()` | `R/helpers.R` → `rview()` | Rewritten as pure R; no prefix (utility) |
| `rglimpse()` | `R/helpers.R` → `rglimpse()` | Rewritten as pure R; no prefix (utility) |
| `rcat()` | `R/helpers.R` → `rcat()` | Rewritten as pure R; no prefix (utility) |
| `R_CONNECTION_CODE` | `R/connect.R` → `sfr_connect()` | Absorbed into connection function |
| `setup_r_environment()` | `R/workspace.R` → `sfr_workspace_setup()` | R wrapper calling `inst/setup/` script |

## Source: `r_notebook/r_forecasting_demo.ipynb`

| Notebook Code Pattern | Package Equivalent | Notes |
| --------------------- | ------------------ | ----- |
| Manual `reticulate::import(...)` | `sfr_connect()` handles internally | No user Python imports needed |
| Manual `CustomModel` class definition | `sfr_log_model()` auto-generates | No user Python class needed |
| `session$sql(...)$to_pandas()` | `sfr_query(conn, sql)` | Returns R data.frame |
| `registry$log_model(...)` | `sfr_log_model(conn, model, ...)` | Pure R call |

---

## Notebook Update Checklist

When updating notebooks to use the `snowflakeR` package:

- [ ] Replace `source("snowflake_registry.R")` with `library(snowflakeR)`
- [ ] Replace `source("r_helpers.py")` calls with package functions
- [ ] Replace `sf_registry_*()` calls with `sfr_*()` equivalents (see mapping above)
- [ ] Replace manual `reticulate::import()` calls with `sfr_connect()`
- [ ] Replace manual Python bridge calls with package wrapper functions
- [ ] Remove `session = session` arguments (now accessed via `conn` object)
- [ ] Test all notebooks end-to-end with the package installed

## Pre-CRAN Installation

Before the package is on CRAN, testers/beta-customers can install directly from GitHub:

```r
# Using pak (recommended)
pak::pak("Snowflake-Labs/snowflakeR")

# Using remotes
remotes::install_github("Snowflake-Labs/snowflakeR")

# Using devtools
devtools::install_github("Snowflake-Labs/snowflakeR")

# From a local clone
devtools::install("/path/to/snowflakeR")
```

For Workspace Notebooks, the package can be installed into the micromamba R environment:

```r
# Within a Workspace Notebook cell
install.packages("snowflakeR", repos = NULL, type = "source",
                 lib = "/path/to/micromamba/lib/R/library")
```
