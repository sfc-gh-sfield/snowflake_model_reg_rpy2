# Gotchas, Hints & Tips -- Master Reference

This is the master list of known issues, workarounds, and tips discovered during
development. Each blog should pull relevant items from here into its own
"Gotchas & Tips" section.

**Last Updated:** 2026-02-13

---

## Environment & Installation

### G01: reticulate Version Must Be >= 1.25

**Affects:** Blog 1 (setup)
**Symptom:** Segfault when rpy2 and reticulate are both loaded in the same process.
**Cause:** Older versions of the R `reticulate` package have a bug that conflicts
with rpy2's R embedding. Fixed in reticulate >= 1.25 (PR #1188).
**Fix:** The `r_packages.yaml` specifies `r-reticulate>=1.25`. If you see the warning
_"The R package 'reticulate' only fixed recently an issue that caused a segfault
when used with rpy2"_, ensure the correct version is installed.
**Reference:** `r_packages.yaml` line: `r-reticulate>=1.25`

### G02: Workspace Notebook Output Formatting (Extra Line Breaks)

**Affects:** Blog 1, Blog 2
**Symptom:** R output in Workspace Notebook cells has excessive blank lines between
each line of output, making tables and multi-line output hard to read.
**Cause:** The Workspace Notebook rendering layer adds extra `<br>` tags to R cell
output from rpy2.
**Fix:** Use the `rprint()`, `rview()`, `rglimpse()`, and `rcat()` helper functions
from the `snowflakeR` package (or from `r_helpers.py`). These use
`writeLines(capture.output(...))` to produce clean single-pass output.
**Example:**
```r
# Bad (extra line breaks):
print(mtcars)

# Good (clean output):
rprint(mtcars)
rview(mtcars, n = 5)
```

### G03: %%R Cell Magic Width

**Affects:** Blog 1, Blog 2
**Symptom:** R output is truncated or wraps awkwardly in notebook cells.
**Fix:** The `setup_r_environment()` Python helper automatically sets
`options(width = 200)` and `options(tibble.width = Inf)`. You can adjust with:
```python
from r_helpers import set_r_console_width
set_r_console_width(150)
```

### G04: %%R Plot Display Requires print() and Size Parameters

**Affects:** Blog 1 (ggplot2 section)
**Symptom:** ggplot2 plots don't display in Workspace Notebooks, or display too
small/large.
**Fix:** Use `%%R -w WIDTH -h HEIGHT` magic parameters and explicitly call `print(p)`
on the plot object. Without `print()`, the plot object is returned silently.
```r
%%R -w 700 -h 450
library(ggplot2)
p <- ggplot(df, aes(x = wt, y = mpg)) + geom_point()
print(p)  # Required!
```

### G05: Install Script Is Idempotent -- Re-run Freely

**Affects:** Blog 1
**Tip:** The `setup_r_environment.sh` script checks what's already installed and
skips those steps. You can re-run it safely to add packages (edit `r_packages.yaml`
first) or upgrade. Use `--force` to reinstall everything from scratch.
**Future:** Many of these installation steps will become unnecessary when R and rpy2
are pre-installed in future Workspace runtime images.

### G06: Disk Space in Workspaces

**Affects:** Blog 1
**Symptom:** Installation fails with cryptic errors.
**Cause:** The R + tidyverse installation requires ~2GB of disk space. Workspace
Notebooks have limited local storage.
**Fix:** The install script checks for minimum disk space (2GB) before proceeding.
If you're low on space, clean up previous installs or temporary files. The script
also runs pre-flight checks for disk space and network connectivity.

### G07: First-Time Setup Takes ~3 Minutes

**Affects:** Blog 1
**Tip:** The initial R environment setup (micromamba + R + packages) takes around
3 minutes. Subsequent runs (after Workspace restart) are faster as micromamba
caches packages. If the Workspace container is recycled, you'll need to re-run
the setup.

---

## Connection & Authentication

### G08: Workspace Notebooks Don't Auto-Set Database/Schema

