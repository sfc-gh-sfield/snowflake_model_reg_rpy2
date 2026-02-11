# Design: DuckDB Integration for R in Snowflake Workspace Notebooks

## 1. Overview

This document outlines the design for extending the R integration to include DuckDB as an intermediary between R and Snowflake, enabling:

1. **R → DuckDB → ADBC → Snowflake**: Use dbplyr with DuckDB backend, with DuckDB querying Snowflake via ADBC
2. **R → DuckDB → Iceberg → Snowflake**: Use DuckDB's Iceberg REST Catalog support with Snowflake-managed Iceberg tables (future)

### Target Use Case

> "Use Snowflake for heavy lifting (large scans/joins), DuckDB for local processing of smaller result sets, and R/dbplyr for analysis and modeling"

---

## 2. Architecture

### 2.1 Component Stack

```
┌─────────────────────────────────────────────────────────────────┐
│                    Snowflake Workspace Notebook                 │
├─────────────────────────────────────────────────────────────────┤
│  R (via rpy2)                                                   │
│    ├── dbplyr / dplyr                                           │
│    ├── DBI                                                      │
│    └── duckdb (R package)                                       │
├─────────────────────────────────────────────────────────────────┤
│  DuckDB Engine                                                  │
│    ├── snowflake extension (community)                          │
│    │     └── ADBC Snowflake driver (libadbc_driver_snowflake.so)│
│    └── iceberg extension (for Iceberg REST Catalog)             │
├─────────────────────────────────────────────────────────────────┤
│  Connection Methods                                             │
│    ├── ADBC → Snowflake (via PAT/Key Pair)                      │
│    └── Iceberg REST → Horizon IRC (OAuth/Bearer)                │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow Patterns

**Pattern A: Query Snowflake, Cache Locally**
```
Snowflake (big query) → ADBC → DuckDB table → R/dbplyr (analysis)
```

**Pattern B: dbplyr with Pushdown**
```
R/dbplyr → DuckDB SQL → snowflake extension → ADBC → Snowflake
                     (some predicates pushed down)
```

**Pattern C: Persist Results Back**
```
DuckDB table → Parquet file → Snowpark PUT → Snowflake stage → TABLE
```

---

## 3. Installation Design

### 3.1 New Installation Flag

Add `--duckdb` flag to `setup_r_environment.sh`:

```bash
./setup_r_environment.sh --duckdb      # R + DuckDB + Snowflake extension
./setup_r_environment.sh --adbc        # R + ADBC (existing)
./setup_r_environment.sh --full        # R + ADBC + DuckDB (everything)
./setup_r_environment.sh --basic       # R only (default)
```

### 3.2 Component Installation

| Component | Install Method | Location |
|-----------|---------------|----------|
| DuckDB CLI | conda-forge | `$MAMBA_ROOT_PREFIX/envs/r_env/bin/duckdb` |
| duckdb R package | conda-forge | R library path |
| snowflake extension | DuckDB `INSTALL` | `~/.duckdb/extensions/` |
| ADBC Snowflake driver | Download + extract | `~/.duckdb/extensions/vX.Y.Z/linux_amd64/` |
| iceberg extension | DuckDB `INSTALL` | `~/.duckdb/extensions/` |
| httpfs extension | DuckDB `INSTALL` | `~/.duckdb/extensions/` |

### 3.3 ADBC Driver Installation Alignment

Currently, our ADBC installation (for direct R use) installs to `$HOME/.local/lib/`. For DuckDB, the driver must be in DuckDB's extension directory.

**Approach**: Install ADBC driver to primary location, then **symlink** for DuckDB:

```bash
ADBC_LIB="libadbc_driver_snowflake.so"
ADBC_PRIMARY="$HOME/.local/lib/$ADBC_LIB"
DUCKDB_EXT_DIR="$HOME/.duckdb/extensions/v${DUCKDB_VERSION}/linux_amd64"

# Install to primary location (for direct R ADBC use)
cp "$ADBC_LIB" "$ADBC_PRIMARY"

# Create symlink for DuckDB (avoids duplicate download/storage)
mkdir -p "$DUCKDB_EXT_DIR"
ln -sf "$ADBC_PRIMARY" "$DUCKDB_EXT_DIR/$ADBC_LIB"
```

This keeps a single source of truth and avoids duplicate downloads.

### 3.4 Version Considerations

| Component | Recommended Version | Notes |
|-----------|-------------------|-------|
| DuckDB | >= 1.1.0 | Iceberg REST support added in 1.1.0 |
| duckdb R | Match DuckDB CLI | Must be compatible |
| ADBC driver | Latest from apache/arrow-adbc | Match DuckDB version requirements |

---

## 4. r_packages.yaml Extension

Add DuckDB packages to `r_packages.yaml`:

```yaml
# DuckDB integration packages (installed with --duckdb flag)
duckdb_packages:
  conda:
    - r-duckdb>=1.1.0     # DuckDB R interface
    - r-dbplyr>=2.4.0     # dplyr backend for databases
    - r-arrow>=14.0       # Arrow integration (for Parquet)
  
  # Note: DuckDB extensions (snowflake, iceberg, httpfs) are installed
  # via DuckDB's extension manager, not conda
```

---

## 5. Helper Functions Design

### 5.1 Python Helpers (`r_helpers.py`)

```python
# New functions for DuckDB integration

def setup_duckdb_environment():
    """Initialize DuckDB extensions and verify installation."""
    pass

def create_duckdb_snowflake_secret(
    account: str,
    user: str,
    auth_type: str = "pat",  # "pat", "keypair", "password"
    pat: str = None,
    private_key_path: str = None,
    password: str = None,
    database: str = None,
    warehouse: str = None,
    secret_name: str = "snowflake_secret"
) -> str:
    """Generate DuckDB SQL to create a Snowflake secret."""
    pass

