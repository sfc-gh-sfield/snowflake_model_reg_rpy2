# =============================================================================
# Test Script: DuckDB + Snowflake Integration
# =============================================================================
#
# Run this after setup_r_duckdb_env.sh --full completes
#
# Usage:
#   Rscript test_duckdb_snowflake.R
#
# Or interactively in R:
#   source("test_duckdb_snowflake.R")
#
# =============================================================================

cat("\n========================================\n")
cat(" DuckDB + Snowflake Integration Test\n")
cat("========================================\n\n")

# -----------------------------------------------------------------------------
# Test 1: Load required packages
# -----------------------------------------------------------------------------

cat("Test 1: Loading packages...\n")

packages <- c("DBI", "duckdb", "dplyr", "dbplyr")
for (pkg in packages) {
    if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
        stop(paste("Package not found:", pkg))
    }
    cat(paste("  ✓", pkg, "loaded\n"))
}

cat("\n")

# -----------------------------------------------------------------------------
# Test 2: Connect to DuckDB
# -----------------------------------------------------------------------------

cat("Test 2: Connecting to DuckDB...\n")

con <- dbConnect(duckdb::duckdb(), dbdir = ":memory:")
cat("  ✓ DuckDB connection established\n\n")

# -----------------------------------------------------------------------------
# Test 3: Load Snowflake extension
# -----------------------------------------------------------------------------

cat("Test 3: Loading Snowflake extension...\n")

tryCatch({
    DBI::dbExecute(con, "LOAD snowflake")
    cat("  ✓ Snowflake extension loaded\n\n")
}, error = function(e) {
    cat(paste("  ✗ Failed to load snowflake extension:", e$message, "\n"))
    cat("    Check that ADBC driver is installed and symlinked correctly\n\n")
})

# -----------------------------------------------------------------------------
# Test 4: List available extensions
# -----------------------------------------------------------------------------

cat("Test 4: Checking installed extensions...\n")

extensions <- DBI::dbGetQuery(con, "
    SELECT extension_name, installed, loaded 
    FROM duckdb_extensions() 
    WHERE installed = true
")
print(extensions)
cat("\n")

# -----------------------------------------------------------------------------
# Test 5: Basic DuckDB operations
# -----------------------------------------------------------------------------

cat("Test 5: Basic DuckDB operations...\n")

# Create a test table
DBI::dbExecute(con, "CREATE TABLE test_data AS SELECT * FROM range(10) t(id)")
cat("  ✓ Created test table\n")

# Query with dbplyr
test_tbl <- tbl(con, "test_data")
result <- test_tbl %>%
    filter(id > 5) %>%
    collect()

cat(paste("  ✓ dbplyr query returned", nrow(result), "rows\n\n"))

# -----------------------------------------------------------------------------
# Test 6: Check Snowflake secret syntax (without actual connection)
# -----------------------------------------------------------------------------

cat("Test 6: Testing Snowflake secret syntax...\n")

# This tests that the extension understands the secret syntax
# We don't actually connect (no credentials), just verify syntax works
tryCatch({
    DBI::dbExecute(con, "
        CREATE OR REPLACE SECRET test_secret (
            TYPE snowflake,
            ACCOUNT 'test_account',
            TOKEN 'test_token_placeholder'
        )
    ")
    cat("  ✓ Snowflake secret syntax accepted\n")
    
    # Clean up
    DBI::dbExecute(con, "DROP SECRET test_secret")
    cat("  ✓ Secret cleanup successful\n\n")
}, error = function(e) {
    cat(paste("  ✗ Secret creation failed:", e$message, "\n\n"))
})

# -----------------------------------------------------------------------------
# Test 7: Check httpfs extension (for future Iceberg support)
# -----------------------------------------------------------------------------

cat("Test 7: Loading httpfs extension...\n")

tryCatch({
    DBI::dbExecute(con, "LOAD httpfs")
    cat("  ✓ httpfs extension loaded\n\n")
}, error = function(e) {
    cat(paste("  ✗ Failed to load httpfs:", e$message, "\n\n"))
})

# -----------------------------------------------------------------------------
# Test 8: Check iceberg extension
# -----------------------------------------------------------------------------

cat("Test 8: Loading iceberg extension...\n")

tryCatch({
    DBI::dbExecute(con, "LOAD iceberg")
    cat("  ✓ iceberg extension loaded\n\n")
}, error = function(e) {
    cat(paste("  ✗ Failed to load iceberg:", e$message, "\n\n"))
})

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

dbDisconnect(con, shutdown = TRUE)

cat("========================================\n")
cat(" All tests completed!\n")
cat("========================================\n\n")

cat("Next steps:\n")
cat("  1. Set SNOWFLAKE_ACCOUNT and SNOWFLAKE_PAT environment variables\n")
cat("  2. Create a real Snowflake secret and test querying\n")
cat("  3. Try the dbplyr workflow against Snowflake tables\n\n")
