# Blog 1: Getting R Running in Snowflake Workspaces with rpy2

**Status:** Planning
**Target length:** ~12-15 min read (~3000-4000 words)
**Companion notebook:** `snowflakeR/inst/notebooks/workspace_quickstart.ipynb`
**Draft location:** `drafts/`

---

## Progress Tracker

- [x] Outline finalised
- [x] Draft v1 written (`drafts/draft_v1.md` -- 2026-02-13)
- [ ] Code snippets tested in Workspace
- [ ] Screenshots captured
- [ ] Architecture diagram created
- [ ] Internal review
- [ ] Draft v2 (post-review)
- [ ] Final review
- [ ] Published to Medium
- [ ] Link added to SERIES_PLAN.md

---

## Key Messages

1. R can now run natively inside Snowflake Workspaces thanks to rpy2
2. The `snowflakeR` package makes this seamless -- R users don't write Python
3. Setup is straightforward (and will get simpler as R is pre-installed)
4. This is a passion project / community effort, not yet officially supported

## Target Reader

An R user who:
- Uses Snowflake for their data platform
- Has heard of Snowflake Workspaces but hasn't used R there
- May have read the previous blogs by Kaitlyn/Mats and wondered about easier approaches
- Wants to evaluate whether this is viable for their workflow

---

## Detailed Outline

### Title & Header Image

Working title: **"Getting R Running in Snowflake Workspaces with rpy2"**
Alternative: **"R Meets Snowflake Workspaces: A First-Class Integration with snowflakeR"**

Series subtitle: *Part 1 of "R in Snowflake" -- building an idiomatic R interface
to Snowflake's ML platform*

### Disclaimer Block

> The `snowflakeR` package described in this series is a passion project and is
> not yet officially supported by Snowflake. [Full caveat text from template]

### 1. The R + Snowflake Landscape Today (~500 words)

**Opening hook:** R remains one of the most popular languages for statistical
computing and data science, with a rich ecosystem of packages. Snowflake is
increasingly the data platform of choice. But using R *inside* Snowflake has
always required workarounds.

