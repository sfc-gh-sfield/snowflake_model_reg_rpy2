# snowflakeR Package: Design & Implementation Plan

**Date:** February 2026
**Status:** Design Phase
**Authors:** Simon Field, with input from Gemini (Snowflake internal docs) and Claude (implementation)

---

## 1. Executive Summary

We are building an R package that provides a native R interface to Snowflake's ML platform (`snowflake-ml-python`), covering connectivity, Model Registry, Feature Store, and data operations. The package uses `reticulate` under the hood to call Python, but presents an idiomatic R API so that R users can work with Snowflake's ML ecosystem without writing Python.

This package consolidates and extends the proof-of-concept code we have already developed and tested:

- **R environment setup** in Snowflake Workspace Notebooks (micromamba, rpy2, ADBC)
- **Model Registry wrappers** (`snowflake_registry.R` + `sfr_registry_bridge.py`) with auto-generated `CustomModel` classes
- **Connectivity helpers** (PAT management, ADBC connection pooling, reticulate + Snowpark)
- **Output helpers** (`rprint`, `rview`, `rglimpse`) for Workspace Notebook formatting

The Feature Store wrapper is new work, informed by the Gemini brainstorming session and the `dbplyr` SQL-extraction pattern described there.

---

## 2. Package Naming

### CRAN Constraints

- Names must contain only **letters, numbers, and dots**
- Must start with a letter (or a dot not followed by a number)
- No underscores or hyphens (unlike Python/npm)
- Must not conflict with existing CRAN packages

### Existing CRAN Packages to Avoid

| Package | Description | Conflict Risk |
|---------|-------------|---------------|
| `snowquery` | Query Snowflake via SQL (wraps snowflake-connector-python) | Direct namespace conflict |
| `snow` | Simple Network of Workstations (parallel computing) | Name too close |
| `DatabaseConnector` | DBI-compatible interface including Snowflake | Different scope |

### Candidate Names

#### Descriptive

| Name | Rationale | Pros | Cons |
|------|-----------|------|------|
| `snowflakeR` | "Snowflake" + "R" suffix (common R convention) | Clear, searchable, memorable | Somewhat generic |
| `snowml` | "Snow[flake]" + "ML" | Short, punchy | Doesn't convey R-specific nature |
| `flakeml` | "Flake" + "ML" | Short | Could be read as "flakey ML" |
| `snowpark.r` | Mirrors Snowpark naming | Consistent with Snowflake brand | Dots in names can confuse (looks like file extension) |

#### Playful / Memorable (CRAN tradition)

| Name | Rationale | Pros | Cons |
|------|-----------|------|------|
| `icebreakeR` | "Breaking the ice" between R and Snowflake; capital R suffix | Memorable, fun, implies bridging | Doesn't convey ML focus |
| `avalanchr` | Avalanche of snow(flake) + R | Dramatic, memorable | Slightly aggressive branding |
| `frostbite` | Frost(snow) + bite(sized API) | Fun, memorable | Negative connotation |
| `chillaR` | Chill(snow) + aR | Relaxed vibe, "chill about Python" | Too informal? |
| `snowr` | Snow + R, simple | Clean, short | Close to `snow` package |
| `blizzaRd` | Blizzard + R + d | Dramatic, embedded R | Slightly forced |
| `snowplow` | Clearing the path from R to Snowflake | Action-oriented, memorable | No R in the name |
| `flurry` | Snow flurry = light snowfall | Elegant, short | No R or ML signal |
| `glacieR` | Glacier + R | Majestic, embedded R, cold storage metaphor | Long |

#### Tongue-in-Cheek / Witty

| Name | Rationale | Pros | Cons |
|------|-----------|------|------|
| `Rctic` | "R" + "Arctic" (cold = snow) | Clever, short, R-first | Hard to pronounce? ("artic") |
| `yetiR` | Yeti = snow creature + R | Fun, very memorable | Unrelated to ML/data |
| `snowcaR` | Snow + caR (like a snowcar/snowcat) | Team name reference, embedded R | Niche |
| `flakeforge` | Snowflake + forge (building things) | Implies building/crafting | Long, no R signal |
| `snowdrift` | Snow + drift (data drift? model drift?) | ML-relevant double meaning | No R signal |
| `piste` | French for ski run; well-groomed path through snow | Elegant, short, implies a clear path | May not be universally known |

### Decision: `snowflakeR`

**Chosen name: `snowflakeR`** (capital R)

- Clear: immediately says "Snowflake + R"
- The capital R visually separates "snowflake" from "R", making the package purpose unambiguous
- CRAN permits mixed case in package names (e.g., `Rcpp`, `RcppTOML`, `DBI`, `bigrquery`)
- Not taken on CRAN. No conflict with `snowquery`, `snowflakeauth`, or `snow`
- Searchable and SEO-friendly
- Professional enough for enterprise use, memorable enough to stick
- Function prefix: `sfr_` (abbreviation of snowflakeR), avoids collision with the popular `sf` spatial package

See also: `internal/snowflakeR_package_dev_standards.md` for complete coding standards and style guide.

---

## 3. Architecture

### 3.1 Layer Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        R User Code                                  │
│   library(snowflakeR)                                               │
│   conn <- sfr_connect(account, user, ...)                           │
│   model <- lm(y ~ x, data); sfr_log_model(conn, model, ...)        │
│   fv <- sfr_create_feature_view(conn, my_dbplyr_tbl, ...)          │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│                     snowflakeR R Package                            │
│                                                                     │
│  R/connect.R        Session management, auth, connection pooling    │
│  R/registry.R       Model Registry: log, predict, manage, deploy   │
│  R/features.R       Feature Store: entities, views, generate_df    │
│  R/query.R          SQL execution, dbplyr integration              │
│  R/helpers.R        Output formatting, diagnostics, PAT mgmt       │
│  R/workspace.R      Workspace Notebook specific setup              │
│  R/zzz.R            .onLoad / .onAttach hooks                      │
│                                                                     │
│  inst/python/       Python bridge modules                           │
│    sfr_registry_bridge.py   (Model Registry engine)                 │
│    sfr_features_bridge.py   (Feature Store engine)                  │
│    sfr_connect_bridge.py    (Connection/session engine)             │
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ reticulate
┌──────────────────────────────▼──────────────────────────────────────┐
│                     Python Environment                              │
│  snowflake-ml-python   (Registry, Feature Store, Datasets)         │
│  snowflake-snowpark-python  (Session, DataFrame, SQL)              │
│  rpy2                  (R↔Python bridge for deployed models)       │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────┐
│                     Snowflake Platform                              │
│  Model Registry  │  Feature Store  │  Warehouses  │  SPCS          │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 Key Design Principles

