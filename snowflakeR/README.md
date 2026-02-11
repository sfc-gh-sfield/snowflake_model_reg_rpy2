# snowflakeR

R interface to the Snowflake ML platform -- Model Registry, Feature Store, Datasets, and data connectivity. Works in **local R environments** (RStudio, VS Code, terminal) and **Snowflake Workspace Notebooks**.

## Overview

**snowflakeR** provides idiomatic R functions for the full Snowflake ML lifecycle, whether you're working locally or directly inside Snowflake:

| Module | What it does |
|---|---|
| **Connect** | One-line connection via `connections.toml`, keypair, or Workspace auto-detect |
| **Query & DBI** | Run SQL, read/write tables, integrate with `dplyr`/`dbplyr` |
| **Model Registry** | Log R models (lm, glm, randomForest, xgboost, ...), deploy to SPCS, run inference |
| **Feature Store** | Create entities & feature views, generate training data, retrieve features at inference |
| **Datasets** | Versioned, immutable snapshots of query results for reproducible ML |
| **Admin** | Manage compute pools, image repos, and external access integrations |
| **Workspace Notebooks** | First-class support for Snowflake Workspace Notebooks with zero-config auth and `%%R` magic cells |

Under the hood, `snowflakeR` uses [`reticulate`](https://rstudio.github.io/reticulate/) to bridge to the [`snowflake-ml-python`](https://docs.snowflake.com/en/developer-guide/snowpark-ml/index) SDK while exposing a native R API with `snake_case` naming, S3 classes, and `cli` messaging. The same code runs identically in local R sessions and Snowflake Workspace Notebooks.

## Installation

```r
# Install from GitHub
# install.packages("pak")
pak::pak("Snowflake-Labs/snowflakeR")
```

### Python dependencies

snowflakeR requires Python >= 3.9 with the Snowflake ML packages:

```r
# Let snowflakeR install them into a dedicated virtualenv
snowflakeR::sfr_install_python_deps()
```

Or install manually:

```bash
pip install snowflake-ml-python snowflake-snowpark-python
```

## Quick start

```r
library(snowflakeR)

# Connect (reads ~/.snowflake/connections.toml by default)
conn <- sfr_connect()

# Run a query
df <- sfr_query(conn, "SELECT * FROM my_table LIMIT 10")

# Log an R model to the Model Registry
model <- lm(mpg ~ wt + hp, data = mtcars)
reg   <- sfr_model_registry(conn)
sfr_log_model(reg, model, model_name = "MPG_MODEL", version = "V1")

# Create a Feature Store entity and feature view
fs <- sfr_feature_store(conn)
sfr_create_entity(fs, name = "CUSTOMER", join_keys = "CUSTOMER_ID")
fv <- sfr_create_feature_view(
  fs,
  name       = "CUSTOMER_FEATURES",
  entity     = "CUSTOMER",
  source_sql = "SELECT customer_id, avg_spend, tenure FROM feature_table"
)
sfr_register_feature_view(fs, fv, version = "V1")
```

## Snowflake Workspace Notebooks

snowflakeR is designed to work seamlessly inside [Snowflake Workspace Notebooks](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks). It auto-detects the Workspace environment, connects via the active session token (no credentials needed), and supports the `%%R` magic cell pattern for mixing Python and R:

```r
# In a Workspace Notebook %%R cell -- zero-config connection
library(snowflakeR)
conn <- sfr_connect()   # auto-detects Workspace session

# All snowflakeR functions work identically
df <- sfr_query(conn, "SELECT * FROM my_table LIMIT 10")
reg <- sfr_model_registry(conn)
fs  <- sfr_feature_store(conn)
```

The package also provides `rprint()`, `rview()`, `rglimpse()`, and `rcat()` helpers for rich output rendering in Workspace cells. See `vignette("workspace-notebooks")` for setup instructions, PAT management, and tips for the dual local/Workspace workflow.

## Vignettes

| Vignette | Topic |
|---|---|
| `vignette("getting-started")` | Installation, connecting, queries, DBI/dbplyr |
| `vignette("model-registry")` | Training, logging, deploying, and serving R models |
| `vignette("feature-store")` | Entities, feature views, training data, inference |
| `vignette("workspace-notebooks")` | Using snowflakeR inside Snowflake Workspace Notebooks |

## Requirements

- R >= 4.1.0
- Python >= 3.9
- `snowflake-ml-python` >= 1.5.0
- `snowflake-snowpark-python`

Optional: [`snowflakeauth`](https://github.com/Snowflake-Labs/snowflakeauth) for `connections.toml` credential management.

## License

Apache License 2.0
