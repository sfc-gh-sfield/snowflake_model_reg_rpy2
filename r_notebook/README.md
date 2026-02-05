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
| `archive/` | Legacy scripts and original notebook (for reference) |

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

## Customizing R Packages

Edit `r_packages.yaml` to add or remove packages:

```yaml
conda_packages:
  - r-base           # Required
  - r-tidyverse      # Data manipulation
  - r-yourpackage    # Add your packages here

cran_packages:
  - somepackage      # Packages not on conda-forge
```

## Features

### Python-R Interoperability
- `%%R` magic cells for R code
- `-i` flag to pass Python variables to R
- `-o` flag to export R variables to Python

### Snowflake Connectivity (with `--adbc`)
- Direct R-to-Snowflake queries via ADBC
- PAT (Programmatic Access Token) authentication
- Arrow-based data transfer for performance

### Helper Module (`r_helpers.py`)
- `setup_r_environment()` - Configure R in one call
- `PATManager` - PAT creation, expiry tracking, refresh
- `check_environment()` - Comprehensive diagnostics
- `validate_adbc_connection()` - Pre-connection validation
- `init_r_connection_management()` - Load R connection functions

```python
from r_helpers import setup_r_environment, PATManager, init_r_connection_management

# Setup R
result = setup_r_environment()

# Manage PAT
pat_mgr = PATManager(session)
pat_mgr.create_pat(days_to_expiry=1)

# Initialize connection management
init_r_connection_management()
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

## Limitations

- No native R kernel (use `%%R` magic instead)
- SPCS OAuth token cannot be used for ADBC (PAT required)
- Setup required each new session (~2-5 minutes)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `rpy2` not found | Run Section 1.2 in the notebook |
| ADBC connection fails | Ensure PAT is created and stored |
| Package not found | Add to `r_packages.yaml` and re-run setup |
| Setup script fails | Check `setup_r.log` for details |
| Disk space error | Free up space (minimum 2GB required) |

### Run Diagnostics
```python
from r_helpers import print_diagnostics
print_diagnostics()  # Shows status of all components
```

## Documentation

See `internal/R_Integration_Summary_and_Recommendations.md` for detailed technical documentation and architecture overview.
