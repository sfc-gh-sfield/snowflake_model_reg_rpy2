#!/usr/bin/env bash
# =============================================================================
# R Environment Setup for Snowflake Workspace Notebooks
# =============================================================================
#
# This script installs R and configured packages into an isolated micromamba
# environment, suitable for use with rpy2 in Snowflake Workspace Notebooks.
#
# Usage:
#   ./setup_r_environment.sh [OPTIONS]
#
# Options:
#   --basic       Install R and packages from r_packages.yaml only (default)
#   --adbc        Install R packages plus ADBC Snowflake driver for direct DB access
#   --config FILE Specify alternate package config file (default: r_packages.yaml)
#   --log FILE    Write output to log file (default: setup_r.log)
#   --no-log      Disable logging to file
#   --verbose     Show detailed output
#   --help        Show this help message
#
# Examples:
#   ./setup_r_environment.sh                    # Basic R installation
#   ./setup_r_environment.sh --adbc             # R + ADBC driver
#   ./setup_r_environment.sh --config custom.yaml --adbc
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Default Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/r_packages.yaml"
LOG_FILE="${SCRIPT_DIR}/setup_r.log"
INSTALL_ADBC=false
ENABLE_LOGGING=true
VERBOSE=false
MICROMAMBA_ROOT="${HOME}/micromamba"
ENV_NAME="r_env"
CHANNEL="conda-forge"

# Version pinning for reproducibility (set to empty for latest)
R_VERSION=""  # e.g., "4.3.2" or empty for latest

# Retry configuration
MAX_RETRIES=3
RETRY_DELAY=5

# Minimum disk space required (in MB)
MIN_DISK_SPACE_MB=2000

# =============================================================================
# Logging Functions
# =============================================================================

setup_logging() {
    if [ "${ENABLE_LOGGING}" = true ]; then
        # Initialize log file with header
        cat > "${LOG_FILE}" << EOF
================================================================================
R Environment Setup Log
Started: $(date -Iseconds)
================================================================================

EOF
        exec > >(tee -a "${LOG_FILE}") 2>&1
    fi
}

log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] $*"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [ "${VERBOSE}" = true ] && log "DEBUG" "$@" || true; }

# =============================================================================
# Pre-flight Checks
# =============================================================================

check_disk_space() {
    log_info "Checking disk space..."
    
    local available_mb
    available_mb=$(df -m / | awk 'NR==2 {print $4}')
    
    log_debug "Available disk space: ${available_mb}MB"
    
    if [ "${available_mb}" -lt "${MIN_DISK_SPACE_MB}" ]; then
        log_error "Insufficient disk space: ${available_mb}MB available, ${MIN_DISK_SPACE_MB}MB required"
        return 1
    fi
    
    log_info "  Disk space OK: ${available_mb}MB available"
    return 0
}

check_network() {
    log_info "Checking network connectivity..."
    
    local endpoints=(
        "https://micro.mamba.pm"
        "https://conda.anaconda.org/conda-forge"
    )
    
    for endpoint in "${endpoints[@]}"; do
        if curl --silent --head --fail --max-time 5 "${endpoint}" > /dev/null 2>&1; then
            log_debug "  ${endpoint}: OK"
        else
            log_warn "  ${endpoint}: unreachable (may cause issues)"
        fi
    done
    
    log_info "  Network check complete"
    return 0
}

run_preflight_checks() {
    log_info "Running pre-flight checks..."
    
    local checks_passed=true
    
    # Disk space check
    if ! check_disk_space; then
        checks_passed=false
    fi
    
    # Network check (warn only, don't fail)
    check_network || true
    
    # Python check
    if ! command -v python3 &> /dev/null; then
        log_error "Python3 not found - required for YAML parsing"
        checks_passed=false
    else
        log_info "  Python3: $(python3 --version)"
    fi
    
    if [ "${checks_passed}" = false ]; then
        log_error "Pre-flight checks failed"
        return 1
    fi
    
    log_info "Pre-flight checks passed"
    return 0
}

# =============================================================================
# Retry Wrapper
# =============================================================================

