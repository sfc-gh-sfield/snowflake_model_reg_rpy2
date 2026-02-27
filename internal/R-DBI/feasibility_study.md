# Feasibility Study: Standalone R DBI Snowflake Connector

**Status**: Draft  
**Date**: 2026-02-27  
**Author**: SnowCAT R Team

---

## Executive Summary

This document evaluates the feasibility of creating a **standalone, pure-R,
DBI-compliant package** that connects R directly to Snowflake's REST API,
eliminating the current dependency on a Python bridge (reticulate ->
snowflake-snowpark-python -> snowflake-connector-python).

The analysis concludes that the project is **highly feasible** and would deliver
significant value to both Snowflake and the R community. The closest precedent
is Google's `bigrquery` package, which uses the same REST-API-wrapper + DBI
architecture we propose and has been a major success on CRAN (1,200+ GitHub
stars, 750k+ downloads).

The recommended approach uses Snowflake's SQL API v2 (`/api/v2/statements`)
for query execution, `httr2` as the HTTP client, and optional Arrow IPC
result fetching via `nanoarrow` for high-performance data transfer. The package
would support Workspace Notebooks via session token authentication while
remaining fully functional in local R environments with key-pair JWT, PAT,
OAuth, and browser-based SSO authentication.

---

## 1. Motivation

### 1.1 Current Architecture and Its Costs

The existing `snowflakeR` package connects R to Snowflake through a
multi-layer Python bridge:

```
R code
  --> reticulate (R-to-Python bridge)
    --> snowflake-snowpark-python
      --> snowflake-connector-python
        --> Snowflake REST API (internal /queries/v1/ endpoints)
```

While this approach works, it carries substantial costs:

**Memory overhead** -- Every query result materializes twice: first as a pandas
DataFrame in Python memory, then as an R data.frame in R memory. The current
`query_to_dict()` bridge in `snowflakeR/inst/python/sfr_connect_bridge.py`
converts pandas DataFrames to Python dicts with native types, which are then
converted again to R vectors. For a 1 GB result set, peak memory usage is ~2 GB.

**Dependency weight** -- The package requires a full Python environment with
`snowflake-ml-python` (>= 1.5.0), `snowflake-snowpark-python`, `rpy2`,
`pandas`, and their transitive dependencies. Setting this up is the most
common source of user friction (conda environment creation, version conflicts,
Python path configuration).

**Fragility** -- NumPy ABI mismatches between versions 1.x and 2.x caused
reticulate to fail when converting numpy-backed DataFrames. This required the
`query_to_dict()` workaround that serializes all data through Python's native
types, adding overhead and losing type fidelity.

**Incomplete DBI compliance** -- The current DBI support in
`snowflakeR/R/dbi.R` is self-described as a "Minimum Viable Implementation".
It does not formally subclass `DBIDriver`/`DBIConnection`/`DBIResult`, does
not support parameterized queries (`dbBind`), transactions
(`dbBegin`/`dbCommit`/`dbRollback`), streaming results, or the Arrow DBI
extensions.

### 1.2 The Opportunity

Snowflake provides a well-documented public SQL API v2 that accepts HTTP
requests with JSON or Arrow payloads. R has mature, CRAN-available packages
for HTTP (`httr2`), JSON (`jsonlite`), Arrow IPC (`nanoarrow`), JWT
generation (`openssl`/`jose`), and the DBI interface itself. All the
building blocks exist to create a direct R-to-Snowflake connection with
no Python dependency.

This is exactly the approach that `bigrquery` takes for Google BigQuery,
`RAthena`/`noctua` take for AWS Athena, and `AzureKusto` takes for Azure
Data Explorer. All of these are successful, well-maintained CRAN packages.

---

## 2. Landscape Analysis

### 2.1 Existing R-to-Snowflake Options

