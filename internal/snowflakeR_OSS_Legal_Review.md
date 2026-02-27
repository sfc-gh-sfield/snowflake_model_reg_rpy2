# snowflakeR -- Open Source Legal Review Document

**Package:** snowflakeR
**Version:** 0.1.0
**License:** Apache License 2.0 (Copyright 2026 Snowflake Inc.)
**Repository:** https://github.com/Snowflake-Labs/snowflakeR
**Target Distribution:** CRAN (Comprehensive R Archive Network)
**Author / Maintainer:** Simon Field (simon.field@snowflake.com)
**Copyright Holder:** Snowflake Inc.
**Date:** February 2026

## 1. Package Overview

snowflakeR is an R package that provides an idiomatic R interface to the
Snowflake ML platform. It enables R users to interact with Snowflake's
Model Registry, Feature Store, Datasets, and data connectivity services
from both local R environments (RStudio, VS Code, terminal) and Snowflake
Workspace Notebooks.

The package does not contain any proprietary algorithms or Snowflake
intellectual property. It is a **client-side wrapper** that translates R
function calls into calls to Snowflake's existing public Python SDK
(`snowflake-ml-python`) via the `reticulate` R-Python bridge, and makes
direct HTTP calls to Snowflake's public REST APIs via the `httr2` R
package. All server-side processing happens within the customer's
Snowflake account.

### 1.1 What snowflakeR Does

| Module | Functionality |
|---|---|
| **Connect** | Establishes a Snowpark session using `connections.toml`, key-pair auth, or Workspace auto-detect |
| **Query & DBI** | Executes SQL, reads/writes tables, provides DBI/dbplyr compatibility for dplyr workflows |
| **Model Registry** | Logs R models (lm, glm, randomForest, xgboost, etc.) to Snowflake's Model Registry, deploys to SPCS, runs inference |
| **Feature Store** | Creates entities and feature views, generates training data, retrieves features at inference time |
| **Datasets** | Creates versioned, immutable dataset snapshots for reproducible ML |
| **Admin** | Manages compute pools, image repositories, and external access integrations |
| **REST Inference** | Direct HTTP inference to SPCS model endpoints (bypasses Python bridge for lower latency) |
| **Workspace** | Setup helpers for Snowflake Workspace Notebook environments enabling R development and code execution within a Workspace Notebook|

### 1.2 Architecture

```
R User Code
    |
    v
snowflakeR  (R package -- Apache-2.0)
    |
    +--> reticulate (R-Python bridge -- Apache-2.0)
    |       |
    |       v
    |    Python bridge modules (inst/python/*.py -- part of snowflakeR)
    |       |
    |       v
    |    snowflake-ml-python  (Snowflake SDK -- Apache-2.0)
    |       |
    |       v
    |    Snowflake Service (customer's account)
    |
    +--> httr2 (R HTTP client -- MIT)
            |
            v
         SPCS REST API (Snowflake's public model serving endpoint)
```

All code in the package is original work authored by Snowflake employees.
No third-party code has been copied or vendored into the repository.

## 2. Repository Structure (Public)

The public repository at `Snowflake-Labs/snowflakeR` contains only the
following. The repository follows the required structure required for submission to CRAN.  R's public package repository.  All internal development notes, personal configuration, and
integration tests with account-specific details are excluded by a synchronisation
devops process from the development repository.

