# SPCS Inference Server: `recarray has no attribute fillna` for R Models

**Priority:** P2 -- SPCS model serving broken for R models via Model Registry  
**Component:** Snowflake ML / Model Registry / SPCS Inference Server  
**Affected Version:** snowflake-ml-python 1.8.0+, container image as of Feb 2025  
**Environment:** Any account deploying R models through Model Registry  

---

## Summary

When an R model (registered via `rpy2` / `snowflake-ml-python` Model Registry)
is deployed to SPCS using `create_service()`, the inference server crashes with
HTTP 500 on **every** prediction request. The error is:

```
AttributeError: recarray has no attribute fillna
```

The crash occurs in the inference server's input preprocessing code
(`inference_server/main.py` line 581), where `inference_df` is a
`numpy.recarray` instead of a `pandas.DataFrame`.

**This bug is specific to R models.** Pure Python models -- including those with
identical mixed integer/float column schemas -- work correctly through both REST
and `mv.run()`.

---

## Error

```
HTTP 500: backend service error:
{
  "error": "Internal error: recarray has no attribute fillna\n
  Traceback (most recent call last):\n
    File \"/opt/conda/lib/python3.12/site-packages/numpy/_core/records.py\", line 427, in __getattribute__\n
      res = fielddict[attr][:2]\n
    KeyError: 'fillna'\n\n
  The above exception was the direct cause of the following exception:\n\n
    File \"/service/inference_server/main.py\", line 581, in _run_inference\n
      inference_df = inference_df.fillna(np.nan).replace([np.nan], [None])\n
    AttributeError: recarray has no attribute fillna. Did you mean: 'fill'?\n"
}
```

### Isolation testing results

We tested multiple model types with the same SPCS infrastructure to isolate the
root cause:

| # | Model | Language | Column Types | REST | mv.run() |
|---|-------|----------|-------------|------|----------|
| 1 | Identity model (returns input) | Python | all float | **HTTP 200** | **Success** |
| 2 | Mixed-type prediction model | Python | int + float (same schema as R model) | **HTTP 200** | **Success** |
| 3 | MPG prediction model (lm) | **R** | int + float | **HTTP 500 -- recarray** | N/A (SQL error) |

Key findings:
- **Python models work** -- both all-float and mixed int/float schemas
- **R model fails** -- even with identical column types to the working Python model
- The bug is NOT caused by mixed data types; it is specific to R model serving
- The service health endpoint (`/health`) returns HTTP 200 even when inference is broken
- The R model works correctly locally (before deployment)

---

## Root Cause Analysis

**The root cause is `rpy2.robjects.numpy2ri`**, not numpy version or Python
version. When the R model wrapper imports `numpy2ri` (even via a scoped
`localconverter`), it installs global hooks into numpy's type system that
cause numpy's structured-array code to return `numpy.recarray` objects
instead of plain `numpy.ndarray`. This affects the *inference server's*
input deserialization -- before the model's predict method is even called.

Line 581 of `inference_server/main.py` then calls:

```python
inference_df = inference_df.fillna(np.nan).replace([np.nan], [None])
```

`fillna()` is a pandas method, not available on numpy recarrays, so this
crashes.

**Key evidence:**

1. The bug occurs even with numpy 1.26.4 + Python 3.11 (tested Feb 2025).
   Initial hypothesis that numpy 2.x was the cause was **incorrect**.
2. A Python model with `rpy2` and `r-base` as dependencies (but not importing
   `numpy2ri`) runs perfectly -- proving rpy2 installation alone is harmless.
3. The actual R model wrapper included `from rpy2.robjects import numpy2ri`
   and `numpy2ri.converter` in its converter chain. Removing this import
   and using only `pandas2ri.converter` **completely fixes the bug**.
4. `pandas2ri.converter` alone is sufficient for DataFrame ↔ R data.frame
   conversion.

**Why this only affects R models:**

Pure Python models never import `numpy2ri`, so the inference server's numpy
state is unmodified. R model wrappers used `numpy2ri.converter` (unnecessary
belt-and-suspenders addition) which corrupted the global numpy state.

### Fix (client-side, implemented)

Remove `numpy2ri` from the rpy2 converter chain in the R model wrapper:

