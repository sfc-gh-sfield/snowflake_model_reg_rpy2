# Test script: dplyr with adbi in Workspace Notebook
# Copy this to a cell in your Workspace Notebook and run it
#
# This tests if adbi + dbplyr enables true dplyr workflows with Snowflake

# ============================================================
# CELL 1: Install adbi (run once)
# ============================================================
"""
%%R
# Install adbi if needed
if (!requireNamespace("adbi", quietly = TRUE)) {
    install.packages("adbi", repos = "https://cloud.r-project.org", quiet = TRUE)
    cat("✓ adbi installed\n")
} else {
    cat("✓ adbi already installed\n")
}

# Check required packages
packages <- c("adbi", "DBI", "dplyr", "dbplyr", "adbcsnowflake")
for (pkg in packages) {
    if (requireNamespace(pkg, quietly = TRUE)) {
        cat(sprintf("✓ %s available\n", pkg))
    } else {
        cat(sprintf("✗ %s NOT available\n", pkg))
    }
}
"""

# ============================================================
# CELL 2: Create PAT if needed (run Section 3.3 in notebook)
# ============================================================

# ============================================================
# CELL 3: Test dplyr connection
# ============================================================
"""
%%R
library(adbi)
library(DBI)
library(dplyr)
library(dbplyr)

cat("Testing dplyr + Snowflake via adbi...\n\n")

# Get credentials from environment
pat <- Sys.getenv("SNOWFLAKE_PAT")
user <- Sys.getenv("SNOWFLAKE_USER")
account <- Sys.getenv("SNOWFLAKE_ACCOUNT")

if (pat == "" || user == "" || account == "") {
    cat("⚠ Missing environment variables:\n")
    if (pat == "") cat("  - SNOWFLAKE_PAT (run Section 3.3)\n")
    if (user == "") cat("  - SNOWFLAKE_USER\n")
    if (account == "") cat("  - SNOWFLAKE_ACCOUNT\n")
    stop("Cannot proceed without credentials")
}

# Build connection URI
uri <- sprintf(
    "user=%s;account=%s;authenticator=SNOWFLAKE_JWT;token=%s;database=SNOWFLAKE_SAMPLE_DATA;schema=TPCH_SF1",
    user, account, pat
)

# Connect
tryCatch({
    con <- dbConnect(adbi::adbi("adbcsnowflake"), uri = uri)
    cat("✓ Connected to Snowflake!\n\n")
    
    # Test 1: Simple lazy query
    cat("TEST 1: Create lazy table reference\n")
    customers <- tbl(con, "CUSTOMER")
    cat("  Class:", class(customers)[1], "\n")
    cat("  ✓ Lazy reference created (no query yet)\n\n")
    
    # Test 2: Build dplyr pipeline
    cat("TEST 2: Build dplyr pipeline\n")
    query <- customers %>%
        filter(C_MKTSEGMENT == "BUILDING") %>%
        group_by(C_NATIONKEY) %>%
        summarise(
            count = n(),
            avg_balance = mean(C_ACCTBAL, na.rm = TRUE)
        ) %>%
        arrange(desc(count)) %>%
        head(5)
    
    cat("  Generated SQL:\n")
    sql <- dbplyr::sql_render(query)
    cat("  ", substr(as.character(sql), 1, 200), "...\n\n")
    
    # Test 3: Execute with collect()
    cat("TEST 3: Execute query (collect)\n")
    result <- collect(query)
    cat("  ✓ Query executed on Snowflake\n")
    cat("  Returned", nrow(result), "rows:\n\n")
    print(result)
    
    # Cleanup
    dbDisconnect(con)
    cat("\n✓ All tests passed! dplyr works with Snowflake.\n")
    
}, error = function(e) {
    cat("\n✗ Error:", conditionMessage(e), "\n")
    cat("\nTroubleshooting:\n")
    cat("  - Verify PAT is valid\n")
    cat("  - Check adbcsnowflake is installed\n")
    cat("  - Ensure network access to Snowflake\n")
})
"""

# ============================================================
# EXPECTED OUTPUT (success):
# ============================================================
"""
Testing dplyr + Snowflake via adbi...

✓ Connected to Snowflake!

TEST 1: Create lazy table reference
  Class: tbl_AdbiConnection 
  ✓ Lazy reference created (no query yet)

TEST 2: Build dplyr pipeline
  Generated SQL:
   SELECT "C_NATIONKEY", COUNT(*) AS "count", AVG("C_ACCTBAL") AS "avg_balance"
   FROM "CUSTOMER" WHERE ("C_MKTSEGMENT" = 'BUILDING') GROUP BY "C_NATIONKEY"
   ORDER BY "count" DESC LIMIT 5

TEST 3: Execute query (collect)
  ✓ Query executed on Snowflake
  Returned 5 rows:

# A tibble: 5 × 3
  C_NATIONKEY count avg_balance
        <dbl> <int>       <dbl>
1          18  1294       4523.
2           3  1282       4504.
...

✓ All tests passed! dplyr works with Snowflake.
"""
