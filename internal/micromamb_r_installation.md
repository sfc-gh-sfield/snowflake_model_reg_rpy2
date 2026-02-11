# When you install R using micromamba, where does it install to, and is it possible to specify an alternative location, and also an specific location for R packages to be installed to, either from conda or cran?

> **Validation Note (Feb 2026):** This document has been reviewed and validated as accurate. 
> The patterns described here are used in the R integration setup scripts. See also:
> - `r_notebook/setup_r_environment.sh` - Implementation using these patterns
> - `internal/spcs_persistent_storage.md` - How to leverage PERSISTENT_DIR for R installation
> - `internal/R_Integration_Summary_and_Recommendations.md` - Persistence strategy recommendations

With micromamba it’s all about the **environment prefix**; R and its libraries live entirely under that prefix.

### 1. Where does micromamba install R?

By default, micromamba uses a **root prefix** and creates envs under that:

- Root prefix (if you haven’t changed it):  
  - Often `~/micromamba` or `~/.local/share/mamba` (depending on how you installed it)
- Environments under:  
  - `"$MAMBA_ROOT_PREFIX/envs/<env-name>"`

So if you do:

```bash
micromamba create -n r_env -c conda-forge r-base
```

you’ll typically get:

```text
$MAMBA_ROOT_PREFIX/envs/r_env/
  bin/R
  lib/R/
  lib/R/library/        # default R library inside env
```

R sees that env as its **R_HOME**, e.g.:

```bash
micromamba run -n r_env R -q -e 'R.home()'
# "/…/envs/r_env/lib/R"
```

### 2. Can you choose where R (the env) is installed?

Yes, two main knobs:

1. **Global root prefix** (where all envs live):

   ```bash
   export MAMBA_ROOT_PREFIX=/opt/mamba_root
   micromamba shell init -s bash --root-prefix "$MAMBA_ROOT_PREFIX"
   ```

   Now `micromamba create -n r_env ...` will put R in:

   ```text
   /opt/mamba_root/envs/r_env
   ```

2. **Per‑env explicit prefix** (env lives exactly where you say):

   ```bash
   micromamba create -p /opt/r_env -c conda-forge r-base
   ```

   Then R is at:

   ```text
   /opt/r_env/bin/R
   /opt/r_env/lib/R
   /opt/r_env/lib/R/library
   ```

This `-p/--prefix` form is usually the cleanest if you want a very specific path.

### 3. Package install locations: conda vs CRAN

Think of two layers:

#### 3.1. R packages installed via micromamba/conda (`r-*`)

- These are **conda packages** (e.g. `r-base`, `r-dplyr`, `r-forecast`).
- They always install under the **env prefix**; you don’t choose a different R library directory for them:

  ```bash
  micromamba install -n r_env -c conda-forge r-dplyr r-forecast
  ```

  go into:

  ```text
  $PREFIX/lib/R/library/dplyr
  $PREFIX/lib/R/library/forecast
  ```

- To “move” that location you change the env prefix (`-p` or `MAMBA_ROOT_PREFIX`), not a separate R_LIBS path. There isn’t a supported way to tell micromamba “put R in one place but its conda-managed libs somewhere else”.

#### 3.2. R packages installed from CRAN (inside R)

Inside that R, `install.packages()` looks at `.libPaths()`:

```r
.libPaths()
# [1] "/…/envs/r_env/lib/R/library"           # system/conda lib
# [2] "/home/.../R/x86_64-conda-linux-gnu/4.3"  # user lib (example)
```

You can control where CRAN packages go in several ways:

**a) One‑off per call**

```r
install.packages("data.table", lib = "/path/to/custom_R_lib")
```

R will create the directory if needed (with permission) and install there, and you can prepend it:

```r
.libPaths("/path/to/custom_R_lib")
```

**b) Session / project default with `.libPaths()`**

In `~/.Rprofile` or a project `.Rprofile`:

```r
.libPaths(c("/path/to/custom_R_lib", .libPaths()))
```

Now `install.packages()` with no `lib=` will default to that directory.

**c) Environment variables (`R_LIBS_USER` / `R_LIBS`) – good with micromamba**

Before starting R (or via env config on the env):

```bash
export R_LIBS_USER=/opt/r_user_libs
micromamba run -n r_env R -q -e '.libPaths(); install.packages("data.table")'
```

Within micromamba you can persist this per‑env:

```bash
micromamba env config vars set -n r_env R_LIBS_USER=/opt/r_user_libs
```

Then every `micromamba run -n r_env R` uses that path as the user library.

- `R_LIBS_USER`: typical knob for a **user** library
- `R_LIBS`: can define a colon‑separated search path of libraries

### 4. Putting it together: typical patterns

**A. Single, self‑contained env (simplest)**

```bash
export MAMBA_ROOT_PREFIX=$HOME/micromamba
micromamba create -n r_env -c conda-forge r-base r-forecast
micromamba run -n r_env R -q
```

- R binary and all conda R libs live under `$MAMBA_ROOT_PREFIX/envs/r_env`.
- CRAN installs go into that same env’s `lib/R/library` unless you override.

**B. Conda‑managed “system” R + separate writable CRAN library**

```bash
export MAMBA_ROOT_PREFIX=$HOME/micromamba
micromamba create -n r_env -c conda-forge r-base

micromamba env config vars set -n r_env R_LIBS_USER=$HOME/R/micromamba-user-lib

micromamba run -n r_env R -q -e '
  print(.libPaths());
  install.packages("data.table");
'
```

- Conda R core & conda `r-*` packages: `$MAMBA_ROOT_PREFIX/envs/r_env/lib/R/library`
- CRAN packages: `$HOME/R/micromamba-user-lib`

**C. Fixed, explicit prefix**

```bash
micromamba create -p /opt/r_env -c conda-forge r-base
micromamba env config vars set -p /opt/r_env R_LIBS_USER=/data/r_libs
```

---

So:

- **Where does R install with micromamba?**  
  Under the **env prefix** (default `$MAMBA_ROOT_PREFIX/envs/<name>`, or a custom `-p` path).

- **Can you choose a different location?**  
  Yes: set `MAMBA_ROOT_PREFIX` or use `micromamba create -p /your/path …`.

- **Can you choose where R packages go?**  
  - **Conda R packages** (`r-*`): live in the env; you control their location only via the env prefix.  
  - **CRAN packages**: fully controllable via `lib=` in `install.packages()`, `.libPaths()`, or `R_LIBS_USER` / `R_LIBS` (which you can set per micromamba env).

Would you like example commands to set up a per‑env prefix and a custom R_LIBS_USER?