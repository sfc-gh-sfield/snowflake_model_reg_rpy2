# R Integration in Snowflake Workspace Notebooks

## Summary and Recommendations

**Date:** February 2026  
**Status:** Proof of Concept - Working

---

## Executive Summary

This document summarizes the work completed to enable R execution within Snowflake Workspace Notebooks using rpy2, including direct database connectivity via ADBC with Programmatic Access Token (PAT) authentication.

### Key Achievements

1. **R Runtime Installation** - Successfully installed R via micromamba in the container's user space
2. **Python-R Interoperability** - Enabled bidirectional data transfer between Python and R using rpy2
3. **Jupyter Magic Support** - Configured `%%R` cell magic for native R code execution within Python notebooks
4. **Database Connectivity** - Established ADBC-based connection from R to Snowflake using PAT authentication

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                 Snowflake Workspace Notebook                    │
│                    (SPCS Container)                             │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────────┐    ┌──────────────────────────────────┐   │
│  │  Python Kernel   │    │     micromamba r_env             │   │
│  │  (managed venv)  │◄──►│  - r-base                        │   │
│  │  - rpy2          │    │  - r-forecast, r-tidyverse       │   │
│  │  - pandas        │    │  - adbcsnowflake                 │   │
│  │  - snowpark      │    │  - go (for ADBC compilation)     │   │
│  └──────────────────┘    └──────────────────────────────────┘   │
│           │                           │                         │
│           ▼                           ▼                         │
│  ┌──────────────────┐    ┌──────────────────────────────────┐   │
│  │ get_active_      │    │  ADBC Connection                 │   │
│  │ session()        │    │  (PAT Authentication)            │   │
│  │ (internal OAuth) │    │  (via public endpoint)           │   │
│  └────────┬─────────┘    └───────────────┬──────────────────┘   │
└───────────┼──────────────────────────────┼──────────────────────┘
            │                              │
            ▼                              ▼
     ┌──────────────────────────────────────────┐
     │            Snowflake Account             │
     └──────────────────────────────────────────┘
```

---

## Setup Components

### 1. File Structure

```
r_notebook/
├── README.md                    # Quick start guide
├── r_workspace_notebook.ipynb   # Main notebook with examples
├── r_packages.yaml              # Package configuration (user-editable)
├── setup_r_environment.sh       # Unified installation script
├── r_helpers.py                 # Helper module (PAT, diagnostics, output helpers)
├── setup_r.log                  # Installation log (created on run)
└── archive/                     # Legacy files (for reference)
    ├── r_notebook.ipynb         # Original exploratory notebook
    ├── setup_r_micromamba_adbc.sh
    └── setup_r_with_micromamba.sh
```

### 2. Setup Script Options

```bash
# Basic R installation (faster)
bash setup_r_environment.sh --basic

# R + ADBC Snowflake driver (for direct DB connectivity)
bash setup_r_environment.sh --adbc

# Custom package configuration
bash setup_r_environment.sh --config custom_packages.yaml --adbc
```

### 3. Package Configuration (`r_packages.yaml`)

```yaml
# R version (optional - leave empty for latest)
r_version: ""        # e.g., "4.3.2" or "" for latest

# Conda-forge packages (supports version pinning)
conda_packages:
  - r-tidyverse      # Latest version
  - r-lazyeval       # Required for tidyverse
  - reticulate       # R-Python interop
  # - r-dplyr=1.1.4  # Exact version example

# CRAN packages (supports version pinning with ==)
cran_packages: []
  # - prophet        # Latest from CRAN
  # - forecast==8.21 # Exact version (uses remotes)