| Approach | Package(s) | Mechanism | Auth Methods | Arrow Support | Workspace Notebooks | CRAN |
|----------|-----------|-----------|-------------|---------------|-------------------|------|
| ODBC | `odbc::snowflake()` | Snowflake ODBC driver | SSO, OAuth, user/pass | No | No (no ODBC driver) | Yes |
| JDBC | `DatabaseConnector` | Snowflake JDBC via JVM | user/pass, OAuth | No | No (no JVM) | Yes |
| ADBC | `adbcsnowflake` + `adbi` | Go-based ADBC driver | URI (user/pass, SSO) | Yes (native) | No (no session token) | R-multiverse |
| Python bridge | `snowflakeR` (current) | reticulate -> snowpark | All (via Python) | Via pandas/pyarrow | Yes | No (not on CRAN) |
| **Proposed** | **RSnowflake** | **httr2 -> SQL API v2** | **PAT, JWT, OAuth, SSO, session token** | **Yes (nanoarrow)** | **Yes** | **Goal** |

### 2.2 Key Gap

No pure-R, REST-API-based, DBI-compliant Snowflake connector exists today.
The ODBC and JDBC approaches require native driver installation (impossible
in Workspace Notebooks). The ADBC approach is promising but immature and
lacks session-token authentication for Workspace Notebooks. The Python
bridge works but is heavy and fragile.

### 2.3 Vendor Precedents

Several cloud database vendors provide dedicated R DBI packages that talk
directly to their REST APIs:

- **Google BigQuery**: `bigrquery` -- pure R REST API wrapper + DBI + dbplyr.
  Optional Arrow acceleration via `bigrquerystorage`. ~1,200 GitHub stars.
  Actively maintained by the tidyverse team. The closest model for our approach.

- **AWS Athena**: `RAthena` and `noctua` -- REST-based DBI backends using
  AWS SDK. Support Arrow result fetching. Available on CRAN.

- **Azure Data Explorer**: `AzureKusto` -- REST-based DBI backend for
  Kusto/ADX. Available on CRAN.

- **Databricks**: Primarily ODBC-based, but Databricks is investing in
  ADBC and REST connectors for newer SDKs.

- **DuckDB**: `duckdb` R package -- embedded database with native R
  integration and Arrow support. Demonstrates the performance ceiling for
  tight R-database integration.

The pattern of REST API wrapper + DBI layer + optional Arrow acceleration
is well-established and proven in the R ecosystem.

---

## 3. Proposed Architecture

### 3.1 Three-Layer Design

The package follows the architecture proven by `bigrquery`:

**Layer 1 -- Low-level REST Client (`sf_api_*`)**

Thin wrappers around Snowflake's REST API endpoints using `httr2`:
- Session management (login, keepalive, close)
- Query submission (`POST /api/v2/statements`)
- Result fetching (JSON and Arrow IPC formats)
- Pagination for large result sets (partition handling)
- Retry logic with exponential backoff
- Error handling (Snowflake error codes -> R conditions)

**Layer 2 -- DBI Interface (formal S4 classes)**

Standard DBI backend implementation:
- `SnowflakeDriver` extends `DBIDriver`
- `SnowflakeConnection` extends `DBIConnection`
- `SnowflakeResult` extends `DBIResult`
- Full DBI method coverage (see DBI Method Inventory)
- Arrow DBI extensions (`dbGetQueryArrow`, `dbFetchArrow`, etc.)
- `DBItest` compliance validation

**Layer 3 -- dplyr/dbplyr Integration**

High-level interface for tidyverse users:
- `dbplyr_edition = 2` support
- Snowflake-specific SQL translation rules
- `tbl()` dispatch, lazy evaluation, `collect()`
- Snowflake function mappings (e.g., `DATEADD`, `FLATTEN`, `PARSE_JSON`)

### 3.2 Data Flow Comparison

**Current (Python bridge)**:
```
Snowflake REST API
  --> snowflake-connector-python (internal endpoints, JSON/Arrow)
  --> pandas DataFrame (Python memory, ~N bytes)
  --> query_to_dict() -- Python dict with native types
  --> reticulate conversion (Python -> R, ~N bytes again)
  --> R data.frame
Peak memory: ~2N bytes (Python + R copies coexist)
```

