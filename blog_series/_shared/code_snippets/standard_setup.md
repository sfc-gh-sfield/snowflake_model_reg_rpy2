# Standard Setup Cells (for Blogs 2-5)

Use these cells at the start of each blog (after Blog 1) to provide a
self-contained setup. Keep it brief and collapsed -- the reader should have
already done Blog 1 for the full explanation.

---

## Cell 1: Install R environment (Python cell)

```python
# Install R environment (~3 minutes first time, fast on subsequent runs)
# See Blog 1 for details: [link to Blog 1]
!bash setup_r_environment.sh --basic
```

## Cell 2: Configure rpy2 (Python cell)

```python
from r_helpers import setup_r_environment
result = setup_r_environment()

if result['success']:
    print(f"R {result['r_version']} ready. %%R magic registered.")
else:
    print("Setup failed:", result['errors'])
```

## Cell 3: Install and load snowflakeR (%%R cell)

```python
# Resolve snowflakeR package path
import os
snowflaker_path = os.path.normpath(os.path.join(os.getcwd(), "..", ".."))
os.environ["SNOWFLAKER_PATH"] = snowflaker_path
```

```r
%%R
options(repos = c(CRAN = "https://cloud.r-project.org"))
try(remove.packages("snowflakeR"), silent = TRUE)
install.packages(Sys.getenv("SNOWFLAKER_PATH"), repos = NULL, type = "source")
library(snowflakeR)
```

## Cell 4: Connect (%%R cell)

```r
%%R
conn <- sfr_connect()
conn <- sfr_load_notebook_config(conn)
conn
```

---

## Abbreviated Version (for blog text)

> **Setup:** If you haven't already, follow [Blog 1](link) to set up your R
> environment. Then run the setup cells at the top of the companion notebook
> to install R, configure rpy2, load `snowflakeR`, and connect to Snowflake.
