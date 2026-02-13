# R in Snowflake -- "First-Class" Integration with snowflakeR

## Blog Series Master Plan

**Author:** Simon Field
**Platform:** Medium (personal publication -- not Snowflake Builders Blog)
**Status:** Planning
**Created:** 2026-02-13
**Last Updated:** 2026-02-13

---

## Important Caveats (Include in Every Blog)

> **Disclaimer:** The `snowflakeR` package described in this series is a passion
> project that gives R users an idiomatic interface to the
> `snowflake-ml-python` SDK and Snowflake's server-side ML capabilities --
> including the Model Registry, Feature Store, and Snowpark -- enabling
> end-to-end ML workflows from R that are fully interoperable with Python.
> It is **not yet officially supported by Snowflake**, but is developed and
> provided to help customers use R within Snowflake Workspaces and Containers,
> and to solicit feedback that will help improve product integration for R users.
> APIs and capabilities may change as the package evolves.

> **Future Simplification:** Some of the installation steps described in Blog 1
> (the `setup_r_environment.sh` script, micromamba, rpy2 pip install) will become
> unnecessary in future Workspace / ML container runtime images when R and key
> dependencies are pre-installed. The install script is designed to be idempotent,
> so it will gracefully skip already-installed components when that happens.

---

## Series Overview & Positioning

### Central Thesis