1. **R-first API.** All user-facing functions take and return R objects (data.frames, lists, character vectors). Python objects are internal implementation details.

2. **Lazy Python initialization.** The Python environment is only spun up when first needed (`reticulate::import_from_path` on first call). Package load (`library(snowflakeR)`) is fast.

3. **No Python for the user.** An R user should never need to write Python, call `reticulate` directly, or understand rpy2. But advanced users _can_ access the underlying Python objects if they choose to.

4. **`inst/python/` for bridge modules.** Python files ship with the package and are located via `system.file("python", package = "snowflakeR")`. This is the standard R package pattern for bundled Python code.

5. **dbplyr as SQL builder.** Feature engineering uses `dbplyr` to translate dplyr pipelines into SQL. The SQL string is extracted and passed to the Python Feature Store API. Users can also pass raw SQL strings.

6. **Idempotent connections.** `sfr_connect()` returns a connection object. All subsequent functions take this object. Connection pooling and session reuse are handled internally.

7. **CRAN-compatible.** No hard dependency on Snowflake-specific infrastructure. The package installs cleanly on any system; Snowflake-specific functionality gracefully errors if `snowflake-ml-python` is not available.

---

## 4. Critique of the Gemini Conversation

The Gemini brainstorming session (`R_interface_for_snowflakeML_GeminiConversation.md`) provided a solid conceptual framework. Here is a critique based on what we've learned from actually building and testing the rpy2/reticulate integration:

### What Gemini Got Right

1. **Single package ("modular monolith")** - Correct. Cross-module object passing (e.g., FeatureView into log_model) is much simpler within one package.

2. **reticulate as the bridge** - Correct. This is the established R-Python interop standard and works well.

3. **dbplyr for SQL extraction** - Excellent idea. `dbplyr::remote_query()` is exactly the right tool. This is the most elegant part of the design.

4. **conda_dependencies requirement** - Correctly identified that the deployed model needs explicit R environment dependencies.

### What Gemini Underestimated or Got Wrong

1. **Serialization complexity.** Gemini says "pass your rpy2-wrapped object directly through reticulate" - this glosses over the hardest problem. R model objects cannot be pickled. They must be:
   - Saved to `.rds` via `saveRDS()`
   - Embedded as a `ModelContext` artifact
   - Loaded lazily inside the `CustomModel.predict()` method
   - All rpy2 imports must be inside methods (not at module level) to avoid pickle failures

   **We solved this** in `sfr_registry_bridge.py` with the `_build_wrapper_class()` factory that handles all of this automatically.

2. **rpy2 API changes.** Gemini's code examples assume `pandas2ri.activate()` which is deprecated in rpy2 >= 3.5. The correct pattern is `localconverter()` context managers. Our code already handles this correctly.

3. **Thread safety.** Gemini doesn't mention that R is single-threaded and rpy2 operations need unique variable names to avoid collisions during concurrent inference. Our `uuid.uuid4().hex[:8]` pattern in the wrapper solves this.

4. **Feature Store API mismatch.** Gemini's `create_feature_view(query=sql_string)` is not how the API works. The actual API takes:
   - A `FeatureView` object constructed with `entities` and a `feature_df` (Snowpark DataFrame)
   - The SQL gets turned into a Snowpark DataFrame first: `session.sql(sql_string)`
   - This is an important detail for the wrapper implementation

5. **"reticulate entry points" oversimplified.** Gemini suggests a simple `import("snowflake.ml.registry")` call. In practice, managing the Python environment (finding the right Python, ensuring snowflake-ml is installed, handling virtual environments vs conda) requires more careful orchestration that `reticulate::use_python()` and `reticulate::import_from_path()` provide.

6. **Missing: local testing.** Gemini's plan has no concept of local prediction testing before registration. Our `sfr_predict_local()` is essential - it runs the exact same wrapper pipeline locally so users can verify before deploying.

7. **Missing: Workspace Notebook specifics.** The R environment setup, ADBC connectivity, PAT management, and output formatting are significant pieces of infrastructure that Gemini doesn't address.

---

## 5. Package Structure

```
snowflakeR/
├── DESCRIPTION
├── NAMESPACE
├── LICENSE
├── README.md
├── .Rbuildignore
├── man/                          # Auto-generated by roxygen2
│   ├── sfr_connect.Rd
│   ├── sfr_log_model.Rd
│   └── ...
├── R/
│   ├── connect.R                 # Connection & session management (DBI compatible)
│   ├── registry.R                # Model Registry wrappers
│   ├── features.R                # Feature Store wrappers
│   ├── datasets.R                # Snowflake Datasets & Parquet access
│   ├── query.R                   # SQL execution & dbplyr helpers
│   ├── admin.R                   # EAI, compute pools, image repos, DDL helpers
│   ├── helpers.R                 # Output formatting, diagnostics
│   ├── workspace.R               # Workspace Notebook setup (R env, ADBC, PAT)
│   ├── python_deps.R             # Python dependency checking/installation
│   ├── zzz.R                     # .onLoad, .onAttach hooks
│   └── snowflakeR-package.R      # Package-level documentation
├── inst/
│   ├── python/
│   │   ├── sfr_registry_bridge.py # Model Registry engine
│   │   ├── sfr_features_bridge.py # Feature Store engine
│   │   ├── sfr_datasets_bridge.py # Datasets engine
│   │   └── sfr_connect_bridge.py  # Connection/session engine
│   └── setup/
│       └── setup_r_environment.sh  # Workspace Notebook R installer
├── tests/
│   ├── testthat/
│   │   ├── test-connect.R
│   │   ├── test-registry.R
│   │   ├── test-features.R
│   │   ├── test-datasets.R
│   │   ├── test-query.R
│   │   ├── test-admin.R
│   │   ├── test-helpers.R
│   │   └── helper-mocks.R        # Shared test helpers and mocks
│   └── testthat.R
└── vignettes/
    ├── getting-started.Rmd
    ├── model-registry.Rmd
    ├── feature-store.Rmd
    ├── datasets.Rmd
    └── workspace-notebooks.Rmd
```

---

## 6. Module Design

### 6.1 `R/connect.R` — Connection & Session Management

This is the foundation. All other modules depend on a connection object.

