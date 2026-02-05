#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Configuration: edit these per project
# =============================================================================

# Where to put micromamba and envs
MICROMAMBA_ROOT="${HOME}/micromamba"

# Name of the R environment
ENV_NAME="r_env"

# Conda channel to use (conda-forge recommended)
CHANNEL="conda-forge"

# List of CONDA-FORGE R packages to install into this env.
# These must be *conda package names*, not plain R names.
# Examples:
#   r-base             -> base R
#   r-forecast         -> CRAN "forecast"
#   r-randomforest     -> CRAN "randomForest"
#   r-tidyverse        -> CRAN "tidyverse"
R_CONDA_PACKAGES=(
  "r-base"
  "r-forecast"
  "r-tidyverse"
  "reticulate"  
  "r-lazyeval"
)

# Optional: list of CRAN package names to install from R afterwards.
# These are *R package names* as you’d pass to install.packages().
# Requires outbound HTTP to CRAN via your EAI.
R_CRAN_PACKAGES=(
  # "prophet"
  # "fable"
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
  echo "Environment '${ENV_NAME}' already exists; updating packages if needed ..."
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
# 5. Optional: install extra CRAN packages inside this env
# =============================================================================

if [ "${#R_CRAN_PACKAGES[@]}" -gt 0 ]; then
  echo
  echo "Installing CRAN packages into this env: ${R_CRAN_PACKAGES[*]}"
  Rscript - <<EOF
cran_pkgs <- c(${R_CRAN_PACKAGES[@]/#/\"},${R_CRAN_PACKAGES[@]/%/\"} )
cran_pkgs <- unique(cran_pkgs)

installed <- rownames(installed.packages())
missing <- setdiff(cran_pkgs, installed)

if (length(missing)) {
  message("Installing missing CRAN packages: ", paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
} else {
  message("All requested CRAN packages already installed.")
}
EOF
fi

# =============================================================================
# 6. Print persistence hint
# =============================================================================

echo
echo "To make R available in future shells, add to ~/.bashrc:"
echo "-----------------------------------------------------------------"
echo "export PATH=\"${ENV_PREFIX}/bin:\$PATH\""
echo "export R_HOME=\"${ENV_PREFIX}/lib/R\""
echo "-----------------------------------------------------------------"

echo
echo "You can test 'forecast' (if installed) with:"
echo "  R -q -e \"library(forecast); packageVersion('forecast')\""

echo
echo "Done."