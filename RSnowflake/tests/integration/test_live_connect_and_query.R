# Integration Tests for RSnowflake
# Run with: Rscript tests/integration/test_live_connect_and_query.R
# Requires: [rsnowflake_dev] profile in ~/.snowflake/connections.toml

library(devtools)
load_all(".")

SCHEMA <- "INTEGRATION_TEST"
passed <- 0L
failed <- 0L

check <- function(desc, expr) {
  result <- tryCatch(
    { eval(expr); TRUE },
    error = function(e) { message("  ERROR: ", conditionMessage(e)); FALSE }
  )
  if (result) {
    cat(sprintf("  PASS: %s\n", desc))
    passed <<- passed + 1L
  } else {
    cat(sprintf("  FAIL: %s\n", desc))
    failed <<- failed + 1L
  }
}

# ==========================================================================
cat("== 1. Connection ==\n")
# ==========================================================================

con <- sf_connect(name = "rsnowflake_dev")
check("Connection is valid", dbIsValid(con))
check("Connection prints", {
  capture.output(show(con))
  TRUE
})

info <- dbGetInfo(con)
check("dbGetInfo returns list", is.list(info))
check("dbGetInfo has dbname", identical(info$dbname, "RSNOWFLAKE"))

# Create/replace test schema
cat("\n== 2. Setup: Create Test Schema ==\n")
dbExecute(con, paste0("DROP SCHEMA IF EXISTS RSNOWFLAKE.", SCHEMA))
dbExecute(con, paste0("CREATE SCHEMA RSNOWFLAKE.", SCHEMA))

# Reconnect targeting the test schema
con_test <- dbConnect(Snowflake(), name = "rsnowflake_dev",
                      schema = SCHEMA)

# ==========================================================================
cat("\n== 3. Scalar Queries & Type Mapping ==\n")
# ==========================================================================

df <- dbGetQuery(con_test, "
  SELECT
    1::INTEGER          AS int_val,
    3.14::DOUBLE        AS dbl_val,
    'hello world'       AS str_val,
    TRUE                AS bool_val,
    '2024-06-15'::DATE  AS date_val,
    '2024-06-15 10:30:00'::TIMESTAMP_NTZ AS ts_val
")

check("integer column", is.integer(df$INT_VAL) && df$INT_VAL == 1L)
check("double column",  is.numeric(df$DBL_VAL) && abs(df$DBL_VAL - 3.14) < 0.001)
check("string column",  is.character(df$STR_VAL) && df$STR_VAL == "hello world")
check("boolean column", is.logical(df$BOOL_VAL) && isTRUE(df$BOOL_VAL))
check("date column",    inherits(df$DATE_VAL, "Date"))
check("timestamp column", inherits(df$TS_VAL, "POSIXct"))

# NULL handling
df_null <- dbGetQuery(con_test, "SELECT NULL AS n, 1 AS a")
check("NULL returns NA", is.na(df_null$N))

# ==========================================================================
cat("\n== 4. Table Operations ==\n")
# ==========================================================================

test_df <- data.frame(
  id   = 1:5,
  name = c("Alice", "Bob", "Charlie", "Dave", "Eve"),
  score = c(95.5, 87.3, 92.1, 78.9, 88.0),
  active = c(TRUE, FALSE, TRUE, TRUE, FALSE),
  stringsAsFactors = FALSE
)

check("dbWriteTable succeeds", {
  dbWriteTable(con_test, "TEST_TYPES", test_df, overwrite = TRUE)
  TRUE
})

check("dbExistsTable finds it", dbExistsTable(con_test, "TEST_TYPES"))

tables <- dbListTables(con_test)
check("dbListTables includes TEST_TYPES", "TEST_TYPES" %in% tables)

fields <- dbListFields(con_test, "TEST_TYPES")
check("dbListFields returns column names",
      all(c("id", "name", "score", "active") %in% fields))

df_back <- dbReadTable(con_test, "TEST_TYPES")
check("dbReadTable returns 5 rows", nrow(df_back) == 5L)
check("dbReadTable integer roundtrip", identical(sort(df_back$id), 1:5))
check("dbReadTable string roundtrip", "Alice" %in% df_back$name)

check("dbWriteTable append", {
  extra <- data.frame(id = 6L, name = "Frank", score = 91.0, active = TRUE,
                      stringsAsFactors = FALSE)
  dbWriteTable(con_test, "TEST_TYPES", extra, append = TRUE)
  df_all <- dbReadTable(con_test, "TEST_TYPES")
  nrow(df_all) == 6L
})

# ==========================================================================
cat("\n== 5. dbSendQuery / dbFetch / dbClearResult ==\n")
# ==========================================================================

res <- dbSendQuery(con_test, 'SELECT * FROM TEST_TYPES ORDER BY "id"')
check("dbSendQuery returns SnowflakeResult", is(res, "SnowflakeResult"))
check("Result is valid", dbIsValid(res))

chunk <- dbFetch(res)
check("dbFetch returns data.frame", is.data.frame(chunk))
check("dbFetch returns rows", nrow(chunk) >= 5L)

stmt <- dbGetStatement(res)
check("dbGetStatement", grepl("TEST_TYPES", stmt))

col_info <- dbColumnInfo(res)
check("dbColumnInfo", nrow(col_info) == 4L)

dbClearResult(res)
check("Result cleared", !dbIsValid(res))

# ==========================================================================
cat("\n== 6. dbExecute (DML) ==\n")
# ==========================================================================

n <- dbExecute(con_test, 'DELETE FROM TEST_TYPES WHERE "id" = 6')
check("dbExecute DELETE returns affected", n >= 0L)

remaining <- dbGetQuery(con_test, "SELECT COUNT(*) AS cnt FROM TEST_TYPES")
check("Row deleted", remaining$CNT == 5L)

# ==========================================================================
cat("\n== 7. Quoting ==\n")
# ==========================================================================

qid <- dbQuoteIdentifier(con, "my table")
check("dbQuoteIdentifier", grepl('"my table"', as.character(qid)))

qs <- dbQuoteString(con, "it's a test")
check("dbQuoteString", grepl("''", as.character(qs)))

# ==========================================================================
cat("\n== 8. Cleanup ==\n")
# ==========================================================================

dbRemoveTable(con_test, "TEST_TYPES")
check("Table removed", !dbExistsTable(con_test, "TEST_TYPES"))

dbExecute(con, paste0("DROP SCHEMA IF EXISTS RSNOWFLAKE.", SCHEMA))

dbDisconnect(con_test)
dbDisconnect(con)
check("Disconnected", !dbIsValid(con))

# ==========================================================================
cat(sprintf("\n== Results: %d passed, %d failed ==\n", passed, failed))
if (failed > 0) quit(status = 1)
