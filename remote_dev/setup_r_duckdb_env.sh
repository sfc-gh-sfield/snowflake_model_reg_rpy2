#!/bin/bash
# =============================================================================
# R + DuckDB Environment Setup for ML Container Runtime Remote Dev
# =============================================================================
#
# This script sets up R, DuckDB, and ADBC in the ML Container Runtime
# environment, using the SAME approach as the Workspace Notebook setup
# for consistency between environments.
#
# Usage:
#   ./setup_r_duckdb_env.sh [--basic|--adbc|--duckdb|--full]
#
# Flags:
#   --basic   Install R and core packages only (default)
#   --adbc    Install R + ADBC driver (Go-compiled) for direct R-Snowflake
#   --duckdb  Install R + DuckDB + Snowflake extension
#   --full    Install everything (R + ADBC + DuckDB)
#
# Consistency with Workspace Notebook:
#   - Uses micromamba for package management
#   - Uses Go to compile ADBC R packages (same as Workspace)
#   - Same library locations and paths
#   - Same ADBC driver compilation approach
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -----------------------------------------------------------------------------
# Configuration - Aligned with Workspace Notebook
# -----------------------------------------------------------------------------

# Installation paths (same as setup_r_environment.sh)
export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/micromamba}"
export R_ENV_NAME="r_env"
export CHANNEL="conda-forge"

# Parse flags
INSTALL_BASIC=false
INSTALL_ADBC=false
INSTALL_DUCKDB=false

case "${1:-}" in
    --basic)
        INSTALL_BASIC=true
        ;;
    --adbc)
        INSTALL_BASIC=true
        INSTALL_ADBC=true
        ;;
    --duckdb)
        INSTALL_BASIC=true
        INSTALL_DUCKDB=true
        ;;
    --full)
        INSTALL_BASIC=true
        INSTALL_ADBC=true
        INSTALL_DUCKDB=true
        ;;
    "")
        INSTALL_BASIC=true
        ;;
    *)
        echo "Usage: $0 [--basic|--adbc|--duckdb|--full]"
        exit 1
        ;;
esac

echo ""
echo "=============================================="
echo " R + DuckDB Environment Setup"
echo " (Consistent with Workspace Notebook)"
echo "=============================================="
echo " Install R basics: $INSTALL_BASIC"
echo " Install ADBC:     $INSTALL_ADBC"
echo " Install DuckDB:   $INSTALL_DUCKDB"
echo "=============================================="
echo ""

# -----------------------------------------------------------------------------
# Step 1: Install micromamba (same as Workspace)
# -----------------------------------------------------------------------------

install_micromamba() {
    log_info "Step 1: Installing micromamba..."
    
    if [ -f "$MAMBA_ROOT_PREFIX/bin/micromamba" ]; then
        log_success "micromamba already installed at $MAMBA_ROOT_PREFIX"
        return 0
    fi
    
    log_info "Downloading micromamba..."
    mkdir -p "$MAMBA_ROOT_PREFIX/bin"
    
    cd /tmp
    curl -Ls --retry 3 --retry-delay 2 https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba
    mv bin/micromamba "$MAMBA_ROOT_PREFIX/bin/micromamba"
    rmdir bin 2>/dev/null || true
    
    log_success "micromamba installed at $MAMBA_ROOT_PREFIX/bin/micromamba"
}

# -----------------------------------------------------------------------------
# Step 2: Set up shell environment
# -----------------------------------------------------------------------------

setup_shell_env() {
    log_info "Step 2: Setting up shell environment..."
    
    export PATH="$MAMBA_ROOT_PREFIX/bin:$PATH"
    
    # Initialize micromamba for current shell
    eval "$("$MAMBA_ROOT_PREFIX/bin/micromamba" shell hook -s bash)"
    
    log_success "Shell environment configured"
}

# -----------------------------------------------------------------------------
# Step 3: Create R environment with conda packages (same as Workspace)
# -----------------------------------------------------------------------------

