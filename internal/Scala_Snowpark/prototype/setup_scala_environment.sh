#!/usr/bin/env bash
# =============================================================================
# Scala / JVM Environment Setup for Snowflake Workspace Notebooks
# =============================================================================
#
# This script installs OpenJDK, Scala, Ammonite, and the Snowpark Scala JAR
# into an isolated micromamba environment, suitable for use with JPype and
# a %%scala magic in Snowflake Workspace Notebooks.
#
# Usage:
#   ./setup_scala_environment.sh [OPTIONS]
#
# Options:
#   --config FILE   Specify alternate config file (default: scala_packages.yaml)
#   --log FILE      Write output to log file (default: setup_scala.log)
#   --no-log        Disable logging to file
#   --verbose       Show detailed output
#   --force         Force reinstallation (skip "already installed" checks)
#   --help          Show this help message
#
# Re-runnability:
#   This script is idempotent. Use --force to reinstall everything.
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Default Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/scala_packages.yaml"
LOG_FILE="${SCRIPT_DIR}/setup_scala.log"
ENABLE_LOGGING=true
VERBOSE=false
FORCE_REINSTALL=false
MICROMAMBA_ROOT="${HOME}/micromamba"
ENV_NAME="jvm_env"
CHANNEL="conda-forge"
JAR_DIR="${HOME}/scala_jars"

MAX_RETRIES=3
RETRY_DELAY=5
MIN_DISK_SPACE_MB=1500

# Defaults (overridden by YAML config)
JAVA_VERSION="17"
SCALA_VERSION="2.12"
SNOWPARK_VERSION="1.18.0"
AMMONITE_VERSION="3.0.8"
JVM_OPTIONS=""
EXTRA_DEPS=""

# =============================================================================
# Logging Functions
# =============================================================================

setup_logging() {
    if [ "${ENABLE_LOGGING}" = true ]; then
        cat > "${LOG_FILE}" << EOF
================================================================================
Scala/JVM Environment Setup Log
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

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
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
        "https://repo1.maven.org"
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

    if ! check_disk_space; then checks_passed=false; fi
    check_network || true

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
Scala/JVM Environment Setup for Snowflake Workspace Notebooks

Usage: ./setup_scala_environment.sh [OPTIONS]

Options:
  --config FILE   Specify alternate config file (default: scala_packages.yaml)
  --log FILE      Write output to log file (default: setup_scala.log)
  --no-log        Disable logging to file
  --verbose       Show detailed output
  --force         Force reinstallation (skip "already installed" checks)
  --help          Show this help message

The package configuration file (scala_packages.yaml) supports:
  java_version: "17"
  scala_version: "2.12"
  snowpark_version: "1.18.0"
  ammonite_version: "3.0.8"
  jvm_options: ["-Xmx1g"]
  extra_dependencies: ["group:artifact:version"]

Examples:
  ./setup_scala_environment.sh                         # Default installation
  ./setup_scala_environment.sh --config custom.yaml    # Custom config
  ./setup_scala_environment.sh --force --verbose       # Force reinstall
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)   CONFIG_FILE="$2"; shift 2 ;;
        --log)      LOG_FILE="$2"; shift 2 ;;
        --no-log)   ENABLE_LOGGING=false; shift ;;
        --verbose)  VERBOSE=true; shift ;;
        --force)    FORCE_REINSTALL=true; shift ;;
        --help|-h)  show_help; exit 0 ;;
        *)          echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# =============================================================================
# Main Setup
# =============================================================================

