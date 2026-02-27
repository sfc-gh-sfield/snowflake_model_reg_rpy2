# DBI Method Inventory for RSnowflake

**Status**: Draft  
**Date**: 2026-02-27

---

## 1. Overview

This document lists every DBI generic method that a fully compliant backend
must implement, along with the implementation plan for RSnowflake. Methods
are grouped by category and assigned to implementation phases.

Reference: [DBI specification](https://dbi.r-dbi.org/articles/spec),
[DBI backend guide](https://cran.r-project.org/web/packages/DBI/vignettes/backend.html),
[DBItest](https://dbitest.r-dbi.org/).

---

## 2. Current snowflakeR Coverage

The existing `snowflakeR/R/dbi.R` implements a subset of DBI methods using
S4 methods registered on the S3 class `sfr_connection`. It is self-described
as a "Minimum Viable Implementation". Coverage:

| Method | snowflakeR Status | Notes |
|--------|------------------|-------|
| `dbGetQuery` | Implemented | Delegates to `sfr_query()` via Python bridge |
| `dbExecute` | Implemented | Delegates to `sfr_execute()` |
| `dbSendQuery` | Implemented | Eagerly fetches all results (not streaming) |
| `dbFetch` | Implemented | Returns pre-fetched data |
| `dbClearResult` | Implemented | No-op (nothing to clean up) |
| `dbHasCompleted` | Implemented | Always returns TRUE |
| `dbDisconnect` | Implemented | Closes Snowpark session |
| `dbListTables` | Implemented | Via SHOW TABLES |
| `dbListFields` | Implemented | Via DESCRIBE TABLE |
| `dbExistsTable` | Implemented | Via sfr_table_exists() |
| `dbReadTable` | Implemented | SELECT * FROM table |
| `dbWriteTable` | Implemented | Via Snowpark DataFrame write |
| `dbGetInfo` | Implemented | Returns connection metadata |
| `dbIsValid` | Implemented | Checks session health |
| `dbQuoteIdentifier` | Implemented | Double-quote wrapping |
| `dbQuoteString` | Implemented | Single-quote wrapping with escaping |
| All other methods | **Not implemented** | |

**Key gaps**: `dbBind`, `dbBegin`/`dbCommit`/`dbRollback`, `dbRemoveTable`,
`dbCreateTable`, `dbAppendTable`, `dbColumnInfo`, `dbGetStatement`,
`dbGetRowCount`, `dbGetRowsAffected`, `dbDataType`, streaming `dbFetch`,
Arrow DBI methods, driver class.

---

## 3. Full DBI Method Inventory

### 3.1 Driver Methods

| Generic | Signature | Phase | Implementation Notes |
|---------|-----------|-------|---------------------|
| `dbConnect` | `(SnowflakeDriver, ...)` | **P1** | Main entry point. Resolves auth, creates session, returns SnowflakeConnection. |
| `dbDataType` | `(SnowflakeDriver, obj)` | **P2** | R type -> Snowflake SQL type string. Used by dbWriteTable/dbCreateTable. |
| `dbGetInfo` | `(SnowflakeDriver)` | **P1** | Returns list(driver.version, client.version). |
| `dbIsValid` | `(SnowflakeDriver)` | **P1** | Always TRUE (driver is stateless). |
| `dbCanConnect` | `(SnowflakeDriver, ...)` | **P2** | Attempt connection, return TRUE/FALSE. |
| `dbUnloadDriver` | `(SnowflakeDriver)` | **P1** | No-op, returns TRUE. Legacy method. |
| `show` | `(SnowflakeDriver)` | **P1** | Print `<SnowflakeDriver>`. |

### 3.2 Connection Methods -- Core

| Generic | Signature | Phase | Implementation Notes |
|---------|-----------|-------|---------------------|
| `dbDisconnect` | `(SnowflakeConnection)` | **P1** | Close session, invalidate connection. |
| `dbGetInfo` | `(SnowflakeConnection)` | **P1** | Return list(dbname, db.version, username, host, port). |
| `dbIsValid` | `(SnowflakeConnection)` | **P1** | Check if session is still active. |
| `show` | `(SnowflakeConnection)` | **P1** | Print connection summary. |

### 3.3 Connection Methods -- Query Execution

| Generic | Signature | Phase | Implementation Notes |
|---------|-----------|-------|---------------------|
| `dbGetQuery` | `(SnowflakeConnection, character)` | **P1** | Execute + fetch all results. Convenience wrapper around dbSendQuery + dbFetch + dbClearResult. |
| `dbExecute` | `(SnowflakeConnection, character)` | **P1** | Execute DDL/DML, return rows affected count. |
| `dbSendQuery` | `(SnowflakeConnection, character)` | **P1** | Submit query, return SnowflakeResult. Must support deferred/streaming fetch. |
| `dbSendStatement` | `(SnowflakeConnection, character)` | **P2** | Like dbSendQuery but for non-SELECT (DDL/DML). Returns SnowflakeResult. |

### 3.4 Connection Methods -- Table Operations

| Generic | Signature | Phase | Implementation Notes |
|---------|-----------|-------|---------------------|
| `dbListTables` | `(SnowflakeConnection)` | **P1** | `SHOW TABLES IN SCHEMA`. Return character vector. |
| `dbExistsTable` | `(SnowflakeConnection, character)` | **P1** | Check via SHOW TABLES or information_schema. |
| `dbListFields` | `(SnowflakeConnection, character)` | **P1** | `DESCRIBE TABLE`. Return character vector of column names. |
| `dbReadTable` | `(SnowflakeConnection, character)` | **P2** | `SELECT * FROM table`. Return data.frame. |
| `dbWriteTable` | `(SnowflakeConnection, character, data.frame)` | **P2** | Create + insert or overwrite. Supports `overwrite`, `append`, `field.types`. |
| `dbCreateTable` | `(SnowflakeConnection, character, data.frame/fields)` | **P2** | CREATE TABLE with column types from dbDataType(). |
| `dbAppendTable` | `(SnowflakeConnection, character, data.frame)` | **P2** | INSERT INTO existing table. |
| `dbRemoveTable` | `(SnowflakeConnection, character)` | **P2** | DROP TABLE. |
| `dbListObjects` | `(SnowflakeConnection)` | **P4** | List databases, schemas, tables hierarchy. |

### 3.5 Connection Methods -- SQL Helpers

| Generic | Signature | Phase | Implementation Notes |
|---------|-----------|-------|---------------------|
| `dbQuoteIdentifier` | `(SnowflakeConnection, character)` | **P1** | Wrap in double quotes, escape embedded quotes. Snowflake uses `"identifier"`. |
| `dbQuoteString` | `(SnowflakeConnection, character)` | **P1** | Wrap in single quotes, escape embedded quotes. `'string'`. |
| `dbQuoteLiteral` | `(SnowflakeConnection, ...)` | **P2** | Type-aware literal quoting (dates, timestamps, etc.). |
| `dbDataType` | `(SnowflakeConnection, obj)` | **P2** | R object -> Snowflake type string. |
| `sqlCreateTable` | `(SnowflakeConnection, ...)` | **P2** | Generate CREATE TABLE SQL. |
| `sqlAppendTable` | `(SnowflakeConnection, ...)` | **P2** | Generate INSERT INTO SQL. |
| `sqlData` | `(SnowflakeConnection, data.frame)` | **P2** | Convert R data to SQL-ready strings. |

### 3.6 Connection Methods -- Transactions

| Generic | Signature | Phase | Implementation Notes |
|---------|-----------|-------|---------------------|
| `dbBegin` | `(SnowflakeConnection)` | **P2** | Execute `BEGIN TRANSACTION`. Track transaction state on connection. |
| `dbCommit` | `(SnowflakeConnection)` | **P2** | Execute `COMMIT`. |
| `dbRollback` | `(SnowflakeConnection)` | **P2** | Execute `ROLLBACK`. |
| `dbWithTransaction` | `(SnowflakeConnection, code)` | **P2** | Default implementation in DBI (begin, run code, commit/rollback). |

Note: Snowflake supports transactions. The SQL API v2 preserves session
state, so BEGIN/COMMIT/ROLLBACK sent as SQL statements work correctly.

### 3.7 Result Methods

| Generic | Signature | Phase | Implementation Notes |
|---------|-----------|-------|---------------------|
| `dbFetch` | `(SnowflakeResult, n)` | **P1** | Fetch up to n rows. n=-1 fetches all. Partition-based streaming. |
| `dbClearResult` | `(SnowflakeResult)` | **P1** | Release server resources. Cancel if not complete. |
| `dbHasCompleted` | `(SnowflakeResult)` | **P1** | TRUE if all partitions fetched. |
| `dbGetRowCount` | `(SnowflakeResult)` | **P2** | Number of rows fetched so far. |
| `dbGetRowsAffected` | `(SnowflakeResult)` | **P2** | Rows affected by DML statement. |
| `dbGetStatement` | `(SnowflakeResult)` | **P2** | Return the SQL string. |
| `dbColumnInfo` | `(SnowflakeResult)` | **P2** | Return data.frame of column name, type, nullable, etc. |
| `dbIsValid` | `(SnowflakeResult)` | **P1** | TRUE if result set is still open. |
| `dbGetInfo` | `(SnowflakeResult)` | **P2** | Return metadata list. |
| `dbBind` | `(SnowflakeResult, params)` | **P2** | Bind parameter values for parameterized queries. |
| `show` | `(SnowflakeResult)` | **P1** | Print result summary. |

### 3.8 Arrow DBI Extensions (DBI >= 1.2.0)

| Generic | Signature | Phase | Implementation Notes |
|---------|-----------|-------|---------------------|
| `dbGetQueryArrow` | `(SnowflakeConnection, character)` | **P3** | Execute query, return nanoarrow array stream. |
| `dbSendQueryArrow` | `(SnowflakeConnection, character)` | **P3** | Submit query, return result for Arrow fetching. |
| `dbFetchArrow` | `(SnowflakeResult)` | **P3** | Fetch result as nanoarrow array stream. |
| `dbFetchArrowChunk` | `(SnowflakeResult)` | **P3** | Fetch one Arrow chunk (one partition). |
| `dbReadTableArrow` | `(SnowflakeConnection, character)` | **P3** | Read table as Arrow stream. |
| `dbWriteTableArrow` | `(SnowflakeConnection, character, nanoarrow_stream)` | **P3** | Write Arrow data to table. |
| `dbCreateTableArrow` | `(SnowflakeConnection, character, nanoarrow_stream)` | **P3** | Create table from Arrow schema. |
| `dbAppendTableArrow` | `(SnowflakeConnection, character, nanoarrow_stream)` | **P3** | Append Arrow data to table. |

---

## 4. dbplyr Integration Methods

These are S3 methods registered for dbplyr compatibility (not formal DBI
generics but required for `tbl()` / `collect()` to work):

| Method | Phase | Implementation Notes |
|--------|-------|---------------------|
| `dbplyr_edition.SnowflakeConnection` | **P4** | Return `2L` for dbplyr edition 2. |
| `db_query_fields.SnowflakeConnection` | **P4** | Return column names from a table/query. `SELECT * FROM ... LIMIT 0`. |
| `sql_translation.SnowflakeConnection` | **P4** | Snowflake-specific SQL function translations. |
| `db_connection_describe.SnowflakeConnection` | **P4** | Description string for connection pane. |
| `sql_query_explain.SnowflakeConnection` | **P4** | Generate EXPLAIN PLAN SQL. |

### 4.1 Snowflake SQL Translation Rules

Snowflake has several SQL dialect differences from ANSI SQL that dbplyr
needs to handle:

| R / dplyr Function | Snowflake SQL | Notes |
|-------------------|---------------|-------|
| `paste()` / `paste0()` | `CONCAT(...)` or `||` | |
| `substr()` | `SUBSTR(str, start, length)` | 1-indexed |
| `nchar()` | `LENGTH(str)` | |
| `tolower()` / `toupper()` | `LOWER()` / `UPPER()` | |
| `as.Date()` | `TO_DATE()` | |
| `as.numeric()` | `TO_DOUBLE()` or `CAST(... AS DOUBLE)` | |
| `Sys.time()` | `CURRENT_TIMESTAMP()` | |
| `ifelse()` | `IFF(cond, true, false)` | Snowflake uses IFF, not IF |
| `coalesce()` | `COALESCE(...)` | Same |
| `n()` | `COUNT(*)` | Same |
| `n_distinct()` | `COUNT(DISTINCT ...)` | Same |
| `lag()` / `lead()` | `LAG()` / `LEAD()` | Same |
| `row_number()` | `ROW_NUMBER()` | Same |
| `%in%` | `IN (...)` | Same |
| `is.na()` | `IS NULL` | |
| `between()` | `BETWEEN ... AND ...` | |

---

## 5. Phase Summary

### Phase 1: Core Connectivity (MVP) -- 20 methods

All methods needed for basic `dbConnect()` / `dbGetQuery()` / `dbDisconnect()`
workflow:

- Driver: `dbConnect`, `dbGetInfo`, `dbIsValid`, `dbUnloadDriver`, `show`
- Connection: `dbDisconnect`, `dbGetInfo`, `dbIsValid`, `show`
- Query: `dbGetQuery`, `dbExecute`, `dbSendQuery`
- Result: `dbFetch`, `dbClearResult`, `dbHasCompleted`, `dbIsValid`, `show`
- SQL: `dbQuoteIdentifier`, `dbQuoteString`
- Table: `dbListTables`, `dbExistsTable`, `dbListFields`

### Phase 2: Full DBI Compliance -- 20 additional methods

- Table ops: `dbReadTable`, `dbWriteTable`, `dbCreateTable`, `dbAppendTable`, `dbRemoveTable`
- SQL helpers: `dbQuoteLiteral`, `dbDataType`, `sqlCreateTable`, `sqlAppendTable`, `sqlData`
- Transactions: `dbBegin`, `dbCommit`, `dbRollback`, `dbWithTransaction`
- Result metadata: `dbGetRowCount`, `dbGetRowsAffected`, `dbGetStatement`, `dbColumnInfo`, `dbGetInfo`
- Params: `dbBind`
- Other: `dbSendStatement`, `dbCanConnect`

### Phase 3: Arrow Performance -- 8 methods

- Arrow DBI extensions: `dbGetQueryArrow`, `dbSendQueryArrow`, `dbFetchArrow`,
  `dbFetchArrowChunk`, `dbReadTableArrow`, `dbWriteTableArrow`,
  `dbCreateTableArrow`, `dbAppendTableArrow`

### Phase 4: Ecosystem Integration -- 5+ methods

- dbplyr: `dbplyr_edition`, `db_query_fields`, `sql_translation`,
  `db_connection_describe`, `sql_query_explain`
- RStudio pane: `dbListObjects`, connection observer hooks

---

## 6. DBItest Integration Plan

The `DBItest` package provides ~400 automated test cases for DBI compliance.
Integration approach:

```r
# tests/testthat/test-dbitest.R

DBItest::make_context(
  RSnowflake::Snowflake(),
  connect_args = list(
    account = Sys.getenv("SNOWFLAKE_ACCOUNT"),
    token   = Sys.getenv("SNOWFLAKE_PAT")
  ),
  set_default_context = TRUE
)

DBItest::test_getting_started()
DBItest::test_driver()
DBItest::test_connection()
DBItest::test_result()
DBItest::test_sql()
DBItest::test_meta()
DBItest::test_transaction()
DBItest::test_compliance()
```

Tests that are known to be unsatisfiable for Snowflake (e.g., tests that
assume local file system access, or specific SQL dialect features) can be
skipped with `DBItest::tweaks()`.

Expected pass rate by phase:
- Phase 1: ~40% of DBItest tests
- Phase 2: ~85% of DBItest tests
- Phase 3: ~90% of DBItest tests (Arrow tests)
- Phase 4: ~95%+ of DBItest tests
