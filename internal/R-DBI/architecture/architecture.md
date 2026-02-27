# RSnowflake Architecture

**Status**: Draft  
**Date**: 2026-02-27

---

## 1. Overview

RSnowflake is a pure-R, DBI-compliant database connector for Snowflake.
It communicates directly with Snowflake's REST API using `httr2` for HTTP,
`jsonlite` for JSON parsing, and optionally `nanoarrow` for Arrow IPC
result deserialization.

The architecture follows the three-layer pattern established by `bigrquery`
(Google BigQuery) and proven across several REST-based R DBI packages.

---

## 2. Layer Diagram

```
┌─────────────────────────────────────────────────────────┐
│                      User Code                          │
│  library(DBI)                                           │
│  con <- dbConnect(RSnowflake::Snowflake(), ...)         │
│  dbGetQuery(con, "SELECT ...")                          │
│  tbl(con, "my_table") |> filter(...) |> collect()       │
└───────────────┬─────────────────────┬───────────────────┘
                │                     │
    ┌───────────▼───────────┐  ┌──────▼──────────────────┐
    │  Layer 2: DBI (S4)    │  │  Layer 3: dbplyr        │
    │                       │  │                         │
    │  SnowflakeDriver      │  │  sql_translation        │
    │  SnowflakeConnection  │  │  dbplyr_edition = 2     │
    │  SnowflakeResult      │  │  Snowflake SQL dialect  │
    │                       │  │  tbl() dispatch         │
    │  dbConnect()          │  │  collect() -> dbFetch() │
    │  dbGetQuery()         │  │                         │
    │  dbSendQuery()        │  └──────┬──────────────────┘
    │  dbFetch()            │         │
    │  dbWriteTable()       │         │
    │  dbBind()             │         │
    │  dbBegin/Commit/      │         │
    │    Rollback()         │         │
    └───────────┬───────────┘         │
                │                     │
    ┌───────────▼─────────────────────▼───────────────────┐
    │              Layer 1: REST Client                    │
    │                                                     │
    │  sf_api_login()      - session management           │
    │  sf_api_query()      - POST /api/v2/statements      │
    │  sf_api_fetch()      - GET result partitions         │
    │  sf_api_cancel()     - cancel running query          │
    │  sf_api_keepalive()  - session heartbeat             │
    │                                                     │
    │  ┌─────────────┐  ┌──────────────┐  ┌────────────┐ │
    │  │ Auth Module  │  │ Result Parse │  │ Type Map   │ │
    │  │             │  │              │  │            │ │
    │  │ PAT         │  │ JSON path    │  │ SF -> R    │ │
    │  │ JWT/keypair │  │ Arrow path   │  │ R -> SF    │ │
    │  │ OAuth       │  │ Pagination   │  │ dbDataType │ │
    │  │ Session tok │  │ Streaming    │  │            │ │
    │  │ Browser SSO │  │              │  │            │ │
    │  └─────────────┘  └──────────────┘  └────────────┘ │
    └───────────────────────┬─────────────────────────────┘
                            │
                     ┌──────▼──────┐
                     │   httr2     │
                     │   (HTTP)    │
                     └──────┬──────┘
                            │ HTTPS
                            ▼
                ┌───────────────────────┐
                │  Snowflake SQL API    │
                │  /api/v2/statements   │
                │  /session/v1/...      │
                └───────────────────────┘
```

---

## 3. S4 Class Hierarchy

### 3.1 SnowflakeDriver

```r
setClass("SnowflakeDriver",
  contains = "DBIDriver"
)

# Constructor function (user-facing)
Snowflake <- function() {
  new("SnowflakeDriver")
}
```

The driver class is a lightweight dispatch target. It has no state.
Users interact with it only through `dbConnect()`:

```r
con <- dbConnect(RSnowflake::Snowflake(),
  account   = "myorg-myaccount",
  user      = "MYUSER",
  token     = Sys.getenv("SNOWFLAKE_PAT"),
  warehouse = "COMPUTE_WH",
  database  = "MYDB",
  schema    = "PUBLIC"
)
```