**Proposed (Direct REST, JSON path)**:
```
Snowflake SQL API v2
  --> httr2 HTTP response (R memory, streamed)
  --> jsonlite::fromJSON() --> R data.frame
Peak memory: ~1.2N bytes (JSON string + R vectors, then JSON is GC'd)
```

**Proposed (Direct REST, Arrow path)**:
```
Snowflake SQL API v2 (Arrow IPC format)
  --> httr2 HTTP response (binary, streamed to temp file)
  --> nanoarrow::read_nanoarrow() --> R vectors (near zero-copy)
Peak memory: ~1.0N bytes (Arrow buffers mapped directly)
```

### 3.3 Authentication Strategy

The package must support multiple authentication methods. Priority order
(based on user environments):

| Priority | Method | Use Case | R Implementation |
|----------|--------|----------|-----------------|
| P0 | Session token | Workspace Notebooks | `SNOWFLAKE_TOKEN` env var -> Bearer header |
| P0 | PAT (Programmatic Access Token) | Local dev, CI/CD | Token string -> Bearer header |
| P1 | Key-pair JWT | Automated pipelines | `openssl` package for RSA signing |
| P1 | OAuth | Enterprise SSO | `httr2` OAuth flows |
| P2 | External browser SSO | Interactive desktop | `httr2` + local HTTP callback |
| P2 | Username/password | Legacy | Direct POST to login endpoint |
| P3 | MFA | High-security environments | Challenge-response flow |

### 3.4 Proposed Package Name

Options to consider:
- `RSnowflake` -- follows `RPostgres`, `RSQLite`, `RMariaDB` convention
- `snowflaker` -- lowercase, modern style (like `bigrquery`)
- `snowflake` -- simplest, but may conflict with the ODBC helper `odbc::snowflake()`
- `sfdb` -- short, distinctive

Recommendation: **`RSnowflake`** for CRAN name consistency with the r-dbi
ecosystem. The ODBC helper `odbc::snowflake()` is a function, not a package
name, so there is no conflict.

---

## 4. Performance and Memory Benefits

### 4.1 Estimated Improvements

| Metric | Current (Python bridge) | Proposed (JSON) | Proposed (Arrow) |
|--------|------------------------|-----------------|------------------|
| Peak memory (1 GB result) | ~2.0 GB | ~1.2 GB | ~1.0 GB |
| Small query latency | 50-100ms | 20-40ms | 25-50ms |
| Large result throughput | Limited by JSON serialization | ~200 MB/s | ~500+ MB/s |
| Install time | 5-15 min (conda env) | <30 sec (CRAN binary) | <30 sec (CRAN binary) |
| Python required | Yes | No | No |

### 4.2 Why Arrow Matters

Snowflake internally stores data in a columnar format. The SQL API v2
can return results as Arrow IPC binary streams. When combined with R's
`nanoarrow` package:

- **Binary transfer**: Arrow IPC is ~3-5x smaller than equivalent JSON
  for numeric data
- **Type preservation**: Snowflake types map directly to Arrow types,
  then to R types, with no string-parsing intermediate step
- **Zero-copy potential**: `nanoarrow` can wrap Arrow buffers as R
  vectors without copying the data
- **Streaming**: Arrow IPC supports chunked reading, enabling processing
  of result sets larger than available memory

This is the same approach that makes `bigrquerystorage` dramatically
faster than `bigrquery`'s default JSON path.

---

## 5. Snowflake SQL API v2 Assessment

### 5.1 Endpoint Coverage

The SQL API v2 provides:

| Operation | Endpoint | Notes |
|-----------|----------|-------|
| Submit SQL | `POST /api/v2/statements` | Supports sync and async |
| Check status | `GET /api/v2/statements/{handle}` | For async queries |
| Cancel query | `POST /api/v2/statements/{handle}/cancel` | |
| Fetch results | `GET /api/v2/statements/{handle}?partition=N` | Paginated |

This covers the core DBI operations: `dbGetQuery`, `dbExecute`,
`dbSendQuery`, `dbFetch`, and `dbClearResult`.

### 5.2 Limitations and Mitigations

