# R Model Scoring with rpy2 - Alternative Implementation

This directory contains an alternative implementation of the R ARIMAX model wrapper that uses **rpy2** for direct Python-R interoperability, replacing the CSV file-based subprocess approach.

## Why rpy2?

The original implementation uses CSV files and subprocess calls to exchange data between Python and R:

```
Python DataFrame → CSV file → Rscript subprocess → CSV file → Python DataFrame
```

The rpy2 approach eliminates this overhead:

```
Python DataFrame → R data.frame (in-memory) → Python DataFrame
```

### Performance Comparison

| Metric | CSV + Subprocess | rpy2 | Improvement |
|--------|-----------------|------|-------------|
| Per-Prediction (small) | ~200-500ms | ~10-50ms | **5-20x faster** |
| Per-Prediction (large) | ~1-5s | ~100-500ms | **5-10x faster** |
| Code complexity | Higher | Lower | ~50% less code |

## Files

| File | Description |
|------|-------------|
| `r_model_wrapper_rpy2.py` | CustomModel wrapper using rpy2 |
| `predict_arimax_rpy2.py` | Standalone prediction functions (for testing) |
| `model_logging_rpy2.ipynb` | Notebook for Snowflake Model Registry |
| `ASSESSMENT.md` | Full feasibility assessment |
| `setup_rpy2.sh` | Local setup script |

## Quick Start

### 1. Local Setup

```bash
# Install dependencies
pip install rpy2 pandas numpy

# Or with conda (recommended)
conda install -c conda-forge rpy2 r-forecast r-base
```

### 2. Test Locally

```bash
# Test the standalone prediction module
python predict_arimax_rpy2.py
```

### 3. Deploy to Snowflake

Use `model_logging_rpy2.ipynb` with these conda dependencies:

```python
conda_dependencies=[
    "r-base>=4.1",
    "r-forecast",
    "rpy2>=3.5"
]
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Snowflake Model Registry                                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  ARIMAXModelWrapperRpy2 (CustomModel)                 │  │
│  │  ├─ R embedded via rpy2                               │  │
│  │  ├─ forecast package imported                         │  │
│  │  └─ predict() - direct R function calls               │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                    │
                    ▼
        ┌───────────────────────┐
        │  SPCS Runtime         │
        │  ├─ Python 3.x        │
        │  ├─ rpy2 (embedded R) │
        │  ├─ R 4.x             │
        │  └─ forecast package  │
        └───────────────────────┘
                    │
                    ▼
        ┌───────────────────────┐
        │  Data Flow            │
        │  1. pandas → R matrix │
        │  2. R forecast()      │
        │  3. R result → pandas │
        │  (All in-memory!)     │
        └───────────────────────┘
```

## Key Code Differences

### Original (subprocess)

```python
def predict(self, X: pd.DataFrame) -> pd.DataFrame:
    temp_dir = tempfile.mkdtemp()
    
    # Write files
    X.to_csv(os.path.join(temp_dir, "input.csv"))
    
    # Subprocess call
    result = subprocess.run(
        ["Rscript", script_path, model_path, input_csv, output_csv],
        capture_output=True
    )
    
    # Read result
    predictions = pd.read_csv(output_csv)
    
    # Cleanup
    shutil.rmtree(temp_dir)
    
    return predictions
```

### rpy2 (direct)

```python
def predict(self, X: pd.DataFrame) -> pd.DataFrame:
    # Create R matrix from numpy array
    xreg_new = r['matrix'](FloatVector(X[cols].values.flatten()), nrow=len(X), ncol=2)
    
    # Direct R function call
    predictions = self._forecast.forecast(self._model, xreg=xreg_new, h=len(X))
    
    # Extract results (automatic conversion)
    return pd.DataFrame({
        'forecast': np.array(predictions.rx2('mean')),
        'lower_80': np.array(predictions.rx2('lower'))[:, 0],
        ...
    })
```

## API Reference

### ARIMAXModelWrapperRpy2

Main wrapper class for Snowflake Model Registry.

```python
from r_model_wrapper_rpy2 import ARIMAXModelWrapperRpy2
from snowflake.ml.model import custom_model

context = custom_model.ModelContext(
    model_rds='path/to/arimax_model.rds'
)
model = ARIMAXModelWrapperRpy2(context)

predictions = model.predict(input_df)
```

### Standalone Functions

For local testing without the CustomModel wrapper:

```python
from predict_arimax_rpy2 import load_arimax_model, predict_arimax_from_dataframe

model = load_arimax_model('arimax_model.rds')
predictions = predict_arimax_from_dataframe(model, input_df)
```

## Troubleshooting

### "R_HOME not set"

```bash
# Find R installation
R RHOME

# Set environment variable
export R_HOME=/usr/lib/R  # Linux
export R_HOME=/Library/Frameworks/R.framework/Resources  # macOS
```

### "forecast package not found"

```r
# In R console
install.packages('forecast', repos='https://cloud.r-project.org/')
```

### "rpy2 import error in SPCS"

Ensure conda_dependencies includes all required packages:

```python
conda_dependencies=[
    "r-base>=4.1",
    "r-forecast",
    "rpy2>=3.5",
    "pandas",
    "numpy"
]
```

## Requirements

### Local Development
- Python 3.8+
- R 4.x
- rpy2 >= 3.5
- R package: forecast

### Snowflake
- Snowpark Container Services enabled
- Model Registry access
- CREATE MODEL privilege

## Comparison with Original Approach

| Aspect | Original (subprocess) | rpy2 |
|--------|----------------------|------|
| Data transfer | CSV files | In-memory |
| R execution | Subprocess | Embedded |
| Cold start | ~2-3s | ~3-4s |
| Per-prediction | ~200-500ms | ~10-50ms |
| Error handling | Parse stderr | Python exceptions |
| Code lines | ~110 | ~60 |
| Dependencies | r-base, r-forecast | + rpy2 |

## References

- [rpy2 Documentation](https://rpy2.github.io/doc/latest/html/introduction.html)
- [Original Medium Article](https://medium.com/snowflake/deploying-r-models-in-snowflakes-model-registry-effcf04dd85c)
- [Snowflake Model Registry](https://docs.snowflake.com/en/developer-guide/snowpark-ml/model-registry/overview)
