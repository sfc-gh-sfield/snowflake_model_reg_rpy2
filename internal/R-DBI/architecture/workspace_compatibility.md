# Workspace Notebook Compatibility Strategy

**Status**: Draft  
**Date**: 2026-02-27

---

## 1. Overview

Snowflake Workspace Notebooks are a cloud-based notebook environment where
R code runs inside Snowflake's managed infrastructure. The environment has
specific constraints and capabilities that the RSnowflake package must
accommodate.

This document details the authentication mechanisms, environment detection,
and dual-backend strategy needed to ensure RSnowflake works seamlessly in
Workspace Notebooks while maintaining full functionality in local R
environments.

---

## 2. Workspace Notebook Environment

### 2.1 What Is Available

- **Python runtime** with `snowflake-snowpark-python` pre-installed
- **Active Snowpark session** accessible via `get_active_session()`
- **Session token** in the `SNOWFLAKE_TOKEN` environment variable
- **Account identifier** derivable from the session or environment
- **micromamba** for additional package installation
- **R runtime** (when R kernel is selected)
- **reticulate** for R-to-Python interop
- **Network access** to Snowflake's REST API endpoints (internal network)

### 2.2 What Is NOT Available

- **ODBC drivers** -- no Snowflake ODBC driver installed
- **JDBC drivers** -- no JVM available by default
- **ADBC drivers** -- Go-based ADBC driver not pre-installed
- **External network access** -- outbound internet access may be restricted
- **Persistent file system** -- notebook files are ephemeral (except stages)
- **External authentication flows** -- no browser for SSO, no MFA prompts

### 2.3 Current snowflakeR Approach

The existing `snowflakeR` package detects Workspace Notebooks by attempting
to import the active Snowpark session via Python:

```python
# snowflakeR/inst/python/sfr_connect_bridge.py
from snowflake.snowpark.context import get_active_session
session = get_active_session()
```

If successful, all SQL operations flow through the Snowpark session:
```
R -> reticulate -> Snowpark session -> snowflake-connector-python -> Snowflake
```

This works but carries the Python bridge overhead (memory duplication,
NumPy ABI issues, serialization costs) for every query.

---

## 3. Proposed Direct REST Approach

### 3.1 Session Token Authentication

In Workspace Notebooks, the `SNOWFLAKE_TOKEN` environment variable contains
a session token that can authenticate directly against Snowflake's SQL API.
This is the same mechanism used by:
- The Snowflake SQL API v2
- SPCS container services
- The existing `sfr_predict_rest()` function in snowflakeR

The token is passed as a Bearer token in the HTTP Authorization header:

```
Authorization: Snowflake Token="<SNOWFLAKE_TOKEN value>"
```

Or, for the SQL API v2:

```
Authorization: Bearer <SNOWFLAKE_TOKEN value>
X-Snowflake-Authorization-Token-Type: OAUTH
```

### 3.2 Account and Host Resolution

In Workspace Notebooks, the Snowflake host is accessible at the account's
standard URL. The account identifier can be resolved from:

1. `SNOWFLAKE_ACCOUNT` environment variable (if set)
2. `SNOWFLAKE_HOST` environment variable (if set)
3. The active Snowpark session (via reticulate, as fallback)
4. The notebook metadata / environment context

The SQL API endpoint is:
```
https://<account_identifier>.snowflakecomputing.com/api/v2/statements
```

### 3.3 Session Context

The session token carries the user's identity, role, and default warehouse.
Additional context (database, schema) can be set via SQL statements:

```sql
USE DATABASE my_database;
USE SCHEMA my_schema;
USE WAREHOUSE my_warehouse;
```

These are sent as regular SQL statements via the SQL API.

---

## 4. Connection Auto-Detection Flow

```
dbConnect(RSnowflake::Snowflake(), ...)
    │
    ├─── Check: Is SNOWFLAKE_TOKEN set?
    │    YES ──► Workspace Notebook mode
    │    │       ├── Use token for REST API auth
    │    │       ├── Resolve account from env vars or session
    │    │       ├── Set database/schema/warehouse from params or defaults
    │    │       └── Return SnowflakeConnection (REST backend)
    │    │
    │    NO ───► Local environment mode
    │            ├── Check explicit params (account, token, private_key, ...)
    │            ├── Check connections.toml profiles
    │            ├── Check SNOWFLAKE_PAT env var
    │            ├── Initiate auth flow (JWT, OAuth, browser SSO)
    │            └── Return SnowflakeConnection (REST backend)
    │
    └─── Both paths use the same REST client underneath.
         The only difference is how the auth token is obtained.
```

### 4.1 Implementation