**Multi-statement transactions**: The SQL API v2 does not directly expose
`BEGIN`/`COMMIT`/`ROLLBACK` as transaction primitives. However, these can
be sent as regular SQL statements, and the API preserves session state
across requests when using the same session token.

**PUT/GET file operations**: The SQL API v2 does not support `PUT`/`GET`
stage operations directly. For bulk data upload (`dbWriteTable`), we have
two strategies:
1. Generate `INSERT INTO ... VALUES (...)` statements (works for small data)
2. Use the internal stage endpoints (requires additional REST calls)
3. Fall back to the Python bridge for large uploads if needed

**Result format**: The SQL API v2 returns results in JSON format by default.
Arrow IPC format may require using the internal `/queries/v1/query-request`
endpoint or negotiating format via headers. This needs further investigation
and testing.

### 5.3 Internal vs Public API

The Python connector uses Snowflake's internal endpoints:
- `/session/v1/login-request` -- session creation
- `/queries/v1/query-request` -- query execution
- `/session/token-request` -- token renewal

These endpoints are not publicly documented but are stable (the Python
connector has used them for years). We have two options:

1. **Use only public SQL API v2**: Safer, but may lack some features
2. **Use internal endpoints**: More complete, matches Python connector behavior

Recommendation: Start with the public SQL API v2 for queries. Use internal
endpoints only where the public API is insufficient (e.g., session
management, Arrow result format negotiation).

---

## 6. Relationship to snowflakeR

### 6.1 Package Separation Strategy

The proposed package (`RSnowflake`) would be a **standalone DBI connector**.
The existing `snowflakeR` package would evolve to become a **higher-level
ML platform package** that depends on `RSnowflake` for connectivity:

```
Current:
  snowflakeR (monolithic)
    ├── Connection (via Python bridge)
    ├── DBI shim
    ├── Model Registry
    ├── Feature Store
    ├── Datasets
    └── REST inference

Proposed:
  RSnowflake (new, standalone, CRAN)     snowflakeR (ML platform, depends on RSnowflake)
    ├── DBI interface (full)               ├── Model Registry
    ├── REST client (httr2)                ├── Feature Store
    ├── Authentication                     ├── Datasets
    ├── Arrow data transfer                ├── REST inference
    ├── dbplyr integration                 └── (uses RSnowflake for connectivity)
    └── connections.toml support
```

### 6.2 Code Reuse from snowflakeR

Several components from `snowflakeR` can be extracted and adapted:

| Component | Source | Adaptation Needed |
|-----------|--------|-------------------|
| REST HTTP calls | `R/rest_inference.R` | Generalize from inference-only to all SQL |
| PAT/JWT auth | `R/rest_inference.R` (`sfr_pat()`) | Expand to support all auth methods |
| JSON response parsing | `R/helpers.R` (`.bridge_dict_to_df()`) | Adapt for SQL API v2 response format |
| connections.toml reading | `R/connect.R` (`.read_connections_toml()`) | Reuse directly |
| DBI method signatures | `R/dbi.R` | Rewrite as formal S4 subclasses |
| dbplyr hooks | `R/dbi.R` (`db_query_fields`, `dbplyr_edition`) | Expand with Snowflake SQL translation |
| Identifier quoting | `R/dbi.R` (`dbQuoteIdentifier`) | Reuse directly |

### 6.3 Migration Path

For existing `snowflakeR` users:

1. `RSnowflake` ships as a separate package
2. `snowflakeR` adds `RSnowflake` to `Imports`
3. `sfr_connect()` gains a `backend = c("direct", "python")` parameter
4. Default backend switches from "python" to "direct" once validated
5. Python bridge remains available for ML-specific features that require
   Snowpark sessions (model registry, feature store DataFrame operations)

---

## 7. Risk Analysis

### 7.1 Technical Risks

| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| SQL API v2 missing features | Medium | Medium | Use internal endpoints as fallback; engage Snowflake API team |
| Arrow result format not available via v2 | Medium | Medium | JSON path works fine for MVP; investigate internal endpoints |
| Authentication edge cases (MFA, SAML) | Low | Medium | Start with PAT/JWT/session token; add complex auth incrementally |
| Snowflake type mapping edge cases | Low | High | Comprehensive type-map module; test with all Snowflake types |
| CRAN submission requirements | Low | Low | Pure R + CRAN deps; follow established patterns from bigrquery |

