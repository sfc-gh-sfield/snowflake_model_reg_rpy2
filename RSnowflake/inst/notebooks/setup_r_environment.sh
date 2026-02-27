#!/usr/bin/env bash
# =============================================================================
# R Environment Setup for RSnowflake in Snowflake Workspace Notebooks
# =============================================================================
#
# Installs R into an isolated micromamba environment. RSnowflake is a pure R
# DBI connector (httr2-based) so no ADBC, Go, or JDBC is needed.
#
# Usage:
#   ./setup_r_environment.sh [OPTIONS]
#
# Options:
#   --config FILE  Alternate package config (default: r_packages.yaml)
#   --log FILE     Log file (default: setup_r.log)
#   --no-log       Disable logging
#   --verbose      Detailed output
#   --force        Force reinstall
#   --help         Show help
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/r_packages.yaml"
LOG_FILE="${SCRIPT_DIR}/setup_r.log"
ENABLE_LOGGING=true
VERBOSE=false
FORCE_REINSTALL=false
MICROMAMBA_ROOT="${HOME}/micromamba"
ENV_NAME="r_env"
CHANNEL="conda-forge"
R_VERSION=""
MAX_RETRIES=3
RETRY_DELAY=5
MIN_DISK_SPACE_MB=2000

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

setup_logging() {
    if [ "${ENABLE_LOGGING}" = true ]; then
        cat > "${LOG_FILE}" << EOF
================================================================================
R Environment Setup Log (RSnowflake)
Started: $(date -Iseconds)
================================================================================

EOF
        exec > >(tee -a "${LOG_FILE}") 2>&1
    fi
}

log() { local level="$1"; shift; echo "[$(date '+%H:%M:%S')] [${level}] $*"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [ "${VERBOSE}" = true ] && log "DEBUG" "$@" || true; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

retry_command() {
    local cmd="$1" description="$2" attempt=1
    while [ ${attempt} -le ${MAX_RETRIES} ]; do
        log_debug "Attempt ${attempt}/${MAX_RETRIES}: ${description}"
        if eval "${cmd}"; then return 0; fi
        if [ ${attempt} -lt ${MAX_RETRIES} ]; then
            log_warn "  ${description} failed, retrying in ${RETRY_DELAY}s..."
            sleep ${RETRY_DELAY}
        fi
        ((attempt++))
    done
    log_error "  ${description} failed after ${MAX_RETRIES} attempts"
    return 1
}

is_conda_pkg_installed() {
    local pkg_name="$1" env_name="${2:-${ENV_NAME}}"
    local base_name
    base_name=$(echo "${pkg_name}" | sed -E 's/[<>=].*//')
    micromamba list -n "${env_name}" 2>/dev/null | grep -q "^${base_name} "
}

get_missing_conda_packages() {
    local env_name="$1"; shift
    local packages=("$@") missing=()
    for pkg in "${packages[@]}"; do
        if ! is_conda_pkg_installed "${pkg}" "${env_name}"; then
            missing+=("${pkg}")
        else
            log_debug "    Already installed: ${pkg}"
        fi
    done
    echo "${missing[*]}"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --basic)   shift ;;
        --config)  CONFIG_FILE="$2"; shift 2 ;;
        --log)     LOG_FILE="$2"; shift 2 ;;
        --no-log)  ENABLE_LOGGING=false; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --force)   FORCE_REINSTALL=true; shift ;;
        --help|-h)
            echo "Usage: ./setup_r_environment.sh [--config FILE] [--force] [--verbose] [--no-log]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    setup_logging

    echo "=============================================================================="
    echo "R Environment Setup for RSnowflake"
    echo "=============================================================================="
    echo ""

    # Pre-flight: disk space
    local available_mb
    available_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [ "${available_mb}" -lt "${MIN_DISK_SPACE_MB}" ]; then
        log_error "Insufficient disk: ${available_mb}MB free, need ${MIN_DISK_SPACE_MB}MB"
        exit 1
    fi
    log_info "Disk space OK: ${available_mb}MB free"

    # Validate config
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "Config not found: ${CONFIG_FILE}"
        exit 1
    fi

    # Parse YAML
    eval "$(python3 << PYEOF
import yaml
with open("${CONFIG_FILE}", 'r') as f:
    config = yaml.safe_load(f)