```
snowflakeR/                     (public repo root)
├── DESCRIPTION                 Package metadata, dependencies, license declaration
├── LICENSE                     Apache-2.0 full text
├── NAMESPACE                   Exported/imported R symbols
├── README.md                   Public documentation
├── TODO.md                     Public roadmap
├── .Rbuildignore               Files excluded from R CMD build
├── .gitignore                  Git ignore patterns (includes secrets protection)
├── R/                          R source code (13 files)
│   ├── connect.R               Session management
│   ├── query.R                 SQL execution
│   ├── registry.R              Model Registry wrappers
│   ├── features.R              Feature Store wrappers
│   ├── datasets.R              Dataset wrappers
│   ├── admin.R                 Admin operations
│   ├── rest_inference.R        Direct REST inference (pure R, no Python)
│   ├── dbi.R                   DBI generics implementation
│   ├── helpers.R               Output helpers and utilities
│   ├── python_deps.R           Python dependency installer
│   ├── workspace.R             Workspace setup helpers
│   ├── snowflakeR-package.R    Package-level roxygen
│   └── zzz.R                   Load/attach hooks
├── inst/
│   ├── python/                 Python bridge modules (5 files)
│   │   ├── sfr_connect_bridge.py
│   │   ├── sfr_registry_bridge.py
│   │   ├── sfr_features_bridge.py
│   │   ├── sfr_datasets_bridge.py
│   │   ├── sfr_admin_bridge.py
│   │   └── __init__.py
│   ├── notebooks/              Example notebooks and setup tooling
│   │   ├── workspace_quickstart.ipynb
│   │   ├── workspace_model_registry.ipynb
│   │   ├── workspace_feature_store.ipynb
│   │   ├── local_quickstart.ipynb
│   │   ├── local_model_registry.ipynb
│   │   ├── local_feature_store.ipynb
│   │   ├── notebook_config.yaml.template
│   │   ├── r_packages.yaml
│   │   ├── setup_r_environment.sh
│   │   ├── r_helpers.py
│   │   └── README.md
│   └── setup/                  Dev/test environment files
│       ├── environment.yml
│       └── create_test_env.sh
├── man/                        Generated .Rd help files (90+ files)
├── tests/
│   ├── testthat.R
│   └── testthat/               Unit tests (9 files)
├── vignettes/                  Long-form documentation (5 .Rmd files)
│   ├── getting-started.Rmd
│   ├── setup.Rmd
│   ├── model-registry.Rmd
│   ├── feature-store.Rmd
│   └── workspace-notebooks.Rmd
├── notebooks/                  Standalone demo notebooks (3 files)
└── .github/
    └── workflows/
        └── R-CMD-check.yml     GitHub Actions CI
```

## 3. snowflakeR License

The package is licensed under **Apache License 2.0** with copyright
assigned to **Snowflake Inc.**

```
Copyright 2026 Snowflake Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```

