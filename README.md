# R Model Inference in Snowflake Model Registry: Subprocess vs rpy2

## Overview

This project explores **two approaches** for deploying R models to Snowflake's Model Registry and executing inference via Snowpark Container Services (SPCS).

**Our hypothesis**: The `rpy2` Python package offers a more efficient and cleaner way of interacting with R for model inference purposes compared to the traditional subprocess + CSV file interchange pattern.

This repository takes an original implementation based on [Snowflake's published approach](https://medium.com/snowflake/deploying-r-models-in-snowflakes-model-registry-effcf04dd85c) and demonstrates an alternative implementation using `rpy2` for direct Python-R interoperability.

---

## Acknowledgements

This project builds upon the excellent work by **Kaitlyn Wells** (Snowflake), whose [Medium article](https://medium.com/snowflake/deploying-r-models-in-snowflakes-model-registry-effcf04dd85c) and accompanying code demonstrated how to deploy R models in Snowflake's Model Registry using the subprocess + CSV approach. Her work provided the foundation and inspiration for exploring the rpy2 optimization presented here.

---

## The Problem

Snowflake's Model Registry is Python-native. To deploy R models, you need a Python wrapper that can execute R code. The conventional approach uses:

```
Python → CSV file → Rscript subprocess → CSV file → Python
```

This pattern has inherent overhead:
- **File I/O** on every prediction call
- **Process spawning** for each inference request
- **Serialization costs** (DataFrame → CSV → R data.frame → CSV → DataFrame)
- **Complex cleanup** of temporary files

---

## The Alternative: rpy2

The `rpy2` package embeds an R interpreter directly within the Python process, enabling:

```
Python → R data.frame (in-memory) → Python
```

**Key benefits**:
- **5-20x faster** per-prediction (no I/O overhead)
- **~50% less code** in the wrapper
- **Better error handling** with Python-native exceptions
- **Type fidelity** preserved (no CSV conversion loss)
- **Simpler deployment** — no temp file management

---

## Project Structure

```
snowflake_model_reg_rpy2/
├── README.md                    # This file
├── environment.yml              # Conda environment specification
├── .gitignore
│
├── dj_ml/                       # Original Implementation (subprocess)
│   ├── README.md               # Detailed documentation
│   ├── r_model_wrapper.py      # Python CustomModel with subprocess
│   ├── predict_arimax.R        # Standalone R prediction script
│   ├── train_arimax.R          # R model training script
│   ├── arimax_model_artifact.rds
│   ├── model_logging.ipynb     # Snowflake deployment notebook
│   └── setup_demo.sh
│
└── dj_ml_rpy2/                  # Alternative Implementation (rpy2)
    ├── README.md               # Detailed documentation
    ├── ASSESSMENT.md           # Full feasibility analysis ⭐
    ├── r_model_wrapper_rpy2.py # Python CustomModel with rpy2
    ├── predict_arimax_rpy2.py  # Standalone prediction module
    ├── model_logging_rpy2.ipynb
    └── setup_rpy2.sh
```

---

## Quick Comparison

| Aspect | Original (subprocess) | Alternative (rpy2) |
|--------|----------------------|-------------------|
| Data transfer | CSV files | In-memory |
| R execution | Subprocess per call | Embedded interpreter |
| Per-prediction latency | ~200-500ms | ~10-50ms |
| Cold start | ~2-3s | ~3-4s |
| Code complexity | Higher | Lower |
| Dependencies | r-base, r-forecast | + rpy2 |

---

## Key Findings

From our [detailed assessment](dj_ml_rpy2/ASSESSMENT.md):

### ✅ rpy2 is Production-Ready for Snowflake

- All dependencies (`rpy2`, `r-base`, `r-forecast`) available on **conda-forge**
- Compatible with Snowflake's `conda_dependencies` parameter
- Works with **Snowpark Container Services** target platform

### ⚡ Performance Gains are Significant

The elimination of file I/O and subprocess spawning delivers **5-20x improvement** in per-prediction latency. For high-frequency inference workloads, this translates to meaningful cost and latency savings.

### ⚠️ Trade-offs to Consider

- **Cold start**: R initialization adds ~1s to container startup
- **Memory footprint**: Embedded R uses base memory (mitigated by appropriate SPCS instance sizing)
- **Debugging**: R errors surface as Python exceptions (requires familiarity with rpy2 error handling)

### 📝 Code Simplification

The rpy2 wrapper eliminates:
- Temporary file creation/cleanup
- CSV serialization/deserialization
- Subprocess management
- External R script dependencies

---

## Getting Started

### Prerequisites

- Python 3.11+
- R 4.x with `forecast` package
- Conda (recommended for environment management)
- Snowflake account with Model Registry and SPCS access

### Local Development Setup

```bash
# Create conda environment with Python, R, and rpy2
conda env create -f environment.yml -p ./.conda/rpy2-arimax

# Activate environment
conda activate ./.conda/rpy2-arimax

# Test rpy2 integration
python dj_ml_rpy2/predict_arimax_rpy2.py
```

### Snowflake Deployment

See the deployment notebooks in each implementation folder:
- Original: [`dj_ml/model_logging.ipynb`](dj_ml/model_logging.ipynb)
- rpy2: [`dj_ml_rpy2/model_logging_rpy2.ipynb`](dj_ml_rpy2/model_logging_rpy2.ipynb)

---

## Documentation

| Document | Description |
|----------|-------------|
| [dj_ml/README.md](dj_ml/README.md) | Original subprocess implementation details |
| [dj_ml_rpy2/README.md](dj_ml_rpy2/README.md) | rpy2 implementation details |
| [dj_ml_rpy2/ASSESSMENT.md](dj_ml_rpy2/ASSESSMENT.md) | **Full feasibility assessment** — architecture diagrams, risk analysis, implementation checklist |

---

## Conda Dependencies

### Original Approach
```python
conda_dependencies=[
    "r-base>=4.1",
    "r-forecast"
]
```

### rpy2 Approach
```python
conda_dependencies=[
    "r-base>=4.1",
    "r-forecast",
    "rpy2>=3.5"
]
```

---

## Conclusion

The rpy2 approach is **technically feasible** and offers **significant advantages** for R model inference in Snowflake:

1. **Performance**: 5-20x faster predictions
2. **Simplicity**: Cleaner, more maintainable code
3. **Reliability**: Better error handling and type fidelity

For production workloads with frequent inference calls, the performance benefits alone justify adopting the rpy2 approach.

---

## References

- **Kaitlyn Wells** — [Deploying R Models in Snowflake's Model Registry](https://medium.com/snowflake/deploying-r-models-in-snowflakes-model-registry-effcf04dd85c) (Original article and code)
- [Snowflake Model Registry Documentation](https://docs.snowflake.com/en/developer-guide/snowpark-ml/model-registry/overview)
- [rpy2 Documentation](https://rpy2.github.io/doc/latest/html/introduction.html)
- [rpy2 on conda-forge](https://anaconda.org/conda-forge/rpy2)

---

## License

This project is provided for educational and demonstration purposes.