main() {
    setup_logging

    echo "=============================================================================="
    echo "Scala/JVM Environment Setup for Snowflake Workspace Notebooks"
    echo "=============================================================================="
    echo ""

    if ! run_preflight_checks; then exit 1; fi

    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "Configuration file not found: ${CONFIG_FILE}"
        exit 1
    fi

    # =========================================================================
    # Step 1: Parse YAML Configuration
    # =========================================================================

    log_info "Step 1: Reading package configuration..."

    eval "$(python3 << PYEOF
import yaml, json

with open("${CONFIG_FILE}", 'r') as f:
    config = yaml.safe_load(f)

print(f'JAVA_VERSION="{config.get("java_version", "17")}"')
print(f'SCALA_VERSION="{config.get("scala_version", "2.12")}"')
print(f'SNOWPARK_VERSION="{config.get("snowpark_version", "1.18.0")}"')
print(f'AMMONITE_VERSION="{config.get("ammonite_version", "3.0.8")}"')

jvm_heap = config.get("jvm_heap", "auto")
print(f'JVM_HEAP="{jvm_heap}"')

jvm_opts = config.get("jvm_options", []) or []
print(f'JVM_OPTIONS="{" ".join(jvm_opts)}"')

extra = config.get("extra_dependencies", []) or []
print(f'EXTRA_DEPS="{" ".join(extra)}"')
PYEOF
)"

    log_info "  Java version:     ${JAVA_VERSION}"
    log_info "  Scala version:    ${SCALA_VERSION}"
    log_info "  Snowpark version: ${SNOWPARK_VERSION}"
    log_info "  Ammonite version: ${AMMONITE_VERSION}"
    log_info "  JVM heap:         ${JVM_HEAP}"
    log_info "  JVM options:      ${JVM_OPTIONS}"
    [ -n "${EXTRA_DEPS}" ] && log_info "  Extra deps:       ${EXTRA_DEPS}"
    echo ""

    # =========================================================================
    # Step 2: Install micromamba
    # =========================================================================

    log_info "Step 2: Installing micromamba..."

    if [ "${FORCE_REINSTALL}" = false ] && [ -x "${MICROMAMBA_ROOT}/bin/micromamba" ]; then
        log_info "  [OK] micromamba already installed (skipping)"
    else
        log_info "  Downloading micromamba..."
        mkdir -p "${MICROMAMBA_ROOT}/bin"
        cd /tmp
        retry_command \
            "curl -Ls --retry 3 --retry-delay 2 https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba" \
            "Download micromamba"
        mv bin/micromamba "${MICROMAMBA_ROOT}/bin/micromamba"
        rmdir bin 2>/dev/null || true
        log_info "  micromamba installed at ${MICROMAMBA_ROOT}/bin/micromamba"
    fi

    export PATH="${MICROMAMBA_ROOT}/bin:${PATH}"

    # =========================================================================
    # Step 3: Create JVM Environment (OpenJDK + Scala)
    # =========================================================================

    echo ""
    log_info "Step 3: Setting up JVM environment..."

    ENV_EXISTS=false
    if micromamba env list 2>/dev/null | awk '{print $1}' | grep -qx "${ENV_NAME}"; then
        ENV_EXISTS=true
    fi

    CONDA_PACKAGES="openjdk=${JAVA_VERSION}"

    if [ "${ENV_EXISTS}" = true ] && [ "${FORCE_REINSTALL}" = false ]; then
        log_info "  [OK] Environment '${ENV_NAME}' already exists (skipping)"
    elif [ "${ENV_EXISTS}" = true ] && [ "${FORCE_REINSTALL}" = true ]; then
        log_info "  Force reinstalling environment packages..."
        retry_command \
            "micromamba install -y -n '${ENV_NAME}' -c '${CHANNEL}' ${CONDA_PACKAGES}" \
            "Update JVM environment"
    else
        log_info "  Creating environment '${ENV_NAME}' with OpenJDK ${JAVA_VERSION}..."
        retry_command \
            "micromamba create -y -n '${ENV_NAME}' -c '${CHANNEL}' ${CONDA_PACKAGES}" \
            "Create JVM environment"
    fi

    ENV_PREFIX="$(micromamba env list | awk -v name="${ENV_NAME}" '$1 == name {print $NF}')"
    if [ -z "${ENV_PREFIX}" ]; then
        log_error "Could not resolve prefix for env '${ENV_NAME}'"
        exit 1
    fi

    export PATH="${ENV_PREFIX}/bin:${PATH}"
    export JAVA_HOME="${ENV_PREFIX}"
    log_info "  Environment prefix: ${ENV_PREFIX}"
    log_info "  JAVA_HOME: ${JAVA_HOME}"

    # Verify Java
    if java -version 2>&1 | head -n1; then
        log_info "  Java OK"
    else
        log_error "  Java not found after installation"
        exit 1
    fi

    # =========================================================================
    # Step 4: Install Coursier
    # =========================================================================

    echo ""
    log_info "Step 4: Installing coursier..."

    CS_BIN="${ENV_PREFIX}/bin/cs"

    if [ "${FORCE_REINSTALL}" = false ] && [ -x "${CS_BIN}" ]; then
        log_info "  [OK] coursier already installed (skipping)"
    else
        log_info "  Downloading coursier..."
        retry_command \
            "curl -fL 'https://github.com/coursier/launchers/raw/master/cs-x86_64-pc-linux.gz' | gzip -d > '${CS_BIN}'" \
            "Download coursier"
        chmod +x "${CS_BIN}"
        log_info "  coursier installed at ${CS_BIN}"
    fi

    # Verify coursier
    cs --version 2>/dev/null && log_info "  coursier OK" || log_warn "  coursier version check failed (may still work)"

    # =========================================================================
    # Step 5: Create JAR directory and resolve Snowpark JARs via Coursier
    # =========================================================================

    echo ""
    log_info "Step 5: Resolving Snowpark JARs..."

    mkdir -p "${JAR_DIR}"

    SNOWPARK_CP_FILE="${JAR_DIR}/snowpark_classpath.txt"
    SNOWPARK_ARTIFACT="com.snowflake:snowpark_${SCALA_VERSION}:${SNOWPARK_VERSION}"

    if [ "${FORCE_REINSTALL}" = false ] && [ -f "${SNOWPARK_CP_FILE}" ]; then
        log_info "  [OK] Snowpark classpath already resolved (skipping)"
    else
        log_info "  Resolving ${SNOWPARK_ARTIFACT} and transitive dependencies..."
        retry_command \
            "cs fetch '${SNOWPARK_ARTIFACT}' --classpath > '${SNOWPARK_CP_FILE}'" \
            "Resolve Snowpark JARs"

        if [ -f "${SNOWPARK_CP_FILE}" ]; then
            local jar_count
            jar_count=$(tr ':' '\n' < "${SNOWPARK_CP_FILE}" | wc -l | tr -d ' ')
            log_info "  Snowpark resolved: ${jar_count} JARs on classpath"
        else
            log_error "  Failed to resolve Snowpark classpath"
        fi
    fi

    # =========================================================================
    # Step 6: Resolve Scala compiler and Ammonite JARs via Coursier
    # =========================================================================

    echo ""
    log_info "Step 6: Resolving Scala compiler and Ammonite JARs..."

    # Determine the full Scala version that coursier will use
    SCALA_FULL_VERSION=""

    # 6a. Fetch Scala compiler/library JARs
    SCALA_CP_FILE="${JAR_DIR}/scala_classpath.txt"

    if [ "${FORCE_REINSTALL}" = false ] && [ -f "${SCALA_CP_FILE}" ]; then
        log_info "  [OK] Scala classpath already resolved (skipping)"
    else
        log_info "  Resolving Scala ${SCALA_VERSION} compiler JARs..."
        # Fetch the latest 2.12.x compiler
        retry_command \
            "cs fetch org.scala-lang:scala-compiler:${SCALA_VERSION}+ org.scala-lang:scala-reflect:${SCALA_VERSION}+ --classpath 2>/dev/null > '${SCALA_CP_FILE}'" \
            "Resolve Scala compiler"

        if [ -f "${SCALA_CP_FILE}" ] && [ -s "${SCALA_CP_FILE}" ]; then
            local num_jars
            num_jars=$(tr ':' '\n' < "${SCALA_CP_FILE}" | wc -l)
            log_info "  Scala classpath: ${num_jars} JARs resolved"
        else
            log_error "  Failed to resolve Scala classpath"
            exit 1
        fi
    fi

    # Detect the exact Scala version from the resolved JARs
    SCALA_FULL_VERSION=$(tr ':' '\n' < "${SCALA_CP_FILE}" | grep 'scala-library' | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
    log_info "  Scala full version: ${SCALA_FULL_VERSION:-unknown}"

    # 6b. Fetch Ammonite JARs
    AMMONITE_CP_FILE="${JAR_DIR}/ammonite_classpath.txt"

    if [ "${FORCE_REINSTALL}" = false ] && [ -f "${AMMONITE_CP_FILE}" ]; then
        log_info "  [OK] Ammonite classpath already resolved (skipping)"
    else
        # Ammonite artifact includes the full Scala version in its name
        # e.g., com.lihaoyi:ammonite_2.12.20:3.0.8
        if [ -n "${SCALA_FULL_VERSION}" ]; then
            AMMONITE_ARTIFACT="com.lihaoyi:ammonite_${SCALA_FULL_VERSION}:${AMMONITE_VERSION}"
        else
            # Fallback: let coursier try with the short version
            AMMONITE_ARTIFACT="com.lihaoyi:ammonite_${SCALA_VERSION}:${AMMONITE_VERSION}"
        fi

        log_info "  Resolving Ammonite: ${AMMONITE_ARTIFACT}..."
        retry_command \
            "cs fetch '${AMMONITE_ARTIFACT}' --classpath 2>/dev/null > '${AMMONITE_CP_FILE}'" \
            "Resolve Ammonite JARs"

        if [ -f "${AMMONITE_CP_FILE}" ] && [ -s "${AMMONITE_CP_FILE}" ]; then
            local num_jars
            num_jars=$(tr ':' '\n' < "${AMMONITE_CP_FILE}" | wc -l)
            log_info "  Ammonite classpath: ${num_jars} JARs resolved"
        else
            log_warn "  Ammonite resolution failed. Will fall back to IMain (Option A)."
            echo "" > "${AMMONITE_CP_FILE}"
        fi
    fi

    # 6c. Resolve extra dependencies
    EXTRA_CP_FILE="${JAR_DIR}/extra_classpath.txt"
    echo "" > "${EXTRA_CP_FILE}"

    if [ -n "${EXTRA_DEPS}" ]; then
        log_info "  Resolving extra dependencies..."
        for dep in ${EXTRA_DEPS}; do
            log_info "    Resolving ${dep}..."
            local dep_cp
            dep_cp=$(cs fetch "${dep}" --classpath 2>/dev/null || echo "")
            if [ -n "${dep_cp}" ]; then
                if [ -s "${EXTRA_CP_FILE}" ]; then
                    echo -n ":${dep_cp}" >> "${EXTRA_CP_FILE}"
                else
                    echo -n "${dep_cp}" > "${EXTRA_CP_FILE}"
                fi
            else
                log_warn "    Failed to resolve: ${dep}"
            fi
        done
    fi

    # =========================================================================
    # Step 7: Write environment metadata
    # =========================================================================

    echo ""
    log_info "Step 7: Writing environment metadata..."

    METADATA_FILE="${JAR_DIR}/scala_env_metadata.json"
    python3 << PYEOF
import json

metadata = {
    "env_prefix": "${ENV_PREFIX}",
    "java_home": "${JAVA_HOME}",
    "java_version": "${JAVA_VERSION}",
    "scala_version": "${SCALA_VERSION}",
    "scala_full_version": "${SCALA_FULL_VERSION}",
    "snowpark_version": "${SNOWPARK_VERSION}",
    "snowpark_classpath_file": "${SNOWPARK_CP_FILE}",
    "ammonite_version": "${AMMONITE_VERSION}",
    "jar_dir": "${JAR_DIR}",
    "scala_classpath_file": "${SCALA_CP_FILE}",
    "ammonite_classpath_file": "${AMMONITE_CP_FILE}",
    "extra_classpath_file": "${EXTRA_CP_FILE}",
    "jvm_heap": "${JVM_HEAP}",
    "jvm_options": "${JVM_OPTIONS}".split(),
}

with open("${METADATA_FILE}", "w") as f:
    json.dump(metadata, f, indent=2)

print(f"  Metadata written to ${METADATA_FILE}")
PYEOF

    # =========================================================================
    # Step 8: Install JPype into kernel venv
    # =========================================================================

    echo ""
    log_info "Step 8: Installing JPype1 into Python kernel..."

    if python3 -c "import jpype" 2>/dev/null && [ "${FORCE_REINSTALL}" = false ]; then
        log_info "  [OK] JPype1 already installed (skipping)"
    else
        retry_command \
            "python3 -m pip install JPype1 -q" \
            "Install JPype1"
        log_info "  JPype1 installed"
    fi

    # Verify JPype can find the JVM
    python3 << PYEOF
import jpype
jvm_path = jpype.getDefaultJVMPath()
print(f"  JPype JVM path: {jvm_path}")
PYEOF

    # =========================================================================
    # Step 9: Summary
    # =========================================================================

    echo ""
    echo "=============================================================================="
    echo "Installation Complete!"
    echo "=============================================================================="
    echo ""
    log_info "Environment Details:"
    log_info "  Environment:      ${ENV_NAME}"
    log_info "  Prefix:           ${ENV_PREFIX}"
    log_info "  JAVA_HOME:        ${JAVA_HOME}"
    log_info "  JAR directory:    ${JAR_DIR}"
    log_info "  Snowpark CP:      ${SNOWPARK_CP_FILE}"
    log_info "  Metadata:         ${METADATA_FILE}"

    if [ "${ENABLE_LOGGING}" = true ]; then
        log_info "  Log file:         ${LOG_FILE}"
    fi

    # Check if Ammonite is available
    if [ -f "${AMMONITE_CP_FILE}" ] && [ -s "${AMMONITE_CP_FILE}" ]; then
        log_info "  REPL engine:      Ammonite (Option A2)"
    else
        log_info "  REPL engine:      IMain (Option A — Ammonite not resolved)"
    fi

    echo ""
    echo "To use in your Notebook, run the configuration cell:"
    echo ""
    echo "    from scala_helpers import setup_scala_environment"
    echo "    result = setup_scala_environment()"
    echo ""
    echo "Then use %%scala cells:"
    echo ""
    echo "    %%scala"
    echo "    println(\"Hello from Scala!\")"
    echo ""

    log_info "Tip: Re-run this script anytime. Use --force to reinstall everything."
    log_info "Done."
}

main "$@"