```

### 4. Key Configuration Steps (Automated by Script)

1. **Install micromamba** - Lightweight conda-compatible package manager
2. **Read package config** - Parse `r_packages.yaml` for package list
3. **Create r_env** - Isolated environment with R and dependencies
4. **Fix symlinks** - Required for rpy2 compilation (`libz.so`, `liblzma.so`)
5. **Set environment variables** - `PATH` and `R_HOME` pointing to r_env
6. **Install rpy2** - Into the notebook kernel's Python (not micromamba's Python)
7. **(--adbc only) Install Go** - Required for compiling `adbcsnowflake` R package
8. **(--adbc only) Install ADBC packages** - `adbcdrivermanager` and `adbcsnowflake`

---

## Authentication Findings

### What Works

| Method | Status | Notes |
|--------|--------|-------|
| **PAT (Programmatic Access Token)** | ✅ Works | Recommended for ADBC - can be created programmatically |
| **Key Pair (JWT)** | ✅ Works | Alternative for ADBC - no token expiry |
| **Reticulate + Snowpark** | ✅ Works | Access Python Snowpark session from R - no auth setup needed |
| **Python get_active_session()** | ✅ Works | Native Snowpark session in Python cells |

### What Doesn't Work

| Method | Status | Reason |
|--------|--------|--------|
| **SPCS OAuth Token** (`/snowflake/session/token`) | ❌ Blocked | Token only authorized for specific Snowflake connectors |
| **Username/Password** | ❌ Blocked | SPCS enforces OAuth-only for internal connections |
| **External OAuth** | ⚠️ Untested | Would require enterprise IdP integration |

### PAT Configuration Required

```sql
-- Option 1: Temporary bypass (for testing)
ALTER USER <username>
ADD PROGRAMMATIC ACCESS TOKEN <token_name>
  ROLE_RESTRICTION = '<role>'
  DAYS_TO_EXPIRY = 1
  MINS_TO_BYPASS_NETWORK_POLICY_REQUIREMENT = 240;

-- Option 2: Authentication policy (for production)
CREATE AUTHENTICATION POLICY pat_no_network_policy
  PAT_POLICY = (NETWORK_POLICY_EVALUATION = ENFORCED_NOT_REQUIRED);
ALTER USER <username> SET AUTHENTICATION POLICY = pat_no_network_policy;
```

---

## Working Code Patterns

### Python-R Data Transfer

```python
# Python → R
from rpy2.robjects import pandas2ri
import rpy2.robjects as ro

with (ro.default_converter + pandas2ri.converter).context():
    r_df = ro.conversion.get_conversion().py2rpy(pandas_df)

# R → Python  
with localconverter(ro.default_converter + pandas2ri.converter):
    pandas_df = pandas2ri.rpy2py(r_dataframe)
```

### R Cell Magic (%%R)

```python
# Register magic
from rpy2.ipython import rmagic
ip = get_ipython()
ip.register_magics(rmagic.RMagics)

# Use in cells
%%R -i python_df
library(dplyr)
glimpse(python_df)
```

### ADBC Connection from R

```r
%%R
library(adbcdrivermanager)
library(adbcsnowflake)

db <- adbc_database_init(
  adbcsnowflake::adbcsnowflake(),
  username = Sys.getenv("SNOWFLAKE_USER"),
  `adbc.snowflake.sql.account` = Sys.getenv("SNOWFLAKE_ACCOUNT"),
  `adbc.snowflake.sql.uri.host` = Sys.getenv("SNOWFLAKE_PUBLIC_HOST"),
  `adbc.snowflake.sql.db` = Sys.getenv("SNOWFLAKE_DATABASE"),
  `adbc.snowflake.sql.schema` = Sys.getenv("SNOWFLAKE_SCHEMA"),
  `adbc.snowflake.sql.warehouse` = Sys.getenv("SNOWFLAKE_WAREHOUSE"),
  `adbc.snowflake.sql.auth_type` = "auth_pat",
  `adbc.snowflake.sql.client_option.auth_token` = Sys.getenv("SNOWFLAKE_PAT")
)