**Affects:** Blog 1, Blog 2
**Symptom:** Queries fail with "object does not exist" errors even though the
table is in the expected database/schema.
**Cause:** Unlike Snowsight worksheets, Workspace Notebooks don't automatically
set the database and schema context. The Snowpark session starts with whatever
the default is (often nothing).
**Fix:** Use `sfr_load_notebook_config(conn)` which reads `notebook_config.yaml`
and runs `USE WAREHOUSE/DATABASE/SCHEMA`. Or use `sfr_use(conn, database=..., schema=...)`.
Always use `sfr_fqn(conn, "TABLE_NAME")` to generate fully qualified table names.
**Example:**
```r
conn <- sfr_connect()
conn <- sfr_load_notebook_config(conn)  # Sets context from YAML
# OR
conn <- sfr_use(conn, database = "MY_DB", schema = "MY_SCHEMA")
```

### G09: sfr_use() Returns a New Object -- Must Reassign

**Affects:** Blog 1, Blog 2
**Symptom:** After calling `sfr_use(conn, schema = "NEW")`, the connection still
shows the old schema.
**Cause:** R is pass-by-value. `sfr_use()` returns a new, updated connection object.
**Fix:** Always reassign: `conn <- sfr_use(conn, schema = "NEW")`

### G10: PAT Tokens Expire

**Affects:** Blog 4 (REST inference)
**Symptom:** REST inference calls fail with 401 Unauthorized after some time.
**Cause:** Programmatic Access Tokens (PATs) have a configurable expiry
(default: 1 day).
**Fix:** Use `PATManager` from `r_helpers.py` with `refresh_if_needed()` for
long-running sessions. For blog demos, a 1-day PAT is usually sufficient.

---

## Data & DataFrames

### G11: Column Name Case Sensitivity

**Affects:** Blog 2, Blog 3
**Symptom:** Column names don't match between R and Snowflake queries.
**Cause:** Snowflake returns column names in UPPERCASE by default. R is
case-sensitive. The bridge helper `.bridge_dict_to_df()` lowercases column
names by default.
**Fix:** Be aware of the case convention. `sfr_read_table()` and `sfr_query()`
return lowercase column names. When using `dplyr` with `dbplyr`, column names
remain in Snowflake's case (usually UPPER). Use consistent casing in your code.
```r
# Via sfr_query -- lowercase
df <- sfr_query(conn, "SELECT MPG, WT FROM MY_TABLE")
# Column names: mpg, wt

# Via dbplyr -- uppercase
cars_tbl <- tbl(conn, I(sfr_fqn(conn, "MY_TABLE")))
# Column names: MPG, WT
```

### G12: NumPy ABI Mismatch with reticulate

**Affects:** Blog 2 (internal detail, mention briefly)
**Symptom:** Errors when converting Snowpark DataFrames to R via pandas.
**Cause:** NumPy 1.x/2.x ABI mismatch between the Workspace Python environment
and reticulate's expectations.
**Fix:** The `snowflakeR` bridge uses `Series.tolist()` to convert numpy arrays
to native Python types before passing to R, avoiding the ABI issue entirely.
This is handled internally -- users don't need to do anything.

### G13: Large Result Sets -- Use Pushdown, Not Pull

**Affects:** Blog 2
**Tip:** For large datasets, prefer `dplyr` + `dbplyr` pushdown (process in
Snowflake) over `sfr_read_table()` or `collect()` which pulls everything into
R memory. The Workspace Notebook has limited RAM. As demonstrated in the Hex
blog, SQL-in-Snowflake can be 10x+ faster than pulling data to R for processing.

---

## dplyr / dbplyr

### G14: Fully Qualified Table Names with I()

**Affects:** Blog 2
**Symptom:** `tbl(conn, "DB.SCHEMA.TABLE")` fails or interprets the name
incorrectly.
**Fix:** Use `I()` to prevent dbplyr from quoting the identifier:
```r
cars_tbl <- tbl(conn, I(sfr_fqn(conn, "SFR_MTCARS")))
```
Without `I()`, dbplyr may double-quote the entire string as a single identifier.

### G15: dplyr Lazy Evaluation -- collect() Triggers Execution

**Affects:** Blog 2
**Tip:** dplyr operations on database tibbles are lazy -- they build up a SQL
query but don't execute until `collect()` (or `compute()`, `as.data.frame()`) is
called. This is powerful for composing complex queries, but means timings on
individual dplyr steps will be near-zero. Time the `collect()` call for accurate
performance measurement.

### G16: Not All R Functions Translate to SQL

**Affects:** Blog 2
**Symptom:** dplyr pipeline errors with "unknown function" or produces incorrect SQL.
**Cause:** `dbplyr` can only translate a subset of R functions to SQL. Complex R
expressions or custom functions won't translate.
**Fix:** Check `show_query()` to see the generated SQL. For untranslatable
operations, `collect()` first and then apply R functions locally. See
`vignette("translation-function", package = "dbplyr")` for the list of
supported translations.