### 3.2 SnowflakeConnection

```r
setClass("SnowflakeConnection",
  contains = "DBIConnection",
  slots = list(
    # Connection identity
    account    = "character",
    user       = "character",
    host       = "character",

    # Session context
    warehouse  = "character",
    database   = "character",
    schema     = "character",
    role       = "character",

    # Auth state (internal)
    .auth      = "environment",   # mutable: token, refresh, expiry
    .session   = "environment",   # mutable: session handle, keepalive timer

    # Configuration
    .config    = "list"           # timeout, result_format, etc.
  )
)
```

The `.auth` and `.session` slots use environments (mutable reference
semantics) so that token refreshes and session state updates are visible
across all references to the connection object, without requiring R's
copy-on-modify to duplicate the entire object.

### 3.3 SnowflakeResult

```r
setClass("SnowflakeResult",
  contains = "DBIResult",
  slots = list(
    # Query identity
    statement       = "character",
    statement_handle = "character",   # Snowflake's opaque handle

    # Connection back-reference
    connection      = "SnowflakeConnection",

    # Result state (internal, mutable)
    .state          = "environment"   # fetched_rows, total_rows,
                                      # current_partition, is_complete,
                                      # column_info, bound_params
  )
)
```

The result object tracks the statement handle (returned by Snowflake's
SQL API), the current fetch position (partition index and row offset),
and column metadata. The `.state` environment enables incremental
fetching without object duplication.

---

## 4. Connection Lifecycle

```
dbConnect()
    │
    ├── Resolve auth credentials
    │   ├── Check SNOWFLAKE_TOKEN env var (Workspace Notebooks)
    │   ├── Check explicit token/PAT parameter
    │   ├── Check connections.toml (via snowflakeauth or direct)
    │   ├── Generate JWT from private key file
    │   └── Initiate OAuth/browser flow
    │
    ├── Establish session
    │   ├── POST /session/v1/login-request (for session-based auth)
    │   │   └── Receive session token + master token
    │   └── Or: use PAT/JWT directly (no login request needed)
    │
    ├── Set session context
    │   ├── USE WAREHOUSE ...
    │   ├── USE DATABASE ...
    │   ├── USE SCHEMA ...
    │   └── USE ROLE ...
    │
    └── Return SnowflakeConnection object

dbDisconnect()
    │
    ├── Cancel any active queries
    ├── POST /session/v1/delete-session
    └── Invalidate connection object
```

### 4.1 Session Token Lifecycle

For methods that require session management (username/password, OAuth),
the connection maintains:

- **Session token**: Short-lived (~4 hours), used for query requests
- **Master token**: Longer-lived (~2 weeks), used to renew session tokens
- **Heartbeat**: Periodic keepalive to prevent session timeout

For PAT and JWT authentication, the SQL API v2 accepts the token directly
in the `Authorization` header, and no session management is needed.

### 4.2 Connection Auto-detection (Workspace Notebooks)

```r
setMethod("dbConnect", "SnowflakeDriver", function(drv, ...) {

  # Priority 1: Workspace Notebook session token
  token <- Sys.getenv("SNOWFLAKE_TOKEN", "")
  if (nzchar(token)) {
    return(.sf_connect_with_token(token, ...))
  }

  # Priority 2: Explicit parameters
  args <- list(...)
  if (!is.null(args$token) || !is.null(args$account)) {
    return(.sf_connect_explicit(args))
  }

  # Priority 3: connections.toml
  toml <- .read_connections_toml(args$name)
  if (!is.null(toml)) {
    return(.sf_connect_from_toml(toml, args))
  }

  stop("No Snowflake credentials found. See ?dbConnect,SnowflakeDriver-method")
})
```

---

## 5. Query Execution Flow

### 5.1 dbGetQuery (Convenience Path)

