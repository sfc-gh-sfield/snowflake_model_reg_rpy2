# Blog 2: R and Snowflake Data Interop -- SQL, dplyr, Snowpark, and DataFrames

**Status:** Planning
**Target length:** ~12-15 min read (~3000-4000 words)
**Companion notebook:** `snowflakeR/inst/notebooks/workspace_quickstart.ipynb` (sections 3-5)
**Draft location:** `drafts/`

---

## Progress Tracker

- [ ] Outline finalised
- [ ] Draft v1 written
- [ ] Code snippets tested in Workspace
- [ ] Screenshots captured
- [ ] Performance benchmarks captured
- [ ] Internal review
- [ ] Draft v2 (post-review)
- [ ] Final review
- [ ] Published to Medium
- [ ] Link added to SERIES_PLAN.md

---

## Key Messages

1. Multiple paths to data: SQL, dplyr pushdown, Snowpark -- choose what fits
2. dplyr + dbplyr gives R users in-database processing at Snowflake scale
3. DataFrames move seamlessly between R, Python, and Snowflake
4. Performance matters: pushdown vs pull patterns

## Target Reader

Same as Blog 1, plus:
- R users familiar with dplyr/tidyverse who want to use it with Snowflake
- Data engineers curious about R as a data transformation tool in Snowflake

---

## Detailed Outline

### Title & Header

Working title: **"R and Snowflake Data Interop -- SQL, dplyr, Snowpark, and DataFrames"**
Alternative: **"Three Ways to Query Snowflake from R (Inside Snowflake)"**

### Disclaimer & Setup

Brief disclaimer + link to Blog 1 for setup.
Include the standard setup cells (from `_shared/code_snippets/standard_setup.md`).

### 1. Introduction (~300 words)

- Recap from Blog 1: we have R running in a Snowflake Workspace
- Now: how do we work with data? Three approaches, each with trade-offs
- This mirrors the approach from my Hex blog, but now from *inside* Snowflake
- **Connection note:** sfr_connection is also a DBI connection, so everything
  in the DBI/dbplyr ecosystem works

### 2. Method 1: SQL from R (~600 words)

**2.1 sfr_query() -- the simplest path**
```r
result <- sfr_query(conn, "SELECT * FROM SFR_MTCARS WHERE cyl = 6")
rview(result, n = 5)
```

**2.2 DBI::dbGetQuery() -- standard R interface**
```r
library(DBI)
result <- DBI::dbGetQuery(conn, "SELECT COUNT(*) AS n FROM SFR_MTCARS")
rprint(result)
```

**2.3 sfr_execute() -- for DDL/DML**
```r
sfr_execute(conn, "CREATE TABLE IF NOT EXISTS ...")
```

**2.4 Fully qualified names with sfr_fqn()**
```r
fqn <- sfr_fqn(conn, "MY_TABLE")  # Returns "DB.SCHEMA.MY_TABLE"
result <- sfr_query(conn, paste("SELECT * FROM", fqn))
```

**When to use SQL:**
- Complex queries with Snowflake-specific functions
- DDL/DML operations
- When you already have SQL you want to reuse
- Maximum performance (no translation layer)

### 3. Method 2: dplyr + dbplyr Pushdown (~1200 words)

**The big win for R users** -- write R, execute in Snowflake.

**3.1 Creating lazy table references**
```r
library(dplyr)
library(dbplyr)

cars_tbl <- tbl(conn, I(sfr_fqn(conn, "SFR_MTCARS")))
```
- Note: `I()` prevents dbplyr from quoting the identifier (G14)

**3.2 Building pipelines**
```r
summary <- cars_tbl |>
  filter(cyl >= 6) |>
  group_by(cyl) |>
  summarise(
    n = n(),
    avg_mpg = mean(mpg, na.rm = TRUE),
    avg_hp = mean(hp, na.rm = TRUE)
  ) |>
  arrange(cyl)
```
- Note: this hasn't executed yet -- lazy evaluation (G15)

**3.3 Seeing the generated SQL**
```r
summary |> show_query()
```
- Show the SQL output, compare with hand-written SQL

**3.4 Materialising results**
```r
result <- summary |> collect()
rprint(result)
```

**3.5 More complex pipeline with joins**
- Demonstrate join, filter, select, mutate -- similar to the Hex blog TPCH example
  but using data available in the Workspace
- Reference back to Hex blog for comparison

**3.6 Performance comparison**
- Time SQL query execution
- Time dplyr-in-R-memory (pull data first, then dplyr)
- Time dplyr-pushdown (dbplyr)
- Show that pushdown is as fast as SQL, and both are much faster than R-memory
  for any significant data volume