**What exists today:**
- ODBC/JDBC connections from RStudio, Posit Connect, etc.
- dplyr + dbplyr for SQL pushdown (reference my Hex blog)
- Model export via PMML/ONNX for deployment
- Custom Docker containers (reference Mats' blog)
- Python subprocess wrappers (reference Kaitlyn's blog)

**The gap:** None of these provide an integrated R experience *within*
Snowflake's own compute environment. You could use Snowflake data from R,
or deploy R models to Snowflake with effort, but you couldn't develop and
iterate in R inside Snowflake.

**What changed:** Snowflake Workspaces -- notebook environments running on
Snowpark Container Services -- provide a full Linux container with Python.
Where there's Python, there's a path to R via `rpy2`.

**How I got here:** Reading Kaitlyn's blog about using subprocess to call R from
Python for model serving, I realised that rpy2 and reticulate could provide a
much deeper integration -- not just for model serving, but for the entire
data science workflow. Other colleagues like Mats had also explored running R
in SPCS containers. This inspired the `snowflakeR` package.

### 2. What is rpy2 and Why Does It Matter? (~400 words)

- Brief intro: rpy2 is a mature (15+ years) Python package that embeds a full
  R interpreter within the Python process
- It enables: calling R functions from Python, passing data bidirectionally,
  and using the `%%R` cell magic in Jupyter/IPython notebooks
- **Key insight for Snowflake:** Workspace Notebooks run a Python kernel. With
  rpy2, we get a full R session inside that kernel. Combined with `reticulate`
  (the R-to-Python bridge), we can call the `snowflake-ml-python` SDK from R.

**Architecture diagram** (reference `_shared/images/architecture_diagram.md`):
```
Notebook → Python kernel → rpy2 → R session → snowflakeR → reticulate → snowflake-ml-python → Snowflake
```

**Contrast with alternatives:**
| Approach | Interop | Overhead | Flexibility |
|----------|---------|----------|-------------|
| Subprocess (Kaitlyn) | File-based (CSV) | High (process spawn + serialise) | Per-model scripts |
| Docker/plumber (Mats) | HTTP/JSON | Medium (REST calls) | Per-model containers |
| rpy2/snowflakeR | In-process | Low (shared memory) | Full R environment |

### 3. Setting Up R in a Snowflake Workspace (~800 words)

**Step 1: The install script**
- What `setup_r_environment.sh` does:
  - Installs micromamba (lightweight conda alternative)
  - Creates an isolated `r_env` environment with R and packages
  - Reads `r_packages.yaml` for declarative package management
  - Fixes library symlinks (a container-specific quirk)
- Options: `--basic`, `--adbc`, `--full`
- **Note:** This is currently necessary but will become simpler when R is
  pre-installed in future Workspace runtime images

**Step 2: Configure rpy2**
- `r_helpers.py`: sets PATH, R_HOME, installs rpy2, registers `%%R` magic
- Show the `setup_r_environment()` call and explain what it returns
- Output helpers loaded automatically: `rprint()`, `rview()`, etc.

**Step 3: Install snowflakeR**
- Currently from local source (cloned repo in Workspace)
- Future: `pak::pak("Snowflake-Labs/snowflakeR")` from GitHub
- Show the install cell and explain the dependency chain

**Gotcha callouts:**
- G01: reticulate >= 1.25 required
- G06: Disk space (~2GB needed)
- G07: First-time setup ~3 minutes
- G05: Script is idempotent -- re-run freely

### 4. Quickstart: Hello Snowflake from R (~1200 words)

Walk through the `workspace_quickstart.ipynb` notebook section by section.

**4.1 Connect**
```r
conn <- sfr_connect()
conn <- sfr_load_notebook_config(conn)
conn
```
- Auto-detection of Workspace session
- `notebook_config.yaml` for execution context
- Show the `sfr_connection` print output

**Gotcha callout:** G08 (database/schema not auto-set), G09 (must reassign conn)

**4.2 Query**
```r
result <- sfr_query(conn, "SELECT CURRENT_TIMESTAMP() AS now, CURRENT_USER() AS user_name")
rprint(result)
```

**4.3 Write & Read Data**
```r
sfr_write_table(conn, sfr_fqn(conn, "SFR_MTCARS"), mtcars, overwrite = TRUE)
df <- sfr_read_table(conn, sfr_fqn(conn, "SFR_MTCARS"))
rview(df, n = 5)
```

**4.4 Explore**
```r
tables <- sfr_list_tables(conn)
fields <- sfr_list_fields(conn, sfr_fqn(conn, "SFR_MTCARS"))
```

**4.5 DBI Integration**
```r
library(DBI)
DBI::dbGetQuery(conn, "SELECT 42 AS answer") |> rprint()
DBI::dbExistsTable(conn, sfr_fqn(conn, "SFR_MTCARS"))
```
- Emphasise: sfr_connection IS a DBI connection (T02)

**4.6 dplyr Preview** (brief teaser for Blog 2)
```r
library(dplyr)
library(dbplyr)
cars_tbl <- tbl(conn, I(sfr_fqn(conn, "SFR_MTCARS")))
summary <- cars_tbl |>
  group_by(cyl) |>
  summarise(n = n(), avg_mpg = mean(mpg)) |>
  collect()
rprint(summary)
```

**4.7 Visualisation**
```r
%%R -w 700 -h 450
library(ggplot2)
p <- ggplot(df, aes(x = wt, y = mpg, color = factor(cyl))) +
  geom_point(size = 3) +
  labs(title = "MPG vs Weight by Cylinder Count") +
  theme_minimal()
print(p)
```

**Gotcha callout:** G02 (output formatting), G04 (plots need print() and size params)

### 5. Gotchas & Tips (~300 words)

Dedicated section pulling from the master list:
- G01, G02, G03, G04, G05, G06, G07, G08, G09
- T01, T02, T03

### 6. Summary & What's Next (~200 words)

What we covered:
- rpy2 as the bridge technology
- Environment setup in Workspaces
- Basic Snowflake operations from R
- DBI compatibility
- First taste of dplyr and ggplot2

What's next (Blog 2):
- Deep dive into data interop patterns
- dplyr pushdown for in-database processing
- DataFrame conversions between R and Python
- Performance comparison

---

## Key Code References (for testing/verification)

| Source File | Sections Used |
|-------------|---------------|
| `inst/notebooks/setup_r_environment.sh` | Section 3 |
| `inst/notebooks/r_helpers.py` | Section 3 |
| `inst/notebooks/r_packages.yaml` | Section 3 |
| `inst/notebooks/workspace_quickstart.ipynb` | Section 4 |
| `R/connect.R` | Section 4.1 |
| `R/workspace.R` | Section 4.1 |
| `R/query.R` | Section 4.2 |
| `R/dbi.R` | Section 4.5 |
| `R/helpers.R` | Section 4 (rprint, rview) |

---

## Screenshots Needed

- [ ] Workspace Notebook with R cell running (%%R magic)
- [ ] sfr_connect() output showing connection details
- [ ] ggplot2 chart rendered in Workspace Notebook
- [ ] setup_r_environment.sh running (terminal output)
- [ ] Architecture diagram (polished version)

---

## Review Notes

*(Add feedback and revision notes here as the blog is drafted)*