r_version = config.get('r_version', '') or ''
print(f'R_VERSION="{r_version}"')
conda_packages = config.get('conda_packages', []) or []
conda_str = ' '.join(f'"{p}"' for p in conda_packages) if conda_packages else ''
print(f'CONDA_PACKAGES=({conda_str})')
cran_packages = config.get('cran_packages', []) or []
cran_latest = [str(p) for p in cran_packages if '==' not in str(p)]
print(f'CRAN_PACKAGES_LATEST="{" ".join(cran_latest)}"')
PYEOF
)"

    log_info "R version:      ${R_VERSION:-<latest>}"
    log_info "Conda packages: ${CONDA_PACKAGES[*]:-<none>}"
    log_info "CRAN packages:  ${CRAN_PACKAGES_LATEST:-<none>}"
    echo ""

    # Step 1: micromamba
    log_info "Step 1: Installing micromamba..."
    if [ "${FORCE_REINSTALL}" = false ] && [ -x "${MICROMAMBA_ROOT}/bin/micromamba" ]; then
        log_info "  [OK] Already installed"
    else
        mkdir -p "${MICROMAMBA_ROOT}/bin"
        cd /tmp
        retry_command \
            "curl -Ls --retry 3 --retry-delay 2 https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba" \
            "Download micromamba"
        mv bin/micromamba "${MICROMAMBA_ROOT}/bin/micromamba"
        rmdir bin 2>/dev/null || true
        log_info "  Installed"
    fi
    export PATH="${MICROMAMBA_ROOT}/bin:${PATH}"

    # Step 2: R environment
    echo ""
    log_info "Step 2: Setting up R environment..."

    INSTALL_PACKAGES=()
    HAS_R_BASE=false
    for pkg in "${CONDA_PACKAGES[@]}"; do
        if [[ "${pkg}" == r-base* ]]; then
            HAS_R_BASE=true
            if [ -n "${R_VERSION}" ] && [ "${pkg}" = "r-base" ]; then
                INSTALL_PACKAGES+=("r-base=${R_VERSION}")
            else
                INSTALL_PACKAGES+=("${pkg}")
            fi
        else
            INSTALL_PACKAGES+=("${pkg}")
        fi
    done
    if [ "${HAS_R_BASE}" = false ]; then
        if [ -n "${R_VERSION}" ]; then
            INSTALL_PACKAGES=("r-base=${R_VERSION}" "${INSTALL_PACKAGES[@]}")
        else
            INSTALL_PACKAGES=("r-base" "${INSTALL_PACKAGES[@]}")
        fi
    fi

    ENV_EXISTS=false
    if micromamba env list | awk '{print $1}' | grep -qx "${ENV_NAME}"; then
        ENV_EXISTS=true
    fi

    if [ "${ENV_EXISTS}" = true ] && [ "${FORCE_REINSTALL}" = false ]; then
        MISSING_PACKAGES=$(get_missing_conda_packages "${ENV_NAME}" "${INSTALL_PACKAGES[@]}")
        if [ -z "${MISSING_PACKAGES}" ]; then
            log_info "  [OK] All conda packages installed"
        else
            log_info "  Installing missing: ${MISSING_PACKAGES}"
            retry_command \
                "micromamba install -y -n '${ENV_NAME}' -c '${CHANNEL}' ${MISSING_PACKAGES}" \
                "Install missing packages"
        fi
    elif [ "${ENV_EXISTS}" = true ] && [ "${FORCE_REINSTALL}" = true ]; then
        retry_command \
            "micromamba install -y -n '${ENV_NAME}' -c '${CHANNEL}' ${INSTALL_PACKAGES[*]}" \
            "Update R environment"
    else
        log_info "  Creating environment '${ENV_NAME}'..."
        retry_command \
            "micromamba create -y -n '${ENV_NAME}' -c '${CHANNEL}' ${INSTALL_PACKAGES[*]}" \
            "Create R environment"
    fi

    ENV_PREFIX="$(micromamba env list | awk -v name="${ENV_NAME}" '$1 == name {print $NF}')"
    if [ -z "${ENV_PREFIX}" ]; then
        log_error "Could not resolve prefix for '${ENV_NAME}'"
        exit 1
    fi

    # Step 3: Fix symlinks
    echo ""
    log_info "Step 3: Fixing library symlinks..."
    LIBDIR="${ENV_PREFIX}/lib"
    if [ -d "${LIBDIR}" ]; then
        cd "${LIBDIR}"
        for base in z lzma; do
            if [ ! -e "lib${base}.so" ]; then
                target="$(ls "lib${base}.so."* 2>/dev/null | head -n1 || true)"
                if [ -n "${target}" ]; then
                    ln -s "${target}" "lib${base}.so"
                    log_debug "  Linked lib${base}.so -> ${target}"
                fi
            fi
        done
        log_info "  [OK] Symlinks checked"
    fi

    # Step 4: Environment variables
    export PATH="${ENV_PREFIX}/bin:${PATH}"
    export R_HOME="${ENV_PREFIX}/lib/R"

    echo ""
    log_info "Step 4: Environment configured"
    log_info "  R_HOME: ${R_HOME}"
    R --version 2>/dev/null | head -n1 || log_warn "  R not found"

    # Step 5: CRAN packages
    echo ""
    if [ -n "${CRAN_PACKAGES_LATEST}" ]; then
        log_info "Step 5: Installing CRAN packages..."
        "${ENV_PREFIX}/bin/R" --vanilla --quiet << REOF
pkgs <- strsplit("${CRAN_PACKAGES_LATEST}", " ")[[1]]
pkgs <- pkgs[pkgs != ""]
if (length(pkgs) > 0) {
    installed <- rownames(installed.packages())
    missing <- setdiff(pkgs, installed)
    if (length(missing) > 0) {
        message("Installing: ", paste(missing, collapse = ", "))
        install.packages(missing, repos = "https://cloud.r-project.org", quiet = TRUE)
    } else {
        message("All CRAN packages already installed")
    }
}
message("Done")
REOF
    else
        log_info "Step 5: No CRAN packages to install"
    fi

    # Summary
    echo ""
    echo "=============================================================================="
    echo "Installation Complete!"
    echo "=============================================================================="
    echo ""
    log_info "Prefix: ${ENV_PREFIX}"
    log_info "R_HOME: ${R_HOME}"
    echo ""
    echo "Next: run the Python configuration cell:"
    echo "    from r_helpers import setup_r_environment"
    echo "    setup_r_environment()"
    echo ""
}

main "$@"
