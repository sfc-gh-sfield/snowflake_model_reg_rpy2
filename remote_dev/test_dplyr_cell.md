# Test dplyr + Snowflake in Workspace Notebook

Copy the R code below into a new cell in your Workspace Notebook.

**Prerequisites:**
1. Run Section 1 (Installation) first
2. Run Section 3.1 (Session Setup) 
3. Run Section 3.3 (Create PAT)

---

## Test Cell (copy this):

```r
%%R
# dplyr + Snowflake Test via adbi
# This demonstrates real dplyr with query pushdown to Snowflake

# Install adbi if needed
if (!requireNamespace("adbi", quietly = TRUE)) {
    install.packages("adbi", repos = "https://cloud.r-project.org", quiet = TRUE)
}

library(adbi)
library(DBI)
library(dplyr)
library(dbplyr)

cat("=== dplyr + Snowflake Test ===\n\n")

# Get credentials
pat <- Sys.getenv("SNOWFLAKE_PAT")
if (pat == "") {
    stop("SNOWFLAKE_PAT not set. Run Section 3.3 first.")
}

# Connect via adbi
uri <- sprintf(
    "user=%s;account=%s;authenticator=SNOWFLAKE_JWT;token=%s;database=SNOWFLAKE_SAMPLE_DATA;schema=TPCH_SF1",
    Sys.getenv("SNOWFLAKE_USER"),
    Sys.getenv("SNOWFLAKE_ACCOUNT"),
    pat
)

con <- dbConnect(adbi::adbi("adbcsnowflake"), uri = uri)
cat("✓ Connected\n\n")

# THE dplyr WAY - no SQL needed!
result <- tbl(con, "CUSTOMER") %>%
    filter(C_MKTSEGMENT == "BUILDING") %>%
    group_by(C_NATIONKEY) %>%
    summarise(
        customers = n(),
        avg_balance = mean(C_ACCTBAL)
    ) %>%
    arrange(desc(customers)) %>%
    head(5) %>%
    collect()

cat("✓ Query pushed to Snowflake, results:\n\n")
print(result)

dbDisconnect(con)
```

---

## Expected Output

```
=== dplyr + Snowflake Test ===

✓ Connected

✓ Query pushed to Snowflake, results:

# A tibble: 5 × 3
  C_NATIONKEY customers avg_balance
        <dbl>     <int>       <dbl>
1          18      1294       4523.
2           3      1282       4504.
3           9      1270       4533.
4          12      1269       4594.
5          21      1268       4465.
```

**Key points:**
- `tbl()` creates a lazy reference (no data fetched)
- `filter()`, `group_by()`, `summarise()` build a query plan
- `collect()` executes the SQL on Snowflake and returns results
- You write dplyr, not SQL!
