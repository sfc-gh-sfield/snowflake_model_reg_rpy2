# Contributing to snowflakeR

**Last Updated:** 2026-02-13

Welcome! This guide will help you get set up to contribute to the `snowflakeR`
package. Whether you're adding features, fixing bugs, improving docs, or
writing tests, this document covers what you need to know.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Getting the Code](#getting-the-code)
3. [Repository Structure](#repository-structure)
4. [Development Environment Setup](#development-environment-setup)
5. [Package Architecture](#package-architecture)
6. [Making Changes](#making-changes)
7. [Testing](#testing)
8. [Documentation](#documentation)
9. [Code Style & Standards](#code-style--standards)
10. [Commit & Release Workflow](#commit--release-workflow)
11. [Key Files to Know](#key-files-to-know)

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| R | >= 4.1.0 | Package development |
| Python | >= 3.9 (3.11 recommended) | `snowflake-ml-python` SDK |
| Git | any recent | Version control |
| `devtools` | latest | R package dev workflow |
| `roxygen2` | latest | Documentation generation |
| `testthat` | >= 3.0 | Unit testing |
| `rmarkdown` + `knitr` | latest | Vignette rendering |

Optional but recommended:
- RStudio or Posit Workbench (best R IDE experience)
- `gh` CLI (for sync to public repo)
- A Snowflake account with a Workspace (for integration testing)

## Getting the Code

```bash
# Clone the internal dev repo
git clone git@github.com:sfc-gh-sfield/snowflake_model_reg_rpy2.git
cd snowflake_model_reg_rpy2
```

The R package source lives in `snowflakeR/`. This is what gets synced to
the public `Snowflake-Labs/snowflakeR` repository.

## Repository Structure

```
snowflake_model_reg_rpy2/
├── snowflakeR/                     # The R package (this is what we develop)
│   ├── R/                          # R source files
│   ├── man/                        # Generated .Rd help files (don't edit by hand)
│   ├── inst/                       # Installed files
│   │   ├── notebooks/              # Demo notebooks + setup scripts
│   │   └── python/                 # Python bridge modules
│   ├── vignettes/                  # Package vignettes (long-form docs)
│   ├── tests/                      # Unit tests (testthat)
│   ├── DESCRIPTION                 # Package metadata and dependencies
│   ├── NAMESPACE                   # Generated exports (don't edit by hand)
│   └── TODO.md                     # Known issues and roadmap
├── blog_series/                    # Blog drafts (private)
├── internal/                       # Internal docs, guides, previews
│   ├── devops/                     # This folder: workflows, contributor guide
│   ├── vignette_previews/          # Rendered HTML previews
│   └── *.md                        # Design docs, research notes
├── .github/                        # CI workflows
├── sync_snowflakeR_to_public.sh    # Sync to Snowflake-Labs/snowflakeR
└── DEVELOPMENT.md                  # Legacy dev guide (see devops/ instead)
```

## Development Environment Setup

### 1. Set up the Python environment

```bash
conda create -n r-snowflakeR python=3.11 -y
conda activate r-snowflakeR
pip install snowflake-ml-python snowflake-snowpark-python
```

### 2. Tell R where Python is

Create or edit `~/.Renviron`:

```
RETICULATE_PYTHON=~/.conda/envs/r-snowflakeR/bin/python
```

### 3. Install R dev dependencies

```r
install.packages(c("devtools", "roxygen2", "testthat", "rmarkdown",
                    "knitr", "DBI", "dplyr", "dbplyr", "cli", "rlang",
                    "reticulate"))
```

### 4. Load the package in dev mode

```r
devtools::load_all("snowflakeR")
```

### 5. Verify

```r
library(snowflakeR)
sfr_check_environment()
```

## Package Architecture

`snowflakeR` follows a **bridge pattern**: R functions call Python functions
via `reticulate`, which call the `snowflake-ml-python` SDK.

```
User R code
  → snowflakeR R functions (R/*)
    → reticulate::import() + py_call()
      → Python bridge modules (inst/python/sfr_*_bridge.py)
        → snowflake-ml-python SDK
          → Snowflake Platform
```

Key design principles:
- **Idiomatic R API** — users write R, never Python
- **S3 classes** — `sfr_connection`, `sfr_model`, `sfr_feature_view`, etc.
- **DBI compatibility** — `sfr_connection` works with `DBI::dbGetQuery()` etc.
- **Workspace + Local** — same code works in both environments

See `internal/snowflakeR_package_dev_standards.md` for the full style guide.

## Making Changes

### Adding a new function

1. Create or edit an `.R` file in `snowflakeR/R/`
2. Add roxygen documentation above the function (see existing functions for
   the pattern)
3. Use `@export` if the function should be user-facing
4. If it needs a Python bridge, add/edit the corresponding
   `inst/python/sfr_*_bridge.py`
5. Regenerate docs: `Rscript -e 'roxygen2::roxygenise("snowflakeR")'`
6. Add tests in `tests/testthat/`

### Editing vignettes

1. Edit the `.Rmd` file in `snowflakeR/vignettes/`
2. Re-render previews:
   ```r
   rmarkdown::render("snowflakeR/vignettes/your-vignette.Rmd",
                     output_dir = "internal/vignette_previews")
   ```
3. Check the HTML preview in `internal/vignette_previews/`

### Editing notebooks

1. Edit `.ipynb` files in `snowflakeR/inst/notebooks/`
2. Keep markdown cells informative -- these are user-facing documentation
3. Clear outputs before committing (the sync script does this for the public
   repo, but keep the dev repo clean too)

## Testing

### Running tests

```r
devtools::test("snowflakeR")
```

### Test structure

Tests live in `snowflakeR/tests/testthat/`. They use mock objects for
Snowflake interactions so they can run without a live connection.

### Integration testing

For changes that affect Snowflake interactions, test in a Workspace Notebook:

1. Upload the `snowflakeR/inst/notebooks/` directory to a Workspace
2. Run `setup_r_environment.sh --basic`
3. Install your development version of `snowflakeR`
4. Run through the relevant quickstart/demo notebook

## Documentation

### Three levels of docs

| Level | Location | Purpose |
|---|---|---|
| **Function help** | Roxygen in `R/*.R` → `man/*.Rd` | `?sfr_query`, `?sfr_fqn` |
| **Vignettes** | `vignettes/*.Rmd` | Long-form guides (setup, workspace, etc.) |
| **Notebooks** | `inst/notebooks/*.ipynb` | Runnable demos |

### Roxygen conventions

- Every exported function must have `@param`, `@returns`, `@export`
- Include `@examples` with `\dontrun{}` for anything requiring a connection
- Use `@seealso` to cross-reference related functions
- Run `roxygen2::roxygenise()` after changes -- never edit `.Rd` files by hand

### Vignette previews

After editing vignettes, render HTML previews to `internal/vignette_previews/`
for review. These are committed to the dev repo but not synced to public.

## Code Style & Standards

The full style guide is in `internal/snowflakeR_package_dev_standards.md`.
Key points:

- **Naming:** `sfr_` prefix for all exported functions, `snake_case` throughout
- **S3 classes:** Named lists with class attribute, print methods for all
- **Error handling:** Use `cli::cli_abort()` and `cli::cli_warn()` for
  user-facing messages; `rlang::abort()` for internal errors
- **Dependencies:** Minimise. Core deps: `reticulate`, `cli`, `rlang`. Soft
  deps (Suggests): `DBI`, `dplyr`, `dbplyr`
- **Python bridge:** All Python calls go through `inst/python/sfr_*_bridge.py`
  modules, never called inline from R
- **Pipe:** Use `|>` (base pipe, R >= 4.1), not `%>%`

## Commit & Release Workflow

See `internal/devops/RELEASE_WORKFLOW.md` for the full step-by-step process.

Quick summary:

```bash
# 1. Make changes in snowflakeR/
# 2. Regenerate docs
cd snowflakeR && Rscript -e 'roxygen2::roxygenise()'
cd ..

# 3. Commit to internal repo
git add -A && git commit -m "description"

# 4. Sync to public (dry-run first)
./sync_snowflakeR_to_public.sh --dry-run
./sync_snowflakeR_to_public.sh
```

## Key Files to Know

| File | What it does | When to edit |
|---|---|---|
| `R/connect.R` | Connection management, `sfr_connect()` | Auth changes, new connection types |
| `R/helpers.R` | Output helpers, `sfr_fqn()`, config loading | Utility functions |
| `R/query.R` | `sfr_query()`, `sfr_execute()` | Query execution |
| `R/dbi.R` | DBI method implementations | DBI compatibility |
| `R/registry.R` | Model Registry functions | Model logging, deployment |
| `R/features.R` | Feature Store functions | Feature views, training data |
| `R/rest_inference.R` | REST-based model inference | Direct HTTP prediction |
| `inst/python/sfr_*_bridge.py` | Python bridge modules | When changing Python SDK calls |
| `inst/notebooks/r_helpers.py` | Notebook Python helpers (rpy2 setup, PAT) | Workspace notebook setup |
| `inst/notebooks/setup_r_environment.sh` | R environment installer | Package dependencies, install flow |
| `inst/notebooks/r_packages.yaml` | R package list for setup script | Adding default packages |
| `vignettes/workspace-notebooks.Rmd` | Workspace Notebook guide | Workspace-specific docs |
| `vignettes/setup.Rmd` | Setup & prerequisites guide | Auth, environment setup |
| `DESCRIPTION` | Package metadata | New dependencies, version bumps |
| `TODO.md` | Known issues and roadmap | Bug tracking, feature planning |

---

## Questions?

Reach out to the project maintainer or check the existing docs in `internal/`
for design decisions, research notes, and technical context.
