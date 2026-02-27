# RSnowflake 0.2.0

## New Features

* **Programmatic Access Token (PAT) authentication** -- set `SNOWFLAKE_PAT` or
  pass a token directly via `dbConnect()`. PATs now use the correct
  `PROGRAMMATIC_ACCESS_TOKEN` header.

* **Arrow IPC result fetching** -- `dbGetQueryArrow()`, `dbSendQueryArrow()`,
  `dbFetchArrow()`, and `dbFetchArrowChunk()` stream results in Apache Arrow
  format via the `nanoarrow` package for significantly faster large-result
  retrieval.

* **dbplyr backend** -- `tbl()`, `filter()`, `select()`, and other dplyr
verbs  are translated to Snowflake SQL and executed lazily. Inherits
  Snowflake-specific translations from `dbplyr::simulate_snowflake()`.

* **Improved bulk upload** -- `dbWriteTable()` and `dbAppendTable()` now
  generate named-column INSERT statements, use a configurable batch size
  (`options(RSnowflake.insert_batch_size = N)`), and display a `cli` progress
  bar for large uploads.

* **`dbListObjects()`** -- hierarchical browsing of databases, schemas, and
  tables for RStudio/Positron Connections Pane integration.

* **`dbUnquoteIdentifier()`** -- parses quoted multi-part identifiers
  (e.g., `"db"."schema"."table"`) into `Id` objects.

* **RStudio/Positron Connections Pane hooks** -- connections appear in
  the Connections Pane with object browsing and column preview.

* **Getting-started vignette** covering authentication, queries, Arrow,
  and dbplyr workflows.

## Bug Fixes

* Identifier case is now preserved in `dbCreateTable()` -- column names
  are no longer uppercased, aligning with DBI round-trip semantics.

* S4 mutability fix: `SnowflakeResult` state tracking uses reference
  semantics (environment slot) to avoid R's copy-on-modify behaviour.

* 401 token refresh for JWT authentication is handled transparently.

# RSnowflake 0.1.0

* Initial release with full DBI compliance via Snowflake SQL API v2.
* JWT key-pair authentication, session-token (Workspace) auth.
* Core DBI methods: `dbConnect`, `dbGetQuery`, `dbExecute`, `dbSendQuery`,
  `dbFetch`, `dbBind`, `dbCreateTable`, `dbWriteTable`, `dbAppendTable`,
  `dbReadTable`, `dbRemoveTable`, `dbListTables`, `dbExistsTable`,
  `dbListFields`, `dbQuoteIdentifier`, `dbQuoteString`, `dbQuoteLiteral`,
  `dbBegin`, `dbCommit`, `dbRollback`, `dbWithTransaction`.
* Snowflake Workspace Notebook support (auto-detects session token).
* `connections.toml` configuration file support.
* 64 unit tests.