Previous approaches to running R in Snowflake required either:
- Converting models to other formats like PMML/ONNX
- Manually writing Python `CustomModel` wrappers that call R via subprocess
  ([Kaitlyn Wells' blog](https://medium.com/snowflake/deploying-r-models-in-snowflakes-model-registry-effcf04dd85c))
- Building bespoke Docker containers with plumber REST APIs per model
  ([Mats Stellwall's blog](https://medium.com/snowflake/running-a-r-udf-with-snowpark-container-services-5828d1380066))

The `snowflakeR` package takes a fundamentally different approach -- using **rpy2**
as a direct, in-process bridge between R and Python within Snowflake Workspaces
(and Containers), presenting an **idiomatic R API** that wraps the
`snowflake-ml-python` SDK. R users never have to write Python.

### Inspiration & Prior Art

- **Kaitlyn Wells** -- "Deploying R Models in Snowflake's Model Registry" (Jan 2026)
  - Approach: Python `CustomModel` wrapper + `Rscript` subprocess
  - Inspired the realisation that rpy2 + reticulate could provide a smoother path
- **Mats Stellwall** -- "Running a R UDF with Snowpark Container Services" (Oct 2023)
  - Approach: Docker container with plumber REST API exposed as a UDF
- **Simon Field (me)** -- "Using Hex's new R support with Snowflake" (Jul 2023)
  - Approach: dplyr + dbplyr pushdown from Hex notebooks
  - Establishes writing style and R+Snowflake credibility

### Target Audience

- R users who work with Snowflake and want to do more within the platform
- Data scientists who prefer R but work in organisations using Snowflake
- ML engineers interested in model deployment patterns
- Snowflake practitioners curious about R integration possibilities

### Writing Style (from Hex blog)

- Tutorial-style walkthrough with actual code cells and results
- Explain the "why" before the "how"
- Use performance comparisons and timings to make concrete points
- Acknowledge trade-offs honestly
- Reference prior work and give credit
- Build progressively -- each section builds on the last
- Clear section headers mapping to logical flow
- Include gotchas, tips, and practical workarounds

---

## Blog Schedule

| # | Title | Status | Target Date | Depends On |
|---|-------|--------|-------------|------------|
| 1 | Getting R Running in Snowflake Workspaces with rpy2 | Draft v1 | TBD | -- |
| 2 | R and Snowflake Data Interop -- SQL, dplyr, Snowpark, and DataFrames | Planning | TBD | Blog 1 |
| 3 | Feature Engineering in Snowflake with R -- The Feature Store | Planning | TBD | Blog 2 |
| 4 | Registering and Serving R Models in Snowflake's Model Registry | Planning | TBD | Blog 3 |
| 5 | End-to-End ML with R in Snowflake -- Feature Store to Model Serving | Planning | TBD | Blog 4 |

### Future Blogs (as package evolves)

| Topic | When | Notes |
|-------|------|-------|
| ADBC + DuckDB integration | When adbi/adbcsnowflake ecosystem matures | `--adbc` and `--full` install flags, direct DB access |
| Running snowflakeR in SPCS Containers | When container deployment is fully tested | Beyond Workspaces -- standalone SPCS jobs |
| Local development with snowflakeR | Available now (lower priority) | `local_*.ipynb` notebooks, `connections.toml`, `snowflakeauth` |
| Tidymodels + Snowflake | Future package enhancement | Training tidymodels workflows and registering them |
| Shiny apps on Snowflake | Future | Interactive R apps served via SPCS |

---

## Blog 1: Getting R Running in Snowflake Workspaces with rpy2

**File:** `01_getting_started/`
**Companion notebook:** `snowflakeR/inst/notebooks/workspace_quickstart.ipynb`
**Estimated length:** ~12-15 min read

### Outline

1. **The R + Snowflake Landscape Today**
   - R users have connected via ODBC/JDBC, dbplyr pushdown (reference Hex blog),
     or exported models as PMML/ONNX
   - The gap: no native R runtime inside Snowflake's compute environment
   - What's changed: Snowflake Workspaces provide containerised Linux + Python,
     which gives us a path to R via rpy2

2. **What is rpy2 and Why Does It Matter Here?**
   - Brief intro: mature Python-to-R bridge, embeds R within a Python process
   - Key insight: Workspace Notebooks run a Python kernel; rpy2 enables `%%R` magic
   - Contrast with subprocess approach (Kaitlyn) and Docker REST API approach (Mats)
   - Architecture diagram: Notebook -> Python kernel -> rpy2 -> R -> snowflakeR ->
     reticulate -> snowflake-ml-python SDK
   - **Caveat:** passion project disclaimer

3. **Setting Up R in a Snowflake Workspace**
   - The install script (`setup_r_environment.sh`):
     - micromamba for fast, isolated R installation
     - `r_packages.yaml` for declarative package management
     - Idempotent design with `--force`, `--adbc`, `--full` flags
     - **Future note:** these steps will be simplified when R is pre-installed
   - The `r_helpers.py` module: PATH/R_HOME, rpy2, `%%R` magic
   - Walk through the 3-step setup

4. **Quickstart: Hello Snowflake from R**
   - Walk through `workspace_quickstart.ipynb`:
     - `sfr_connect()` -- auto-detects Workspace session
     - `sfr_load_notebook_config()` -- sets context
     - `sfr_query()` -- SQL -> R data.frames
     - `sfr_write_table()` / `sfr_read_table()` -- round-trip data
     - `sfr_list_tables()`, `sfr_list_fields()` -- exploration
   - DBI integration (`DBI::dbGetQuery(conn, ...)` works)
   - ggplot2 visualisation from Snowflake data

5. **Gotchas & Tips** (dedicated section)
   - See `_shared/GOTCHAS_AND_TIPS.md` for the master list
   - Blog 1 specific: Workspace output formatting, reticulate version, etc.

6. **What's Next** -- tease Blog 2

### Key Code References

- `snowflakeR/inst/notebooks/setup_r_environment.sh`
- `snowflakeR/inst/notebooks/r_helpers.py`
- `snowflakeR/inst/notebooks/r_packages.yaml`
- `snowflakeR/inst/notebooks/workspace_quickstart.ipynb`
- `snowflakeR/R/connect.R`
- `snowflakeR/R/workspace.R`
- `snowflakeR/R/query.R`

---

## Blog 2: R and Snowflake Data Interop

**File:** `02_data_interop/`
**Companion notebook:** `workspace_quickstart.ipynb` (sections 3-4)
**Estimated length:** ~12-15 min read

### Outline

1. **Recap & Setup** (brief, link to Blog 1)

2. **Method 1: SQL from R**
   - `sfr_query()`, `DBI::dbGetQuery()`, `sfr_execute()`
   - Parameterised queries and `sfr_fqn()`

3. **Method 2: dplyr + dbplyr Pushdown**
   - `tbl(conn, I(sfr_fqn(...)))` for lazy references
   - Build pipelines: filter, select, mutate, group_by, summarise, join
   - `show_query()` to see generated SQL
   - `collect()` to materialise
   - Performance comparison: SQL vs R-memory vs pushdown (echo Hex blog)
   - dbplyr translation nuances for Snowflake

4. **Method 3: Snowpark DataFrames via reticulate**
   - `conn$session` is a full Snowpark Session
   - When and why to use Snowpark from R
   - Example: Snowpark DataFrame ops from R

5. **DataFrame Conversion Patterns**
   - R <-> Snowflake tables
   - R <-> pandas (rpy2 pandas2ri)
   - The bridge dict pattern (`.bridge_dict_to_df` in helpers.R)
   - Output helpers: `rprint()`, `rview()`, `rglimpse()`, `rcat()`

6. **Table Management Utilities**

7. **Gotchas & Tips** (Blog 2 specific)

8. **What's Next** -- tease Feature Store

### Key Code References

- `snowflakeR/R/query.R`
- `snowflakeR/R/dbi.R`
- `snowflakeR/R/helpers.R`
- `snowflakeR/inst/notebooks/workspace_quickstart.ipynb` (sections 3-5)

---

## Blog 3: Feature Engineering in Snowflake with R

**File:** `03_feature_store/`
**Companion notebook:** `snowflakeR/inst/notebooks/workspace_feature_store.ipynb`
**Estimated length:** ~12-15 min read

### Outline

1. **Why Feature Store Matters for R Users**
   - Feature engineering maps naturally to SQL/dplyr
   - Point-in-time correctness is hard manually
   - Feature reuse across models/teams

2. **The snowflakeR Feature Store API**
   - `sfr_feature_store(conn, create=TRUE)` -- connect/create
   - Entities: `sfr_create_entity()`, `sfr_list_entities()`, `sfr_get_entity()`
   - Feature Views: `sfr_create_feature_view()` / `sfr_register_feature_view()`
   - Reading/refreshing: `sfr_read_feature_view()`, `sfr_refresh_feature_view()`

3. **Walkthrough: Building Features for a Predictive Model**
   - Define source data (SQL or dplyr)
   - Create entities
   - Create feature views with timestamp columns
   - Register and materialise

4. **Training Data Generation**
   - `sfr_generate_training_data()` -- point-in-time correct joins
   - `sfr_retrieve_features()` -- inference-time lookup
   - Converting to R data.frames

5. **Datasets**
   - `sfr_create_dataset()`, `sfr_read_dataset()` -- versioned snapshots
   - Reproducibility through versioning

6. **Gotchas & Tips** (Blog 3 specific)

7. **What's Next** -- tease Model Registry

### Key Code References

- `snowflakeR/R/features.R`
- `snowflakeR/R/datasets.R`
- `snowflakeR/inst/python/sfr_features_bridge.py`
- `snowflakeR/inst/python/sfr_datasets_bridge.py`
- `snowflakeR/inst/notebooks/workspace_feature_store.ipynb`

---

## Blog 4: Registering and Serving R Models in Snowflake's Model Registry

**File:** `04_model_registry/`
**Companion notebook:** `snowflakeR/inst/notebooks/workspace_model_registry.ipynb`
**Estimated length:** ~15-18 min read (flagship post)

### Outline

1. **The Problem, Revisited**
   - Kaitlyn's approach: manual Python wrapper + subprocess (per model)
   - Mats' approach: Docker container + plumber REST API (per model)
   - snowflakeR approach: `sfr_log_model()` auto-generates everything

2. **Architecture Deep-Dive**
   - How `sfr_log_model()` works:
     - Serialises R model via `saveRDS()`
     - Auto-generates Python `CustomModel` using rpy2
     - Registers with `target_platforms=["SNOWPARK_CONTAINER_SERVICES"]`
     - `conda_dependencies` include `r-base` + model's R packages
   - The `sfr_registry_bridge.py` Python bridge

3. **Walkthrough: Train, Test, Register, Deploy**
   - Train: `lm(mpg ~ wt + hp + cyl, data = mtcars)` -- nothing special
   - Test: `sfr_predict_local()` -- same logic as remote
   - Register: `sfr_log_model()` -- one function call
   - Manage: `sfr_show_models()`, versions, metrics
   - Deploy: `sfr_deploy_model()` -- compute pool + image repo + service
   - Inference: `sfr_predict()` via SPCS
   - REST inference: `sfr_predict_rest()` -- direct HTTP, no rpy2 overhead

4. **Model Versioning & Lifecycle**
   - `sfr_set_default_model_version()`
   - `sfr_undeploy_model()`, `sfr_delete_model()`
   - Metrics: `sfr_set_model_metric()`, `sfr_show_model_metrics()`

5. **Advanced: Custom Predict Code**

6. **Comparison Table**
   - subprocess vs plumber/SPCS vs snowflakeR/rpy2
   - Pros/cons honestly stated

7. **Gotchas & Tips** (Blog 4 specific)

8. **What's Next** -- end-to-end pipeline

### Key Code References

- `snowflakeR/R/registry.R`
- `snowflakeR/R/rest_inference.R`
- `snowflakeR/R/admin.R`
- `snowflakeR/inst/python/sfr_registry_bridge.py`
- `snowflakeR/inst/notebooks/workspace_model_registry.ipynb`

---

## Blog 5: End-to-End ML with R in Snowflake

**File:** `05_end_to_end/`
**Companion notebooks:** feature store + model registry notebooks
**Estimated length:** ~12-15 min read

### Outline

1. **The Full Pipeline**
   - Data exploration -> feature engineering -> training data -> model training ->
     local test -> registration -> deployment -> inference
   - Realistic example (not mtcars)

2. **Feature Store + Model Registry Together**
   - From `workspace_feature_store.ipynb` Section 7 ("End-to-End")

3. **SPCS Administration from R**
   - `sfr_create_compute_pool()`, `sfr_create_image_repo()`, `sfr_create_eai()`
   - Monitoring: service status, benchmarking

4. **Monitoring & Observability**
   - `sfr_benchmark_inference()`, `sfr_benchmark_rest()`
   - Service endpoint management

5. **Gotchas & Tips** (Blog 5 specific)

6. **Series Wrap-Up & What's Coming**
   - Package roadmap
   - Call for feedback
   - Links to repo and all notebooks

### Key Code References

- All R source files
- All notebooks
- `snowflakeR/inst/python/sfr_admin_bridge.py`

---

## Folder Structure

```
blog_series/
├── SERIES_PLAN.md                    # This file -- master plan
├── _shared/
│   ├── GOTCHAS_AND_TIPS.md           # Master list of gotchas/tips (all blogs)
│   ├── templates/
│   │   └── blog_template.md          # Standard blog post template
│   ├── images/
│   │   └── architecture_diagram.md   # Shared architecture diagrams (mermaid/text)
│   └── code_snippets/
│       └── standard_setup.md         # The 3-cell setup snippet for Blogs 2-5
├── 01_getting_started/
│   ├── OUTLINE.md                    # Detailed outline for this blog
│   ├── drafts/                       # Draft versions
│   ├── images/                       # Screenshots, diagrams
│   ├── code_snippets/                # Extracted code for the blog
│   └── review_notes/                 # Feedback and revision notes
├── 02_data_interop/
│   ├── OUTLINE.md
│   ├── drafts/
│   ├── images/
│   ├── code_snippets/
│   └── review_notes/
├── 03_feature_store/
│   ├── OUTLINE.md
│   ├── drafts/
│   ├── images/
│   ├── code_snippets/
│   └── review_notes/
├── 04_model_registry/
│   ├── OUTLINE.md
│   ├── drafts/
│   ├── images/
│   ├── code_snippets/
│   └── review_notes/
└── 05_end_to_end/
    ├── OUTLINE.md
    ├── drafts/
    ├── images/
    ├── code_snippets/
    └── review_notes/
```

---

## Working Process

1. **For each blog:**
   - Start with the `OUTLINE.md` in the blog's folder
   - Draft in `drafts/draft_v1.md`, iterate to `draft_v2.md`, etc.
   - Extract code snippets that need testing into `code_snippets/`
   - Capture screenshots/diagrams in `images/`
   - Record feedback in `review_notes/`

2. **Cross-blog consistency:**
   - All gotchas go into `_shared/GOTCHAS_AND_TIPS.md` first, then
     relevant ones are pulled into each blog
   - Use `_shared/templates/blog_template.md` for consistent structure
   - Use `_shared/code_snippets/standard_setup.md` for the setup cells in Blogs 2-5

3. **Memory/continuity across sessions:**
   - Update this `SERIES_PLAN.md` with progress, decisions, and status changes
   - Each blog's `OUTLINE.md` tracks that blog's specific progress
   - `review_notes/` captures decisions that affect future blogs

---

## Revision Log

| Date | Change |
|------|--------|
| 2026-02-13 | Initial plan created. Folder structure established. |
| 2026-02-13 | Blog 1 draft v1 written. All code snippets verified against source. |
| 2026-02-13 | Series title updated: "First-Class" in quotes per author direction. |
