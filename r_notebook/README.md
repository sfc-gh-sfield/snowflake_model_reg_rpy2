
# R Integration for Snowflake Workspace Notebooks

This folder contains everything needed to run R within Snowflake Workspace Notebooks using rpy2.

## Quick Start

1. Upload this folder to your Snowflake Workspace
2. Open `r_workspace_notebook.ipynb`
3. Run the installation cell (Section 1.1)
4. Run the configuration cell (Section 1.2)
5. Start using `%%R` magic cells!

## Files

| File | Description |
|------|-------------|
| `r_workspace_notebook.ipynb` | Main notebook with examples and documentation |
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

# View all options
bash setup_r_environment.sh --help
```

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