def get_duckdb_connection_r_code(
    db_path: str = ":memory:",
    load_snowflake: bool = True
) -> str:
    """Generate R code to connect to DuckDB with extensions loaded."""
    pass

class DuckDBSnowflakeConfig:
    """Configuration manager for DuckDB-Snowflake integration."""
    pass
```

### 5.2 R Helpers (new file: `r_duckdb_helpers.R` or embedded)

```r
# Helper functions for R-DuckDB-Snowflake integration

#' Create DuckDB connection with Snowflake extension
#' @param db_path Path to DuckDB database file (":memory:" for in-memory)
#' @param load_extensions Whether to load snowflake/iceberg extensions
duckdb_connect <- function(db_path = ":memory:", load_extensions = TRUE) {
    # Implementation
}

#' Configure Snowflake secret in DuckDB
#' @param con DuckDB connection
#' @param account Snowflake account identifier
#' @param user Snowflake username
#' @param auth_type Authentication type: "pat", "keypair", "password"
#' @param ... Additional auth parameters
duckdb_create_sf_secret <- function(con, account, user, auth_type = "pat", ...) {
    # Implementation
}

#' Attach Snowflake as a DuckDB catalog
#' @param con DuckDB connection
#' @param secret_name Name of the Snowflake secret
#' @param catalog_name Name for the attached catalog (default: "sf")
duckdb_attach_snowflake <- function(con, secret_name, catalog_name = "sf") {
    # Implementation
}

#' Query Snowflake and create local DuckDB table
#' @param con DuckDB connection
#' @param query SQL query to execute in Snowflake
#' @param table_name Local DuckDB table name
#' @param secret_name Snowflake secret name
sf_to_duckdb <- function(con, query, table_name, secret_name = "snowflake_secret") {
    # Implementation
}

#' Export DuckDB table to Parquet for upload to Snowflake
#' @param con DuckDB connection
#' @param table_name DuckDB table to export
#' @param parquet_path Output Parquet file path
duckdb_to_parquet <- function(con, table_name, parquet_path) {
    # Implementation
}
```

---

## 6. Notebook Sections Design

### 6.1 New Sections to Add

Add to `r_workspace_notebook.ipynb` after existing ADBC section:

```
Section 7: DuckDB Integration
├── 7.1 Introduction to DuckDB + Snowflake
│   └── When to use this approach
├── 7.2 Setup and Configuration
│   ├── Verify DuckDB installation
│   ├── Load extensions (snowflake, httpfs)
│   └── Configure Snowflake secret
├── 7.3 Querying Snowflake via DuckDB
│   ├── Using snowflake_query() function
│   ├── Attaching Snowflake as catalog
│   └── Understanding pushdown behavior
├── 7.4 Using dbplyr with DuckDB + Snowflake
│   ├── dbplyr/dplyr workflows
│   ├── When queries run in Snowflake vs DuckDB
│   └── Performance considerations
├── 7.5 Local Caching Pattern
│   ├── Query Snowflake → DuckDB table
│   ├── Iterative analysis on cached data
│   └── Memory vs file-backed databases
├── 7.6 Persisting Results Back to Snowflake
│   ├── Export to Parquet
│   ├── Upload via Snowpark
│   └── Create Snowflake table from stage
└── 7.7 Troubleshooting
    ├── Extension loading issues
    ├── Authentication errors
    └── Type mapping considerations

Section 8: Iceberg Integration (Future/Experimental)
├── 8.1 Overview of Snowflake Storage for Iceberg
├── 8.2 Configuring DuckDB Iceberg REST Catalog
├── 8.3 Querying Iceberg Tables
└── 8.4 Limitations and Caveats
```

### 6.2 Example Notebook Cells

**7.2 Setup and Configuration:**
```r
%%R
library(DBI)
library(duckdb)
library(dplyr)
library(dbplyr)

# Connect to DuckDB (file-backed for persistence)
con <- dbConnect(duckdb::duckdb(), dbdir = "/tmp/snowflake_cache.duckdb")

# Load extensions
DBI::dbExecute(con, "INSTALL snowflake FROM community")
DBI::dbExecute(con, "LOAD snowflake")

writeLines("DuckDB with Snowflake extension ready")
```

**7.3 Configure Snowflake Secret:**
```r
%%R
# Get PAT from environment (set earlier in notebook)
pat <- Sys.getenv("SNOWFLAKE_PAT")
account <- Sys.getenv("SNOWFLAKE_ACCOUNT")