```
dbGetQuery(con, "SELECT * FROM t WHERE id > 100")
    │
    ├── sf_api_query(con, sql)
    │   ├── POST /api/v2/statements
    │   │   Headers:
    │   │     Authorization: Bearer <token>
    │   │     Content-Type: application/json
    │   │     Accept: application/json
    │   │   Body:
    │   │     {"statement": "SELECT ...", "warehouse": "...", ...}
    │   │
    │   └── Response:
    │       ├── resultSetMetaData (column names, types, row count, partitions)
    │       └── data (first partition, JSON arrays of strings)
    │
    ├── Parse column metadata -> R types
    │
    ├── Fetch remaining partitions (if > 1)
    │   └── GET /api/v2/statements/{handle}?partition=1
    │   └── GET /api/v2/statements/{handle}?partition=2
    │   └── ...
    │
    ├── Combine partitions into single data.frame
    │
    └── Return data.frame
```

### 5.2 dbSendQuery / dbFetch (Streaming Path)

```
res <- dbSendQuery(con, "SELECT * FROM large_table")
    │
    ├── POST /api/v2/statements (async=true for very large queries)
    └── Return SnowflakeResult (with statement_handle, partition count)

while (!dbHasCompleted(res)) {
  chunk <- dbFetch(res, n = 10000)
    │
    ├── Fetch next partition(s) up to n rows
    ├── Parse to data.frame
    ├── Update .state (current_partition, fetched_rows)
    └── Return chunk

  process(chunk)
}

dbClearResult(res)
    │
    └── Release server-side resources (cancel if not complete)
```

### 5.3 Parameterized Queries

```
res <- dbSendQuery(con, "SELECT * FROM t WHERE id = ? AND name = ?")
dbBind(res, list(42L, "Alice"))
df <- dbFetch(res)
dbClearResult(res)
```

The SQL API v2 supports parameterized queries via the `bindings` field
in the request body:

```json
{
  "statement": "SELECT * FROM t WHERE id = ? AND name = ?",
  "bindings": {
    "1": {"type": "FIXED", "value": "42"},
    "2": {"type": "TEXT",  "value": "Alice"}
  }
}
```

---

## 6. Result Parsing

### 6.1 JSON Path

The default result format from the SQL API v2 is JSON. Each row is an
array of string values within the `data` field:

```json
{
  "resultSetMetaData": {
    "numRows": 3,
    "format": "jsonv2",
    "rowType": [
      {"name": "ID", "type": "fixed", "scale": 0, ...},
      {"name": "NAME", "type": "text", ...},
      {"name": "CREATED", "type": "timestamp_ntz", ...}
    ]
  },
  "data": [
    ["1", "Alice", "2024-01-15 10:30:00.000"],
    ["2", "Bob",   "2024-02-20 14:15:00.000"],
    ["3", "Carol", null]
  ]
}
```

The JSON path:
1. Extracts `rowType` to build column metadata (names, Snowflake types)
2. Pre-allocates R vectors of the correct type using the type map
3. Iterates through `data` rows, parsing each value according to its column type
4. Handles `null` -> `NA` conversion per R type
5. Assembles columns into a `data.frame`

### 6.2 Arrow Path (Client-Side Conversion via nanoarrow)

When `nanoarrow` is available, DBI Arrow methods (`dbGetQueryArrow`,
`dbFetchArrow`, `dbFetchArrowChunk`) are supported. These fetch data
through the normal JSON path and convert the resulting R data.frame to
a `nanoarrow_array_stream` on the client side:

1. Submit query via `POST /api/v2/statements` (standard JSON format)
2. Fetch JSON partitions (same as section 6.1)
3. Parse JSON to R data.frame
4. Convert data.frame to nanoarrow stream via `nanoarrow::as_nanoarrow_array_stream()`

This provides the standard DBI Arrow interface expected by downstream
packages while working within the constraints of the SQL API v2.

**Why not native Arrow transport?** The Snowflake SQL API v2 (public REST
API) only supports JSON responses. The `Accept` header must be
`application/json` or `*/*` -- Arrow media types are rejected with
HTTP 400. See section 11 for details on how native Arrow transport
could be achieved via the internal Snowflake protocol in the future.

### 6.3 Snowflake-to-R Type Mapping