### 7.2 Strategic Risks

| Risk | Mitigation |
|------|-----------|
| ADBC Snowflake driver matures and makes this redundant | ADBC still needs DBI wrapper (adbi); our package adds auth flexibility and Workspace support |
| Snowflake ships an official R connector | Unlikely in near term; if they do, our package provides a community baseline |
| Maintaining two packages (RSnowflake + snowflakeR) | Clear separation of concerns; RSnowflake is infrastructure, snowflakeR is ML platform |

---

## 8. Benefits to the R Community

### 8.1 For Individual Users

- **Zero Python setup**: `install.packages("RSnowflake")` and go. No conda,
  no pip, no Python version management.
- **Familiar DBI interface**: Works with every tool that speaks DBI --
  `dplyr`, `dbplyr`, `DT`, `shiny`, RStudio Connections Pane, etc.
- **Better performance**: Arrow result fetching for large datasets;
  no Python memory overhead.
- **Workspace Notebooks**: First-class R support in Snowflake's cloud
  notebook environment, without the Python bridge overhead.

### 8.2 For the R Ecosystem

- **Fills a gap**: R is the only major language without a pure,
  native Snowflake DBI connector.
- **CRAN availability**: Puts Snowflake on equal footing with PostgreSQL,
  SQLite, BigQuery, etc. in the R package ecosystem.
- **dbplyr integration**: Enables lazy evaluation and SQL translation
  for Snowflake, making it a first-class citizen in the tidyverse.
- **Teaching and learning**: Simpler setup lowers the barrier for
  R courses and workshops that use Snowflake.

### 8.3 For Snowflake

- **R community engagement**: Demonstrates commitment to the R ecosystem.
- **Reduced support burden**: Eliminates Python bridge issues as the
  most common source of R user support tickets.
- **Competitive parity**: Google (bigrquery), AWS (RAthena), and
  Microsoft (AzureKusto) all have dedicated R DBI packages.
- **Workspace Notebooks**: Better R performance in Workspace Notebooks
  improves the product experience.

---

## 9. Effort Estimate

### 9.1 Phase Breakdown

| Phase | Scope | Effort | Dependencies |
|-------|-------|--------|-------------|
| Phase 1: Core Connectivity | REST client, basic auth, dbConnect/dbGetQuery/dbExecute | 3-4 weeks | None |
| Phase 2: Full DBI | All DBI generics, DBItest, type mapping | 3-4 weeks | Phase 1 |
| Phase 3: Arrow Performance | nanoarrow integration, bulk upload | 2-3 weeks | Phase 2 |
| Phase 4: Ecosystem | dbplyr, RStudio pane, OAuth/SSO, vignettes, CRAN | 3-4 weeks | Phase 3 |

**Total estimated effort: 11-15 weeks** for a single developer.

### 9.2 MVP Timeline

A working MVP (Phase 1) that supports `dbConnect()` with PAT/session token,
`dbGetQuery()`, `dbExecute()`, and basic DBI compliance could be delivered
in **3-4 weeks**. This would be sufficient for Workspace Notebook usage
and basic local development.

---

## 10. Recommendation

**Proceed with implementation.** The project is feasible, fills a real gap,
and has clear precedent in the R ecosystem. The recommended approach:

1. Start with Phase 1 (REST client + basic DBI) targeting Workspace Notebooks
   and PAT/JWT authentication.
2. Validate against the existing `snowflakeR` test suite and real workloads.
3. Incrementally add full DBI compliance, Arrow performance, and ecosystem
   integration.
4. Target CRAN submission after Phase 4.
5. Refactor `snowflakeR` to depend on `RSnowflake` for connectivity,
   keeping the ML platform features (model registry, feature store) in
   the higher-level package.

The detailed architecture, dependency mapping, DBI method inventory,
Workspace compatibility strategy, and competitive landscape analysis
are provided in the companion documents in this directory.
