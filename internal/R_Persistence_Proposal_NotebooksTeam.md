# R Environment Persistence in Workspace Notebooks

## Proposal for Snowflake Notebooks Team

**Date:** February 2026  
**Author:** SnowCAT Team  
**Status:** Proposal for Discussion

---

## Executive Summary

We have developed a working solution to run R within Snowflake Workspace Notebooks using rpy2 and ADBC. However, the current implementation requires **reinstalling R and all packages (~2-5 minutes) every time the kernel or service restarts**.

This document proposes leveraging `PERSISTENT_DIR` (pd0 block storage) to persist R installations across restarts, reducing subsequent startup time to **~10 seconds**.

---

## Current Situation

### What We've Built

- R installation via micromamba in user space
- rpy2 integration for Python-R interoperability
- ADBC connectivity to Snowflake using PAT authentication
- Helper scripts and utilities for setup

### Current Pain Point

| Scenario | Time Required |
|----------|---------------|
| First run | 2-5 minutes |
| Kernel restart | 2-5 minutes (full reinstall) |
| Service restart | 2-5 minutes (full reinstall) |

**Root cause:** R is installed to `$HOME/micromamba` which is ephemeral and does not persist across restarts.

---

## Understanding Workspace Notebook Storage

Based on our analysis (see `internal/spcs_persistent_storage.md`), Workspace Notebooks have **two separate storage layers**:

```
┌─────────────────────────────────────────────────────────────────┐
│                  Workspace Notebook Container                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. WORKSPACE FILES (FBE)              2. PERSISTENT STORAGE    │
│  ─────────────────────────             ─────────────────────    │
│  /workspace/WS_NAME/                   $PERSISTENT_DIR (pd0/)   │
│  /filesystem/<hash>/                                            │
│                                                                 │
│  • Notebook files (.ipynb)             • SPCS Block Storage     │
│  • Python scripts (.py)                • Large artifacts        │
│  • Config files                        • Installed packages     │
│  • Git-tracked if Git-backed           • NOT Git-tracked        │
│  • Synced to Workspace UI              • Per-notebook storage   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** The `PERSISTENT_DIR` (pd0) uses SPCS block storage that **persists across kernel/service restarts** and is only deleted when the notebook itself is deleted.

---

## Proposed Solution

### Install R to PERSISTENT_DIR

Instead of installing to ephemeral `$HOME`, install R and packages to `$PERSISTENT_DIR/r_env`:

| Consideration | Assessment |
|---------------|------------|
| **Persistence** | ✅ Survives kernel/service restarts |
| **Storage type** | ✅ SPCS block storage, designed for this use case |
| **Size** | ✅ Block storage handles 500MB-2GB+ R installations |
| **Performance** | ✅ Local filesystem, fast access |
| **Lifecycle** | ⚠️ Deleted when notebook is deleted (acceptable) |
| **Sharing** | ⚠️ Per-notebook, not shared across notebooks |

### Why Not Git-backed Workspace Directory?

We evaluated installing to `/workspace/WS_NAME/R` but this is **not recommended**:

| Issue | Impact |
|-------|--------|
| **Size** | R + packages = 500MB-2GB+; FBE designed for source files |
| **Git performance** | Large binaries cause slow clone/push/pull |
| **Workspace sync** | Two-way sync not optimized for binary trees |
| **.gitignore** | Even if excluded, FBE persistence behavior uncertain |

---

## Implementation Approach

### Phase 1: Detect and Use Persistent Storage

The setup script would check for `PERSISTENT_DIR` and use it if available:

```bash
# Pseudo-code for enhanced setup script
if [ -n "${PERSISTENT_DIR:-}" ]; then
    # Use persistent storage
    MICROMAMBA_ROOT="${PERSISTENT_DIR}/micromamba"
    ENV_PREFIX="${PERSISTENT_DIR}/r_env"
    
    # Check if already installed
    if [ -x "${ENV_PREFIX}/bin/R" ]; then
        echo "R already installed in persistent storage, skipping installation"
        # Just configure environment variables
        export PATH="${ENV_PREFIX}/bin:${PATH}"
        export R_HOME="${ENV_PREFIX}/lib/R"
        exit 0
    fi