create_r_env() {
    log_info "Step 3: Setting up R environment..."
    
    # Check if environment exists
    local ENV_EXISTS=false
    if micromamba env list | awk '{print $1}' | grep -qx "$R_ENV_NAME"; then
        ENV_EXISTS=true
    fi
    
    # Build package list (similar to Workspace)
    local PACKAGES="r-base>=4.3 r-tidyverse r-dbi r-dbplyr>=2.4"
    
    # Add DuckDB packages if requested
    if [ "$INSTALL_DUCKDB" = true ]; then
        PACKAGES="$PACKAGES r-duckdb>=1.1 r-arrow>=14.0"
    fi
    
    # Add rpy2 for Python-R bridge
    PACKAGES="$PACKAGES rpy2>=3.5"
    
    if [ "$ENV_EXISTS" = true ]; then
        log_info "Environment '$R_ENV_NAME' exists, updating packages..."
        micromamba install -y -n "$R_ENV_NAME" -c "$CHANNEL" $PACKAGES
    else
        log_info "Creating environment '$R_ENV_NAME'..."
        micromamba create -y -n "$R_ENV_NAME" -c "$CHANNEL" $PACKAGES
    fi
    
    micromamba activate "$R_ENV_NAME"
    
    # Get environment prefix
    ENV_PREFIX="$(micromamba env list | awk -v name="$R_ENV_NAME" '$1 == name {print $NF}')"
    export ENV_PREFIX
    export R_HOME="${ENV_PREFIX}/lib/R"
    export PATH="${ENV_PREFIX}/bin:${PATH}"
    
    log_success "R environment ready at $ENV_PREFIX"
}

# -----------------------------------------------------------------------------
# Step 4: Fix library symlinks (same as Workspace)
# -----------------------------------------------------------------------------

