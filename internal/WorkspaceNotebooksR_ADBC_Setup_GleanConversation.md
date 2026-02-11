# Workspace Notebooks R & ADBC Setup – Conversation

Below is a transcript-style capture of the conversation between **Simon** (user) and the assistant about Snowflake Workspace Notebooks, R, rpy2, ADBC, SPCS tokens, and PAT authentication.

---


**User:** I want to install miniconda and configure the path to execute conda in a Workspace Notebook Terminal.  Can you give me the commands.  I then what to install r-base

**Assistant:** Provides minimal, copy-pasteable steps assuming Linux x86\_64, installing Miniconda under `$HOME/miniconda3` and then installing `r-base`.

```shell
cd /tmp
curl -LO https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh -b -p "$HOME/miniconda3"

export PATH="$HOME/miniconda3/bin:$PATH"
conda --version

conda config --set auto_activate_base false

conda create -n r_env -c conda-forge r-base -y
conda activate r_env
R --version
```

---

**User:** How can i install rpy2 and configure to work with that environment

**Assistant:** Explains two approaches:

1. Create a new env with `python + r-base + rpy2` together.  
2. Add `python` and `rpy2` into existing `r_env`.

Example (adding to existing env):

```shell
conda activate r_env
conda install -c conda-forge python=3.11 -y
conda install -c conda-forge rpy2 -y
```

Verifying rpy2 sees R:

```shell
python - << 'EOF'
import rpy2.robjects as ro
print("R 1+1 =", ro.r("1 + 1")[0])
print("R version from rpy2:", ro.r("R.version.string")[0])
EOF
```

Notes that in **Snowflake Notebooks**, the kernel is managed; conda envs don’t automatically surface as kernels. If you want rpy2 inside the Snowflake kernel, you need to install rpy2 into that kernel’s Python.

---

**User:** The Notebook Workspace runs Python 3.13.11  and I cant change that.  Will the commands for rpy2 above work with that version

**Assistant:**

- rpy2 (3.6.x) supports Python up to 3.13, so version-wise that’s fine.  
- But the conda-based commands install rpy2 into Miniconda’s Python, not into the **Notebook kernel’s** Python.

Recommends using conda only for R and system libs, and installing rpy2 into the Snowflake-managed Python 3.13.11 (via `pip` from the Notebook/terminal using the kernel’s `python`).

Pattern:

1. Miniconda for R (`r-base`) only.  
2. Expose that R to the Notebook Python (`PATH` and possibly `R_HOME`).  
3. `python -m pip install rpy2` using the **same Python as the Notebook kernel**.

---

**User:** I installed miniconda and r-base ok.  It works from within the Worspace Notebook Terminal.

I then followed your instructions on path setup, tested R works, and installed the rpy2 package.  I ran python in the terminal and then ran rpy2 succesfully.

(Provides terminal transcript showing `python -m pip install --user rpy2` under `/root/miniconda3/...` and successful test of `ro.r("2+3")`.)

Then:

I restarted the workspace kernel. Retested in the terminal. Still good. But running the same commands in a Python cell in the Notebook results in `ModuleNotFoundError: No module named 'rpy2'`.

**Assistant:** Explains:

- Terminal Python is Miniconda’s Python 3.13.11 (`/root/miniconda3/...`).  
- Notebook kernel Python is a separate venv, e.g. `/venv/.../bin/python`.

So we need to install rpy2 into the Notebook kernel’s Python, not Miniconda’s.

Provides a Python cell using `sys.executable` and `subprocess.run([..., '-m', 'pip', 'install', 'rpy2'])` to install rpy2 into the kernel, with `PATH`/`R_HOME` pointed at the conda R.

---

**User:** Getting this error running your FIX: `ERROR: Can not perform a '--user' install. User site-packages are not visible in this virtualenv.` (Shows error from running pip with `--user`.)

**Assistant:** Explains:

- The Notebook kernel runs in a venv that disallows `--user` installs.  
- Solution: pip install **without** `--user` from the kernel Python.

Provides updated cell:

```py
import os, sys, subprocess

ENV_PREFIX = "/root/miniconda3/envs/r_env"
os.environ["PATH"] = f"{ENV_PREFIX}/bin:" + os.environ["PATH"]
# set R_HOME similarly

subprocess.run([sys.executable, "-m", "pip", "install", "rpy2"], check=True)
```

---

**User:** Now error when building rpy2-rinterface: missing `-llzma` and `-lz` in link step.

**Assistant:** Explains this is a linking issue against the conda R libs; we need `liblzma.so` and `libz.so` symlinks in the env’s `lib` directory. Suggests:

```shell
cd /root/miniconda3/envs/r_env/lib
ln -s libz.so.1 libz.so
ln -s liblzma.so.5 liblzma.so
```

(repeat if needed for other libs) and then re-run `pip install rpy2` from the kernel.

---

**User:** Perfect.  Thats working.  I'm also wondering if we can install an R Kernel for the Notebook now that Workspace Notebooks run Jupyter?  ... Ideally I want to be able to run both R and Python and SQL cells\!

**Assistant:**

- Workspace Notebooks support Python, SQL, and Markdown cells; they run on a managed Python runtime, not a generic multi-kernel JupyterLab. There’s no supported way to add a separate R kernel to the notebook’s language selector.  
- Suggests using rpy2 (with optional `%%R` magics) to make R feel more “cell-like”, but emphasizes this is not an official Snowflake feature.

Outlines patterns for Python↔R roundtrips, including an example using rpy2 magics if they work in this environment.

---

**User:** We need to install the R forecast package into the Notebook R environment for the code Im testing

**Assistant:** Since R is in conda env `r_env`, simply:

```shell
/root/miniconda3/bin/conda install -n r_env -c conda-forge r-forecast -y
```

and test from R:

```
library(forecast); packageVersion('forecast')
```

From the Notebook via rpy2, load `forecast` with `ro.r("library(forecast)")`.

---

**User:** If I do whoami in the Notebook cell with \!, or in its terminal it returns root.  I'm wondering if there is an alternative approach to installing and configuring R and dependant libraries, that avoids miniconda. ... Ideally I want the approach that we devise to work for both Notebook Containers, and ML Conatianer Runtime.

**Assistant:** Explains the constraints:

- Workspace Notebooks and ML Container Runtime are SPCS-based; you can install Python packages but not easily modify system-level libs.  
- Conda/micromamba is the pragmatic way to bring in R \+ system libs in user space.

Outlines three options:

1. **Recommended**: micromamba/miniconda as “R distro”, Python stays native. Use conda-forge `r-base` and R packages; install rpy2 into the runtime Python.  
2. System-level R (apt/yum) in ML containers only, via Dockerfile.  
3. Building R from source at runtime (discouraged).

Conclusion: codify the conda/micromamba pattern for both Notebook and ML containers, rather than trying to avoid it completely.

---

**User:** Whats the different between micromamba and miniconda?  Why use micromamba?  Is it cleaner/smaller package manager for Conda

**Assistant:** Summarizes:

- **Miniconda**: Python distribution with conda, base env, etc. Heavier.  
- **micromamba**: Single small C++ binary implementing conda/mamba CLI, no Python, no base env. Ideal for containers and ephemeral setups.

Micromamba is smaller, faster, and doesn’t carry a second Python interpreter.

---

**User:** These are the notes I created when we were setting up the R environment in a Notebook Workspace. (Shows a shell snippet using Miniconda, `conda tos accept`, `conda create -n r_env -c conda-forge r-base`, `conda install r-forecast`, `export PATH`, `R_HOME`, `pip install rpy2`, plus symlinks.)  
Some of these may be out of order, or not requried.  Can we create a script as you suggested that can be used to install and configure R but use micromamba instead.  I assume it is open-source without restrictions?

**Assistant:** Confirms micromamba is open-source (BSD-3-Clause) and provides a complete `setup_r_with_micromamba.sh` script that:

- Installs micromamba under `$HOME/micromamba`.  
- Creates `r_env` with `r-base` and `r-forecast` from conda-forge.  
- Fixes `libz.so` and `liblzma.so` symlinks.  
- Exports `PATH` and `R_HOME`.  
- Installs `forecast` and prints hints.

Also shows how to point Notebook Python at this R via `PATH` and `R_HOME` and install rpy2 into the kernel.

---

**User:** When I installed R with miniconda I think there were some R terms of service I had to manually accept?  Will this script avoid those, or accept them silently?

**Assistant:** Explains:

- The TOS accept commands (`conda tos accept`) were for **Anaconda’s** default channels, not R itself.  
- The micromamba script uses only **conda-forge**, not Anaconda’s channels, so there’s no Anaconda TOS to accept.

---

**User:** I may want to install a number of different R packages, depending on what Im workin on.  How can we provide a list of packages to the script to makke it flexible

**Assistant:** Provides a refined script where:

- `R_CONDA_PACKAGES` is an array of conda-forge R packages (`r-base`, `r-forecast`, etc.).  
- `R_CRAN_PACKAGES` is an array of CRAN names to install via `install.packages()` after the env is created.

