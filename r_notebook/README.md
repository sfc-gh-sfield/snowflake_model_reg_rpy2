
# R Integration for Snowflake Workspace Notebooks

This folder contains everything needed to run R within Snowflake Workspace Notebooks using rpy2.

## snowflakeR Package Notebooks (NEW)

The `snowflakeR/` subdirectory contains **updated notebooks** that use the
`snowflakeR` R package. These are the recommended starting point:

| Notebook | Description |
|----------|-------------|
| [`snowflakeR/quickstart.ipynb`](snowflakeR/quickstart.ipynb) | Connect, query, DBI/dbplyr, visualization |
| [`snowflakeR/model_registry_demo.ipynb`](snowflakeR/model_registry_demo.ipynb) | Train, register, predict, manage R models |
| [`snowflakeR/feature_store_demo.ipynb`](snowflakeR/feature_store_demo.ipynb) | Entities, Feature Views, training data, end-to-end ML |

## Original Notebooks (pre-package)

The notebooks below are the original pre-package explorations. They use manual
`rpy2` setup, `source("snowflake_registry.R")`, and raw helper scripts. They
are preserved for historical reference.

## Quick Start

1. Upload this folder to your Snowflake Workspace
2. Open `r_workspace_notebook.ipynb`
3. Run the installation cell (Section 1.1)
4. Run the configuration cell (Section 1.2)
5. Start using `%%R` magic cells!

## Files

| File | Description |
|------|-------------|
| `snowflakeR/` | **snowflakeR package notebooks** (recommended) |
| `r_workspace_notebook.ipynb` | Main notebook with examples and documentation |
| `r_forecasting_demo.ipynb` | End-to-end forecasting demo (manual Python wrapper approach) |
| `r_registry_demo.ipynb` | **R-native Model Registry demo** (uses R wrapper functions) |
| `snowflake_registry.R` | **R wrapper library** for Snowflake Model Registry |
| `sf_registry_bridge.py` | Python bridge module (called by snowflake_registry.R) |
| `setup_r_environment.sh` | Installation script for R environment |
| `r_packages.yaml` | Package configuration (edit to customize) |
| `r_helpers.py` | Helper module for PAT management and diagnostics |
| `setup_r.log` | Installation log (created on run) |
| `archive/` | Legacy files (for reference) |
| `archive/auth_methods_not_working.ipynb` | Tests for blocked auth methods (SPCS OAuth, password) |

## Installation Options

```bash
# Basic R installation
bash setup_r_environment.sh --basic

# R + ADBC Snowflake driver (for direct DB connectivity)
bash setup_r_environment.sh --adbc

# With verbose logging
bash setup_r_environment.sh --adbc --verbose

# Force reinstall everything (skip "already installed" checks)
bash setup_r_environment.sh --adbc --force

# View all options
bash setup_r_environment.sh --help
```

### Re-runnability

The script is **idempotent** - it checks what's already installed and skips those steps:
- Re-running after adding packages to `r_packages.yaml` installs only the new packages
- Use `--force` to reinstall everything regardless of current state

The script includes:
- Pre-flight checks (disk space, network)
- Automatic retry for network operations
- Logging to `setup_r.log`

## Customizing R Version and Packages

Edit `r_packages.yaml` to customize your R environment:

```yaml
# Specify R version (leave empty for latest)
r_version: "4.3.2"    # Or "" for latest available

# Conda packages with optional version pinning
conda_packages:
  - r-tidyverse           # Latest version
  - r-dplyr=1.1.4         # Exact version
  - r-ggplot2>=3.4.0      # Minimum version
  - r-yourpackage         # Add your packages here

# CRAN packages with optional version pinning
cran_packages:
  - prophet               # Latest version
  - forecast==8.21        # Exact version (uses remotes::install_version)
```

### Version Specifiers

| Type | Syntax | Example |
|------|--------|---------|
| Conda (latest) | `package` | `r-tidyverse` |
| Conda (exact) | `package=version` | `r-dplyr=1.1.4` |
| Conda (minimum) | `package>=version` | `r-ggplot2>=3.4.0` |
| Conda (range) | `package>=min,<max` | `r-base>=4.3,<4.5` |
| CRAN (latest) | `package` | `prophet` |
| CRAN (exact) | `package==version` | `forecast==8.21` |

## Features

