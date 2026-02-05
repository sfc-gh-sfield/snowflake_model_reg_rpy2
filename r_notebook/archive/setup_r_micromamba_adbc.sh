#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Configuration: edit these if needed
# =============================================================================

# Where to put micromamba and envs
MICROMAMBA_ROOT="${HOME}/micromamba"

# Name of the R environment
ENV_NAME="r_env"

# Conda channel to use (conda-forge recommended)
CHANNEL="conda-forge"

# List of CONDA-FORGE packages for this env.
# NOTE: libadbc-driver-snowflake is the ADBC Snowflake C driver.
R_CONDA_PACKAGES=(
  "r-base"
  "r-forecast"
  "r-tidyverse"
  "r-lazyeval"
  "reticulate"  
  "libadbc-driver-snowflake"
)

# -----------------------------------------------------------------------------
# 1. Install micromamba under $HOME (if needed)
# -----------------------------------------------------------------------------
if [ ! -x "${MICROMAMBA_ROOT}/bin/micromamba" ]; then
  echo "Installing micromamba under ${MICROMAMBA_ROOT} ..."
  mkdir -p "${MICROMAMBA_ROOT}/bin"

  # Download to /tmp and extract there to avoid path collisions
  cd /tmp
  curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba

  mv bin/micromamba "${MICROMAMBA_ROOT}/bin/micromamba"
  rmdir bin || true
else
  echo "micromamba already present at ${MICROMAMBA_ROOT}/bin/micromamba"
fi

export PATH="${MICROMAMBA_ROOT}/bin:${PATH}"

# =============================================================================
# 2. Create / update the R environment with requested conda packages
# =============================================================================

if ! micromamba env list | awk '{print $1}' | grep -qx "${ENV_NAME}"; then
  echo "Creating environment '${ENV_NAME}' with packages: ${R_CONDA_PACKAGES[*]} ..."
  micromamba create -y -n "${ENV_NAME}" -c "${CHANNEL}" "${R_CONDA_PACKAGES[@]}"
else
  echo "Environment '${ENV_NAME}' already exists; installing/updating packages if needed ..."
  micromamba install -y -n "${ENV_NAME}" -c "${CHANNEL}" "${R_CONDA_PACKAGES[@]}"
fi

# Resolve the full env prefix (e.g. $HOME/micromamba/envs/r_env)
ENV_PREFIX="$(micromamba env list | awk -v name="${ENV_NAME}" '$1 == name {print $NF}')"
if [ -z "${ENV_PREFIX}" ]; then
  echo "ERROR: could not resolve prefix for env '${ENV_NAME}'"
  exit 1
fi

echo "ENV_PREFIX for '${ENV_NAME}' = ${ENV_PREFIX}"

# =============================================================================
# 3. Fix common .so symlinks (helps when building rpy2 against this R)
# =============================================================================

LIBDIR="${ENV_PREFIX}/lib"
if [ -d "${LIBDIR}" ]; then
  cd "${LIBDIR}"

  fix_symlink() {
    local base="$1"   # e.g. z or lzma
    if [ ! -e "lib${base}.so" ]; then
      local target
      target="$(ls "lib${base}.so."* 2>/dev/null | head -n1 || true)"
      if [ -n "${target}" ]; then
        echo "Creating symlink lib${base}.so -> ${target}"
        ln -s "${target}" "lib${base}.so"
      fi
    fi
  }

  fix_symlink "z"      # libz.so
  fix_symlink "lzma"   # liblzma.so
else
  echo "WARNING: lib directory '${LIBDIR}' not found; skipping symlink fix."
fi

# =============================================================================
# 4. Export PATH and R_HOME for this shell
# =============================================================================

export PATH="${ENV_PREFIX}/bin:${PATH}"
export R_HOME="${ENV_PREFIX}/lib/R"

echo
echo "R is now configured for this shell:"
echo "  which R   -> $(which R || echo 'not found')"
echo "  R --version:"
R --version || true

# =============================================================================
# 5. Install R packages: adbcdrivermanager (CRAN) + adbcsnowflake (R-multiverse)
# =============================================================================

echo
echo "Installing R packages 'adbcdrivermanager' (CRAN) and 'adbcsnowflake' (R-multiverse) into ${ENV_NAME} ..."

"${ENV_PREFIX}/bin/R" --vanilla --quiet <<'EOF'
repos_cran <- "https://cloud.r-project.org"
repos_multiverse <- "https://community.r-multiverse.org"

if (!requireNamespace("adbcdrivermanager", quietly = TRUE)) {
  install.packages("adbcdrivermanager", repos = repos_cran)
}

if (!requireNamespace("adbcsnowflake", quietly = TRUE)) {
  install.packages("adbcsnowflake", repos = repos_multiverse)
}
EOF

echo
echo "R ADBC setup complete."

# =============================================================================
# 6. Print persistence hint
# =============================================================================

echo
echo "To make R from this env available in future shells, add to ~/.bashrc:"
echo "-----------------------------------------------------------------"
echo "export PATH=\"${ENV_PREFIX}/bin:\$PATH\""
echo "export R_HOME=\"${ENV_PREFIX}/lib/R\""
echo "-----------------------------------------------------------------"

echo
echo "You can test the ADBC Snowflake driver from R (inside r_env) with something like:"
cat <<'EOS'
library(adbcdrivermanager)
library(adbcsnowflake)

token <- readLines("/snowflake/session/token", warn = FALSE)

db <- adbc_database_init(
  adbcsnowflake::adbcsnowflake(),
  `adbc.snowflake.sql.account`                  = Sys.getenv("SNOWFLAKE_ACCOUNT"),
  `adbc.snowflake.sql.client_option.auth_token` = token,
  `adbc.snowflake.sql.auth_type`                = "auth_oauth",
  `adbc.snowflake.sql.db`                       = Sys.getenv("SNOWFLAKE_DATABASE"),
  `adbc.snowflake.sql.schema`                   = Sys.getenv("SNOWFLAKE_SCHEMA"),
  `adbc.snowflake.sql.warehouse`                = "YOUR_WH"
)
con <- adbc_connection_init(db)
stmt <- adbc_statement_init(con)
adbc_statement_set_sql_query(stmt, "SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE()")
res <- adbc_statement_execute_query(stmt)
res
EOS

echo
echo "Done."