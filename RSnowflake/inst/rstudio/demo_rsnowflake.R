# =============================================================================
# RSnowflake -- Feature Demo (RStudio / Positron)
# =============================================================================
#
# First-time setup (from the project root in RStudio):
#   renv::restore()                # install all pinned dependencies
#   renv::install("./RSnowflake")  # install package from local source
#
# An interactive walkthrough of RSnowflake's key features:
#   1. DBI connection via connections.toml
#   2. Querying (dbGetQuery, dbSendQuery/dbFetch)
#   3. Table operations (write, read, append, remove)
#   4. Identifier case handling
#   5. Parameterized queries
#   6. Transactions
#   7. dbplyr / dplyr lazy evaluation
#   8. Arrow fast path
#   9. Connections Pane browsing (dbListObjects)
#
# Intended to be run section-by-section in RStudio (Cmd+Enter per block).
# =============================================================================

library(DBI)
library(RSnowflake)

# ── 1. Connect ──────────────────────────────────────────────────────────────

# Uses the [rsnowflake_dev] profile from ~/.snowflake/connections.toml
# (JWT key-pair auth -- no password or MFA required)
con <- dbConnect(Snowflake(), name = "rsnowflake_dev")
con
dbGetInfo(con)


# ── 2. Simple Queries ───────────────────────────────────────────────────────

dbGetQuery(con, "SELECT CURRENT_VERSION() AS version")

dbGetQuery(con, "
  SELECT
    42            AS int_val,
    3.14::DOUBLE  AS dbl_val,
    'hello'       AS str_val,
    TRUE          AS bool_val,
    CURRENT_DATE()          AS date_val,
    CURRENT_TIMESTAMP()     AS ts_val
")


# ── 3. Table Operations ────────────────────────────────────────────────────

# Create a demo data.frame with lowercase column names.
# RSnowflake preserves the case you give it (unlike ODBC which uppercases).
demo <- data.frame(
  id     = 1:10,
  city   = c("London", "Paris", "Tokyo", "Sydney", "NYC",
             "Berlin", "Toronto", "Mumbai", "Seoul", "Dubai"),
  temp_c = c(12.5, 15.2, 22.3, 25.1, 18.7,
             10.3, 8.9, 33.2, 19.8, 38.5),
  rainy  = c(TRUE, TRUE, FALSE, FALSE, TRUE,
             TRUE, TRUE, FALSE, FALSE, FALSE),
  stringsAsFactors = FALSE
)

dbWriteTable(con, "DEMO_CITIES", demo, overwrite = TRUE)

# Verify column names preserved their original case
dbListFields(con, "DEMO_CITIES")

# Read it back
dbReadTable(con, "DEMO_CITIES")

# Append more rows
extra <- data.frame(
  id = 11:12,
  city = c("Rome", "Cairo"),
  temp_c = c(20.1, 35.0),
  rainy = c(FALSE, FALSE)
)
dbAppendTable(con, "DEMO_CITIES", extra)

dbGetQuery(con, "SELECT COUNT(*) AS n FROM DEMO_CITIES")


# ── 4. Identifier Case Handling ─────────────────────────────────────────────

# Snowflake uppercases unquoted identifiers. RSnowflake always quotes them,
# so the case you specify in R is the case stored in Snowflake.

# To reference columns in raw SQL, use quoted identifiers:
dbGetQuery(con, 'SELECT "city", "temp_c" FROM DEMO_CITIES WHERE "temp_c" > 25')

# dbQuoteIdentifier wraps names in double-quotes:
dbQuoteIdentifier(con, "myColumn")

# dbUnquoteIdentifier parses back:
dbUnquoteIdentifier(con, SQL('"mydb"."myschema"."mytable"'))


# ── 5. Parameterized Queries ───────────────────────────────────────────────

# Use ? placeholders with the params argument:
dbGetQuery(
  con,
  'SELECT * FROM DEMO_CITIES WHERE "temp_c" > ?',
  params = list(30)
)

# Or via dbBind:
res <- dbSendQuery(con, 'SELECT * FROM DEMO_CITIES WHERE "city" = ?')
dbBind(res, list("Tokyo"))
dbFetch(res)
dbClearResult(res)


# ── 6. Transactions ────────────────────────────────────────────────────────

# Transaction support requires session-based state (not yet available via
# SQL API v2). This section will work once transactions are implemented.
tryCatch({
  dbBegin(con)
  dbExecute(con, "INSERT INTO \"DEMO_CITIES\" (\"id\",\"city\",\"temp_c\",\"rainy\") VALUES (13, 'Lima', 22.0, FALSE)")
  dbRollback(con)

  dbGetQuery(con, "SELECT COUNT(*) AS n FROM DEMO_CITIES")

  dbWithTransaction(con, {
    dbExecute(con, "INSERT INTO \"DEMO_CITIES\" (\"id\",\"city\",\"temp_c\",\"rainy\") VALUES (14, 'Oslo', 5.0, TRUE)")
    stop("Simulated error -- transaction will roll back")
  })
}, error = function(e) {
  message("Transactions not yet supported: ", conditionMessage(e))
})

dbGetQuery(con, "SELECT COUNT(*) AS n FROM DEMO_CITIES")


# ── 7. dbplyr / dplyr Integration ──────────────────────────────────────────

if (requireNamespace("dbplyr", quietly = TRUE) &&
    requireNamespace("dplyr", quietly = TRUE)) {

  library(dplyr)

  cities_tbl <- tbl(con, "DEMO_CITIES")
  cities_tbl

  # Lazy query -- translated to Snowflake SQL, not executed yet
  hot_cities <- cities_tbl |>
    filter(temp_c > 20) |>
    select(city, temp_c) |>
    arrange(desc(temp_c))

  # See the generated SQL
  show_query(hot_cities)

  # Execute and pull into R
  hot_cities |> collect()

  # Aggregation
  cities_tbl |>
    summarise(
      avg_temp = mean(temp_c, na.rm = TRUE),
      n_rainy  = sum(as.integer(rainy), na.rm = TRUE),
      n_cities = n()
    ) |>
    collect()

} else {
  message("Install dbplyr and dplyr for this section: install.packages(c('dbplyr', 'dplyr'))")
}


# ── 8. Arrow Fast Path (optional) ──────────────────────────────────────────

if (requireNamespace("nanoarrow", quietly = TRUE)) {
  stream <- dbGetQueryArrow(con, "SELECT * FROM DEMO_CITIES")
  arrow_df <- as.data.frame(stream)
  str(arrow_df)
  cat("Arrow result:", nrow(arrow_df), "rows,", ncol(arrow_df), "columns\n")
} else {
  message("Install nanoarrow for Arrow fast path: install.packages('nanoarrow')")
}


# ── 9. Connections Pane Browsing ────────────────────────────────────────────

# dbListObjects powers the RStudio Connections Pane hierarchy.
# NULL prefix -> databases:
head(dbListObjects(con))

# 1-component prefix -> schemas in a database:
dbListObjects(con, prefix = Id(catalog = "RSNOWFLAKE"))

# 2-component prefix -> tables in a schema:
dbListObjects(con, prefix = Id(catalog = "RSNOWFLAKE", schema = "PUBLIC"))


# ── 10. Cleanup ─────────────────────────────────────────────────────────────

dbRemoveTable(con, "DEMO_CITIES")
dbDisconnect(con)
cat("Done! Connection closed.\n")