| Snowflake Type | R Type | Notes |
|---------------|--------|-------|
| FIXED (integer, scale=0) | `integer` | Overflow to `bit64::integer64` or `double` |
| FIXED (decimal, scale>0) | `double` | |
| REAL / FLOAT | `double` | |
| TEXT / VARCHAR | `character` | |
| BOOLEAN | `logical` | |
| DATE | `Date` | |
| TIME | `hms::hms` | Via Suggests |
| TIMESTAMP_NTZ | `POSIXct` (UTC) | |
| TIMESTAMP_LTZ | `POSIXct` (local tz) | |
| TIMESTAMP_TZ | `POSIXct` (with tz attr) | |
| BINARY | `blob::blob` | Via Suggests |
| VARIANT | `character` (JSON string) | |
| ARRAY | `character` (JSON string) | |
| OBJECT | `character` (JSON string) | |
| GEOGRAPHY | `character` (GeoJSON/WKT) | |
| GEOMETRY | `character` (WKT) | |
| VECTOR | `list` of `double` | Fixed-size float arrays |

---

## 7. Data Upload (dbWriteTable)

### 7.1 Strategy Overview

Data upload is the most complex DBI operation because Snowflake's optimal
upload path (internal stage + COPY INTO) requires multiple steps:

| Data Size | Strategy | Mechanism |
|-----------|----------|-----------|
| < 1,000 rows | Multi-row INSERT | `INSERT INTO t VALUES (?,?),(?,?),...` |
| 1,000 - 100,000 rows | Batched INSERT | Multiple INSERT statements in transaction |
| > 100,000 rows | Stage + COPY INTO | PUT to stage, then COPY INTO table |

### 7.2 Small Data Path (INSERT)

For small uploads, generate a multi-row INSERT statement:

```r
dbWriteTable(con, "my_table", my_df)
# -->
# CREATE TABLE my_table ("COL1" NUMBER, "COL2" TEXT, ...)
# INSERT INTO my_table VALUES (1, 'a'), (2, 'b'), ...
```

R data types are mapped to Snowflake types via `dbDataType()`:

| R Type | Snowflake Type |
|--------|---------------|
| `integer` | `NUMBER(10, 0)` |
| `double` | `DOUBLE` |
| `character` | `TEXT` |
| `logical` | `BOOLEAN` |
| `Date` | `DATE` |
| `POSIXct` | `TIMESTAMP_NTZ` |
| `raw` / `blob` | `BINARY` |

### 7.3 Large Data Path (Stage + COPY INTO)

For large uploads, write data to a temporary internal stage:

1. Create temporary stage: `CREATE TEMPORARY STAGE rsnowflake_upload_stage`
2. Serialize data.frame to CSV or Parquet in a temp file
3. Upload via SQL API `PUT` command (or direct stage upload API)
4. `COPY INTO target_table FROM @rsnowflake_upload_stage FILE_FORMAT = (...)`
5. Drop temporary stage

The Arrow path (Parquet via `nanoarrow`) preserves types and is faster than CSV.

---

## 8. File Organization

```
RSnowflake/
├── DESCRIPTION
├── NAMESPACE
├── LICENSE
├── R/
│   ├── driver.R              # SnowflakeDriver S4 class + Snowflake() constructor
│   ├── connection.R          # SnowflakeConnection S4 class
│   ├── result.R              # SnowflakeResult S4 class
│   ├── auth.R                # Authentication module (PAT, JWT, OAuth, SSO, token)
│   ├── auth-jwt.R            # JWT generation (openssl-based)
│   ├── auth-oauth.R          # OAuth 2.0 flows
│   ├── api.R                 # Low-level REST client (sf_api_* functions)
│   ├── api-parse.R           # JSON/Arrow result parsing
│   ├── type-map.R            # Snowflake <-> R type mapping
│   ├── write.R               # dbWriteTable implementation (INSERT + stage paths)
│   ├── transactions.R        # dbBegin/dbCommit/dbRollback
│   ├── dbplyr.R              # dbplyr SQL translation rules
│   ├── connections-toml.R    # connections.toml / config.toml reader
│   ├── utils.R               # Internal utilities
│   └── zzz.R                 # .onLoad / .onAttach hooks
├── tests/
│   ├── testthat.R
│   └── testthat/
│       ├── test-driver.R     # SnowflakeDriver tests
│       ├── test-connection.R # Connection + auth tests
│       ├── test-result.R     # Query + fetch tests
│       ├── test-types.R      # Type mapping tests
│       ├── test-write.R      # dbWriteTable tests
│       ├── test-dbitest.R    # DBItest compliance suite
│       └── helper-*.R        # Test fixtures and helpers
├── man/                      # Generated roxygen2 docs
├── vignettes/
│   ├── getting-started.Rmd
│   ├── authentication.Rmd
│   └── performance.Rmd
└── inst/
    └── CITATION
```