### Python-R Interoperability
- `%%R` magic cells for R code
- `-i` flag to pass Python variables to R
- `-o` flag to export R variables to Python

### Snowflake Connectivity

**Option 1: ADBC** (with `--adbc` flag)
- Direct R-to-Snowflake queries via ADBC driver
- Authentication: PAT (recommended) or Key Pair
- Arrow-based data transfer for performance
- Best for: Production R pipelines, large datasets

**Option 2: Reticulate + Snowpark** (no extra setup)
- Access Python Snowpark session from R via reticulate
- Uses notebook's built-in authentication (no PAT needed)
- Data path: Snowflake → Snowpark → pandas → R
- Best for: Quick analysis, prototyping, interactive work

### Helper Module (`r_helpers.py`)
- `setup_r_environment()` - Configure R in one call (also loads output helpers)
- `PATManager` - PAT creation, expiry tracking, refresh
- `KeyPairAuth` - RSA key pair authentication setup
- `OAuthAuth` - OAuth token authentication setup
- `check_environment()` - Comprehensive diagnostics
- `validate_adbc_connection()` - Pre-connection validation
- `init_r_connection_management()` - Load R connection functions
- `init_r_output_helpers()` - Load R output formatting functions
- `init_r_alt_auth()` - Load R alternative auth test functions
- `set_r_console_width()` - Adjust R console width

```python
from r_helpers import setup_r_environment, PATManager, init_r_connection_management

# Setup R (also loads output helpers automatically)
result = setup_r_environment()

# Manage PAT
pat_mgr = PATManager(session)
pat_mgr.create_pat(days_to_expiry=1)

# Initialize connection management
init_r_connection_management()
```

### Data Visualization with ggplot2

Create publication-quality charts using ggplot2 (included via tidyverse):

```r
%%R -w 700 -h 450
library(ggplot2)

p <- ggplot(data, aes(x = var1, y = var2)) +
    geom_point() +
    theme_minimal()
    
print(p)  # Required to render the plot
```

**Plot size parameters:**
- `-w WIDTH` - Width in pixels (e.g., `-w 800`)
- `-h HEIGHT` - Height in pixels (e.g., `-h 500`)

**Saving plots:**
```r
ggsave("/tmp/my_plot.png", p, width = 8, height = 5, dpi = 150)
```

### Output Helpers (R functions)

Workspace Notebooks add extra line breaks to R output. Use these R functions for cleaner display:

| Function | Usage | Description |
|----------|-------|-------------|
| `rprint(x)` | `rprint(df)` | Print any object cleanly |
| `rview(df, n)` | `rview(iris, n=10)` | View data frame with optional row limit |
| `rglimpse(df)` | `rglimpse(df)` | Glimpse data frame structure |
| `rcat(...)` | `rcat("Value: ", x)` | Clean replacement for cat() |
| `print_connection_status()` | | Print ADBC connection status |

```r
%%R
# Instead of print(df), use:
rprint(df)

# Instead of glimpse(df), use:
rglimpse(df)

# View first 10 rows:
rview(my_data, n = 10)
```

### Python DataFrame Output

The `tabulate` package is installed automatically, enabling nice DataFrame output:

```python
# Markdown table output (renders nicely in notebooks)
print(df.to_markdown())

# Or for simpler display:
print(df.to_string())
```

### Reticulate Output Pattern

When using reticulate (Section 5), export R data frames to Python using `-o` for nice Notebook display:

```r
%%R -o result_df
# R code that creates result_df
result_df <- session$sql("SELECT * FROM table")$to_pandas()
```

```python
# Next cell - Python displays the DataFrame nicely
result_df
```

### Connection Pooling (R)
The connection is stored as `r_sf_con` and reused across cells:
```r
%%R
r_sf_con <- get_snowflake_connection()  # Get or create
r_sf_con |> read_adbc("SELECT * FROM table")  # Use
close_snowflake_connection()  # Clean up
```

## Requirements

- Snowflake Workspace Notebook environment
- Network access to conda-forge and CRAN (for package installation)
- For ADBC: Permissions to create PAT tokens

### Minimum Package Versions

| Package | Min Version | Reason |
|---------|-------------|--------|
| `r-reticulate` | >= 1.25 | Required for rpy2 compatibility (fixes segfault) |
| `r-base` | >= 4.0 | Recommended for modern R features |
| `rpy2` (Python) | >= 3.5 | Stable R-Python bridge |