```python
# Before (broken -- numpy2ri corrupts global numpy state):
from rpy2.robjects import numpy2ri
combined = ro.default_converter + pandas2ri.converter + numpy2ri.converter

# After (fixed -- pandas2ri alone is sufficient):
combined = ro.default_converter + pandas2ri.converter
```

Also add a defensive check after prediction:

```python
if not isinstance(result_df, pd.DataFrame):
    result_df = pd.DataFrame(result_df)
```

### Suggested server-side fix (defense in depth)

In `inference_server/main.py`, around line 581:

```python
# Before:
inference_df = inference_df.fillna(np.nan).replace([np.nan], [None])

# After (safe against any recarray-producing model):
if not isinstance(inference_df, pd.DataFrame):
    inference_df = pd.DataFrame(inference_df)
inference_df = inference_df.fillna(np.nan).replace([np.nan], [None])
```

This would protect all models, not just those using rpy2.

---

## Reproduction

### Prerequisites

- A Snowflake account with SPCS enabled (compute pool + image repo)
- `pip install snowflake-ml-python cryptography PyJWT requests`
- Key-pair authentication configured in `~/.snowflake/connections.toml`

### Option A: Use the R model deployment

If you have an R model registered via `snowflake-ml-python`:

```python
from snowflake.ml.registry import Registry
reg = Registry(session=session)
m = reg.get_model("MY_R_MODEL")
mv = m.version("V1")
mv.create_service(
    service_name="test_r_svc",
    service_compute_pool="MY_POOL",
    image_build_compute_pool="MY_POOL",
    image_repo="MY_DB.MY_SCHEMA.MY_IMAGE_REPO",
    ingress_enabled=True,
)
# Wait for service ready, then:
# curl or Python requests to https://<ingress>/predict → HTTP 500
```

### Option B: Manual curl test (against any deployed R model service)

```bash
JWT="your_jwt_or_pat_token"
ENDPOINT="https://xxxxx-account.snowflakecomputing.app"

curl -X POST "$ENDPOINT/predict" \
  -H "Authorization: Snowflake Token=\"$JWT\"" \
  -H "Content-Type: application/json" \
  -d '{"dataframe_split":{"index":[0],"columns":["CYL","DISP","HP","DRAT","WT","QSEC","VS","AM","GEAR","CARB"],"data":[[6,160.0,110,3.9,2.62,16.46,0,1,4,4]]}}'

# Returns HTTP 500: recarray has no attribute fillna
```

### Confirmation: Python model with same schema works

```python
# This Python model uses the EXACT same mixed int/float schema:
class MixedTypeModel(custom_model.CustomModel):
    @custom_model.inference_api
    def predict(self, input_df: pd.DataFrame) -> pd.DataFrame:
        result = input_df.select_dtypes(include="number").sum(axis=1)
        return pd.DataFrame({"prediction": result})

# Deployed with same compute pool/image repo → HTTP 200, works fine
```

This proves the issue is specific to R models, not to mixed data types.

---

## Impact

- **All R models** deployed via Model Registry `create_service()` are affected
- The REST endpoint returns HTTP 500 for every prediction request
- `mv.run(service_name=...)` also fails (same server-side code path)
- Python models (even with identical schemas) are NOT affected
- The service appears healthy (`/health` returns 200)
- R models work correctly locally -- only the SPCS serving container is broken

### Who is affected

Any customer deploying R models through:
- `ModelVersion.create_service()` or `ModelVersion.deploy()`  
- `mv.run()` with `service_name=`
- Direct REST calls to the SPCS inference endpoint

### Workaround (implemented)

**Root cause fix:** Remove `numpy2ri` from the rpy2 converter chain in the
R model wrapper. Use `pandas2ri.converter` alone:

```python
# In the model wrapper's predict() and _ensure_initialized():
combined = ro.default_converter + pandas2ri.converter
# (NOT + numpy2ri.converter)
```

This is implemented in `snowflakeR/inst/python/sfr_registry_bridge.py`.
Models registered with the updated wrapper work correctly on both
Python 3.11 and Python 3.12 containers, with any numpy version.

**Tested and confirmed (Feb 2025):**

- R model (`lm()`) registered with `sfr_log_model()` using the fixed wrapper
- Deployed to SPCS with default `conda_dependencies=["r-base>=4.1", "rpy2>=3.5", "numpy<2.0"]`
- Container: Python 3.11.14, numpy 1.26.4
- **HTTP 200**: REST predictions match local R predictions exactly
- Benchmark: median 0.584s per call