---

## 9. Error Handling Strategy

### 9.1 Error Hierarchy

Map Snowflake error codes to DBI condition classes:

| Snowflake Error Category | R Condition | DBI Mapping |
|-------------------------|-------------|------------|
| Authentication failure | `sf_auth_error` | `dbConnect` error |
| SQL syntax error | `sf_sql_error` | `dbSendQuery` error |
| Object not found | `sf_not_found_error` | `dbExistsTable` = FALSE |
| Permission denied | `sf_permission_error` | `dbGetQuery` error |
| Session expired | `sf_session_error` | Auto-reconnect or error |
| Network/HTTP error | `sf_network_error` | Retry or error |
| Result too large | `sf_result_error` | Warning + pagination |

### 9.2 Condition Construction

Use `rlang::abort()` with structured metadata for programmatic handling:

```r
rlang::abort(
  message = "SQL compilation error: Object 'MISSING_TABLE' does not exist.",
  class = "sf_sql_error",
  sf_code = "002003",
  sf_sqlstate = "42S02",
  sf_statement = sql,
  sf_handle = statement_handle
)
```

---

## 10. Configuration

### 10.1 Connection Parameters

```r
dbConnect(RSnowflake::Snowflake(),
  # Identity
  account       = "myorg-myaccount",
  user          = "MYUSER",

  # Authentication (one of)
  token         = "...",               # PAT or session token
  private_key   = "~/.snowflake/rsa_key.p8",  # Key-pair auth
  authenticator = "externalbrowser",   # Browser SSO
  password      = "...",               # Username/password (legacy)

  # Session context
  warehouse     = "COMPUTE_WH",
  database      = "MYDB",
  schema        = "PUBLIC",
  role          = "MYROLE",

  # Options
  timeout       = 60,                  # Query timeout (seconds)
  timezone      = "UTC",               # Session timezone

  # Profile-based (reads connections.toml)
  name          = "default"            # Profile name
)
```

### 10.2 Package Options

```r
options(
  RSnowflake.timeout       = 60,       # Default query timeout
  RSnowflake.retry_max     = 3,        # Max retry attempts
  RSnowflake.verbose       = FALSE     # Debug logging
)
```

---

## 11. Native Arrow Transport -- Findings & Future Work

### 11.1 Background

The Snowflake Python connector achieves 3-10x faster result fetching for
large datasets by using native Apache Arrow IPC transport. We investigated
whether the same approach is available via the SQL API v2 used by
RSnowflake.

### 11.2 How the Python Connector Does It

The Python connector does **not** use the public SQL API v2
(`/api/v2/statements`). It uses Snowflake's internal GS (Global Services)
protocol, which provides a fundamentally different result delivery
mechanism:

1. **Initial response** -- The query metadata response includes a
   `rowsetBase64` field containing the first partition's data as
   base64-encoded Arrow IPC bytes (instead of a `data` JSON array).
   The Python connector decodes this via `base64.b64decode()`.

2. **Subsequent partitions** -- The response includes a `chunks` array
   where each chunk has a `url` field containing a **pre-signed cloud
   storage URL** (S3, Azure Blob, or GCS). The connector downloads raw
   Arrow IPC bytes directly from cloud storage, bypassing the Snowflake
   API entirely. Encryption headers (`chunkHeaders`, `qrmk`) are
   provided for SSE-C decryption.