```r
# Option A: Use connections.toml (via snowflakeauth if installed)
# Reads ~/.snowflake/connections.toml automatically
conn <- sfr_connect()                       # Default connection
conn <- sfr_connect(name = "production")    # Named connection

# Option B: Explicit parameters (overrides connections.toml)
conn <- sfr_connect(
  account   = "xy12345.us-east-1",
  user      = "MYUSER",
  warehouse = "COMPUTE_WH",
  database  = "MY_DB",
  schema    = "MY_SCHEMA",
  role      = "DATA_SCIENTIST",
  authenticator = "externalbrowser"
)

# Option C: Key-pair authentication
conn <- sfr_connect(
  account          = "xy12345.us-east-1",
  user             = "MYUSER",
  private_key_file = "~/.snowflake/rsa_key.p8"
)

# Option D: In Workspace Notebooks - auto-detect active session
conn <- sfr_connect()  # Zero-arg: auto-detect Workspace session or connections.toml

# Connection status & info
sfr_status(conn)
print(conn)
# <sfr_connection> [production]
#   account:     xy12345.us-east-1
#   user:        MYUSER
#   database:    MY_DB
#   schema:      MY_SCHEMA
#   warehouse:   COMPUTE_WH
#   auth_method: externalbrowser
#   environment: local
#   created_at:  2026-02-10 14:30:00

# Use a different warehouse/schema
sfr_use(conn, warehouse = "ML_WH", schema = "FEATURES")
```

**Connection object (`sfr_connection`):** S3 class (named list) with descriptive attributes:
- `session` -- The underlying Snowpark session (Python, via reticulate)
- `account`, `user`, `database`, `schema`, `warehouse`, `role` -- Connection metadata
- `auth_method` -- `"externalbrowser"`, `"keypair"`, `"pat"`, `"oauth"`, or `"session_token"`
- `environment` -- `"workspace"` or `"local"`
- `created_at` -- POSIXct timestamp
- Sensitive fields (password, PAT, private key) redacted in `print.sfr_connection`

**snowflakeauth integration:**
- When `snowflakeauth` is installed: delegates credential resolution to `snowflakeauth::snowflake_connection()` which handles `connections.toml`, `config.toml`, `SNOWFLAKE_*` env vars, and multiple auth methods (browser SSO, key-pair, OAuth)
- When `snowflakeauth` is not installed: reads `connections.toml` directly (via `RcppTOML` or `jsonlite`) or accepts explicit parameters

**External tooling assumptions:**
- Snowflake CLI, Snowpark, etc. may optionally be present in the environment
- We check for existence where needed (e.g., `Sys.which("snow")`)
- In Workspace Notebooks: controlled environment; `snowflake-ml-python` is available
- Locally: `sfr_install_python_deps()` provides opt-in setup

**From existing code:** Adapts `r_helpers.py` (`detect_environment`, `get_snowpark_session`, PAT management) and `R_CONNECTION_CODE` from `r_helpers.py`. See also: `internal/snowflakeR_package_dev_standards.md` for coding standards and integration patterns.

### 6.2 `R/registry.R` — Model Registry

Adapts our existing `snowflake_registry.R` and `sfr_registry_bridge.py`.

```r
# Register a model
mv <- sfr_log_model(
  conn,
  model        = arima_model,           # Any R model
  model_name   = "ORDERS_FORECAST",
  version_name = "v1",                  # Optional (auto-generated)
  predict_fn   = "forecast",            # R function for inference
  predict_pkgs = c("forecast"),         # R packages needed
  input_cols   = list(period = "integer"),
  output_cols  = list(
    point_forecast = "double",
    lower_80 = "double", upper_80 = "double",
    lower_95 = "double", upper_95 = "double"
  ),
  conda_deps = c("r-base>=4.1", "r-forecast>=8.0", "rpy2>=3.5"),
  target_platforms = "SNOWPARK_CONTAINER_SERVICES",
  comment = "ARIMA forecast model",
  metrics = list(aic = arima_model$aic)
)

# Test locally (same wrapper pipeline as deployed)
preds <- sfr_predict_local(
  model = arima_model,
  new_data = data.frame(period = 1:12),
  predict_fn = "forecast",
  predict_pkgs = c("forecast")
)

# Run remote inference
preds <- sfr_predict(conn, "ORDERS_FORECAST",
                    new_data = data.frame(period = 1:12),
                    service_name = "my_svc")

# Model management
sfr_show_models(conn)
sfr_show_model_versions(conn, "ORDERS_FORECAST")
sfr_get_model(conn, "ORDERS_FORECAST")
sfr_delete_model(conn, "ORDERS_FORECAST")
sfr_set_default_model_version(conn, "ORDERS_FORECAST", "v2")

# Metrics
sfr_set_model_metric(conn, "ORDERS_FORECAST", "v1", "rmse", 42.5)
sfr_show_model_metrics(conn, "ORDERS_FORECAST", "v1")

# SPCS deployment
sfr_deploy_model(conn, "ORDERS_FORECAST", "v1",
                service_name = "forecast_svc",
                compute_pool = "ML_POOL",
                image_repo = "ML_IMAGES")
sfr_undeploy_model(conn, "ORDERS_FORECAST", "v1", "forecast_svc")

# Custom predict code (advanced - ARIMAX with xreg)
sfr_log_model(conn, arimax_model, model_name = "ARIMAX",
  predict_body = '
    xreg_{{UID}} <- as.matrix({{INPUT}}[, c("exog1", "exog2")])
    pred_{{UID}} <- forecast({{MODEL}}, xreg = xreg_{{UID}}, h = {{N}})
    result_{{UID}} <- data.frame(
      forecast = as.numeric(pred_{{UID}}$mean),
      lower_95 = as.matrix(pred_{{UID}}$lower)[, 2],
      upper_95 = as.matrix(pred_{{UID}}$upper)[, 2]
    )
  ',
  predict_pkgs = c("forecast"),
  input_cols = list(exog1 = "double", exog2 = "double"),
  output_cols = list(forecast = "double", lower_95 = "double", upper_95 = "double")
)
```

**From existing code:** Direct evolution of `snowflake_registry.R` and `sfr_registry_bridge.py`. Main changes:
- Function prefix changes from `sf_registry_*` to `sfr_*` (shorter, consistent with package abbreviation)
- All functions take `conn` as first argument (consistent API)
- `sfr_predict_local` and `sfr_predict` replace `sf_registry_predict_local` / `sf_registry_predict`

### 6.3 `R/features.R` — Feature Store

New implementation based on Gemini brainstorming, corrected for actual API. Uses a two-step create/register pattern that mirrors the Python API, plus a one-step convenience wrapper.