con <- adbc_connection_init(db)
result <- con |> read_adbc("SELECT * FROM my_table") |> tibble::as_tibble()
```

---

## Recommendations

### High Priority

#### 1. Create a Unified Setup Cell/Script ✅ IMPLEMENTED

**Status:** Completed

**Implementation:**
- Created `setup_r_environment.sh` with `--basic` and `--adbc` flags
- Package configuration externalized to `r_packages.yaml`
- New notebook (`r_workspace_notebook.ipynb`) has clear setup cells
- Section 1.2 handles rpy2 installation and magic registration

#### 2. PAT Management Improvements ✅ IMPLEMENTED

**Status:** Completed

**Implementation:**
- Created `PATManager` class in `r_helpers.py` with:
  - Automatic expiry tracking (`is_expired`, `time_remaining()`)
  - Token refresh capability (`refresh_if_needed()`)
  - Status reporting (`get_status()`)
  - Secure environment variable storage
- Convenience function `create_pat()` for simple use cases
- `validate_adbc_connection()` function to check prerequisites

**Usage:**
```python
from r_helpers import PATManager
pat_mgr = PATManager(session)
pat_mgr.create_pat(days_to_expiry=1)
print(pat_mgr.get_status())
```

#### 3. Add Error Handling and Diagnostics ✅ IMPLEMENTED

**Status:** Completed

**Implementation:**
- Created comprehensive diagnostic functions in `r_helpers.py`:
  - `check_environment()` - Full diagnostic check of all components
  - `print_diagnostics()` - Formatted diagnostic output
  - `validate_adbc_connection()` - ADBC prerequisite validation
- Individual checks for: R environment, rpy2, ADBC, Snowflake env vars, disk space, network
- Setup script includes pre-flight checks (disk space, network connectivity)

**Usage:**
```python
from r_helpers import check_environment, print_diagnostics
print_diagnostics()  # Run all checks and display results
```

### Medium Priority

#### 4. Script Improvements ✅ IMPLEMENTED

**Status:** Completed

**Implementation:**
- Version pinning support (`R_VERSION` variable in script)
- Retry logic with configurable attempts and delay (`retry_command()` function)
- Logging to file (`setup_r.log`) with `--log` and `--no-log` flags
- `--verbose` flag for detailed output
- Pre-flight disk space check (minimum 2GB required)
- Network connectivity check to conda-forge and micromamba endpoints
- Timestamped log entries with log levels (INFO, WARN, ERROR, DEBUG)

#### 5. Create README for r_notebook Folder ✅ IMPLEMENTED

**Status:** Completed - `r_notebook/README.md` created with:
- Quick start guide
- File descriptions
- Installation options
- Troubleshooting table

#### 6. Connection Pooling/Reuse ✅ IMPLEMENTED

**Status:** Completed

**Implementation:**
- Connection stored as `r_sf_con` in R's global environment
- R helper functions added to `r_helpers.py`:
  - `get_snowflake_connection()` - Get or create connection
  - `close_snowflake_connection()` - Close and release resources
  - `is_snowflake_connected()` - Check if connected
  - `snowflake_connection_status()` - Get detailed status
- Python wrapper functions for management from Python:
  - `init_r_connection_management()` - Load R functions
  - `get_r_connection_status()` - Check status from Python
  - `close_r_connection()` - Close from Python

**Usage:**
```r
%%R
# Get or reuse connection (stored as r_sf_con)
r_sf_con <- get_snowflake_connection()

# Use in queries
r_sf_con |> read_adbc("SELECT * FROM my_table")

# Check status
is_snowflake_connected()