This is the same license used by Snowflake's other open-source projects
including `snowflake-ml-python`, `snowflake-snowpark-python`, and
`snowflake-connector-python`, and a prior R package `dbplyr-snowflakedb` no longer maintained (https://github.com/snowflakedb/dplyr-snowflakedb).

The `DESCRIPTION` file declares:
```
License: Apache License 2.0 | file LICENSE
```

The `Authors@R` field designates Snowflake Inc. as copyright holder (`cph`):
```r
Authors@R: c(
    person("Simon", "Field", email = "simon.field@snowflake.com",
           role = c("aut", "cre")),
    person("Snowflake Inc.", role = "cph"))
```

## 4. R Package Dependencies and Their Licenses

### 4.1 Hard Dependencies (Imports)

These packages are required at runtime and are installed automatically
from CRAN when a user installs snowflakeR.

| Package | CRAN Version | License | Maintainer / Org | Purpose |
|---|---|---|---|---|
| **methods** | (base R) | GPL-2 \| GPL-3 (part of R) | R Core Team | S4 method dispatch |
| **DBI** | >= 1.0 | LGPL-2.1 \| LGPL-3 | R Consortium / r-dbi | Database interface |
| **reticulate** | >= 1.34 | Apache-2.0 | Posit (RStudio) | R-Python bridge |
| **cli** | >= 3.0 | MIT | Posit (RStudio) | CLI output formatting |
| **rlang** | >= 1.0 | MIT | Posit (RStudio) | Tidy evaluation |
| **jsonlite** | >= 1.0 | MIT | Jeroen Ooms | JSON parsing |

### 4.2 Suggested Dependencies (Suggests)

These are optional and only needed for specific features. They are not
installed automatically.

| Package | CRAN Version | License | Purpose |
|---|---|---|---|
| **snowflakeauth** | any | MIT (Posit) | `connections.toml` credential management |
| **RcppTOML** | any | GPL-2+ | TOML file parsing |
| **httr2** | >= 1.0.0 | MIT (Posit) | HTTP client for REST inference |
| **testthat** | >= 3.0.0 | MIT (Posit) | Unit testing framework |
| **dplyr** | any | MIT (Posit) | Data manipulation |
| **dbplyr** | any | MIT (Posit) | SQL backend for dplyr |
| **arrow** | any | Apache-2.0 (Apache Foundation) | Arrow data interchange |
| **knitr** | any | GPL-2 \| GPL-3 | Vignette building |
| **rmarkdown** | any | GPL-3 (Posit) | Vignette rendering |
| **withr** | any | MIT (Posit) | Temporary state management |

### 4.3 License Compatibility Summary (R Dependencies)

All R dependencies use licenses that are compatible with Apache-2.0:

- **MIT**: Permissive, fully compatible with Apache-2.0.
- **Apache-2.0**: Same license family.
- **LGPL-2.1+**: Compatible for linking/dynamic use (not static
  incorporation). snowflakeR calls DBI functions but does not copy or
  modify DBI source code.
- **GPL-2/GPL-3**: `methods` (base R), `knitr`, `rmarkdown`, `RcppTOML`
  are all *Suggested* (optional) dependencies. They are not linked into
  snowflakeR and are only needed if the user opts to use those features.
  CRAN policy permits Apache-2.0 packages to have GPL Suggests.

## 5. Python Dependencies and Their Licenses

snowflakeR requires a Python (>= 3.9) environment with the following
packages. These are **not bundled** -- the user installs them separately
via `pip` or `conda`, or uses `sfr_install_python_deps()`.

### 5.1 Required Python Packages

| Package | Version | License | Publisher | Purpose |
|---|---|---|---|---|
| **snowflake-ml-python** | >= 1.5.0 | Apache-2.0 | Snowflake Inc. | ML platform SDK (Model Registry, Feature Store, Datasets) |
| **snowflake-snowpark-python** | any | Apache-2.0 | Snowflake Inc. | Snowpark DataFrame API and session management |

### 5.2 Transitive Python Dependencies (installed by the above)

These are pulled in automatically by `snowflake-ml-python` and are not
directly referenced by snowflakeR code, but are present in the runtime
environment.

| Package | License | Notes |
|---|---|---|
| **pandas** | BSD-3-Clause | Data manipulation |
| **numpy** | BSD-3-Clause | Numerical arrays |
| **pyarrow** | Apache-2.0 | Arrow data interchange |
| **cryptography** | Apache-2.0 OR BSD-3-Clause (dual-licensed) | Key-pair auth (RSA) |
| **scikit-learn** | BSD-3-Clause | ML framework (used by snowflake-ml-python) |

All transitive Python dependencies use permissive licenses (Apache-2.0,
BSD-3-Clause, or MIT) that are compatible with Apache-2.0.

### 5.3 Python Bridge in Workspace Notebooks (rpy2)

When running inside Snowflake Workspace Notebooks, the R environment is
accessed via **rpy2**, a Python-to-R bridge. This is pre-installed in
the Workspace environment and is not distributed with snowflakeR.

| Package | License | Notes |
|---|---|---|
| **rpy2** | GPL-2+ | Python-to-R bridge; used only in Workspace Notebooks; not bundled or required for local use |

rpy2 is GPL-licensed. It is **not bundled with, linked into, or
distributed as part of snowflakeR**. It is a pre-existing component of
the Snowflake Workspace Notebook environment that users optionally
interact with. snowflakeR provides helper functions (`r_helpers.py`) that
configure rpy2 when it is already available, but does not install,
distribute, or depend on it.

## 6. System Software Dependencies

### 6.1 micromamba

**What:** Lightweight, statically-linked conda package manager.
**License:** BSD-3-Clause (mamba-org/mamba project).
**How used:** The `setup_r_environment.sh` script (in `inst/notebooks/`)
downloads and uses micromamba to install R and R packages inside
Snowflake Workspace Notebooks. It is downloaded at runtime by the user's
setup script -- it is **not bundled with or distributed as part of
snowflakeR**.
**URL:** https://github.com/mamba-org/mamba

### 6.2 conda-forge

**What:** Community-maintained collection of conda packages.
**License:** Packages have individual licenses (predominantly BSD, MIT,
GPL, Apache). The conda-forge infrastructure itself is BSD-3-Clause.
**How used:** `setup_r_environment.sh` installs R packages from
conda-forge channels. The packages themselves are not redistributed --
they are downloaded by the end user.

### 6.3 Go Compiler (optional)

**What:** Go programming language toolchain.
**License:** BSD-3-Clause (Google).
**How used:** Only installed if the user opts for ADBC Snowflake driver
support (`--adbc` flag). Required to compile `adbcsnowflake` from
source. Not bundled or distributed.

## 7. What snowflakeR Does NOT Contain

For clarity, the following are explicitly **not present** in the package
or public repository:

- No Snowflake proprietary source code or internal APIs
- No secrets, credentials, tokens, or private keys
- No account-specific identifiers (account locators, usernames, etc.)
- No internal Snowflake documentation or non-public information
- No vendored/copied third-party code (all dependencies are declared
  and installed from their original sources)
- No binary artefacts or compiled code (pure R + Python source)
- No pre-trained models or datasets

## 8. CRAN Submission Considerations

CRAN has specific policies regarding package licensing. Key points for
review:

1. **Apache-2.0 is a CRAN-accepted license.** It is listed in CRAN's
   standard license specifications.

2. **GPL Suggests are acceptable.** CRAN allows Apache-2.0 packages to
   have GPL-licensed packages in `Suggests` (optional dependencies).
   snowflakeR's GPL dependencies (`methods`, `knitr`, `rmarkdown`,
   `RcppTOML`) are all in Suggests or are part of base R.