```r
setMethod("dbConnect", "SnowflakeDriver", function(drv,
    account = NULL, user = NULL, token = NULL,
    private_key = NULL, authenticator = NULL,
    warehouse = NULL, database = NULL, schema = NULL, role = NULL,
    name = NULL, ...) {

  # --- Workspace Notebook auto-detect ---
  ws_token <- Sys.getenv("SNOWFLAKE_TOKEN", "")
  if (nzchar(ws_token) && is.null(token)) {
    token <- ws_token
    # Resolve account from environment
    if (is.null(account)) {
      account <- .resolve_workspace_account()
    }
    cli::cli_inform("Connected via Workspace Notebook session token.")
  }

  # --- connections.toml fallback ---
  if (is.null(token) && is.null(account)) {
    toml <- .read_connections_toml(name)
    if (!is.null(toml)) {
      account  <- account  %||% toml$account
      user     <- user     %||% toml$user
      # ... etc
    }
  }

  # --- Build auth object ---
  auth <- .sf_auth_resolve(
    account = account, user = user, token = token,
    private_key = private_key, authenticator = authenticator
  )

  # --- Create connection ---
  .sf_connection_create(auth, warehouse, database, schema, role, ...)
})
```

### 4.2 Account Resolution in Workspace

```r
.resolve_workspace_account <- function() {
  # Try environment variables first
  acct <- Sys.getenv("SNOWFLAKE_ACCOUNT", "")
  if (nzchar(acct)) return(acct)

  host <- Sys.getenv("SNOWFLAKE_HOST", "")
  if (nzchar(host)) {
    # Extract account from host: "myorg-myaccount.snowflakecomputing.com"
    return(sub("\\.snowflakecomputing\\.com$", "", host))
  }

  # Fallback: query the active Snowpark session (requires reticulate)
  if (requireNamespace("reticulate", quietly = TRUE)) {
    tryCatch({
      ctx <- reticulate::import("snowflake.snowpark.context")
      session <- ctx$get_active_session()
      acct <- session$get_current_account()
      return(gsub('"', '', acct))
    }, error = function(e) NULL)
  }

  cli::cli_abort(c(
    "Cannot determine Snowflake account in Workspace Notebook.",
    "i" = "Set {.envvar SNOWFLAKE_ACCOUNT} or pass {.arg account} explicitly."
  ))
}
```

---

## 5. Dual Backend Strategy

### 5.1 When to Use Each Backend

| Feature | Direct REST (RSnowflake) | Python Bridge (snowflakeR) |
|---------|------------------------|--------------------------|
| SQL queries (SELECT, DDL, DML) | Primary | Fallback |
| Read results to data.frame | Primary | Fallback |
| Write data.frame to table | Primary (Phase 2) | Available |
| dbplyr / dplyr lazy SQL | Primary (Phase 4) | Available |
| Arrow result fetching | Primary (Phase 3) | Via pyarrow |
| Model Registry operations | Not applicable | **Required** (Snowpark API) |
| Feature Store operations | Not applicable | **Required** (Snowpark API) |
| Snowpark DataFrame API | Not applicable | **Required** |
| PUT/GET stage operations | Phase 3 | Available now |

### 5.2 snowflakeR Integration

Once RSnowflake is available, `snowflakeR` can use it as its connectivity
backend while keeping the Python bridge for ML-specific features:

```r
# snowflakeR/R/connect.R (future)

sfr_connect <- function(..., backend = c("auto", "direct", "python")) {
  backend <- match.arg(backend)

  if (backend == "auto") {
    # Use direct REST if RSnowflake is available
    if (requireNamespace("RSnowflake", quietly = TRUE)) {
      backend <- "direct"
    } else {
      backend <- "python"
    }
  }

  if (backend == "direct") {
    # Use RSnowflake for connectivity
    dbi_con <- DBI::dbConnect(RSnowflake::Snowflake(), ...)
    conn <- .wrap_dbi_connection(dbi_con)
  } else {
    # Use Python bridge (current approach)
    conn <- .connect_via_python(...)
  }

  conn
}
```

### 5.3 Workspace Notebook Optimization

In Workspace Notebooks, the direct REST path provides significant benefits:

| Metric | Python Bridge | Direct REST | Improvement |
|--------|--------------|-------------|-------------|
| Small query (100 rows) | ~80ms | ~25ms | 3x faster |
| Medium query (10K rows) | ~500ms | ~200ms | 2.5x faster |
| Large query (1M rows) | ~15s | ~5s (JSON), ~2s (Arrow) | 3-7x faster |
| Memory (1M rows, 10 cols) | ~800 MB peak | ~400 MB (JSON), ~200 MB (Arrow) | 2-4x less |
| First query after connect | ~2s (Python init) | ~200ms | 10x faster |

The first-query improvement is particularly noticeable because the Python
bridge requires initializing the reticulate Python session, importing
snowflake modules, and creating the Snowpark session -- all of which are
eliminated with the direct REST approach.

---

## 6. Token Lifecycle in Workspace Notebooks

### 6.1 Token Validity