---

## Feature Store

### G17: Feature View Registration Is a Two-Step Process

**Affects:** Blog 3
**Tip:** Mirroring the Python API, creating a feature view is two steps:
1. `fv <- sfr_create_feature_view(...)` -- creates the definition
2. `fv <- sfr_register_feature_view(fs, fv)` -- registers it in the Feature Store

Or use the convenience one-liner: `sfr_feature_view(...)`.

### G18: Timestamp Columns Required for Point-in-Time Joins

**Affects:** Blog 3
**Symptom:** Training data generation fails or produces incorrect results.
**Cause:** Feature views need a timestamp column for point-in-time correct joins.
**Fix:** Always specify the `timestamp_col` parameter when creating feature views
that will be used with `sfr_generate_training_data()`.

---

## Model Registry

### G19: Model Deployment Takes 5-10 Minutes (First Time)

**Affects:** Blog 4
**Tip:** The first deployment of a model to SPCS involves building a container
image, which takes 5-10 minutes. Subsequent deployments of new versions to the
same service are faster. Use `sfr_wait_for_service()` or `sfr_get_service_status()`
to monitor progress.

### G20: Conda Dependencies Must Include R Packages

**Affects:** Blog 4
**Symptom:** Model prediction fails in SPCS with "package not found" errors.
**Cause:** The SPCS container environment needs to have the R packages your model
depends on. These must be specified as conda dependencies when logging the model.
**Fix:** When calling `sfr_log_model()`, specify `conda_dependencies` including
`r-base` and any R packages your model uses:
```r
sfr_log_model(reg, model, "MY_MODEL",
  conda_dependencies = c("r-base>=4.1", "r-forecast", "r-tidyverse"),
  ...)
```

### G21: REST Inference Bypasses rpy2 -- Lower Latency

**Affects:** Blog 4
**Tip:** For production inference, `sfr_predict_rest()` calls the SPCS HTTP
endpoint directly from R using `httr2`, completely bypassing the rpy2/Python
bridge. This gives lower latency and avoids the known `basic_string::substr`
C++ crash that can occur in some Workspace Notebook environments when using
the Python-bridged inference path.

### G22: Local Testing Before Deployment

**Affects:** Blog 4
**Tip:** Always test with `sfr_predict_local()` before registering. This runs
the exact same prediction logic that will execute in Snowflake, entirely in R.
It validates that your model, predict function, and data types all work correctly.

---

## Performance & Data Transfer

### G23: Large Dataset Transfer -- Arrow IPC Path (Future)

**Affects:** Blog 2, Blog 5
**Context:** Currently, data transfer between Python (Snowpark DataFrames) and R
goes through a `Series.tolist()` path that converts numpy arrays to Python lists
before passing to R via reticulate. This avoids a NumPy ABI crash but involves
copying every value.
**Impact:** For moderate result sets (< 100K rows), this is fine. For large datasets,
it can be slow.
**Future fix:** An Apache Arrow IPC transfer path is on the roadmap
(`pyarrow.Table.from_pandas()` -> Arrow IPC -> `arrow::read_ipc_stream()` in R).
This would be significantly faster for large datasets.
**Current workaround:** For large data, prefer dplyr pushdown (`collect()` only the
result) or use `sfr_query()` which returns smaller result sets. Avoid pulling
entire large tables into R when possible (G13).
**Reference:** `snowflakeR/TODO.md`

### G24: basic_string::substr C++ Crash in Workspace Notebooks

**Affects:** Blog 4 (model inference)
**Symptom:** C++ exception `basic_string::substr` when running model inference
through the Python bridge (reticulate/rpy2) in some Workspace Notebook environments.
**Cause:** Large strings crossing the rpy2/reticulate boundary can trigger a C++
string handling bug.
**Fix:** Use `sfr_predict_rest()` for inference instead of `sfr_predict()`. The REST
path bypasses the Python bridge entirely, calling the SPCS endpoint directly from
R via `httr2`. This is both more reliable and lower latency.
**Reference:** `snowflakeR/R/rest_inference.R` (lines 6-8), `snowflakeR/R/registry.R` (line 367)

### G25: Workspace Container Recycling