# Create Snowflake secret
secret_sql <- sprintf("
  CREATE OR REPLACE SECRET snowflake_secret (
    TYPE snowflake,
    ACCOUNT '%s',
    TOKEN '%s'
  )
", account, pat)

DBI::dbExecute(con, secret_sql)
writeLines("Snowflake secret configured")
```

**7.4 Query and Cache:**
```r
%%R
# Heavy query in Snowflake, cache result in DuckDB
DBI::dbExecute(con, "
  CREATE TABLE orders_sample AS
  SELECT *
  FROM snowflake_query(
    'SELECT * FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS
     WHERE O_ORDERDATE >= ''1995-01-01''
     LIMIT 100000',
    'snowflake_secret'
  )
")

# Now work locally with dbplyr
orders <- tbl(con, "orders_sample")

orders %>%
  group_by(O_ORDERSTATUS) %>%
  summarise(
    count = n(),
    total = sum(O_TOTALPRICE, na.rm = TRUE)
  ) %>%
  collect()
```

---

## 7. Work Plan

### Phase 1: Installation Infrastructure (Est. 4-6 hours)

| Task | Description | Files |
|------|-------------|-------|
| 1.1 | Add `--duckdb` flag to setup script | `setup_r_environment.sh` |
| 1.2 | Add DuckDB packages to r_packages.yaml | `r_packages.yaml` |
| 1.3 | Implement DuckDB extension installation | `setup_r_environment.sh` |
| 1.4 | Implement ADBC driver installation for DuckDB | `setup_r_environment.sh` |
| 1.5 | Add `--full` flag combining all options | `setup_r_environment.sh` |
| 1.6 | Update idempotency checks for DuckDB | `setup_r_environment.sh` |

### Phase 2: Helper Functions (Est. 3-4 hours)

| Task | Description | Files |
|------|-------------|-------|
| 2.1 | Add DuckDB Python helpers | `r_helpers.py` |
| 2.2 | Create R helper functions (embedded or separate) | `r_helpers.py` / new file |
| 2.3 | Add secret configuration helpers | `r_helpers.py` |
| 2.4 | Add diagnostic functions for DuckDB | `r_helpers.py` |

### Phase 3: Notebook Development (Est. 4-6 hours)

| Task | Description | Files |
|------|-------------|-------|
| 3.1 | Create Section 7.1-7.2 (Setup) | `r_workspace_notebook.ipynb` |
| 3.2 | Create Section 7.3 (Querying) | `r_workspace_notebook.ipynb` |
| 3.3 | Create Section 7.4 (dbplyr workflows) | `r_workspace_notebook.ipynb` |
| 3.4 | Create Section 7.5 (Caching pattern) | `r_workspace_notebook.ipynb` |
| 3.5 | Create Section 7.6 (Persist to Snowflake) | `r_workspace_notebook.ipynb` |
| 3.6 | Create Section 7.7 (Troubleshooting) | `r_workspace_notebook.ipynb` |

### Phase 4: Documentation (Est. 2-3 hours)

| Task | Description | Files |
|------|-------------|-------|
| 4.1 | Update README with DuckDB section | `README.md` |
| 4.2 | Update PROJECT_OVERVIEW | `PROJECT_OVERVIEW.md` |
| 4.3 | Add DuckDB to installation examples | Various |

### Phase 5: Testing (Est. 3-4 hours)

| Task | Description | Notes |
|------|-------------|-------|
| 5.1 | Test `--duckdb` installation flag | In Workspace Notebook |
| 5.2 | Test DuckDB → Snowflake query path | With PAT auth |
| 5.3 | Test dbplyr workflows | Various query patterns |
| 5.4 | Test persistence patterns | Parquet export/import |
| 5.5 | Test `--full` installation | Combined install |

### Phase 6: Iceberg Integration (Future)

| Task | Description | Notes |
|------|-------------|-------|
| 6.1 | Add `--iceberg` flag | When Storage for Iceberg is GA |
| 6.2 | Implement Iceberg REST config | Horizon IRC setup |
| 6.3 | Create Section 8 (Iceberg) | Notebook content |
| 6.4 | Test Iceberg read/write | Requires preview access |

---

## 8. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| DuckDB snowflake extension is community-maintained | Medium | Medium | Document as experimental, provide fallback to direct ADBC |
| ADBC driver version incompatibility | Medium | High | Pin versions, test compatibility matrix |
| DuckDB Iceberg REST not supporting non-S3 storage | High | Medium | Document AWS-only limitation, defer non-AWS |
| Auth complexity (PAT/OAuth/KeyPair variations) | Medium | Medium | Provide clear examples for each auth type |
| DuckDB extension dir structure changes | Low | Medium | Abstract paths in helpers, update as needed |

---

## 9. Success Criteria

1. **Installation**: `./setup_r_environment.sh --duckdb` successfully installs all components
2. **Connectivity**: R can query Snowflake via DuckDB using PAT authentication
3. **dbplyr**: Standard dplyr pipelines work against Snowflake tables via DuckDB
4. **Caching**: Users can cache Snowflake query results locally in DuckDB
5. **Persistence**: Users can export DuckDB tables back to Snowflake via Parquet
6. **Documentation**: Clear examples and troubleshooting guide in notebook

---

## 10. Open Questions (RESOLVED)

1. **R helper file organization**: Embed R helpers in `r_helpers.py` (loaded via rpy2) or create separate `r_duckdb_helpers.R`?
   - ✅ **Resolved**: Embedded in `r_helpers.py` with functions like `detect_environment()`, `query_snowflake_to_r()`

2. **DuckDB database persistence location**: Where should users store their DuckDB files?
   - ✅ **Resolved**: Use `:memory:` for temp analysis, document file path option for persistence

3. **Iceberg section timing**: Include placeholder in initial release or wait for Storage for Iceberg GA?
   - ✅ **Resolved**: Iceberg REST Catalog is now **GA as of Feb 6, 2026**! DuckDB is listed as supported engine.
   - See: https://docs.snowflake.com/en/user-guide/tables-iceberg-query-using-external-query-engine-snowflake-horizon

4. **Test with Key Pair auth**: We know PAT works; should we prioritize Key Pair testing for DuckDB?
   - ✅ **Resolved**: Key-pair auth tested and **working** with `AUTH_TYPE 'key_pair'` in CREATE SECRET

---

## 11. Remote Dev Testing Results (2026-02-09)

### 11.1 Environment Tested

- **Platform**: SPCS ML Container Runtime (Remote Dev)
- **Container**: Ubuntu 24.04.3 LTS, x86_64
- **R Version**: 4.4.3 (via micromamba)
- **DuckDB Version**: 1.4.4
- **ADBC Driver**: 1.10.0 (via pip)

### 11.2 Component Status (UPDATED 2026-02-09)

| Component | Status | Notes |
|-----------|--------|-------|
| R + tidyverse | ✅ Working | micromamba conda-forge |
| DuckDB R package | ✅ Working | Local queries work |
| DuckDB Snowflake extension | ✅ Working | **Fixed** - requires `AUTH_TYPE 'key_pair'` |
| ADBC driver (libadbc_driver_snowflake.so) | ✅ Working | Go-compiled, symlinked for DuckDB |
| DuckDB → Snowflake queries | ✅ Working | **Fixed** - use 2-part table names (sf.schema.table) |
| Python snowflake-connector | ✅ Working | Key-pair auth works |
| rpy2 Python-R bridge | ✅ Working | pandas2ri converter works |
| Arrow data transfer | ✅ Working | High-performance fetch |

**Key Fixes Applied:**
1. `AUTH_TYPE 'key_pair'` is **required** in `CREATE SECRET` (was missing)
2. Use 2-part table names (`sf.schema.table`) when database is in secret
3. Go-based ADBC compilation for consistency with Workspace Notebook

### 11.3 Authentication Issues Found & Fixed

**DuckDB Snowflake Extension - RESOLVED:**

1. **"user is empty" error** - ✅ **Fixed**: Must specify `AUTH_TYPE 'key_pair'` explicitly in `CREATE SECRET`. Without it, defaults to password auth.

2. **Secret parameters** - ✅ **Fixed**: Correct parameters are: `ACCOUNT`, `USER`, `DATABASE`, `WAREHOUSE`, `AUTH_TYPE`, `PRIVATE_KEY`. The `authenticator` parameter is NOT used - use `AUTH_TYPE` instead.

3. **ADBC driver location** - ✅ **Fixed**: DuckDB searches in `~/.local/share/R/duckdb/extensions/vX.Y.Z/linux_amd64/`.
   - **Solution**: Symlink from conda lib to DuckDB's expected path (Go-compiled driver preferred).

4. **JWT/Key-pair auth** - ✅ **Fixed**: Use `AUTH_TYPE 'key_pair'` and `PRIVATE_KEY` (full PEM content). Works perfectly.

5. **Table name format** - ✅ **Fixed**: Use 2-part names (`sf.schema.table`) when database is set in secret. 3-part names cause parser errors.

### 11.4 Alternative: Python Bridge (Fallback Option)

DuckDB direct Snowflake connectivity now works with proper `AUTH_TYPE`. However, the Python bridge remains a **useful fallback** for Workspace Notebooks where key-pair auth isn't configured:

```
R (dplyr/tidyverse)
    ↕ rpy2 + pandas2ri converter
Python (snowflake-connector-python)
    ↕ Arrow (high-performance)
Snowflake (key-pair auth)
```

**Verified Working Code Pattern:**

```python
# Python: Connect and fetch
import snowflake.connector
from cryptography.hazmat.primitives import serialization

with open("key.p8", "rb") as f:
    p_key = serialization.load_pem_private_key(f.read(), password=None)
pkb = p_key.private_bytes(...)

conn = snowflake.connector.connect(
    account="...", user="...", private_key=pkb, database="..."
)
cur = conn.cursor()
cur.execute("SELECT ...")
df = cur.fetch_arrow_all().to_pandas()  # High-performance Arrow fetch

# Transfer to R via rpy2
from rpy2.robjects.conversion import localconverter
with localconverter(ro.default_converter + pandas2ri.converter):
    r_df = ro.conversion.py2rpy(df)
    ro.globalenv['data'] = r_df

# R: Process with dplyr
ro.r('''
library(dplyr)
result <- data %>% group_by(...) %>% summarise(...)
''')
```

### 11.5 Correct DuckDB Snowflake API Usage

After analyzing the [iqea-ai/duckdb-snowflake](https://github.com/iqea-ai/duckdb-snowflake) source code:

**Correct Secret Parameters** (from `snowflake_secret_provider.cpp`):
```sql
CREATE SECRET sf_keypair (
    TYPE snowflake,
    ACCOUNT 'ak32940',           -- Required
    DATABASE 'SIMON',            -- Required
    USER 'SIMON',                -- Optional but needed for auth
    WAREHOUSE 'SIMON_XS',        -- Optional
    AUTH_TYPE 'key_pair',        -- Critical: 'oauth', 'key_pair', 'ext_browser', 'okta', 'mfa'
    PRIVATE_KEY '-----BEGIN...'  -- PEM content or file path
);

ATTACH '' AS sf (TYPE snowflake, SECRET sf_keypair, READ_ONLY);
```

**Auth Types Supported** (from `snowflake_client.cpp`):
- `oauth` → `auth_oauth` (uses `token`)
- `key_pair` → `auth_jwt` (uses `private_key`)
- `ext_browser` / `externalbrowser` → `auth_ext_browser`
- `okta` → `auth_okta` (uses `okta_url`)
- `mfa` → `auth_mfa` (uses `password`)

**Root Cause of Earlier Failures:**
We were **not** specifying `AUTH_TYPE 'key_pair'` in the secret, causing it to default to PASSWORD auth.

### 11.6 Recommended Approaches (UPDATED)

**Approach 1: DuckDB + Snowflake (Primary - Both Environments)**
- Use `setup_r_environment.sh --full` or `setup_r_duckdb_env.sh --full`
- DuckDB with `AUTH_TYPE 'key_pair'` in `CREATE SECRET`
- Cache locally + dplyr for analysis
- Best for: dplyr/dbplyr workflows, local caching, iterative analysis

**Approach 2: Direct ADBC from R (Pure R Workflow)**
- Use `setup_r_environment.sh --adbc`
- R → adbcsnowflake → Snowflake (Go-compiled driver)
- Best for: Users who want pure R without DuckDB

**Approach 3: Python Bridge (Default for Workspace Notebooks)**
- Use `snowflake_r_bridge.py` module or Reticulate
- Python snowflake-connector + rpy2 (uses session auth)
- Best for: Workspace Notebooks - no additional credentials needed

**Approach 4: DuckDB + Iceberg (NEW - GA Feb 2026)**
- Use DuckDB `iceberg` extension with Horizon Catalog REST API
- R → DuckDB → Iceberg REST → Snowflake Horizon Catalog
- Best for: Accessing Snowflake-managed Iceberg tables
- See: https://docs.snowflake.com/en/user-guide/tables-iceberg-query-using-external-query-engine-snowflake-horizon

### 11.6 Private Key Access by Environment (UPDATED 2026-02-05)

DuckDB's Snowflake extension requires key-pair authentication (the tested/recommended method). However, accessing private keys varies significantly by environment:

| Environment | Key Access Method | Complexity | Recommended Approach |
|-------------|-------------------|------------|---------------------|
| **Local IDE** | File on local disk | Simple | Direct key-pair auth |
| **SPCS Containers** | Mount via service spec YAML | Simple | Direct key-pair auth |
| **ML Container Runtime Remote Dev** | Mount via service spec | Simple | Direct key-pair auth |
| **Workspace Notebooks (vNext)** | Complex (see below) | High | **Python Bridge** |
| **Container Runtime Notebooks (Snowsight)** | `st.secrets` (GA May 2025) | Medium | `st.secrets` |

#### Workspace Notebooks (vNext) - Detailed Analysis

Workspace Notebooks have significant limitations for secret/key access:

1. **No `st.secrets`** - Streamlit is not supported in Workspace Notebooks (vNext)
2. **No service spec control** - Cannot mount secrets via YAML like SPCS
3. **No `SYSTEM$GET_SECRET` SQL** - This function doesn't exist
4. **UDF workaround requires EAI** - Using `_snowflake.get_generic_secret_string()` in a UDF still requires External Access Integration setup

**Options for Workspace Notebooks:**

| Option | Security | Privileges Required | Notes |
|--------|----------|---------------------|-------|
| **Python Bridge** (Recommended) | ✅ High | None extra | Uses existing session, no key needed |
| Upload .p8 file | ❌ Low | None | Key exposed in container filesystem |
| Stage-based key | ⚠️ Medium | Stage access | Key is a file with RBAC |
| Secret + UDF + EAI | ✅ High | CREATE SECRET, CREATE INTEGRATION | Complex setup, many users lack privileges |

**Recommendation**: Use **Python Bridge** as the default for Workspace Notebooks. It requires no additional credentials (uses the existing Snowpark session) and works for all users regardless of privilege level.

#### SPCS / Remote Dev - Secret Mounting

For self-managed SPCS containers or ML Container Runtime Remote Dev, secrets can be mounted directly via the service specification:

```yaml
# In service spec YAML
containers:
  - name: my-container
    secrets:
      - snowflakeSecret:
          objectName: my_private_key_secret
          directoryPath: /secrets           # Mount as file at /secrets/my_private_key_secret
      # OR
      - snowflakeSecret:
          objectName: my_private_key_secret
          envVarName: SF_PRIVATE_KEY        # Mount as environment variable
          secretKeyRef: secret_string
```

Then in R/Python, read the key directly:
```r
# R - read from mounted file
private_key <- readLines("/secrets/my_private_key_secret", warn = FALSE) |> paste(collapse = "\n")
```

This approach:
- ✅ No EAI needed (for secret access itself)
- ✅ Key available immediately on container start
- ✅ Full Snowflake audit trail
- ✅ RBAC on secrets

### 11.7 Updated Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│               Local IDE / SPCS / Remote Dev                     │
├─────────────────────────────────────────────────────────────────┤
│  R (via rpy2)                                                   │
│    ├── dplyr / tidyverse (data manipulation)                    │
│    ├── DBI + duckdb (local analytical queries)                  │
│    └── rpy2 bridge (data transfer)                              │
├─────────────────────────────────────────────────────────────────┤
│  DuckDB + Snowflake Extension                                   │
│    ├── Key-pair auth ✅ (Tested, recommended)                   │
│    ├── Password auth ✅ (Tested, for development)               │
│    ├── OAuth auth ⚠️ (Known issues per extension docs)          │
│    └── Direct query pushdown to Snowflake ✅                    │
├─────────────────────────────────────────────────────────────────┤
│  Python (fallback / bridge)                                     │
│    ├── snowflake-connector-python (alternative connectivity)    │
│    ├── pyarrow (high-performance data transfer)                 │
│    └── rpy2 + pandas2ri (R-Python bridge)                       │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│               Workspace Notebooks (vNext)                       │
├─────────────────────────────────────────────────────────────────┤
│  R (via rpy2)                                                   │
│    ├── dplyr / tidyverse (data manipulation)                    │
│    ├── DBI + duckdb (LOCAL queries only)                        │
│    └── rpy2 bridge (data transfer from Python)                  │
├─────────────────────────────────────────────────────────────────┤
│  Python Bridge (RECOMMENDED)                                    │
│    ├── Snowpark session (uses existing OAuth)                   │
│    ├── pyarrow (high-performance data transfer)                 │
│    └── rpy2 + pandas2ri (transfer to R/DuckDB)                  │
├─────────────────────────────────────────────────────────────────┤
│  DuckDB (local only)                                            │
│    ├── Local analytical queries ✅                              │
│    ├── Direct Snowflake connection ❌ (key access issues)       │
│    └── Receives data via Python Bridge ✅                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## Appendix A: DuckDB Snowflake Extension Auth Types

**Source**: [iqea-ai/duckdb-snowflake](https://github.com/iqea-ai/duckdb-snowflake)

**Required Parameters**: `ACCOUNT`, `DATABASE`

**Optional Parameters**: `USER`, `PASSWORD`, `WAREHOUSE`, `SCHEMA`, `ROLE`, `AUTH_TYPE`, `TOKEN`, `OKTA_URL`, `PRIVATE_KEY`, `PRIVATE_KEY_PASSPHRASE`

```sql
-- Key Pair (TESTED WORKING - recommended for SPCS)
CREATE SECRET sf_keypair (
  TYPE snowflake,
  ACCOUNT 'xy12345',
  USER 'MYUSER',
  DATABASE 'MYDB',
  WAREHOUSE 'MYWH',
  AUTH_TYPE 'key_pair',                    -- Critical: must specify auth type
  PRIVATE_KEY '-----BEGIN PRIVATE KEY-----
...PEM content...
-----END PRIVATE KEY-----'
);

-- OAuth Token
CREATE SECRET sf_oauth (
  TYPE snowflake,
  ACCOUNT 'xy12345',
  USER 'MYUSER',
  DATABASE 'MYDB',
  AUTH_TYPE 'oauth',
  TOKEN '<OAUTH_TOKEN>'
);

-- External Browser SSO
CREATE SECRET sf_sso (
  TYPE snowflake,
  ACCOUNT 'xy12345',
  USER 'MYUSER',
  DATABASE 'MYDB',
  AUTH_TYPE 'ext_browser'                  -- Opens browser for SSO
);

-- Okta
CREATE SECRET sf_okta (
  TYPE snowflake,
  ACCOUNT 'xy12345',
  USER 'MYUSER',
  DATABASE 'MYDB',
  AUTH_TYPE 'okta',
  OKTA_URL 'https://mycompany.okta.com'
);

-- Password (may be blocked in SPCS/MFA environments)
CREATE SECRET sf_password (
  TYPE snowflake,
  ACCOUNT 'xy12345',
  USER 'MYUSER',
  PASSWORD '<PASSWORD>',
  DATABASE 'MYDB',
  WAREHOUSE 'MYWH'
  -- AUTH_TYPE not needed, defaults to password
);
```

## Appendix B: DuckDB Iceberg REST Config (Future)

```sql
-- Install extensions
INSTALL httpfs;
INSTALL iceberg;
LOAD httpfs;
LOAD iceberg;

-- Create secret for Horizon IRC
CREATE SECRET horizon_secret (
  TYPE iceberg,
  TOKEN '<SNOWFLAKE_OAUTH_TOKEN>'
);

-- Attach Snowflake Iceberg catalog
ATTACH 'sf_iceberg' AS sf_ice (
  TYPE iceberg,
  ENDPOINT '<HORIZON_IRC_ENDPOINT>',
  SECRET 'horizon_secret'
);

-- Query Iceberg table
SELECT * FROM sf_ice."MYDB"."MYSCHEMA"."MY_ICEBERG_TABLE" LIMIT 10;
```

---

## Appendix C: Final Verified Working Solution (Feb 2026)

### C.1 Working Configuration

After extensive testing, here is the **verified working** DuckDB + Snowflake + R configuration:

**Key Finding**: The `AUTH_TYPE 'key_pair'` parameter is **required** for key-pair authentication. Without it, the extension defaults to password auth and fails.

**Table Name Format**: Use 2-part table names (`sf.schema.table`) when database is set in the secret. The 3-part format (`sf.database.schema.table`) causes parser errors.

### C.2 Verified R Code

```r
library(DBI)
library(duckdb)
library(dplyr)
library(dbplyr)

# Connect to DuckDB
con <- dbConnect(duckdb::duckdb(), dbdir = ":memory:")
dbExecute(con, "LOAD snowflake")

# Read private key
key_content <- paste(readLines("~/.snowflake/keys/rsa_key.p8"), collapse = "\n")

# Create secret with AUTH_TYPE (CRITICAL!)
secret_sql <- sprintf("
CREATE OR REPLACE SECRET sf_keypair (
    TYPE snowflake,
    ACCOUNT 'xy12345',
    USER 'MYUSER',
    DATABASE 'SNOWFLAKE_SAMPLE_DATA',  -- Set database here
    WAREHOUSE 'MYWH',
    AUTH_TYPE 'key_pair',               -- REQUIRED for key-pair auth
    PRIVATE_KEY '%s'
)", gsub("'", "''", key_content))

dbExecute(con, secret_sql)
dbExecute(con, "ATTACH '' AS sf (TYPE snowflake, SECRET sf_keypair, READ_ONLY)")

# Query with 2-part table names (sf.schema.table)
result <- dbGetQuery(con, "
    SELECT C_MKTSEGMENT, COUNT(*) as customers
    FROM sf.tpch_sf1.customer
    GROUP BY C_MKTSEGMENT
")
print(result)

# For dplyr: Cache locally first, then analyze
dbExecute(con, "
    CREATE TABLE orders_local AS 
    SELECT * FROM sf.tpch_sf1.orders LIMIT 50000
")

# Use dplyr on local table (works smoothly)
tbl(con, "orders_local") %>%
    group_by(O_ORDERSTATUS) %>%
    summarise(orders = n()) %>%
    collect()
```

### C.3 Recommended Workflow Patterns

| Pattern | Use Case | Code |
|---------|----------|------|
| Direct SQL | Simple queries, aggregations | `dbGetQuery(con, "SELECT ... FROM sf.schema.table")` |
| Cache + dplyr | Complex analysis, window functions | `CREATE TABLE local AS ...; tbl(con, "local") %>% ...` |
| Python Bridge | When ADBC unavailable | `query_snowflake_to_r(sql, "r_var")` |

### C.4 Cross-Environment Support

The notebook now supports both:

1. **Workspace Notebook**: Auto-detected, uses `get_active_session()`, Python bridge for data transfer
2. **Local IDE (VSCode/Cursor)**: Auto-detected, uses key-pair auth, DuckDB + Snowflake extension

Detection is automatic via the `detect_environment()` helper function.

### C.5 Setup Scripts

| Environment | Script | Flags |
|-------------|--------|-------|
| Workspace Notebook | `setup_r_environment.sh` | `--full` for R + ADBC + DuckDB |
| Remote Dev Container | `setup_r_duckdb_env.sh` | `--full` for same setup |

Both scripts use Go-based ADBC compilation for consistency.

---

## Appendix D: Iceberg Integration via Horizon Catalog

### D.1 Overview

Snowflake Horizon Catalog exposes an Apache Iceberg REST API that allows external query engines 
(including DuckDB) to read Snowflake-managed Iceberg tables. This integration became Generally 
Available in February 2026.

### D.2 Authentication Flow

1. **Generate JWT**: Sign a JWT with your private key (same key-pair used for Snowflake)
2. **Exchange for Access Token**: POST to `/polaris/api/catalog/v1/oauth/tokens`
3. **Use Access Token**: Bearer token for all subsequent REST API calls

```python
# JWT Payload Format
{
    "iss": "{ACCOUNT}.{USER}.{FINGERPRINT}",
    "sub": "{ACCOUNT}.{USER}",
    "iat": timestamp,
    "exp": timestamp + 3600  # 1 hour
}

# Token Exchange
POST https://{ACCOUNT}.snowflakecomputing.com/polaris/api/catalog/v1/oauth/tokens
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
scope=session:role:{ROLE}
client_secret={JWT}
```

### D.3 Current Status (Feb 2026)

| Component | Status | Notes |
|-----------|--------|-------|
| Token Generation | ✅ Working | Python script generates valid access tokens |
| Catalog Metadata | ✅ Working | Can list namespaces, tables via REST API |
| Table Metadata | ✅ Working | Can retrieve full Iceberg table metadata |
| DuckDB ATTACH | ✅ Working | Catalog attaches successfully, tables visible |
| DuckDB Query | ⚠️ Limited | Schema shows as UNKNOWN, queries fail |
| Vended Credentials | 🔴 403 Error | S3 credentials not vended to external clients |

### D.4 Known Limitations

1. **Vended Credentials Issue**: When DuckDB requests vended credentials via the 
   `X-Iceberg-Access-Delegation: vended-credentials` header, Snowflake returns 403 Forbidden.
   This may require specific privileges or account-level settings.

2. **Schema Resolution**: DuckDB can see the table exists but cannot resolve the schema 
   because it can't access the Parquet files in S3 without vended credentials.

3. **Table Name Syntax**: When querying via DuckDB's iceberg extension, tables appear 
   in the catalog but queries fail with "Table does not exist" errors, likely due to 
   the inability to load the actual table schema.

### D.5 Workarounds

**Option 1: Direct S3 Access (if you have AWS credentials)**

If you have direct access to the S3 bucket where Iceberg data is stored:

```sql
-- Configure AWS credentials in DuckDB
CREATE SECRET aws_creds (TYPE S3, PROVIDER credential_chain);

-- Read Iceberg table directly by metadata location
SELECT * FROM iceberg_scan('s3://bucket/path/to/metadata/00001-xxx.metadata.json');
```

**Option 2: Use Snowflake + DuckDB Hybrid (Recommended)**

Use the working ADBC-based approach to query Snowflake, then cache locally in DuckDB:

```r
# Query Snowflake via ADBC, cache in DuckDB
dbExecute(con, "
    CREATE TABLE nation_local AS 
    SELECT * FROM sf.TPCH_SF1.NATION
")

# DuckDB dplyr analysis on local cache
tbl(con, "nation_local") %>% 
    group_by(N_REGIONKEY) %>% 
    summarise(n = n())
```

**Option 3: PyIceberg via Python Bridge**

PyIceberg has more mature Snowflake Horizon support:

```python
from pyiceberg.catalog import load_catalog

catalog = load_catalog(
    "snowflake_horizon",
    **{
        "uri": f"https://{ACCOUNT}.snowflakecomputing.com/polaris/api/catalog",
        "credential": access_token,
        "warehouse": DATABASE,
        "scope": f"session:role:{ROLE}",
        "header.X-Iceberg-Access-Delegation": "vended-credentials"
    }
)

table = catalog.load_table("PUBLIC.NATION_ICEBERG")
df = table.scan().to_pandas()
```

### D.6 Iceberg Table Creation

To create a Snowflake-managed Iceberg table for testing:

```sql
-- Requires an external volume with S3/Azure/GCS storage
CREATE OR REPLACE ICEBERG TABLE my_db.my_schema.my_iceberg_table (
    id INT,
    name STRING,
    created_at TIMESTAMP
)
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'my_external_volume'
    BASE_LOCATION = 'path/to/data/'
    AS SELECT * FROM source_table;
```

Note: Iceberg tables use `STRING` instead of `VARCHAR(n)` for variable-length text.

### D.7 Billing (Starting mid-2026)

- **API Calls**: 0.5 credits per million calls
- **Cross-Region Egress**: Standard Snowflake egress charges apply

### D.8 Next Steps

1. **Investigate Privileges**: Determine if specific grants are needed for vended credentials
2. **Test PyIceberg**: More mature library that may handle Horizon better
3. **Monitor DuckDB Updates**: The iceberg extension is actively developed
4. **Document Spark Path**: Spark + Horizon is well-documented and working

---

## Appendix E: dplyr + ADBC Ecosystem Status (2026-02-05)

This section documents the current state of using dplyr/dbplyr with Snowflake via ADBC.

### E.1 The Goal

R users want to write dplyr code with lazy evaluation and query pushdown to Snowflake:

```r
# The dream:
tbl(con, "CUSTOMER") %>%
  filter(C_MKTSEGMENT == "BUILDING") %>%
  group_by(C_NATIONKEY) %>%
  summarise(count = n()) %>%
  collect()  # SQL generated and executed on Snowflake
```

### E.2 Current Ecosystem Components

| Component | Purpose | Status |
|-----------|---------|--------|
| **adbcsnowflake** | ADBC driver for Snowflake (Go-based) | ✅ Works for queries via `read_adbc()` |
| **adbcdrivermanager** | R package to manage ADBC drivers | ✅ Works |
| **adbi** | DBI-compliant interface over ADBC | ⚠️ Partial - missing driver methods |
| **dbplyr** | dplyr backend for databases | 🔄 ADBC backend in development |

### E.3 Blocking Issues

#### Issue 1: adbcsnowflake Missing Methods

The Snowflake ADBC driver (Go-based) does not implement `GetParameterSchema`:

```r
# In adbi's AdbiResult.R, this call fails:
adbcdrivermanager::adbc_statement_get_parameter_schema(stmt)
# Error: NOT_IMPLEMENTED
```

**Impact**: `adbi` cannot create prepared statements, which dbplyr requires for lazy evaluation.

**Missing ADBC methods in Snowflake driver:**

| Method | Purpose | Status |
|--------|---------|--------|
| `GetParameterSchema` | Get parameter types for prepared statements | ❌ NOT_IMPLEMENTED |
| `adbc.ingest.temporary` | Create temporary tables | ❌ NOT_IMPLEMENTED |
| `adbc.ingest.target_db_schema` | Specify target schema | ❌ NOT_IMPLEMENTED |

#### Issue 2: dbplyr ADBC Backend Not Yet Complete

- [tidyverse/dbplyr#1581](https://github.com/tidyverse/dbplyr/issues/1581) - Original feature request (Closed)
- [tidyverse/dbplyr#1787](https://github.com/tidyverse/dbplyr/issues/1787) - **Active implementation** by Hadley Wickham (Open, Jan 2026)

From issue #1787, dbplyr is working on native ADBC support with SQL dialect mapping:

```
snowflake: snowflake
postgresql: postgresql
sqlite: sqlite
duckdb: duckdb
...
```

### E.4 What Works Today

| Approach | dplyr Syntax | Query Pushdown | Status |
|----------|--------------|----------------|--------|
| `adbcdrivermanager` + `read_adbc()` | ❌ SQL strings | ✅ Full | ✅ Works |
| `adbi` + `dbplyr` | ✅ dplyr | ✅ Full | ❌ Blocked by `GetParameterSchema` |
| ADBC → DuckDB → dplyr | ✅ dplyr | ⚠️ Local only | ✅ Works |

### E.5 Recommended Approach: Hybrid (ADBC → DuckDB → dplyr)

Until the ecosystem issues are resolved, use this pattern:

```r
library(adbcdrivermanager)
library(adbcsnowflake)
library(duckdb)
library(dplyr)
library(dbplyr)

# 1. Connect to Snowflake via ADBC
db <- adbc_database_init(
  adbcsnowflake::adbcsnowflake(),
  username = Sys.getenv("SNOWFLAKE_USER"),
  `adbc.snowflake.sql.account` = Sys.getenv("SNOWFLAKE_ACCOUNT"),
  `adbc.snowflake.sql.auth_type` = "auth_pat",
  `adbc.snowflake.sql.client_option.auth_token` = Sys.getenv("SNOWFLAKE_PAT"),
  ...
)
sf_con <- adbc_connection_init(db)

# 2. Fetch data to DuckDB (local)
duck_con <- dbConnect(duckdb::duckdb())
data <- sf_con |> read_adbc("SELECT * FROM CUSTOMER") |> as.data.frame()
dbWriteTable(duck_con, "customers", data)

# 3. Use dplyr on DuckDB!
result <- tbl(duck_con, "customers") %>%
    filter(C_MKTSEGMENT == "BUILDING") %>%
    group_by(C_NATIONKEY) %>%
    summarise(count = n()) %>%
    collect()
```

**Trade-offs:**
- ✅ Full dplyr syntax
- ✅ DuckDB's excellent dbplyr support
- ⚠️ Data must fit in memory
- ⚠️ No query pushdown to Snowflake (aggregations happen locally)

### E.6 Future: When Will Native dplyr + Snowflake ADBC Work?

Two things need to happen:

1. **adbcsnowflake driver** must implement `GetParameterSchema`
   - Track: [apache/arrow-adbc](https://github.com/apache/arrow-adbc) issues
   
2. **dbplyr** must complete ADBC backend
   - Track: [tidyverse/dbplyr#1787](https://github.com/tidyverse/dbplyr/issues/1787)

Once both are complete, this should work:

```r
# Future (not working yet):
con <- dbConnect(adbi::adbi("adbcsnowflake"), ...)
tbl(con, "CUSTOMER") %>%
    filter(C_MKTSEGMENT == "BUILDING") %>%
    collect()
```

### E.7 References

- [r-dbi/adbi](https://github.com/r-dbi/adbi) - DBI interface over ADBC
- [apache/arrow-adbc](https://github.com/apache/arrow-adbc) - ADBC drivers including Snowflake
- [tidyverse/dbplyr#1787](https://github.com/tidyverse/dbplyr/issues/1787) - ADBC backend implementation
- [ADBC Driver Status](https://arrow.apache.org/adbc/current/driver/status.html) - Feature support matrix