These minimums are enforced in the default `r_packages.yaml`. If you see warnings about reticulate/rpy2 compatibility, ensure `r-reticulate >= 1.25` is installed.

## R Model Registry Wrapper (NEW)

The `snowflake_registry.R` library provides **R-native functions** to register and serve R models in Snowflake's Model Registry - no Python code needed from the R user.

### Quick Example

```r
source("snowflake_registry.R")
sf_registry_init()

# Train model in R (as usual)
library(forecast)
model <- auto.arima(AirPassengers)

# Test locally (uses the same wrapper that runs in Snowflake)
preds <- sf_registry_predict_local(model, data.frame(period = 1:12),
                                    predict_fn = "forecast",
                                    predict_pkgs = c("forecast"))

# Register to Snowflake Model Registry (one function call!)
mv <- sf_registry_log_model(
  model, model_name = "MY_FORECAST",
  predict_fn = "forecast", predict_pkgs = c("forecast"),
  input_cols  = list(period = "integer"),
  output_cols = list(point_forecast = "double", lower_80 = "double",
                     upper_80 = "double", lower_95 = "double",
                     upper_95 = "double")
)

# Run remote inference
sf_registry_predict("MY_FORECAST", data.frame(period = 1:12),
                     service_name = "my_svc")
```

### Available Functions

| Function | Purpose |
|----------|---------|
| `sf_registry_init()` | Initialize the wrapper |
| `sf_registry_log_model()` | Register R model to registry |
| `sf_registry_predict_local()` | Test model locally |
| `sf_registry_predict()` | Run remote inference |
| `sf_registry_show_models()` | List registered models |
| `sf_registry_show_versions()` | List model versions |
| `sf_registry_get_model()` | Get model details |
| `sf_registry_set_metric()` | Add metrics |
| `sf_registry_show_metrics()` | View metrics |
| `sf_registry_create_service()` | Deploy to SPCS |
| `sf_registry_delete_model()` | Delete model |
| `sf_registry_help()` | Show help |

### Architecture

```
R user code
  → snowflake_registry.R     (user-facing R functions)
  → reticulate                (R-Python bridge)
  → sf_registry_bridge.py    (auto-generates CustomModel wrappers)
  → snowflake.ml.registry    (Snowflake ML Python SDK)
```

See `r_registry_demo.ipynb` for the full walkthrough.

## Forecasting Demos

### r_registry_demo.ipynb (Recommended)

Uses the **R wrapper functions** - R users never write Python:

1. Train model in pure R
2. `sf_registry_log_model()` to register
3. `sf_registry_predict()` for inference
4. Includes examples for: ARIMA, linear models, ARIMAX with exogenous vars

### r_forecasting_demo.ipynb (Manual Approach)

Shows the underlying **manual Python wrapper** approach:

1. **Query Data** - TPC-H orders data from Snowflake
2. **Train Model** - R `auto.arima()` for automatic ARIMA parameter selection
3. **Write Python Wrapper** - ~80 lines of CustomModel class
4. **Register** - Log model to Snowflake Model Registry
5. **Deploy** - Create SPCS service for inference
6. **Predict** - Generate forecasts via the deployed model
7. **Visualize** - Create ggplot2 charts of results

Both demos are designed for **R-preferring data scientists** who need to integrate with Snowflake's MLOps ecosystem.

## Limitations

- No native R kernel (use `%%R` magic instead)
- SPCS OAuth token cannot be used for ADBC (use PAT or Key Pair instead)
- Setup required each new session (~2-5 minutes)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `rpy2` not found | Run Section 1.2 in the notebook |
| ADBC connection fails | Ensure PAT is created and stored |
| Package not found | Add to `r_packages.yaml` and re-run setup |
| Setup script fails | Check `setup_r.log` for details |
| Disk space error | Free up space (minimum 2GB required) |
| R output has extra line breaks | Use `rprint()`, `rview()`, or `rglimpse()` |
| `rprint` not found | Re-run `setup_r_environment()` or `init_r_output_helpers()` |
| reticulate/rpy2 segfault warning | Safe to ignore if reticulate >= 1.25 (default) |

### Run Diagnostics
```python
from r_helpers import print_diagnostics
print_diagnostics()  # Shows status of all components
```

## Documentation

See `internal/R_Integration_Summary_and_Recommendations.md` for detailed technical documentation and architecture overview.