```r
# Create an entity
entity <- sfr_create_entity(
  conn,
  name      = "CUSTOMER",
  join_keys = c("CUSTOMER_ID"),
  desc      = "Customer entity for feature joins"
)

# Define features using dbplyr pipeline
library(dplyr)
feature_query <- tbl(conn, "RAW_ORDERS") |>
  group_by(CUSTOMER_ID) |>
  summarise(
    TOTAL_SPEND   = sum(ORDER_TOTAL, na.rm = TRUE),
    ORDER_COUNT   = n(),
    AVG_ORDER_VAL = mean(ORDER_TOTAL, na.rm = TRUE),
    LAST_ORDER    = max(ORDER_DATE)
  )

# --- Two-step pattern (mirrors Python: FeatureView() + register_feature_view()) ---

# Step 1: Create a local draft Feature View
draft_fv <- sfr_feature_view(
  name          = "CUSTOMER_SPEND_FEATURES",
  entities      = entity,           # or list(entity1, entity2)
  features      = feature_query,    # dbplyr lazy_tbl, SQL string, or table ref
  refresh_freq  = "1 hour",         # Managed: auto-refresh
  warehouse     = "ML_WH",
  desc          = "Customer spending features"
)

# Inspect before registering
print(draft_fv)

# Step 2: Register to Snowflake (materialises as dynamic table)
fv <- sfr_register_feature_view(conn, draft_fv, version = "v1")

# --- One-step convenience (create + register in one call) ---

fv <- sfr_create_feature_view(
  conn,
  name          = "CUSTOMER_SPEND_FEATURES",
  version       = "v1",
  entities      = entity,
  features      = feature_query,
  refresh_freq  = "1 hour",
  warehouse     = "ML_WH",
  desc          = "Customer spending features"
)

# Raw SQL string as features source
fv2 <- sfr_create_feature_view(
  conn,
  name     = "PRODUCT_FEATURES",
  version  = "v1",
  entities = product_entity,
  features = "SELECT PRODUCT_ID, AVG(PRICE) as AVG_PRICE FROM PRODUCTS GROUP BY 1",
  desc     = "Product pricing features"
)

# Existing Snowflake table as features source
fv3 <- sfr_create_feature_view(
  conn,
  name     = "PRECOMPUTED_FEATURES",
  version  = "v1",
  entities = customer_entity,
  features = tbl(conn, "MY_FEATURE_TABLE")
)

# --- Feature Store management ---

sfr_list_feature_views(conn)
sfr_get_feature_view(conn, "CUSTOMER_SPEND_FEATURES")
sfr_show_fv_versions(conn, "CUSTOMER_SPEND_FEATURES")
sfr_get_fv_version(conn, "CUSTOMER_SPEND_FEATURES", "v1")
sfr_delete_feature_view(conn, "CUSTOMER_SPEND_FEATURES")

# List/manage entities
sfr_list_entities(conn)
sfr_get_entity(conn, "CUSTOMER")
sfr_delete_entity(conn, "CUSTOMER")

# Generate training data from Feature Views
training_df <- sfr_generate_training_data(
  conn,
  spine_df   = tbl(conn, "TRAINING_LABELS"),  # dbplyr or SQL
  features   = list(fv, fv2),
  spine_timestamp_col = "EVENT_TIME",
  spine_label_cols    = c("LABEL")
)

# Retrieve feature values for inference (point-in-time correct)
feature_df <- sfr_retrieve_features(
  conn,
  spine_df = data.frame(CUSTOMER_ID = c(1, 2, 3)),
  features = list(fv)
)
```

**Python bridge (`sfr_features_bridge.py`) responsibilities:**
- `sfr_create_feature_view` with `features` parameter:
  - If `features` is a `dbplyr` lazy_tbl: extract SQL via `dbplyr::remote_query()`, then `session.sql(sql)` to get Snowpark DF
  - If `features` is a character string: treat as raw SQL, `session.sql(sql)`
  - Pass Snowpark DF to `FeatureView()` constructor
- `FeatureStore` instantiation and method calls
- Data type mapping between R and Snowpark

**Technical challenge (from our experience):** The `FeatureView` constructor takes a Snowpark DataFrame, not a SQL string. So we must convert SQL → Snowpark DF on the Python side. This is straightforward with `session.sql(extracted_sql)`. The Gemini conversation incorrectly showed `create_feature_view(query=sql_string)` which is not the actual API.

### 6.4 `R/query.R` — SQL Execution & dbplyr Integration

```r
# Execute SQL and return R data.frame
result <- sfr_query(conn, "SELECT * FROM my_table LIMIT 100")

# Execute SQL for side effects (DDL, DML)
sfr_execute(conn, "CREATE TABLE foo AS SELECT 1 AS x")

# dbplyr integration: make conn work as a DBI-like source for tbl()
# This enables: tbl(conn, "MY_TABLE") |> filter(...) |> collect()
tbl.sfr_connection <- function(src, from, ...) {
  # Returns a dbplyr lazy_tbl backed by a Snowpark query
}
```

**Design consideration:** We could make `sfr_connection` objects DBI-compatible so that `dplyr::tbl()` works natively. However, full DBI compliance is a large scope. Initially, we provide `sfr_query()` and `tbl(conn, "TABLE")` via a custom method, deferring full DBI compliance to a later phase.

### 6.5 `R/helpers.R` — Output Formatting & Diagnostics

Adapts existing code from `r_helpers.py`:

```r
# Workspace Notebook output formatting
rprint(df)          # Clean print (bypasses extra line breaks)
rview(df, n = 10)   # View data frame head
rglimpse(df)        # Glimpse data frame
rcat("Value:", x)   # Clean cat() replacement

# Diagnostics
sfr_check_environment()  # Check R, Python, snowflake-ml, connectivity
sfr_check_python()       # Check Python environment specifically
```

### 6.6 `R/workspace.R` — Workspace Notebook Setup

Adapts `setup_r_environment()` and related helpers:

```r
# One-call setup for Workspace Notebooks
sfr_workspace_setup(install_adbc = TRUE)

# PAT management
pat <- sfr_create_pat(conn, days_to_expiry = 1)
sfr_pat_status()
sfr_refresh_pat(conn)

# ADBC connection for direct R-to-Snowflake queries
adbc_conn <- sfr_adbc_connect(pat = pat)
result <- sfr_adbc_query(adbc_conn, "SELECT * FROM my_table")
sfr_adbc_disconnect(adbc_conn)
```

### 6.7 `R/python_deps.R` — Python Dependency Management