3. **The LICENSE file is included** in the package root as required by
   CRAN when using `License: ... | file LICENSE`.

4. **Python is declared as a SystemRequirement.** CRAN accepts packages
   that depend on external software (Python, Java, etc.) when declared
   in the `SystemRequirements` field.

5. **No compiled code.** snowflakeR is pure R + Python source, so there
   are no C/C++/Fortran compilation concerns.

## 9. Summary of License Landscape

| Category | Licenses Used | Compatible with Apache-2.0? |
|---|---|---|
| snowflakeR itself | Apache-2.0 | N/A (is Apache-2.0) |
| R hard dependencies (Imports) | MIT, Apache-2.0, LGPL-2.1+ | Yes |
| R optional dependencies (Suggests) | MIT, Apache-2.0, GPL-2+, GPL-3 | Yes (not linked, optional) |
| Python required dependencies | Apache-2.0 | Yes |
| Python transitive dependencies | Apache-2.0, BSD-3-Clause, MIT | Yes |
| System tools (micromamba, Go) | BSD-3-Clause | Yes (not bundled) |
| rpy2 (Workspace only, not bundled) | GPL-2+ | N/A (not distributed) |

All dependencies use OSI-approved open-source licenses that are
compatible with Apache-2.0 distribution.

## 10. Devops / Sync Process

Development happens in a private Snowflake-internal repository. A sync
script (`sync_snowflakeR_to_public.sh`) copies the public-facing subset
to the `Snowflake-Labs/snowflakeR` repository. The sync process:

1. Excludes `internal/` (development notes, plans, prototypes)
2. Excludes `tests/integration/` (live-connection tests with env-var
   references to local paths)
3. Excludes `notebook_config.yaml` (user-specific Snowflake configuration)
4. Runs an automated scan for blocked patterns (account identifiers,
   filesystem paths, credential filenames) and **aborts** if any are
   found

The public repository currently has a single clean (squashed) commit with no
historical credential exposure.
