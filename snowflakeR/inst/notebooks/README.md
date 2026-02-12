# snowflakeR Notebooks

Interactive Jupyter notebooks demonstrating the `snowflakeR` package.

## Before you start

1. Copy the config template:
   ```bash
   cp notebook_config.yaml.template notebook_config.yaml
   ```
2. Edit `notebook_config.yaml` with your warehouse, database, schema, and
   (for local) connection parameters.

All notebooks read this single config file to set the execution context.
Table references use fully qualified names (`DATABASE.SCHEMA.TABLE`) as
recommended by Snowflake for Workspace Notebooks.

## Choose your environment

Each topic has two versions -- pick the one that matches where you're running:

| Topic | Workspace Notebook | Local (RStudio / Jupyter) |
|---|---|---|
| **Quickstart** | `workspace_quickstart.ipynb` | `local_quickstart.ipynb` |

**Workspace Notebooks** run in Snowflake with a Python kernel. R code goes in
`%%R` magic cells. Setup includes installing R via `micromamba`.

**Local Notebooks** use a native R kernel (IRkernel). No `%%R` magic needed.
Requires `connections.toml` or explicit credentials.

## Accessing notebooks

After installing `snowflakeR`, find the notebooks with:

```r
system.file("notebooks", package = "snowflakeR")
```

Or copy them to your working directory:

```r
nb_dir <- system.file("notebooks", package = "snowflakeR")
file.copy(list.files(nb_dir, full.names = TRUE), ".", recursive = TRUE)
```