```r
# Check if Python dependencies are available
sfr_check_python_deps()

# Install required Python packages (if not present)
sfr_install_python_deps(
  method = "auto",  # "auto", "conda", "pip", or "virtualenv"
  envname = "r-snowflakeR"
)
```

Uses `reticulate::py_install()` or `reticulate::conda_install()` under the hood. Important for CRAN: installation must be opt-in (not automatic), per CRAN policies about not modifying the user's system without consent.

---

## 7. DESCRIPTION File (Draft)

```
Package: snowflakeR
Title: R Interface to the Snowflake ML Platform
Version: 0.1.0
Authors@R: c(
    person("Simon", "Field", role = c("aut", "cre"),
           email = "simon.field@snowflake.com")
  )
Description: Provides native R functions for working with the Snowflake ML
    platform, including Model Registry (log, deploy, and serve R models),
    Feature Store (create and manage feature views using dplyr/dbplyr or SQL),
    and data connectivity. Uses 'reticulate' to bridge to the
    'snowflake-ml-python' SDK while presenting an idiomatic R API. Supports
    both Snowflake Workspace Notebooks and local R environments. Integrates
    with 'snowflakeauth' for 'connections.toml'/'config.toml' credential
    management when available.
License: Apache License (>= 2)
URL: https://github.com/Snowflake-Labs/snowflakeR
BugReports: https://github.com/Snowflake-Labs/snowflakeR/issues
Encoding: UTF-8
Roxygen: list(markdown = TRUE)
RoxygenNote: 7.3.2
Depends:
    R (>= 4.1.0)
Imports:
    reticulate (>= 1.34),
    jsonlite,
    cli,
    rlang
Suggests:
    snowflakeauth,
    testthat (>= 3.0.0),
    dplyr,
    dbplyr,
    DBI,
    knitr,
    rmarkdown,
    withr
Config/testthat/edition: 3
VignetteBuilder: knitr
SystemRequirements: Python (>= 3.9), snowflake-ml-python (>= 1.5.0)
```

**CRAN compliance notes:**
- `Imports`: `reticulate` (Python bridge), `jsonlite` (config parsing), `cli` (user messages/errors per tidyverse convention), `rlang` (tidy evaluation utilities, `%||%` operator)
- `snowflakeauth` is in `Suggests` — used for `connections.toml`/`config.toml` credential management when available; falls back to direct parameter handling otherwise
- `dplyr`/`dbplyr` are `Suggests` — the package works without them (Feature Store functions just require them at call time)
- No binary dependencies that would complicate CRAN builds
- Python is a `SystemRequirements`, not a hard R dependency
- The package can be installed on any system; Snowflake operations fail gracefully with informative messages if Python deps are missing

---

## 8. CRAN Compliance Checklist

| Requirement | Plan |
|-------------|------|
| **No side effects on load** | `.onLoad` only sets options, no Python init |
| **No writes to user filesystem** | Python deps installed only via explicit `sfr_install_python_deps()` |
| **No internet access on check** | Tests that need Snowflake connection are skipped via `testthat::skip_on_cran()` |
| **Examples run < 5 sec** | All Snowflake examples wrapped in `\dontrun{}` |
| **No hard Python dependency** | Package installs without Python; functions error with helpful message |
| **License** | Apache 2.0 (matches snowflake-ml-python) |
| **No non-ASCII in R code** | Enforce in CI |
| **R CMD check passes** | 0 errors, 0 warnings, 0 notes target |

---

## 9. Testing Strategy

### 9.1 Unit Tests (run anywhere, no Snowflake)

- R function argument validation
- Type mapping (`_DTYPE_MAP`) correctness
- SQL extraction from mock dbplyr objects
- Connection object construction
- Error messages for missing Python deps

### 9.2 Integration Tests (require Snowflake, skip on CRAN)

- `sfr_connect()` with various auth methods
- `sfr_log_model()` → `sfr_predict_local()` → `sfr_predict()` round-trip
- `sfr_create_entity()` → `sfr_create_feature_view()` → `sfr_generate_training_data()` pipeline
- `sfr_query()` with various SQL patterns
- SPCS deployment/teardown

### 9.3 CI/CD

- GitHub Actions workflow:
  - `R CMD check` on Linux, macOS, Windows (CRAN-like)
  - Integration tests on a Snowflake trial account (nightly)
- Pre-commit hooks for code style (`lintr`, `styler`)

---

## 10. Implementation Roadmap

### Phase 0: Scaffolding (Week 1)

- [ ] Decide on final package name
- [ ] Create package skeleton with `usethis::create_package()`
- [ ] Set up DESCRIPTION, NAMESPACE, LICENSE
- [ ] Configure roxygen2, testthat, pkgdown
- [ ] Migrate `inst/python/` bridge modules from existing code
- [ ] Set up GitHub Actions CI

### Phase 1: Connection & Core (Week 2)

- [ ] `R/connect.R` — `sfr_connect()`, `sfr_status()`, `sfr_use()`
- [ ] `R/query.R` — `sfr_query()`, `sfr_execute()`
- [ ] `R/python_deps.R` — `sfr_check_python_deps()`, `sfr_install_python_deps()`
- [ ] `R/zzz.R` — `.onLoad` / `.onAttach`
- [ ] `inst/python/sfr_connect_bridge.py`
- [ ] Unit tests for connect, query, deps
- [ ] Vignette: `getting-started.Rmd`

### Phase 2: Model Registry (Week 3)

- [ ] `R/registry.R` — Full API (adapting existing `snowflake_registry.R`)
- [ ] `inst/python/sfr_registry_bridge.py` — Adapt existing bridge
- [ ] `sfr_log_model()`, `sfr_predict_local()`, `sfr_predict()`
- [ ] `sfr_show_models()`, `sfr_get_model()`, `sfr_show_model_versions()`, etc.
- [ ] `sfr_deploy_model()`, `sfr_undeploy_model()`
- [ ] Unit tests (mock-based) + integration tests
- [ ] Vignette: `model-registry.Rmd`

### Phase 3: Feature Store (Weeks 4-5)

- [ ] `R/features.R` — Entity and FeatureView API
- [ ] `inst/python/sfr_features_bridge.py`
- [ ] dbplyr SQL extraction (`dbplyr::remote_query()` or `dbplyr::sql_render()`)
- [ ] Raw SQL and table-reference modes
- [ ] `sfr_generate_training_data()`, `sfr_retrieve_features()`
- [ ] Integration tests
- [ ] Vignette: `feature-store.Rmd`

### Phase 4: Helpers & Workspace (Week 6)