fix_symlinks() {
    log_info "Step 4: Fixing library symlinks..."
    
    local LIBDIR="${ENV_PREFIX}/lib"
    if [ -d "${LIBDIR}" ]; then
        cd "${LIBDIR}"
        
        local SYMLINKS_CREATED=0
        fix_symlink() {
            local base="$1"
            if [ ! -e "lib${base}.so" ]; then
                local target
                target="$(ls "lib${base}.so."* 2>/dev/null | head -n1 || true)"
                if [ -n "${target}" ]; then
                    log_info "  Creating symlink: lib${base}.so -> ${target}"
                    ln -s "${target}" "lib${base}.so"
                    ((SYMLINKS_CREATED++)) || true
                fi
            fi
        }
        
        fix_symlink "z"
        fix_symlink "lzma"
        
        if [ ${SYMLINKS_CREATED} -eq 0 ]; then
            log_success "Symlinks already configured"
        else
            log_success "Created ${SYMLINKS_CREATED} symlink(s)"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Step 5: Install ADBC using Go (SAME AS WORKSPACE)
# -----------------------------------------------------------------------------

install_adbc_with_go() {
    if [ "$INSTALL_ADBC" != true ]; then
        log_info "Step 5: Skipping ADBC installation (use --adbc to enable)"
        return 0
    fi
    
    log_info "Step 5: Installing ADBC Snowflake driver (Go-based, same as Workspace)..."
    
    # 5a. Install Go compiler (same as Workspace)
    local GO_BIN="${ENV_PREFIX}/bin/go"
    if [ ! -x "${GO_BIN}" ]; then
        log_info "  Installing Go compiler..."
        micromamba install -y -n "$R_ENV_NAME" -c "$CHANNEL" go
    else
        log_success "  Go compiler already installed"
    fi
    
    GO_BIN="${ENV_PREFIX}/bin/go"
    if [ ! -x "${GO_BIN}" ]; then
        log_error "Go installation failed"
        exit 1
    fi
    log_info "  Go binary: ${GO_BIN}"
    
    # 5b. Install libadbc-driver-snowflake C driver (same as Workspace)
    if ! micromamba list -n "$R_ENV_NAME" 2>/dev/null | grep -q "^libadbc-driver-snowflake "; then
        log_info "  Installing ADBC C driver..."
        micromamba install -y -n "$R_ENV_NAME" -c "$CHANNEL" libadbc-driver-snowflake
    else
        log_success "  ADBC C driver already installed"
    fi
    
    # 5c. Install R packages for ADBC (same as Workspace)
    log_info "  Installing R ADBC packages (this compiles with Go)..."
    
    "${ENV_PREFIX}/bin/R" --vanilla --quiet << REOF
# Set GO_BIN for adbcsnowflake compilation
Sys.setenv(GO_BIN = "${GO_BIN}")
cat("GO_BIN set to:", Sys.getenv("GO_BIN"), "\n")

# Install adbcdrivermanager from CRAN
if (!requireNamespace("adbcdrivermanager", quietly = TRUE)) {
    message("Installing adbcdrivermanager from CRAN...")
    install.packages("adbcdrivermanager", repos = "https://cloud.r-project.org", quiet = TRUE)
} else {
    message("adbcdrivermanager already installed")
}

# Install adbcsnowflake from R-multiverse (requires Go)
if (!requireNamespace("adbcsnowflake", quietly = TRUE)) {
    message("Installing adbcsnowflake from R-multiverse (this may take a few minutes)...")
    install.packages("adbcsnowflake", repos = "https://community.r-multiverse.org")
} else {
    message("adbcsnowflake already installed")
}

# Verify installation
if (requireNamespace("adbcsnowflake", quietly = TRUE)) {
    message("ADBC Snowflake driver ready")
} else {
    stop("Failed to install adbcsnowflake")
}
REOF
    
    log_success "ADBC installation complete (Go-compiled)"
}

# -----------------------------------------------------------------------------
# Step 6: Install DuckDB extensions and set up ADBC symlink
# -----------------------------------------------------------------------------

install_duckdb_setup() {
    if [ "$INSTALL_DUCKDB" != true ]; then
        log_info "Step 6: Skipping DuckDB setup (use --duckdb to enable)"
        return 0
    fi
    
    log_info "Step 6: Setting up DuckDB extensions..."
    
    # Install DuckDB extensions
    micromamba run -n "$R_ENV_NAME" duckdb -c "
        INSTALL snowflake FROM community;
        INSTALL httpfs;
        INSTALL iceberg;
    " 2>/dev/null || true
    
    log_success "DuckDB extensions installed"
    
    # Set up ADBC symlink for DuckDB Snowflake extension
    # The extension looks for libadbc_driver_snowflake.so in specific locations
    log_info "  Setting up ADBC driver symlink for DuckDB..."
    
    # Get DuckDB version
    local DUCKDB_VER=$(micromamba run -n "$R_ENV_NAME" Rscript -e "cat(as.character(packageVersion('duckdb')))" 2>/dev/null)
    if [ -z "$DUCKDB_VER" ]; then
        DUCKDB_VER="1.1.3"
        log_warn "Could not detect DuckDB version, using: $DUCKDB_VER"
    fi
    
    # Find the ADBC driver from conda installation
    local ADBC_SOURCE=""
    # Check conda lib directory first
    if [ -f "${ENV_PREFIX}/lib/libadbc_driver_snowflake.so" ]; then
        ADBC_SOURCE="${ENV_PREFIX}/lib/libadbc_driver_snowflake.so"
    fi
    
    if [ -n "$ADBC_SOURCE" ]; then
        # Create symlinks in locations DuckDB searches
        # Based on extension code: ~/.local/share/R/duckdb/extensions/vX.Y.Z/linux_amd64/
        local DUCKDB_EXT_DIR="$HOME/.local/share/R/duckdb/extensions/v${DUCKDB_VER}/linux_amd64"
        mkdir -p "$DUCKDB_EXT_DIR"
        
        if [ ! -e "$DUCKDB_EXT_DIR/libadbc_driver_snowflake.so" ]; then
            ln -sf "$ADBC_SOURCE" "$DUCKDB_EXT_DIR/libadbc_driver_snowflake.so"
            log_success "Created ADBC symlink for DuckDB: $DUCKDB_EXT_DIR/"
        else
            log_success "ADBC symlink already exists"
        fi
        
        # Also create in /usr/local/lib as fallback
        if [ -w /usr/local/lib ]; then
            ln -sf "$ADBC_SOURCE" /usr/local/lib/libadbc_driver_snowflake.so 2>/dev/null || true
        fi
    else
        log_warn "ADBC driver not found in conda environment"
        log_warn "DuckDB Snowflake extension may need to download ADBC separately"
    fi
}

# -----------------------------------------------------------------------------
# Step 7: Install Python packages for bridge (snowflake-connector)
# -----------------------------------------------------------------------------

install_python_packages() {
    log_info "Step 7: Installing Python packages..."
    
    # Install snowflake-connector-python for Python bridge approach
    micromamba run -n "$R_ENV_NAME" pip install -q \
        snowflake-connector-python[pandas] \
        cryptography \
        pyarrow 2>/dev/null || true
    
    log_success "Python packages installed"
}

# -----------------------------------------------------------------------------
# Step 8: Verify installation
# -----------------------------------------------------------------------------

verify_installation() {
    log_info "Step 8: Verifying installation..."
    
    echo ""
    echo "--- R Version ---"
    micromamba run -n "$R_ENV_NAME" R --version 2>/dev/null | head -3
    
    echo ""
    echo "--- Key R Packages ---"
    micromamba run -n "$R_ENV_NAME" Rscript -e "
        pkgs <- c('DBI', 'dplyr', 'dbplyr')
        if ($INSTALL_DUCKDB) pkgs <- c(pkgs, 'duckdb', 'arrow')
        if ($INSTALL_ADBC) pkgs <- c(pkgs, 'adbcdrivermanager', 'adbcsnowflake')
        for (p in pkgs) {
            if (requireNamespace(p, quietly=TRUE)) {
                cat(sprintf('  %s: %s\n', p, packageVersion(p)))
            } else {
                cat(sprintf('  %s: NOT INSTALLED\n', p))
            }
        }
    " 2>/dev/null || echo "(could not verify)"
    
    if [ "$INSTALL_DUCKDB" = true ]; then
        echo ""
        echo "--- DuckDB Version ---"
        micromamba run -n "$R_ENV_NAME" duckdb --version 2>/dev/null || echo "(not found)"
        
        echo ""
        echo "--- ADBC Driver Location ---"
        ls -la "${ENV_PREFIX}/lib/libadbc_driver_snowflake.so" 2>/dev/null || echo "(not in conda lib)"
        find "$HOME/.local/share/R/duckdb" -name "libadbc_driver_snowflake.so" -ls 2>/dev/null || true
    fi
    
    if [ "$INSTALL_ADBC" = true ]; then
        echo ""
        echo "--- Go Version ---"
        micromamba run -n "$R_ENV_NAME" go version 2>/dev/null || echo "(not found)"
    fi
    
    log_success "Verification complete"
}

# -----------------------------------------------------------------------------
# Step 9: Print instructions
# -----------------------------------------------------------------------------

print_instructions() {
    echo ""
    echo "=============================================="
    echo " Installation Complete!"
    echo "=============================================="
    echo ""
    echo "To activate the environment:"
    echo ""
    echo "  export MAMBA_ROOT_PREFIX=$MAMBA_ROOT_PREFIX"
    echo "  export PATH=\$MAMBA_ROOT_PREFIX/bin:\$PATH"
    echo "  eval \"\$(\$MAMBA_ROOT_PREFIX/bin/micromamba shell hook -s bash)\""
    echo "  micromamba activate $R_ENV_NAME"
    echo ""
    
    if [ "$INSTALL_ADBC" = true ]; then
        echo "To use ADBC from R (direct connection):"
        echo ""
        echo "  library(DBI)"
        echo "  library(adbcsnowflake)"
        echo "  con <- adbcsnowflake::snowflake()"
        echo "  # ... set PAT/credentials ..."
        echo ""
    fi
    
    if [ "$INSTALL_DUCKDB" = true ]; then
        echo "To use DuckDB + Snowflake from R:"
        echo ""
        echo "  library(DBI)"
        echo "  library(duckdb)"
        echo "  con <- dbConnect(duckdb::duckdb())"
        echo "  DBI::dbExecute(con, 'LOAD snowflake')"
        echo ""
        echo "  # Create secret with key_pair auth"
        echo "  DBI::dbExecute(con, \"CREATE SECRET sf (TYPE snowflake, ...\")"
        echo "  DBI::dbExecute(con, \"ATTACH '' AS sf (TYPE snowflake, SECRET sf, READ_ONLY)\")"
        echo ""
    fi
    
    echo "=============================================="
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    install_micromamba
    setup_shell_env
    create_r_env
    fix_symlinks
    install_adbc_with_go
    install_duckdb_setup
    install_python_packages
    verify_installation
    print_instructions
}

main