else
    # Fall back to ephemeral home directory
    MICROMAMBA_ROOT="${HOME}/micromamba"
fi
```

### Phase 2: Use Micromamba's Prefix Control

Micromamba supports explicit prefix specification (see `internal/micromamb_r_installation.md`):

```bash
# Install to specific persistent path
micromamba create -p "${PERSISTENT_DIR}/r_env" -c conda-forge r-base r-tidyverse
```

For CRAN packages:

```bash
# Set custom library path for CRAN packages
export R_LIBS_USER="${PERSISTENT_DIR}/r_libs"
micromamba env config vars set -p "${PERSISTENT_DIR}/r_env" R_LIBS_USER="${R_LIBS_USER}"
```

### Phase 3: Hybrid Storage Model

```
Git-backed Workspace (tracked)     PERSISTENT_DIR (not tracked)
─────────────────────────────      ─────────────────────────────
r_notebook/                        $PERSISTENT_DIR/
├── r_packages.yaml      ──────►   ├── micromamba/
├── setup_r_environment.sh         ├── r_env/
├── r_helpers.py                   │   ├── bin/R
├── r_workspace_notebook.ipynb     │   ├── lib/R/
└── README.md                      │   └── lib/R/library/
                                   └── r_libs/  (CRAN packages)
```

---

## Expected Benefits

| Metric | Current (Ephemeral) | With Persistence |
|--------|---------------------|------------------|
| First run | 2-5 minutes | 2-5 minutes |
| Subsequent runs | 2-5 minutes | **~10 seconds** |
| Kernel restart | Full reinstall | **Path config only** |
| Service restart | Full reinstall | **Path config only** |

**User experience improvement:** 10-30x faster startup on subsequent runs.

---

## Caveats and Considerations

1. **Notebook deletion**: Deleting the notebook deletes `PERSISTENT_DIR` and all installed packages (acceptable - user can reinstall)

2. **Not shared**: Each notebook has its own persistent storage; R must be installed per-notebook (acceptable for isolation)

3. **Version management**: May need version checks to detect stale installations after updates

4. **Disk space**: Users should monitor `PERSISTENT_DIR` usage; block storage has limits

5. **rpy2 reinstall**: rpy2 is installed into the kernel's Python venv (ephemeral), so it still needs reinstallation on kernel restart (~30 seconds, unavoidable without kernel changes)

---

## Questions for Notebooks Team

1. **Is `PERSISTENT_DIR` available and writable** in all Workspace Notebook configurations?

2. **Are there size limits** on `PERSISTENT_DIR` that would affect R installations (typically 500MB-2GB)?

3. **Is this the intended use case** for `PERSISTENT_DIR`, or are there better alternatives?

4. **Are there plans** for shared persistent storage across notebooks (e.g., workspace-level persistence)?

5. **Would the Notebooks team consider** pre-installing R as an optional runtime component (similar to how Python is pre-installed)?

---

## References

### Internal Documentation
- `internal/spcs_persistent_storage.md` - SPCS storage architecture analysis
- `internal/micromamb_r_installation.md` - Micromamba installation customization
- `internal/R_Integration_Summary_and_Recommendations.md` - Full R integration documentation
- `r_notebook/` - Working implementation (ephemeral storage)

### External Documentation
- [SPCS Block Storage Volumes](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/block-storage-volume)
- [Workspace Notebooks Documentation](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks)

---

## Next Steps

1. **Discuss with Notebooks team** to validate approach
2. **Confirm PERSISTENT_DIR availability** and constraints
3. **Implement `--persistent` flag** in setup script (if approved)
4. **Test persistence** across kernel/service restarts
5. **Document** the persistence feature for users