- [ ] `R/helpers.R` — Output helpers, diagnostics (from `r_helpers.py`)
- [ ] `R/workspace.R` — Workspace Notebook setup (from `setup_r_environment.sh`)
- [ ] PAT management functions
- [ ] ADBC connection functions
- [ ] Vignette: `workspace-notebooks.Rmd`

### Phase 5: Polish & Release (Weeks 7-8)

- [ ] `pkgdown` documentation site
- [ ] Complete `README.md` with badges, examples
- [ ] `R CMD check` passes with 0/0/0
- [ ] Code coverage > 80%
- [ ] Internal review
- [ ] GitHub release (v0.1.0)
- [ ] Submit to CRAN (v1.0.0 target)

---

## 11. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| **Python environment fragility** | Users struggle to get Python deps installed | High | Clear error messages, `sfr_install_python_deps()` helper, detailed vignette |
| **rpy2 pickle issues in deployed models** | Model inference fails in SPCS | Medium | Already solved: lazy init, saveRDS serialization, uuid-scoped variables |
| **Snowflake ML API changes** | Wrapper functions break on SDK updates | Medium | Pin minimum version, test against latest in CI, version-check in bridge modules |
| **CRAN submission delays** | Manual review can take weeks | Medium | Ensure perfect `R CMD check`, pre-submit with `rhub` |
| **dbplyr SQL dialect mismatches** | Generated SQL doesn't work in Snowflake | Low | Test common patterns; users can fall back to raw SQL |
| **Feature Store API is still evolving** | API may change before we're done | Medium | Build against latest stable release, abstract behind our wrapper layer |
| **reticulate + conda conflicts** | Python environment detection issues | Medium | Support multiple methods (conda, virtualenv, system), document clearly |

---

## 12. Resolved Decisions (formerly Open Questions)

1. **Package name** — **`snowflakeR`** (capital R). Built by Snowflake (Simon Field). No trademark issue since this is an official Snowflake project. Function prefix: `sfr_`.

2. **DBI compatibility** — **Yes, implement from the start.** `sfr_connection` should implement `DBI::dbConnect()` so that `dplyr::tbl(conn, "TABLE")` works natively. This is a core usability feature and easier to get right from the start than to retrofit.

3. **Scope boundary** — **No `snowflake.ml.modeling` wrappers.** These are scikit-learn-based distributed training functions. The whole point of `snowflakeR` is that R users train in R, then use Snowflake for deployment. No value in wrapping sklearn from R.

4. **Snowflake Datasets** — **Yes, include.** Wrap `snowflake.ml.dataset` for versioned datasets. Also provide R utility functions for reading the underlying Parquet files directly into R (via the Python `fsspec` interface or `arrow`/`nanoparquet`). This complements both Feature Store and Model Registry.

5. **External Access Integrations** — **Yes, include.** Create R utility functions that simplify creating/managing EAIs and other Snowflake objects that ML users frequently need to CRUD (assuming they have privileges). This includes EAIs, compute pools, image repositories, etc.

6. **Tidymodels integration** — **Yes, include.** Support `tidymodels` framework integration. Also consider `tidypredict` (converts models to SQL for in-database prediction) and `orbital` (converts tidymodels workflows to database-ready objects). Where applicable, `snowflakeR` could use these to enable SQL-native prediction for supported model types, complementing the rpy2 container approach.

---

## 12a. Package Development Folder Structure

The package is developed in a **top-level `snowflakeR/` folder** within this project:

```
snowflake_model_reg_rpy2/           # This repo (internal development)
├── snowflakeR/                    # R PACKAGE (new)
│   ├── DESCRIPTION
│   ├── NAMESPACE
│   ├── LICENSE
│   ├── README.md
│   ├── R/
│   │   ├── connect.R
│   │   ├── registry.R
│   │   ├── features.R
│   │   ├── datasets.R
│   │   ├── query.R
│   │   ├── helpers.R
│   │   ├── workspace.R
│   │   ├── admin.R               # EAI, compute pool, etc.
│   │   ├── python_deps.R
│   │   ├── zzz.R
│   │   └── snowflakeR-package.R
│   ├── inst/python/
│   ├── tests/
│   ├── vignettes/
│   └── man/
├── r_notebook/                    # Existing notebooks (will be updated to use package)
├── internal/                      # Internal docs (not synced)
├── dj_ml/                         # Original approaches (reference)
├── dj_ml_rpy2/                    # rpy2 approach (reference)
└── sync_to_public_repo.sh         # Existing sync for r_notebook
```

**Why a subfolder (not a separate repo):**
- Keeps development alongside the notebooks that depend on it
- Easy to test package changes against existing notebooks
- Internal docs, experiments, and reference code stay accessible
- When ready, the `snowflakeR/` folder becomes the root of the public `Snowflake-Labs/snowflakeR` repo
- A new `sync_snowflakeR_to_public.sh` script (like `sync_to_public_repo.sh`) handles:
  - Copying `snowflakeR/` to the public repo
  - Stripping internal dev values (database names, credentials)
  - Preserving `.git/`, `LICENSE`, etc. in the target

**Pre-CRAN installation:** Testers and beta customers install directly from GitHub:

```r
pak::pak("Snowflake-Labs/snowflakeR")
# or
remotes::install_github("Snowflake-Labs/snowflakeR")
```

---

## 12b. Feature View Create/Register Convention

In Python, creating a Feature View is a two-step process:
1. `fv = FeatureView(name, entities, feature_df, ...)` — creates a local draft object
2. `registered_fv = fs.register_feature_view(fv, version)` — materialises it in Snowflake

**R approach: Provide both patterns.**

### Two-step (mirrors Python, gives control)

```r
# Step 1: Create a local draft Feature View
draft_fv <- sfr_feature_view(
  name     = "CUSTOMER_SPEND",
  entities = customer_entity,
  features = feature_query,       # dbplyr lazy_tbl or SQL string
  refresh_freq = "1 hour",
  desc     = "Customer spending features"
)

# User can inspect/modify before registering
print(draft_fv)
draft_fv$desc <- "Updated description"

# Step 2: Register to Snowflake (materialises)
registered_fv <- sfr_register_feature_view(conn, draft_fv, version = "v1")
```

### One-step convenience (most common use case)

```r
# Create AND register in one call
registered_fv <- sfr_create_feature_view(
  conn,
  name     = "CUSTOMER_SPEND",
  version  = "v1",
  entities = customer_entity,
  features = feature_query,
  refresh_freq = "1 hour",
  desc     = "Customer spending features"
)
```

