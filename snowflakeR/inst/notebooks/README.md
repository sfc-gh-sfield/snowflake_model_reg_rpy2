# snowflakeR Notebooks

Interactive Jupyter notebooks demonstrating the `snowflakeR` package.

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
