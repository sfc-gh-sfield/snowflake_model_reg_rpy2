# R Integration for Snowflake Workspace Notebooks

## Executive Summary

This project demonstrates a complete solution for running R code within Snowflake Workspace Notebooks using `rpy2`. It enables R-preferring data scientists to leverage their existing R skills while integrating with Snowflake's data platform and MLOps ecosystem.

**Key Achievement:** End-to-end workflow from R model training to Snowflake Model Registry deployment, all within Workspace Notebooks.

---

## What We Built

### 1. R Environment Installation Framework

A robust installation system using `micromamba` that:
- Installs R and packages into the container without root access
- Supports configurable package lists via YAML
- Provides both basic R and ADBC-enabled configurations
- Is idempotent (safe to re-run)

**Files:**
- `setup_r_environment.sh` - Main installation script
- `r_packages.yaml` - Package configuration
- `r_helpers.py` - Python helper module

### 2. Python-R Interoperability

Seamless bidirectional data transfer using `rpy2`:
- `%%R` magic cells for inline R code
- `-i` flag to pass Python objects to R
- `-o` flag to export R objects to Python
- Automatic pandas ↔ R data.frame conversion

### 3. Snowflake Connectivity from R

Two proven methods for R to access Snowflake data:

| Method | Authentication | Best For |
|--------|---------------|----------|
| **ADBC** | PAT or Key Pair | Production pipelines, large datasets |
| **Reticulate + Snowpark** | Built-in (no setup) | Quick analysis, prototyping |

### 4. Model Registry Integration

Python wrapper pattern enabling R models in Snowflake Model Registry:
- R model trained and saved as `.rds`
- Python `CustomModel` wrapper using rpy2
- Deployed to SPCS for inference
- 5-20x faster than subprocess/CSV approach

### 5. Data Visualization

ggplot2 integration with proper Notebook rendering:
- Plot sizing via `%%R -w WIDTH -h HEIGHT`
- `ggsave()` for export
- Display saved plots from Python cells

---

## What We Tested

### Environment Setup
| Test | Result |
|------|--------|
| R installation via micromamba | ✅ Works |
| rpy2 installation into kernel venv | ✅ Works |
| `%%R` magic registration | ✅ Works |
| Package installation from YAML | ✅ Works |
| Interactive package installation (CRAN) | ✅ Works |
| Interactive package installation (micromamba) | ✅ Works |

### Data Transfer
| Test | Result |
|------|--------|
| Python DataFrame → R | ✅ Works |
| R data.frame → Python | ✅ Works |
| Large dataset transfer | ✅ Works |
| Type preservation | ✅ Works |

### Snowflake Connectivity
| Method | Result | Notes |
|--------|--------|-------|
| ADBC + PAT | ✅ Works | Recommended |
| ADBC + Key Pair (JWT) | ✅ Works | Alternative |
| ADBC + SPCS OAuth Token | ❌ Blocked | Token restricted to specific connectors |
| ADBC + Username/Password | ❌ Blocked | SPCS enforces OAuth internally |
| Reticulate + Snowpark | ✅ Works | No auth setup needed |

### Model Registry
| Test | Result |
|------|--------|
| Train R model (forecast/ARIMA) | ✅ Works |
| Save model as .rds | ✅ Works |
| Create rpy2 Python wrapper | ✅ Works |
| Log to Model Registry | ✅ Works |
| Deploy to SPCS | ✅ Works |
| Run inference | ✅ Works |

### Visualization
| Test | Result |
|------|--------|
| Basic ggplot2 plots | ✅ Works |
| Plot sizing (-w, -h) | ✅ Works |
| ggsave() to file | ✅ Works |
| Display PNG from Python | ✅ Works |
| Faceted/complex plots | ✅ Works |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Snowflake Workspace Notebook                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Python Kernel                                             │  │
│  │  ├─ rpy2 (Python-R bridge)                                │  │
│  │  ├─ %%R magic cells                                       │  │
│  │  └─ Snowpark session (built-in)                           │  │
│  └───────────────────────────────────────────────────────────┘  │
│                          │                                      │
│                          ▼                                      │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  R Environment (micromamba)                               │  │
│  │  ├─ R 4.x                                                 │  │
│  │  ├─ tidyverse, ggplot2, dplyr                            │  │
│  │  ├─ forecast (time series)                               │  │
│  │  ├─ adbcsnowflake (optional)                             │  │
│  │  └─ reticulate (Python interop from R)                   │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
┌─────────────────────┐       ┌─────────────────────┐
│  Snowflake Data     │       │  Model Registry     │
│  (via ADBC or       │       │  (SPCS deployment)  │
│   Reticulate)       │       │                     │
└─────────────────────┘       └─────────────────────┘
```

---

## Key Findings

### What Works Well
1. **rpy2 integration** - Stable, fast, good error handling
2. **micromamba** - Lightweight, no root needed, reproducible
3. **ADBC performance** - Arrow-based transfer is efficient
4. **Reticulate fallback** - Zero-config Snowflake access from R
5. **Model Registry** - R models deployable via Python wrapper

### Limitations Discovered
1. **SPCS OAuth token** - Cannot be used with ADBC (restricted to specific connectors)
2. **R output formatting** - Notebooks add extra line breaks; workaround via helper functions
3. **No persistence** - R environment must be reinstalled on restart (see proposal doc)
4. **No native R kernel** - Must use Python kernel with `%%R` magic

### Performance Notes
- R environment installation: ~2-3 minutes (basic), ~3-4 minutes (with ADBC)
- rpy2 wrapper vs subprocess: 5-20x faster per prediction
- ADBC queries: Arrow-native, minimal serialization overhead

---

## Notebooks

### 1. `r_workspace_notebook.ipynb` (Main Reference)
Comprehensive guide covering:
- Section 1: Installation & Configuration
- Section 2: Python-R Interoperability  
- Section 3: Snowflake via ADBC
- Section 4: Key Pair Authentication
- Section 5: Snowflake via Reticulate
- Section 6: Data Visualization with ggplot2

### 2. `r_forecasting_demo.ipynb` (End-to-End Example)
Complete workflow demonstrating:
- Query TPC-H data from Snowflake
- Train ARIMA model in R
- Register to Snowflake Model Registry
- Deploy and run inference via SPCS
- Visualize results with ggplot2

---

## Files Reference

| File | Purpose |
|------|---------|
| `r_workspace_notebook.ipynb` | Main reference notebook |
| `r_forecasting_demo.ipynb` | End-to-end forecasting demo |
| `setup_r_environment.sh` | R installation script |
| `r_packages.yaml` | Package configuration |
| `r_helpers.py` | Python helper module |
| `README.md` | Quick start guide |
| `PROJECT_OVERVIEW.md` | This document |

---

## Related Documentation

| Document | Location |
|----------|----------|
| Summary & Recommendations | `internal/R_Integration_Summary_and_Recommendations.md` |
| Persistence Proposal | `internal/R_Persistence_Proposal_NotebooksTeam.md` |
| SPCS Storage Explanation | `internal/spcs_persistent_storage.md` |
| Original Glean Conversation | `internal/WorkspaceNotebooksR_ADBC_Setup_GleanConversation.md` |

---

## Next Steps / Recommendations

1. **Persistence** - Evaluate using `PERSISTENT_DIR` for R installation (see proposal doc)
2. **Native R kernel** - Would simplify UX for R-only users
3. **Pre-built R image** - Container with R pre-installed would eliminate setup time
4. **Documentation** - Consider adding R integration to official Notebooks docs

---

## Contact

For questions about this implementation, contact the project maintainer or refer to the internal documentation in the `internal/` folder.