**3.7 Translation limitations**
- Not all R functions translate to SQL (G16)
- Show an example that doesn't translate
- show_query() is your friend for debugging

**When to use dplyr pushdown:**
- Exploratory data analysis
- Feature engineering pipelines
- When you prefer R syntax over SQL
- When composability and testability matter

### 4. Method 3: Snowpark DataFrames via reticulate (~500 words)

**When R and SQL aren't enough** -- the escape hatch to Snowpark.

**4.1 Accessing the Snowpark Session**
```r
session <- conn$session  # This is a Python Snowpark Session via reticulate
```

**4.2 Snowpark operations from R**
```r
# Create a Snowpark DataFrame
sp_df <- session$table(sfr_fqn(conn, "SFR_MTCARS"))

# Show schema
sp_df$schema  # via reticulate

# Collect to pandas, then to R
pandas_df <- sp_df$to_pandas()
r_df <- reticulate::py_to_r(pandas_df)
rview(r_df, n = 5)
```

**4.3 When to use Snowpark from R**
- Accessing Snowpark-specific features not yet wrapped in snowflakeR
- Complex multi-step operations that combine SQL, Python, and R
- Building data pipelines that span both languages

### 5. DataFrame Conversion Patterns (~600 words)

**5.1 The conversion landscape**
```
Snowflake Table  ←→  R data.frame
                 ←→  Python pandas DataFrame
                 ←→  Snowpark DataFrame
```

**5.2 R ↔ Snowflake**
```r
# Write R data to Snowflake
sfr_write_table(conn, sfr_fqn(conn, "MY_DATA"), my_df, overwrite = TRUE)

# Read Snowflake table to R
my_df <- sfr_read_table(conn, sfr_fqn(conn, "MY_DATA"))
```

**5.3 R ↔ pandas (via rpy2)**
```r
# This happens internally, but you can do it explicitly:
library(reticulate)
pd <- import("pandas")
pandas_df <- r_to_py(my_r_df)
r_df_back <- py_to_r(pandas_df)
```

**5.4 Internal bridge pattern**
- Brief mention of `.bridge_dict_to_df()` in helpers.R
- Why it exists: avoids NumPy ABI issues (G12)
- Users don't need to worry about this -- it's handled internally

**5.5 Column naming conventions (G11)**
- Snowflake: UPPERCASE
- snowflakeR sfr_query/sfr_read_table: lowercase
- dbplyr: UPPERCASE (matches Snowflake)
- Be consistent in your code

### 6. Output Formatting Helpers (~300 words)

- `rprint(x)` -- clean print for any R object
- `rview(df, n)` -- view data.frame with optional row limit
- `rglimpse(df)` -- tibble-style glimpse
- `rcat(...)` -- clean replacement for cat()
- Why these exist (G02: Workspace Notebook extra line breaks)
- These are part of snowflakeR and also available via r_helpers.py

### 7. Table Management Utilities (~200 words)

```r
sfr_list_tables(conn)
sfr_table_exists(conn, sfr_fqn(conn, "MY_TABLE"))
sfr_list_fields(conn, sfr_fqn(conn, "MY_TABLE"))
```

### 8. Gotchas & Tips (~300 words)

Pull from master list: G02, G03, G08, G09, G11, G12, G13, G14, G15, G16, T02

### 9. Summary & What's Next (~200 words)

What we covered:
- Three methods for data access: SQL, dplyr pushdown, Snowpark
- DataFrame conversion patterns
- Performance guidance: use pushdown for scale

What's next (Blog 3):
- Feature Store integration
- Using SQL and dplyr for feature engineering
- Training data generation with point-in-time correct joins

---

## Key Code References

| Source File | Sections Used |
|-------------|---------------|
| `R/query.R` | Section 2 |
| `R/dbi.R` | Section 2, 3 |
| `R/helpers.R` | Section 5, 6 |
| `inst/notebooks/workspace_quickstart.ipynb` | Sections 3-5 |

---

## Benchmarks Needed

- [ ] SQL query timing (sfr_query)
- [ ] dplyr in-memory timing (pull all data, then dplyr)
- [ ] dplyr pushdown timing (dbplyr collect)
- [ ] Compare at different data sizes if possible

---

## Screenshots Needed

- [ ] dplyr pipeline with show_query() output
- [ ] Performance comparison table/chart
- [ ] dbplyr-generated SQL in Snowsight query history (optional)

---

## Review Notes

*(Add feedback and revision notes here)*