3. **Parsing** -- The raw Arrow IPC bytes (from base64 or direct
   download) are fed into nanoarrow (as of Python connector 3.5.0+)
   or pyarrow for zero-copy conversion to Python/Pandas types.

Key fields in the internal protocol response that are NOT available in
the SQL API v2:

| Field | Purpose |
|-------|---------|
| `rowsetBase64` | Base64-encoded Arrow IPC for inline first partition |
| `chunks[].url` | Pre-signed cloud storage URLs for partition downloads |
| `chunkHeaders` | HTTP headers for SSE-C encrypted chunk downloads |
| `qrmk` | Query Result Master Key for chunk decryption |

Reference: `snowflake-connector-python/src/snowflake/connector/result_batch.py`
(classes `ArrowResultBatch` and `JSONResultBatch`).

### 11.3 What the SQL API v2 Actually Supports

The public SQL API v2 (`/api/v2/statements`) only supports JSON:

- The `Accept` header **must** be `application/json` or `*/*`. Any other
  media type (including `application/vnd.apache.arrow.stream`) is rejected
  with HTTP 400 error code 391926.
- The `resultSetMetaData.format` field in the request body accepts
  `"jsonv2"` but does not change the transport format.
- All partition data is returned as JSON arrays of string values via the
  `data` field.
- Additional partitions are fetched via
  `GET /api/v2/statements/{handle}?partition=N`, which returns
  gzip-compressed JSON.

### 11.4 Current RSnowflake Approach

Given the SQL API v2 constraints, RSnowflake provides DBI Arrow methods
by fetching JSON data through the normal path and converting to nanoarrow
on the client side:

```
dbGetQueryArrow(con, sql)
    │
    ├── sf_api_submit(con, sql)           # POST, JSON format
    ├── sf_parse_response(resp)           # JSON -> data.frame
    └── nanoarrow::as_nanoarrow_array_stream(df)  # data.frame -> Arrow
```

This gives users the standard DBI Arrow interface (`dbGetQueryArrow`,
`dbFetchArrow`, `dbSendQueryArrow`) for downstream compatibility, but
does not provide the performance benefits of native Arrow transport.

### 11.5 Future: Native Arrow via Internal Protocol

**TODO**: Prototype a native Arrow transport path using the internal
Snowflake GS protocol. This would be enabled via a hidden option
(e.g. `options(RSnowflake.use_native_arrow = TRUE)`) and would:

1. **Login via `/session/v1/login-request`** to obtain a session token
   and master token (required for the internal protocol).

2. **Submit queries** via the internal query endpoint (used by the Python
   connector) with `resultSetMetaData.format = "arrow"` to receive
   `rowsetBase64` and chunk URLs.

3. **Decode first partition** from base64 Arrow IPC.

4. **Download subsequent partitions** directly from pre-signed cloud
   storage URLs as raw Arrow IPC bytes, with optional SSE-C decryption.

5. **Parse Arrow IPC** via `nanoarrow::read_nanoarrow()` for zero-copy
   conversion to R data.frames.

Complexity and risks:

- The internal protocol is undocumented and subject to change without
  notice. The Python/JDBC/Go connectors track it closely but it is not
  a public contract.
- Session management (session tokens, master tokens, heartbeat/keepalive)
  is required, adding significant implementation complexity.
- SSE-C chunk decryption (`qrmk` + `chunkHeaders`) must be implemented
  for encrypted result sets.
- The login endpoint may require different auth flows than what we
  currently support via SQL API v2.
- Testing would need to cover both the SQL API v2 path (default) and
  the native Arrow path (opt-in).

Expected performance impact:

- **Small results (<1,000 rows)**: Negligible difference. JSON parsing
  overhead is minimal.
- **Medium results (1K-100K rows)**: 2-3x improvement expected from
  avoiding string serialization/deserialization.
- **Large results (>100K rows)**: 5-10x improvement expected, matching
  what the Python connector blog reports, primarily from direct cloud
  storage downloads and binary Arrow transport.