**Additional defense:** The default `conda_deps` still include `numpy<2.0` as
a belt-and-suspenders measure. This is *not* the primary fix (removing
`numpy2ri` is), but it keeps the container environment aligned with the
known-good Python model container.

**Server-side fix (recommended):** Add a defensive check in
`inference_server/main.py` line 581 (see Suggested Fix section above).
This would protect all models regardless of their wrapper implementation.

---

## Environment Details

### Container comparison (from VersionReporter and workaround deployments)

| Package | Python Model Container | R Model Container (buggy) | R Model Container (workaround) |
|---------|----------------------|---------------------------|-------------------------------|
| Python | 3.11.14 | 3.12.x | **3.11.14** |
| numpy | 2.3.5 | 2.x (from traceback) | **1.26.4** |
| pandas | 2.3.3 | Unknown (likely 2.x) | (likely 2.x) |
| gunicorn | 23.0.0 | 23.0.0 | 23.0.0 |
| uvicorn | 0.40.0 | (likely same) | (likely same) |
| pyarrow | 18.1.0 | Unknown | Unknown |
| rpy2 | NOT_INSTALLED | Installed (>=3.5) | Installed (>=3.5) |
| r-base | NOT_INSTALLED | Installed (>=4.1) | Installed (>=4.1) |
| Inference | **HTTP 200** | **HTTP 500** | **HTTP 200** |

**Key difference:** Without `numpy<2.0`, `r-base` + `rpy2` resolves to
Python 3.12 + numpy 2.x, which triggers the recarray bug. With `numpy<2.0`,
the solver picks Python 3.11.14 + numpy 1.26.4, which works correctly.

**Important SDK constraints:**
- `python` cannot be specified in `conda_dependencies` (SDK raises
  `ValueError: Don't specify python as a dependency`).
- Snowflake's internal conda channel only has `rpy2`/`r-base` builds for
  Python 3.12+ -- **not** 3.10 or 3.11. So `python_version="3.11"` fails.
- `numpy<2.0` is the only viable workaround: it forces Python 3.11 indirectly.

```
Inference server: /service/inference_server/main.py (line 581)
Base image path (buggy): /opt/conda/lib/python3.12/site-packages/
Base image path (workaround): /opt/conda/lib/python3.11/site-packages/

Client (not relevant -- bug is server-side):
  snowflake-ml-python: 1.26.0
  snowflake-snowpark-python: 1.45.0
  rpy2: 3.6.4
  R: 4.4.x
  Account: ak32940 (SFPRODUCTSTRATEGY)
```

---

## Timeline

- **Feb 9, 2025:** R model serving worked (deployed with older container image)
- **Feb 13, 2025:** Fresh deploy of R model produces broken container
- **Feb 13, 2025:** Initial hypothesis: bug affects ALL models
- **Feb 13, 2025:** Pure Python identity model deployed → works fine (HTTP 200)
- **Feb 13, 2025:** Python model with mixed int/float schema → works fine (HTTP 200)
- **Feb 13, 2025:** Confirmed bug is **R-model specific**, not a general infrastructure issue
- **Feb 13, 2025:** R model REST → HTTP 500 `recarray has no attribute fillna`
- **Feb 13, 2025:** Attempted `python>=3.11,<3.12` in conda_deps → SDK rejects python as dependency
- **Feb 13, 2025:** Attempted `python_version="3.11"` → rpy2/r-base not available for Py3.11 on SF channel
- **Feb 13, 2025:** Attempted `python_version="3.10"` → rpy2/r-base not available for Py3.10 on SF channel
- **Feb 13, 2025:** `numpy<2.0` + `target_platforms=SPCS` → Python 3.11.14, numpy 1.26.4, HTTP 200 for Python model
- **Feb 13, 2025:** R model with `numpy<2.0` still fails → recarray bug on Python 3.11 + numpy 1.x too
- **Feb 13, 2025:** Root cause identified: `rpy2.robjects.numpy2ri` import corrupts numpy global state
- **Feb 13, 2025:** Removed `numpy2ri` from converter chain → **FIXED**: R model HTTP 200, predictions correct

---

## Related files

- [`repro_recarray_bug.py`](./repro_recarray_bug.py) -- Python reproduction script (registers identity model, tests REST)
- `snowflakeR/R/rest_inference.R` -- R package with specific error detection for this bug