The script installs both sets and can be customized just by editing those arrays.

---

**User:** This is the notebook environment.  Ideally I want the R user to be able to connect to Snowflake to retrieve data.  At it's simplest this would be via a database connection (via ODBC or ADBC).  ... I'm wondering if any of the environment variables provide the ability to authenticate a database session on the account the Notebook service is running on.  Something similar must be the way that the Python Snowpark session is provided in Notebooks for users?

(Provides an env dump file.)

**Assistant:** After analyzing SPCS docs, explains:

- The Notebook env exposes account context via env vars (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_HOST`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_SERVICE_NAME`, etc.).  
- SPCS adds an OAuth token file at `/snowflake/session/token` that can be used to connect back to Snowflake using OAuth from **supported** clients (Python connector, gosnowflake, JDBC with `token_file_path`, etc.)citation\_64,66,72.

But:

- The only documented way in Workspaces to reuse the implicit notebook session is `get_active_session()` in Python.  
- R/ODBC/ADBC can build connection strings from env vars, but need their own auth (password, key pair, PAT, OAuth from PAT/ JWT) unless using a supported SPCS token flow.

Suggests two main patterns:

1. Python Snowpark with `get_active_session()` as the “data plane”, using rpy2 to bridge to R.  
2. R as a separate client with its own auth (PAT, key pair, etc.), optionally using env vars for non-secret connection parameters.

---

**User:** Workspace Notebooks run on Snowpark Container Services, not in a warehouse via stored-procedure. ... Given it's using same/similar container image to ML Container Runtime with the documented pattern where Snowflake injects an OAuth token into the container filesystem, does the same exist in the Workspace Notebook.  How can we check?  If it exists we can use that

**Assistant:** Confirms via SPCS docs that:

- Containers get env vars and `/snowflake/session/token`citation\_64,66,72.  
- The user can check existence via `ls /snowflake/session` or `os.path.isfile("/snowflake/session/token")`.

Then:

- Shows how to use this token from Python, Node, Java, and from R (in principle) using OAuth.  
- For R specifically, suggests using ODBC/ADBC and either `Token`/`TOKEN_FILE_PATH` pointing at `/snowflake/session/token` if the driver supports it, or reading the token and using OAuth.

Then pivots to an idea: use **ADBC Snowflake driver** in R to avoid full ODBC setup, because ADBC is simpler to deploy in a container.

---

**User:** I can see that the token exists. ... For this to work though we will need ODBC or ADBC installed/configured in the Notebook Container.  Installing/configuring odbc in the container might be tricky

**Assistant:** Recommends using **Apache Arrow ADBC Snowflake driver** instead of full ODBC, since it’s available in R (`adbcsnowflake`) and has a conda-forge C driver (`libadbc-driver-snowflake`) that can be installed into `r_env`.

Outlines steps:

1. Install `libadbc-driver-snowflake` into `r_env` via micromamba.  
2. Install R packages `adbcdrivermanager` and `adbcsnowflake`.  
3. Use `/snowflake/session/token` as OAuth token via ADBC driver options (`adbc.snowflake.sql.auth_type = "auth_oauth"`, `adbc.snowflake.sql.client_option.auth_token = token`).

Provides sample R code for this.

---

**User:** Can you adjust the earlier script that you provided to install the adbc driver and dependancies, so that we can test this with %%R with rpy2 in the Notebook.

**Assistant:** Provides an updated script `setup_r_with_micromamba_adbc.sh` that:

- Installs micromamba.  
- Creates env `r_env` with `r-base`, `r-forecast`, and `libadbc-driver-snowflake`.  
- Fixes symlinks.  
- Installs `adbcdrivermanager` and `adbcsnowflake` in that env.

Then shows how to:

- Set `PATH` and `R_HOME` from Python to point to `r_env`.  
- Register rpy2 magics and test `%%R` with ADBC-based Snowflake connection.

---

**User:** When I run \!bash setup\_r\_micromamba\_adbc.sh from a Notebook cell I get a `mv: 'bin/micromamba' and '/root/micromamba/bin/micromamba' are the same file` error.

**Assistant:** Explains it’s due to extracting and moving micromamba into the same directory and suggests fixing the script to extract in `/tmp` and move the binary into `${MICROMAMBA_ROOT}/bin` from there.

---

**User:** Now getting:

- micromamba installs. Env is created under `/root/.local/share/mamba/envs/r_env`.  
- Then: `Fatal error: you must specify '--save', '--no-save' or '--vanilla'` from the R install block.

**Assistant:** Explains that `R` is being invoked in a non-batch mode and we need to pass `--vanilla` or `--no-save`. Fixes the R invocation in the script to:

```shell
"${ENV_PREFIX}/bin/R" --vanilla --quiet <<'EOF'
...
EOF
```

---

**User:** SyntaxError: unterminated f-string literal (on the Python cell setting `R_HOME`).

**Assistant:** Points out a missing closing quote and provides the correct cell:

```py
import os
ENV_PREFIX = "/root/.local/share/mamba/envs/r_env"
os.environ["PATH"] = f"{ENV_PREFIX}/bin:" + os.environ["PATH"]
os.environ["R_HOME"] = f"{ENV_PREFIX}/lib/R"
```

---

**User:** ModuleNotFoundError: No module named 'rpy2'

**Assistant:** Explains that rpy2 is not installed into the Notebook kernel’s Python venv and provides a Python cell using `sys.executable -m pip install rpy2` (with `PATH`/`R_HOME` set) to install rpy2 into the kernel Python.

---

**User:** Trying ADBC from R via `%%R` fails with `there is no package called 'adbcsnowflake'`.

**Assistant:** Suggests installing `adbcsnowflake` directly from within `%%R` using:

```
install.packages("adbcsnowflake", repos = "https://community.r-multiverse.org")
```

If it fails, we inspect the error.

---

**User:** `adbcsnowflake` install fails: "The Go compiler is required to install this package".

**Assistant:** Suggests installing Go into `r_env` via micromamba:

```shell
micromamba install -y -n r_env -c conda-forge go
```

Then, in R, set `GO_BIN` to the `go` binary path and re-run `install.packages("adbcsnowflake", ...)`.

---

**User:** Now ADBC connection using `/snowflake/session/token` fails with:

`Error connecting to Snowflake via Snowpark Container Services. Client is unauthorized to use Snowpark Container Services OAuth token.`

**Assistant:** Explains:

- `/snowflake/session/token` is a special SPCS token, not a general OAuth token for arbitrary clients.  
- The error indicates this client (ADBC) is not allowed to use that token on the internal SPCS path.

Then user tests username/password via ADBC; that is rejected too with:

`Error connecting to Snowflake via Snowpark Container Services. Please use OAuth when connecting to Snowflake.`

Assistant concludes:

- Inside SPCS (Notebook on Container Runtime), internal connections require OAuth and disallow username/password.  
- The internal SPCS token is only accepted for specific connector patterns, not generic old clients.

Thus, only supported patterns are:

1. Python `get_active_session()` for Snowpark inside Notebook.  
2. External-style connection (e.g. PAT/ JWT OAuth) via the public endpoint.

---

**User:** What would the R code look like for ADBC with a username and password. I want to test that isnt blocked first...

**Assistant:** Provides ADBC R code using `username` and `password` with env vars, but the test shows it is indeed blocked with `390432 Network policy is required` if using PAT-style auth, or `must use OAuth` for internal connections.

Then explains PAT prerequisites: by default, user must be subject to a network policy to use PAT, unless an auth policy relaxes that.citation\_83

Suggests 2 ways around the network policy requirement for PAT:

1. Use `ALTER USER ... ADD PROGRAMMATIC ACCESS TOKEN ... MINS_TO_BYPASS_NETWORK_POLICY_REQUIREMENT = N` for a short-term bypass.  
2. Create an authentication policy with `PAT_POLICY = (NETWORK_POLICY_EVALUATION = ENFORCED_NOT_REQUIRED)` and assign it to the user.

---

**User:** Now I’m trying a different issue: getting R’s `iris` dataset into a pandas DataFrame from a Python cell using rpy2. Using:

```py
datasets = importr('datasets')
with (ro.default_converter + pandas2ri.converter).context():
  iris = datasets.data('iris')
```

This fails with `AttributeError: module 'datasets' has no attribute 'data'`.

**Assistant:** Explains that in R, `data()` is in **utils**, not `datasets`, and that for `iris` it’s simpler to do:

```py
from rpy2 import robjects as ro
from rpy2.robjects import pandas2ri
from rpy2.robjects.conversion import localconverter

# Load iris into R
ro.r("data(iris)")

iris_r = ro.r["iris"]
with localconverter(ro.default_converter + pandas2ri.converter):
    iris_df = pandas2ri.rpy2py(iris_r)

iris_df.head()
```

Also clarifies that `pandas2ri.activate()` is deprecated; `localconverter` is the modern way.

---

**User:** Can you create a Google document of this entire conversation history

**Assistant:** Explains that it will generate a Google Doc via the integration, reconstructing this conversation as a markdown transcript, and then proceeds to create the document.

(End of transcript.)  