`sfr_create_feature_view()` is syntactic sugar that calls `sfr_feature_view()` + `sfr_register_feature_view()` internally. The two-step pattern is available for users who need to customise the draft before registration, or who want to inspect the generated SQL.

---

## 12c. Namespace Disambiguation: Model Registry vs Feature Store

Both Model Registry and Feature Store have objects with **versions**, **metrics**, **descriptions**, and **list/get/delete** operations. Without disambiguation, function names like `sfr_show_versions()` or `sfr_get_version()` would be ambiguous.

### Solution: Explicit object type in function names

We embed the **object type** (`model` or `fv`) in every function name that could be ambiguous:

| Operation | Model Registry | Feature Store |
| --------- | -------------- | ------------- |
| **Log/Create** | `sfr_log_model()` | `sfr_create_feature_view()` |
| **Get** | `sfr_get_model()` | `sfr_get_feature_view()` |
| **List all** | `sfr_show_models()` | `sfr_list_feature_views()` |
| **Delete** | `sfr_delete_model()` | `sfr_delete_feature_view()` |
| **Show versions** | `sfr_show_model_versions()` | `sfr_show_fv_versions()` |
| **Get version** | `sfr_get_model_version()` | `sfr_get_fv_version()` |
| **Set default version** | `sfr_set_default_model_version()` | (N/A) |
| **Metrics** | `sfr_set_model_metric()` | (N/A for FV) |
| **Show metrics** | `sfr_show_model_metrics()` | (N/A for FV) |
| **Deploy** | `sfr_deploy_model()` | (N/A) |
| **Register** | (part of `sfr_log_model`) | `sfr_register_feature_view()` |
| **Entities** | (N/A) | `sfr_create_entity()`, `sfr_list_entities()` |
| **Training data** | (N/A) | `sfr_generate_training_data()` |

**Key principle:** If a function is unique to one domain (e.g., `sfr_log_model` can only be Model Registry, `sfr_create_entity` can only be Feature Store), no sub-prefix is needed. Only version/metric operations that could span both domains get the explicit `_model_` or `_fv_` qualifier.

**Why not `sfr_mr_` / `sfr_fs_` sub-prefixes:**
- Most functions are already unambiguous from their names (`sfr_log_model`, `sfr_create_feature_view`)
- Sub-prefixes add typing burden: `sfr_mr_show_versions()` is 24 chars vs `sfr_show_model_versions()` is 26 chars — nearly the same length but the latter reads more naturally
- Sub-prefixes create a mental barrier: users must remember *which prefix* to use before they can auto-complete
- The explicit-object-name approach is the pattern used by `dplyr` (e.g., `rows_insert`, `rows_update`, `rows_delete` vs generic `insert`, `update`, `delete`)

---

## 12d. Snowflake Datasets & Parquet Access

Wrap `snowflake.ml.dataset` for versioned datasets:

```r
# Create a dataset from a query
ds <- sfr_create_dataset(conn, name = "TRAINING_DATA_V1",
                         query = "SELECT * FROM FEATURES WHERE SPLIT = 'TRAIN'")

# List datasets
sfr_list_datasets(conn)

# Read dataset into R (returns data.frame)
df <- sfr_read_dataset(conn, "TRAINING_DATA_V1")

# Read underlying Parquet files directly (via fsspec or arrow)
df <- sfr_read_parquet(conn, "TRAINING_DATA_V1")
```

---

## 12e. External Access & Admin Utilities

R utility functions for common Snowflake administrative operations ML users need:

```r
# External Access Integrations
sfr_create_eai(conn, name = "PYPI_ACCESS",
               allowed_hosts = c("pypi.org", "files.pythonhosted.org"))
sfr_list_eais(conn)

# Compute pools (for SPCS)
sfr_create_compute_pool(conn, name = "ML_POOL",
                        instance_family = "CPU_X64_S", min_nodes = 1, max_nodes = 3)
sfr_list_compute_pools(conn)

# Image repositories
sfr_create_image_repo(conn, name = "ML_IMAGES")
sfr_list_image_repos(conn)

# Generic DDL/admin
sfr_execute(conn, "GRANT USAGE ON INTEGRATION PYPI_ACCESS TO ROLE DATA_SCIENTIST")
```

---

## 12f. Tidymodels, TidyPredict & Orbital Integration

### Phase 1: Basic tidymodels support (register any tidymodels workflow)

Any fitted tidymodels workflow can be registered to Model Registry using the standard `sfr_log_model()` path (saved as `.rds`, executed via rpy2 in SPCS).

### Phase 2: SQL-native prediction via tidypredict/orbital

For **supported model types** (lm, glm, randomForest, ranger, xgboost, etc.), we can optionally convert the model to SQL using `tidypredict::tidypredict_sql()` or `orbital::orbital()`, enabling prediction directly in Snowflake SQL without rpy2/SPCS:

```r
# Standard path (rpy2 in SPCS - works for any R model)
sfr_log_model(conn, my_workflow, model_name = "MY_MODEL")

# SQL-native path (no SPCS needed, but limited to supported model types)
sfr_log_model(conn, my_workflow, model_name = "MY_MODEL_SQL",
              target_platforms = "WAREHOUSE",
              use_sql_predict = TRUE)  # Converts to SQL via tidypredict/orbital
```

This is a significant value-add: models that can be expressed as SQL run faster and cheaper (no container runtime needed). The `use_sql_predict = TRUE` flag triggers the conversion and registers the model with a SQL-based prediction UDF rather than a rpy2 container.

---

## 13. Relationship to Existing Code

### What Gets Absorbed Into the Package

| Current File | Package Destination | Notes |
|-------------|-------------------|-------|
| `r_notebook/snowflake_registry.R` | `R/registry.R` | Refactor: prefix `sfr_*`, add `conn` param |
| `r_notebook/sf_registry_bridge.py` | `inst/python/sfr_registry_bridge.py` | Rename to `sfr_` prefix |
| `r_notebook/r_helpers.py` (output helpers) | `R/helpers.R` (R native) | Rewrite as pure R functions |
| `r_notebook/r_helpers.py` (PAT mgmt) | `R/workspace.R` + `inst/python/sfr_connect_bridge.py` | Split R/Python parts |
| `r_notebook/r_helpers.py` (connection mgmt) | `R/connect.R` + `inst/python/sfr_connect_bridge.py` | Refactor for general use |
| `r_notebook/r_helpers.py` (diagnostics) | `R/helpers.R` | Adapt to package context |
| `r_notebook/setup_r_environment.sh` | `inst/setup/setup_r_environment.sh` | Ship as-is for Workspace users |
| `dj_ml_rpy2/r_model_wrapper_rpy2.py` | Superseded by `sfr_registry_bridge.py` | Factory approach is more general |