# Clean up
close_snowflake_connection()
```

### Low Priority / Future Enhancements

#### 7. Consider Alternative Approaches

For production use cases, evaluate:
- **Custom Container Image:** Pre-bake R and dependencies into ML Container Runtime image
- **Snowpark Container Services Job:** For batch R workloads
- **External Function:** Wrap R models as external functions for SQL access

#### 8. Performance Optimization

- Profile setup time and identify bottlenecks
- Consider parallel package installation
- Cache compiled packages between sessions (if persistent storage available)

#### 9. Testing Framework

Create automated tests for:
- R installation verification
- rpy2 interoperability
- ADBC connectivity
- Data type conversion accuracy

---

## Persistence Strategy

### Current Limitation

R is installed to `$HOME/micromamba` which is **ephemeral** - it does not persist across kernel or service restarts. This means users must wait 2-5 minutes for R to reinstall each time the notebook restarts.

### Potential Solution: PERSISTENT_DIR

We have identified that Workspace Notebooks have access to persistent block storage via `PERSISTENT_DIR` (pd0). Installing R to this location could reduce subsequent startup time from 2-5 minutes to ~10 seconds.

**This requires coordination with the Snowflake Notebooks team.**

See: `internal/R_Persistence_Proposal_NotebooksTeam.md` for the full proposal.

---

## Known Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| No native R kernel | Cannot use pure R cells | Use `%%R` magic via rpy2 |
| SPCS OAuth token restricted | Cannot use container's injected token | Use PAT authentication |
| Setup required per session | ~2-5 min setup time each session | Pending: PERSISTENT_DIR (requires Notebooks team) |
| No persistent R package cache | Must reinstall packages each session | Pending: PERSISTENT_DIR (requires Notebooks team) |
| Network policy requirements | PAT auth may be blocked | Configure auth policy |
| rpy2 in kernel venv | Must reinstall rpy2 on kernel restart | ~30 seconds, unavoidable |
| R output formatting | Workspace Notebooks add extra line breaks | Use `rprint()`, `rview()`, `rglimpse()` helpers |

### R Output Formatting Workaround

Workspace Notebooks add extra line breaks to R output, causing poor formatting of data frames and other output. The `r_helpers.py` module automatically loads R helper functions on setup:

| Function | Usage | Description |
|----------|-------|-------------|
| `rprint(x)` | `rprint(df)` | Print any object cleanly |
| `rview(df, n)` | `rview(iris, n=10)` | View data frame with optional row limit |
| `rglimpse(df)` | `rglimpse(df)` | Glimpse data frame structure |

These functions wrap output with `writeLines(capture.output(...))` to bypass the rendering issue.

---

## Security Considerations

1. **PAT Tokens:** Short-lived tokens recommended; never commit to git
2. **Role Restriction:** Use `ROLE_RESTRICTION` on PATs to limit scope
3. **Network Policies:** Understand implications of bypassing network policies
4. **Secrets Management:** Consider using Snowflake Secrets for PAT storage

---

## References

### External Documentation
- [Snowflake Workspace Notebooks Documentation](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks)
- [SPCS OAuth Token Usage](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/additional-considerations-services-jobs#connecting-to-snowflake-from-inside-a-container)
- [SPCS Block Storage Volumes](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/block-storage-volume)
- [rpy2 Documentation](https://rpy2.github.io/)
- [ADBC Snowflake Driver](https://arrow.apache.org/adbc/)
- [Programmatic Access Tokens](https://docs.snowflake.com/en/user-guide/programmatic-access-tokens)

### Internal Documentation
- `internal/spcs_persistent_storage.md` - SPCS storage types and Workspace Notebook persistence
- `internal/micromamb_r_installation.md` - Micromamba R installation locations and customization
- `internal/WorkspaceNotebooksR_ADBC_Setup_GleanConversation.md` - Original development conversation
- `internal/R_Persistence_Proposal_NotebooksTeam.md` - Proposal for Notebooks team to enable PERSISTENT_DIR usage

---

## Appendix: Quick Start Checklist

Using the new `r_workspace_notebook.ipynb`:

- [ ] Run `!bash setup_r_environment.sh --adbc` (Section 1.1)
- [ ] Run the configuration cell (Section 1.2) - handles PATH, R_HOME, rpy2, and magic registration
- [ ] Verify R with `%%R` cell showing R version (Section 1.3)
- [ ] Create PAT for database access (Section 3.2)
- [ ] Test ADBC connectivity (Section 3.3-3.4)

### Notebook Sections

| Section | Description |
|---------|-------------|
| **1. Installation & Configuration** | Setup R environment, configure rpy2, verify installation |
| **2. Python & R Interoperability** | Examples of `%%R` magic, data transfer between Python and R |
| **3. Snowflake Database Connectivity** | PAT creation, ADBC connection, querying examples |