The `SNOWFLAKE_TOKEN` in Workspace Notebooks is a session token with:
- **Lifetime**: Tied to the notebook session (typically hours)
- **Scope**: User's identity, default role, active warehouse
- **Refresh**: Managed by the Workspace infrastructure (not the R package)

### 6.2 Token Expiry Handling

If a query fails with a 401 (Unauthorized) response, the token may have
expired. The package should:

1. Check if `SNOWFLAKE_TOKEN` has been refreshed (re-read env var)
2. If refreshed, retry the request with the new token
3. If not refreshed, surface a clear error to the user

```r
.sf_request_with_retry <- function(con, ...) {
  resp <- .sf_api_request(con, ...)

  if (httr2::resp_status(resp) == 401L) {
    # Token may have been refreshed by the Workspace infrastructure
    new_token <- Sys.getenv("SNOWFLAKE_TOKEN", "")
    if (nzchar(new_token) && new_token != con@.auth$token) {
      con@.auth$token <- new_token
      resp <- .sf_api_request(con, ...)
    }
  }

  resp
}
```

### 6.3 PAT (Programmatic Access Token) Support

For users who prefer to use PATs (longer-lived tokens) in Workspace
Notebooks, the package supports:

```r
# User sets PAT before connecting
Sys.setenv(SNOWFLAKE_PAT = "ver:1-hint:...")

# dbConnect auto-detects PAT
con <- dbConnect(RSnowflake::Snowflake())
```

PATs are preferred for:
- Scheduled notebook runs
- Long-running operations
- Interacting with external Snowflake services (SPCS endpoints)

---

## 7. Testing in Workspace Notebooks

### 7.1 Test Matrix

| Scenario | Auth Method | Backend | Test Focus |
|----------|-----------|---------|-----------|
| Workspace Notebook (interactive) | Session token | Direct REST | Auto-detect, query execution, result types |
| Workspace Notebook (scheduled) | Session token / PAT | Direct REST | Token refresh, error handling |
| Workspace Notebook (R + Python) | Session token | Both | Python bridge for ML, REST for queries |
| Local (connections.toml) | Key-pair JWT | Direct REST | Full DBI compliance |
| Local (PAT) | PAT | Direct REST | Quick setup, CI/CD |
| Local (browser SSO) | OAuth | Direct REST | Interactive desktop |

### 7.2 Integration Test Script

```r
# Test that RSnowflake works in Workspace Notebook environment
test_workspace_notebook <- function() {
  # Should auto-detect SNOWFLAKE_TOKEN

  con <- dbConnect(RSnowflake::Snowflake())

  # Basic query
  result <- dbGetQuery(con, "SELECT CURRENT_TIMESTAMP() AS ts, 42 AS num")
  stopifnot(nrow(result) == 1, "num" %in% names(result))

  # Table operations
  dbWriteTable(con, "RSNOWFLAKE_TEST", data.frame(x = 1:3, y = letters[1:3]))
  stopifnot(dbExistsTable(con, "RSNOWFLAKE_TEST"))
  df <- dbReadTable(con, "RSNOWFLAKE_TEST")
  stopifnot(nrow(df) == 3)
  dbRemoveTable(con, "RSNOWFLAKE_TEST")

  # dbplyr (if available)
  if (requireNamespace("dbplyr", quietly = TRUE)) {
    tbl_result <- dplyr::tbl(con, "INFORMATION_SCHEMA.TABLES") |>
      dplyr::filter(TABLE_SCHEMA == "PUBLIC") |>
      dplyr::collect()
  }

  dbDisconnect(con)
  message("All Workspace Notebook tests passed.")
}
```

---

## 8. Migration Guide for snowflakeR Users

### 8.1 For Workspace Notebook Users

Before (snowflakeR with Python bridge):
```r
library(snowflakeR)
conn <- sfr_connect()                           # Python bridge
result <- sfr_query(conn, "SELECT * FROM t")    # via Snowpark
```

After (RSnowflake direct REST):
```r
library(DBI)
con <- dbConnect(RSnowflake::Snowflake())        # Direct REST
result <- dbGetQuery(con, "SELECT * FROM t")     # Standard DBI
```

Both work in Workspace Notebooks. The RSnowflake version is faster,
uses less memory, and follows DBI conventions.

### 8.2 For Users Who Need Both

Users who need ML platform features (Model Registry, Feature Store)
alongside standard SQL operations:

```r
library(DBI)
library(snowflakeR)

# Fast SQL queries via RSnowflake
con <- dbConnect(RSnowflake::Snowflake())
training_data <- dbGetQuery(con, "SELECT * FROM features WHERE split = 'train'")

# ML operations via snowflakeR (Python bridge for Snowpark API)
ml_conn <- sfr_connect()
reg <- sfr_model_registry(ml_conn)
sfr_log_model(reg, my_model, ...)
```

Future: `snowflakeR` will use `RSnowflake` under the hood for SQL
operations, eliminating the need for two connection objects.