retry_command() {
    local cmd="$1"
    local description="$2"
    local attempt=1
    
    while [ ${attempt} -le ${MAX_RETRIES} ]; do
        log_debug "Attempt ${attempt}/${MAX_RETRIES}: ${description}"
        
        if eval "${cmd}"; then
            return 0
        fi
        
        if [ ${attempt} -lt ${MAX_RETRIES} ]; then
            log_warn "  ${description} failed, retrying in ${RETRY_DELAY}s..."
            sleep ${RETRY_DELAY}
        fi
        
        ((attempt++))
    done
    
    log_error "  ${description} failed after ${MAX_RETRIES} attempts"
    return 1
}

# =============================================================================
# Parse Command Line Arguments
# =============================================================================

show_help() {
    cat << 'EOF'
R Environment Setup for Snowflake Workspace Notebooks

Usage: ./setup_r_environment.sh [OPTIONS]

Options:
  --basic       Install R and packages from r_packages.yaml only (default)
  --adbc        Install R packages plus ADBC Snowflake driver for direct DB access
  --config FILE Specify alternate package config file (default: r_packages.yaml)
  --log FILE    Write output to log file (default: setup_r.log)
  --no-log      Disable logging to file
  --verbose     Show detailed output
  --help        Show this help message

The package configuration file (r_packages.yaml) should contain:
  - conda_packages: List of conda-forge package names (e.g., r-base, r-tidyverse)
  - cran_packages: List of CRAN package names to install via install.packages()

Examples:
  ./setup_r_environment.sh                    # Basic R installation
  ./setup_r_environment.sh --adbc             # R + ADBC driver for Snowflake
  ./setup_r_environment.sh --config custom.yaml --adbc
  ./setup_r_environment.sh --adbc --verbose   # With detailed logging
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --basic)
            INSTALL_ADBC=false
            shift
            ;;
        --adbc)
            INSTALL_ADBC=true
            shift
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --log)
            LOG_FILE="$2"
            shift 2
            ;;
        --no-log)
            ENABLE_LOGGING=false
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# =============================================================================
# Main Setup
# =============================================================================