### What Stays Separate

| File | Reason |
|------|--------|
| `r_notebook/r_workspace_notebook.ipynb` | User-facing notebook, not part of package |
| `r_notebook/r_forecasting_demo.ipynb` | Demo notebook |
| `r_notebook/r_registry_demo.ipynb` | Demo notebook |
| `dj_ml/` | Original subprocess-based approach (kept for reference) |
| `remote_dev/` | DuckDB/Iceberg experiments (separate concern) |

---

## 14. Migration Mapping

A detailed mapping of old function names to new `snowflakeR` package names is maintained in:

**`internal/snowflakeR_migration_mapping.md`**

This document tracks:
- Every function rename from `sf_registry_*` to `sfr_*`
- Source file to package file mappings
- Notebook code patterns and their package equivalents
- A checklist for updating existing notebooks

This mapping must be kept current as we develop the package, and used when we update the existing notebooks to use `library(snowflakeR)` instead of `source()`.

---

## 15. Resolved Open Questions (Round 2)

All questions from the previous round have been answered:

1. **Snowflake trademark/branding** — **OK.** Built by Snowflake employee on Snowflake's behalf. Posit's `snowflakeauth` sets precedent for using "snowflake" in CRAN package names.

2. **DBI method completeness** — **Minimum viable for Phase 1.** Implement: `dbConnect()`, `dbDisconnect()`, `dbGetQuery()`, `dbSendQuery()`, `dbListTables()`. Full DBI compliance (~40 methods) deferred to later phase.

3. **tidypredict/orbital scope** — **Deferred to Phase 3+.** Captured as a TODO in the roadmap. Focus on the rpy2/SPCS prediction path first; SQL-native prediction via tidypredict/orbital is a future enhancement for supported model types.

4. **Snowflake Datasets fsspec** — **Both approaches.** Use Python `fsspec` (via reticulate) to discover/list the underlying Parquet file paths, then use R-native `arrow::read_parquet()` to efficiently read them into R. This gives the best of both worlds: fsspec for Snowflake-specific file discovery, arrow for high-performance R-native data loading.

5. **Admin utilities scope** — **Minimum for now.** Just create/list/delete for EAI, compute pools, image repos. Enhance with alter/describe as needed based on user feedback.

6. **Package versioning strategy** — **Semantic versioning.** `0.x.y` for pre-CRAN development, `1.0.0` for first CRAN release.

7. **CI/CD Snowflake account** — **Use AK32940** (existing dev account) for integration tests in GitHub Actions for now.

8. **Python environment recommendation** — **Single shared conda environment** that works for both `rpy2` and `reticulate`. This is critical: both packages need to see the same Python interpreter and installed packages. The recommended setup:
   - One conda environment (e.g., `r-snowflakeR`) with `snowflake-ml-python`, `rpy2`, and all dependencies
   - `reticulate::use_condaenv("r-snowflakeR")` in R
   - `rpy2` also runs in this environment (since it's a Python package in the same env)
   - This avoids the dual-install problem: packages are installed once into conda and visible to both rpy2 and reticulate
   - In Workspace Notebooks: the micromamba environment already serves this purpose
   - `sfr_install_python_deps()` will create/manage this environment

---

## 15a. Remaining TODOs Before Development

| # | Item | Priority | Phase |
|---|------|----------|-------|
| 1 | Scaffold `snowflakeR/` package folder with `usethis::create_package()` | P0 | 0 |
| 2 | Implement DBI minimum viable methods in `connect.R` | P0 | 1 |
| 3 | Migrate existing `snowflake_registry.R` to `R/registry.R` with `sfr_*` naming | P0 | 2 |
| 4 | Migrate existing `sf_registry_bridge.py` to `inst/python/sfr_registry_bridge.py` | P0 | 2 |
| 5 | Build Feature Store two-step create/register pattern | P0 | 3 |
| 6 | Implement `sfr_feature_view()` + `sfr_register_feature_view()` + `sfr_create_feature_view()` | P0 | 3 |
| 7 | Implement Snowflake Datasets: fsspec file discovery + arrow Parquet reading | P1 | 3 |
| 8 | Implement admin utilities (EAI, compute pool, image repo) - create/list/delete only | P1 | 4 |
| 9 | Add tidypredict/orbital SQL-native prediction support for supported model types | P2 | 3+ |
| 10 | Full DBI compliance (~40 methods) | P2 | Future |
| 11 | Create `sync_snowflakeR_to_public.sh` for public repo sync | P1 | 5 |
| 12 | Set up GitHub Actions CI with AK32940 account credentials | P1 | 1 |

---

## 16. Summary

We are building `snowflakeR` — an official Snowflake R package that makes the Snowflake ML platform accessible to R users without requiring Python knowledge. The package covers:

1. **Connection management** — `connections.toml`/`config.toml` support via `snowflakeauth`, DBI compatibility
2. **Model Registry** — Train in R, register/deploy/serve with R functions (already proven)
3. **Feature Store** — Define features with dplyr/dbplyr or SQL, two-step create/register pattern
4. **Snowflake Datasets** — Versioned datasets, direct Parquet access
5. **Data operations** — Query, execute SQL, integrate with dbplyr/DBI
6. **Admin utilities** — EAI, compute pool, image repo management
7. **Workspace support** — R environment setup, ADBC, PAT management
8. **Tidymodels integration** — `tidypredict`/`orbital` for SQL-native prediction where possible

The architecture is a "modular monolith" R package with Python bridge modules under `inst/python/`, connected via `reticulate`. Developed in `snowflakeR/` subfolder within this project, synced to public `Snowflake-Labs/snowflakeR` repo.

Function prefix `sfr_`, S3 classes, `snake_case` naming, Tidyverse style. Namespace disambiguation via explicit object names in functions (`sfr_show_model_versions()` vs `sfr_show_fv_versions()`).

Target: CRAN-ready release within 8 weeks of starting implementation.

**Companion documents:**
- `internal/snowflakeR_package_dev_standards.md` — Package development standards, style guide, S3 class design, naming conventions, and coding rules
- `internal/snowflakeR_migration_mapping.md` — Old-to-new function name mapping for updating existing notebooks
- `internal/R_interface_for_snowflakeML_GeminiConversation.md` — Original brainstorming session with Gemini
- `internal/R_Integration_Summary_and_Recommendations.md` — Lessons learned from R integration work