**Affects:** Blog 1
**Symptom:** R environment is gone after returning to a Workspace after some time.
**Cause:** Workspace containers may be recycled after periods of inactivity. The
micromamba R environment is installed to local storage which doesn't persist.
**Fix:** Re-run `!bash setup_r_environment.sh --basic`. The script is idempotent and
will be faster on subsequent runs as micromamba caches some packages. The
snowflakeR package install cell also needs to be re-run.
**Tip:** Consider adding the setup cells to a "run on open" workflow if your
Workspace supports it.

### G26: install.packages() in Notebooks -- Suppress Prompts and Noise

**Affects:** Blog 1
**Symptom:** `install.packages()` hangs forever, or floods the notebook cell
with pages of compiler output and startup banners.
**Cause:** Workspace Notebooks have no interactive stdin, so any prompt blocks
indefinitely. There are at least two prompts to watch for: the CRAN mirror
selection prompt, and the "install from sources?" prompt when R detects that a
binary isn't available (Linux containers don't get CRAN binaries). Source
compilation also generates very verbose output.
**Fix:** Use this pattern:
```r
options(repos = c(CRAN = "https://cloud.r-project.org"))
install.packages("forecast", type = "source", quiet = TRUE)
suppressPackageStartupMessages(library(forecast))
```
- `options(repos = ...)` -- suppresses the mirror selection prompt
- `type = "source"` -- suppresses the "binary vs source" prompt
- `quiet = TRUE` -- suppresses compilation chatter (compiler flags, warnings,
  progress)
- `suppressPackageStartupMessages()` -- suppresses startup banners from
  `library()`

For `pak::pak()`, use `ask = FALSE, upgrade = FALSE` to suppress its own
interactive prompts.

Our setup cells set the repos option automatically, but ad-hoc cells need it
explicitly.
**Tip -- R package deps vs system deps:** R package dependencies (other R
packages) are handled automatically by `install.packages()`. However, packages
with compiled code may depend on system-level C/C++ libraries (e.g., `sf` needs
`libgdal`, `curl` needs `libcurl-dev`). If those shared libraries aren't in the
container, compilation fails with "library not found" errors, and you don't have
root/`apt-get` to install them. **Use conda-forge packages for anything with
system library dependencies** -- conda-forge bundles the required system
libraries alongside the R package.

**Tip -- Source compilation is slow:** Even when system deps are satisfied,
packages with C/C++/Fortran code compile from source on the Linux container,
which is slower than on your desktop. conda-forge provides pre-compiled
binaries, making install much faster.

**Tip -- Persistence:** Packages installed interactively don't persist across
container recycles; add them to `r_packages.yaml` for automatic reinstallation.

---

## General Tips

### T01: Notebook Config YAML

**Tip:** Copy `notebook_config.yaml.template` to `notebook_config.yaml` and edit
it with your warehouse, database, and schema. This file is `.gitignore`d so your
credentials/settings don't get committed.

### T02: The snowflakeR Connection Object Is a DBI Connection

**Tip:** The `sfr_connection` object inherits from `DBIConnection`, so standard
DBI functions work directly: `dbGetQuery(conn, sql)`, `dbExistsTable(conn, name)`,
`dbListTables(conn)`, etc. You don't have to choose between snowflakeR functions
and DBI -- use whichever feels more natural.

### T03: Check the Environment

**Tip:** If things aren't working, run `sfr_check_environment(conn)` for diagnostics,
or use the Python-side `check_environment()` from `r_helpers.py` for a comprehensive
environment report.

### T04: Package Updates

**Tip:** To update the `snowflakeR` package in a Workspace, re-run the install cell:
```r
try(remove.packages("snowflakeR"), silent = TRUE)
install.packages(Sys.getenv("SNOWFLAKER_PATH"), repos = NULL, type = "source")
library(snowflakeR)
```
The `try(remove.packages(...))` ensures a clean install even if the package was
previously loaded.

---

## Index by Blog

### Blog 1: Getting Started
G01, G02, G03, G04, G05, G06, G07, G08, G09, G26, T01, T03

### Blog 2: Data Interop
G02, G03, G08, G09, G11, G12, G13, G14, G15, G16, T02

### Blog 3: Feature Store
G08, G11, G17, G18

### Blog 4: Model Registry
G10, G19, G20, G21, G22, T04

### Blog 5: End-to-End
All of the above as a summary reference, plus G23, G24, G25