main() {
    # Initialize logging
    setup_logging
    
    echo "=============================================================================="
    echo "R Environment Setup for Snowflake Workspace Notebooks"
    echo "=============================================================================="
    echo ""
    
    # Run pre-flight checks
    if ! run_preflight_checks; then
        exit 1
    fi
    
    # Validate configuration file
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "Configuration file not found: ${CONFIG_FILE}"
        log_error "Please create r_packages.yaml or specify --config <file>"
        exit 1
    fi
    
    echo ""
    log_info "Configuration:"
    log_info "  Package config file: ${CONFIG_FILE}"
    log_info "  Install ADBC:        ${INSTALL_ADBC}"
    log_info "  Environment name:    ${ENV_NAME}"
    log_info "  Log file:            ${LOG_FILE:-<disabled>}"
    echo ""
    
    # =========================================================================
    # Parse YAML Configuration
    # =========================================================================
    
    log_info "Reading package configuration..."
    
    # Get conda packages
    CONDA_PACKAGES=$(python3 << PYEOF
import yaml
with open("${CONFIG_FILE}", 'r') as f:
    config = yaml.safe_load(f)
packages = config.get('conda_packages', [])
if packages:
    print(' '.join(packages))
PYEOF
)
    
    # Get CRAN packages
    CRAN_PACKAGES=$(python3 << PYEOF
import yaml
with open("${CONFIG_FILE}", 'r') as f:
    config = yaml.safe_load(f)
packages = config.get('cran_packages', [])
if packages:
    print(' '.join(packages))
PYEOF
)
    
    log_info "  Conda packages: ${CONDA_PACKAGES:-<none>}"
    log_info "  CRAN packages:  ${CRAN_PACKAGES:-<none>}"
    echo ""
    
    # Convert space-separated list to array
    read -ra R_CONDA_PACKAGES <<< "${CONDA_PACKAGES}"
    
    # =========================================================================
    # Step 1: Install micromamba
    # =========================================================================
    
    log_info "Step 1: Installing micromamba..."
    
    if [ ! -x "${MICROMAMBA_ROOT}/bin/micromamba" ]; then
        log_info "  Downloading micromamba..."
        mkdir -p "${MICROMAMBA_ROOT}/bin"
        
        # Download with retry
        cd /tmp
        retry_command \
            "curl -Ls --retry 3 --retry-delay 2 https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba" \
            "Download micromamba"
        
        mv bin/micromamba "${MICROMAMBA_ROOT}/bin/micromamba"
        rmdir bin 2>/dev/null || true
        
        log_info "  micromamba installed at ${MICROMAMBA_ROOT}/bin/micromamba"
    else
        log_info "  micromamba already installed"
    fi
    
    export PATH="${MICROMAMBA_ROOT}/bin:${PATH}"
    
    # =========================================================================
    # Step 2: Create/Update R Environment
    # =========================================================================
    
    echo ""
    log_info "Step 2: Setting up R environment..."
    
    if [ ${#R_CONDA_PACKAGES[@]} -eq 0 ]; then
        log_error "No conda packages specified. At minimum, r-base is required."
        exit 1
    fi
    
    # Add version pin if specified
    if [ -n "${R_VERSION}" ]; then
        log_info "  Pinning R version to ${R_VERSION}"
        R_CONDA_PACKAGES=("${R_CONDA_PACKAGES[@]/r-base/r-base=${R_VERSION}}")
    fi
    
    if ! micromamba env list | awk '{print $1}' | grep -qx "${ENV_NAME}"; then
        log_info "  Creating environment '${ENV_NAME}'..."
        retry_command \
            "micromamba create -y -n '${ENV_NAME}' -c '${CHANNEL}' ${R_CONDA_PACKAGES[*]}" \
            "Create R environment"
    else
        log_info "  Environment '${ENV_NAME}' exists, updating packages..."
        retry_command \
            "micromamba install -y -n '${ENV_NAME}' -c '${CHANNEL}' ${R_CONDA_PACKAGES[*]}" \
            "Update R environment"
    fi
    
    # Resolve environment prefix
    ENV_PREFIX="$(micromamba env list | awk -v name="${ENV_NAME}" '$1 == name {print $NF}')"
    if [ -z "${ENV_PREFIX}" ]; then
        log_error "Could not resolve prefix for env '${ENV_NAME}'"
        exit 1
    fi
    
    log_info "  Environment prefix: ${ENV_PREFIX}"
    
    # =========================================================================
    # Step 3: Fix Symlinks
    # =========================================================================
    
    echo ""
    log_info "Step 3: Fixing library symlinks..."
    
    LIBDIR="${ENV_PREFIX}/lib"
    if [ -d "${LIBDIR}" ]; then
        cd "${LIBDIR}"
        
        fix_symlink() {
            local base="$1"
            if [ ! -e "lib${base}.so" ]; then
                local target
                target="$(ls "lib${base}.so."* 2>/dev/null | head -n1 || true)"
                if [ -n "${target}" ]; then
                    log_debug "  Creating symlink: lib${base}.so -> ${target}"
                    ln -s "${target}" "lib${base}.so"
                fi
            fi
        }
        
        fix_symlink "z"
        fix_symlink "lzma"
        log_info "  Symlinks configured"
    else
        log_warn "  lib directory not found, skipping symlink fix"
    fi
    
    # =========================================================================
    # Step 4: Set Environment Variables
    # =========================================================================
    
    export PATH="${ENV_PREFIX}/bin:${PATH}"
    export R_HOME="${ENV_PREFIX}/lib/R"
    
    echo ""
    log_info "Step 4: Environment configured"
    log_info "  PATH includes: ${ENV_PREFIX}/bin"
    log_info "  R_HOME: ${R_HOME}"
    
    # Verify R installation
    echo ""
    log_info "  R version:"
    R --version 2>/dev/null | head -n1 || log_warn "  R not found"
    
    # =========================================================================
    # Step 5: Install CRAN Packages
    # =========================================================================
    
    if [ -n "${CRAN_PACKAGES}" ]; then
        echo ""
        log_info "Step 5: Installing CRAN packages..."
        
        # Convert to R vector format
        CRAN_VECTOR=$(echo "${CRAN_PACKAGES}" | tr ' ' '\n' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
        
        "${ENV_PREFIX}/bin/R" --vanilla --quiet << REOF
cran_pkgs <- c(${CRAN_VECTOR})
installed <- rownames(installed.packages())
missing <- setdiff(cran_pkgs, installed)

if (length(missing) > 0) {
    message("Installing CRAN packages: ", paste(missing, collapse = ", "))
    install.packages(missing, repos = "https://cloud.r-project.org", quiet = TRUE)
} else {
    message("All CRAN packages already installed")
}
REOF
    else
        echo ""
        log_info "Step 5: No CRAN packages to install"
    fi
    
    # =========================================================================
    # Step 6: ADBC Installation (optional)
    # =========================================================================
    
    if [ "${INSTALL_ADBC}" = true ]; then
        echo ""
        log_info "Step 6: Installing ADBC Snowflake driver..."
        
        # 6a. Install Go
        log_info "  Installing Go compiler..."
        retry_command \
            "micromamba install -y -n '${ENV_NAME}' -c '${CHANNEL}' go" \
            "Install Go"
        
        GO_BIN="${ENV_PREFIX}/bin/go"
        if [ ! -x "${GO_BIN}" ]; then
            log_error "Go installation failed"
            exit 1
        fi
        log_info "  Go installed at: ${GO_BIN}"
        
        # 6b. Install libadbc-driver-snowflake
        log_info "  Installing ADBC C driver..."
        retry_command \
            "micromamba install -y -n '${ENV_NAME}' -c '${CHANNEL}' libadbc-driver-snowflake" \
            "Install ADBC C driver"
        
        # 6c. Install R packages for ADBC
        log_info "  Installing R ADBC packages..."
        
        "${ENV_PREFIX}/bin/R" --vanilla --quiet << REOF
# Set GO_BIN for adbcsnowflake compilation
Sys.setenv(GO_BIN = "${GO_BIN}")
cat("GO_BIN set to:", Sys.getenv("GO_BIN"), "\n")

# Install adbcdrivermanager from CRAN
if (!requireNamespace("adbcdrivermanager", quietly = TRUE)) {
    message("Installing adbcdrivermanager from CRAN...")
    install.packages("adbcdrivermanager", repos = "https://cloud.r-project.org", quiet = TRUE)
}

# Install adbcsnowflake from R-multiverse (requires Go)
if (!requireNamespace("adbcsnowflake", quietly = TRUE)) {
    message("Installing adbcsnowflake from R-multiverse (this may take a few minutes)...")
    install.packages("adbcsnowflake", repos = "https://community.r-multiverse.org")
}

# Verify installation
if (requireNamespace("adbcsnowflake", quietly = TRUE)) {
    message("ADBC Snowflake driver installed successfully")
} else {
    stop("Failed to install adbcsnowflake")
}
REOF
        
        log_info "  ADBC installation complete"
    else
        echo ""
        log_info "Step 6: Skipping ADBC installation (use --adbc flag to enable)"
    fi
    
    # =========================================================================
    # Step 7: Summary
    # =========================================================================
    
    echo ""
    echo "=============================================================================="
    echo "Installation Complete!"
    echo "=============================================================================="
    echo ""
    log_info "Environment Details:"
    log_info "  Environment: ${ENV_NAME}"
    log_info "  Prefix:      ${ENV_PREFIX}"
    log_info "  R_HOME:      ${ENV_PREFIX}/lib/R"
    
    if [ "${ENABLE_LOGGING}" = true ]; then
        log_info "  Log file:    ${LOG_FILE}"
    fi
    
    echo ""
    echo "To use in your Notebook, run the configuration cell (Section 1.2)"
    echo "or use the helper module:"
    echo ""
    echo "    from r_helpers import setup_r_environment"
    echo "    setup_r_environment()"
    echo ""
    
    if [ "${INSTALL_ADBC}" = true ]; then
        echo "ADBC is installed. Use PATManager for token management:"
        echo ""
        echo "    from r_helpers import PATManager"
        echo "    pat_mgr = PATManager(session)"
        echo "    pat_mgr.create_pat()"
        echo ""
    fi
    
    log_info "Done."
}

# Run main function
main "$@"
