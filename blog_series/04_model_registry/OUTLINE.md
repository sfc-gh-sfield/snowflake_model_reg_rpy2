# Blog 4: Registering and Serving R Models in Snowflake's Model Registry

**Status:** Planning
**Target length:** ~15-18 min read (~4000-5000 words) -- flagship post
**Companion notebook:** `snowflakeR/inst/notebooks/workspace_model_registry.ipynb`
**Draft location:** `drafts/`

---

## Progress Tracker

- [ ] Outline finalised
- [ ] Draft v1 written
- [ ] Code snippets tested in Workspace
- [ ] Screenshots captured (including SPCS deployment)
- [ ] Comparison table verified
- [ ] Internal review
- [ ] Draft v2 (post-review)
- [ ] Final review
- [ ] Published to Medium
- [ ] Link added to SERIES_PLAN.md

---

## Key Messages

1. `sfr_log_model()` auto-generates everything -- no Python, no Docker, no subprocess scripts
2. Train in R as normal, test locally, register with one call, deploy to SPCS
3. Two inference paths: Python-bridged (full integration) and REST (lower latency)
4. Honest comparison with existing approaches -- this is simpler but acknowledge trade-offs

## Target Reader

- Data scientists who train models in R and need to deploy them
- ML engineers responsible for model serving infrastructure
- Anyone who read Kaitlyn's or Mats' blogs and wants a simpler path

---

## Detailed Outline

### Title & Header

Working title: **"Registering and Serving R Models in Snowflake's Model Registry"**
Alternative: **"From lm() to Production: Deploying R Models in Snowflake Without Writing Python"**

### Disclaimer & Setup

Full disclaimer + standard setup cells.
Additional: `reg <- sfr_model_registry(conn)`

### 1. The Problem, Revisited (~500 words)

**Open with the challenge:** You've trained a great model in R. Now what?
Deploying it to production in Snowflake has historically been non-trivial.

**Review the existing approaches (with credit):**

**Kaitlyn Wells' approach (Jan 2026):**
- Write a standalone R prediction script
- Write a Python `CustomModel` wrapper that calls R via subprocess
- Serialise data to CSV for each prediction
- Upload artifacts to a stage, register manually
- **Pros:** Works, gives full control
- **Cons:** Per-model boilerplate, subprocess overhead, manual Python coding

**Mats Stellwall's approach (Oct 2023):**
- Build a Docker container with plumber REST API
- Create service specification, push image, create compute pool
- Write UDF that calls the REST endpoint
- **Pros:** Production-grade, any R package, SQL-callable
- **Cons:** Docker knowledge required, per-model container builds, infrastructure management

**The snowflakeR approach:**
- Train your R model as usual
- Test locally with `sfr_predict_local()`
- Register with `sfr_log_model()` -- one function call
- Deploy with `sfr_deploy_model()`
- **Pros:** No Python, no Docker, no per-model boilerplate
- **Cons:** Depends on rpy2 ecosystem, not yet officially supported

### 2. Architecture Deep-Dive (~600 words)

**What happens inside sfr_log_model():**

1. **Serialise:** Saves R model via `saveRDS()` to a temporary `.rds` file
2. **Generate wrapper:** Auto-creates a Python `CustomModel` class that:
   - Loads the `.rds` file using rpy2
   - Converts input pandas DataFrame to R data.frame via rpy2
   - Calls R's `predict()` function
   - Converts output back to pandas DataFrame
3. **Register:** Calls `snowflake.ml.registry.Registry.log_model()` with:
   - The generated CustomModel
   - `target_platforms=["SNOWPARK_CONTAINER_SERVICES"]`
   - `conda_dependencies` including `r-base` and specified R packages
   - Model signature (input/output schema)

**Architecture diagram** (reference `_shared/images/architecture_diagram.md`):
```
sfr_log_model() → saveRDS() + auto-generate wrapper → Model Registry
sfr_deploy_model() → SPCS container (R + Python + rpy2)
sfr_predict() → Python bridge → SPCS → result
sfr_predict_rest() → HTTP direct → SPCS → result (faster)
```

**The REST inference path (`rest_inference.R`):**
- Bypasses rpy2/Python entirely at inference time
- R → httr2 POST → SPCS HTTP endpoint → JSON response → R
- Uses Snowflake `dataframe_split` format
- PAT-based authentication

### 3. Walkthrough: Train, Test, Register (~1200 words)

**3.1 Train a model (nothing special)**
```r
model_lm <- lm(mpg ~ wt + hp + cyl, data = mtcars)
summary(model_lm)
```

**3.2 Test locally**
```r
test_data <- data.frame(wt = c(2.5, 3.0, 3.5), hp = c(110, 150, 200), cyl = c(4, 6, 8))
local_preds <- sfr_predict_local(model_lm, test_data)
rprint(local_preds)
```
- **Tip (G22):** Always test locally first -- same logic as remote

**3.3 Register to Snowflake**
```r
mv <- sfr_log_model(
  reg = reg,
  model = model_lm,
  model_name = "R_MTCARS_LM",
  version_name = "V1",
  conda_dependencies = c("r-base>=4.1"),
  sample_input = test_data,
  comment = "Linear model: mpg ~ wt + hp + cyl"
)
rprint(mv)
```
- Show what gets logged (model artifact, wrapper, signature)
- **Gotcha (G20):** conda_dependencies must include all R packages

**3.4 Manage models**
```r
# List all models
sfr_show_models(reg) |> rview()

# Get a specific model version
mv <- sfr_get_model_version(reg, "R_MTCARS_LM", "V1")

# Set metrics
sfr_set_model_metric(mv, "rmse", 2.45)
sfr_set_model_metric(mv, "r_squared", 0.87)
sfr_show_model_metrics(mv) |> rprint()

# Set default version
sfr_set_default_model_version(reg, "R_MTCARS_LM", "V1")

# List versions
sfr_show_model_versions(reg, "R_MTCARS_LM") |> rview()
```

### 4. Deploy and Serve (~800 words)

**4.1 Deploy to SPCS**
```r
sfr_deploy_model(mv,
  service_name = "MTCARS_LM_SERVICE",
  compute_pool = "R_MODEL_POOL",
  image_repo = "R_MODEL_IMAGES"
)
```
- **Tip (G19):** First deployment takes 5-10 minutes (container image build)
- Show monitoring: `sfr_get_service_status()`, `sfr_wait_for_service()`

**4.2 Inference via Python bridge**
```r
predictions <- sfr_predict(mv, test_data, service_name = "MTCARS_LM_SERVICE")
rprint(predictions)
```

**4.3 Inference via REST (recommended for production)**
```r
# Get the service endpoint
endpoint <- sfr_service_endpoint(mv, service_name = "MTCARS_LM_SERVICE")
rprint(endpoint)

# Direct REST inference
rest_preds <- sfr_predict_rest(endpoint, test_data)
rprint(rest_preds)
```
- **Tip (G21):** REST path bypasses rpy2, gives lower latency
- Show latency comparison between the two paths

**4.4 Benchmarking**
```r
sfr_benchmark_inference(mv, test_data, n = 10, service_name = "MTCARS_LM_SERVICE")
sfr_benchmark_rest(endpoint, test_data, n = 10)
```

### 5. Advanced: Custom Predict Code (~400 words)

For models with custom preprocessing:
```r
custom_predict <- function(model, data) {
  # Custom preprocessing
  data$wt_squared <- data$wt^2
  # Run prediction
  preds <- predict(model, data)
  # Custom postprocessing
  data.frame(prediction = preds, confidence = 0.95)
}

mv_custom <- sfr_log_model(
  reg = reg,
  model = model_lm,
  model_name = "R_MTCARS_LM_CUSTOM",
  version_name = "V1",
  predict_fn = custom_predict,
  ...
)
```

### 6. Comparison Table (~300 words)

| Aspect | Subprocess (Kaitlyn) | Docker/plumber (Mats) | snowflakeR/rpy2 |
|--------|---------------------|----------------------|-----------------|
| **Python required** | Yes (wrapper code) | No (pure R container) | No (auto-generated) |
| **Docker required** | No | Yes | No |
| **Per-model boilerplate** | R script + Python wrapper | Dockerfile + plumber API + spec | One function call |
| **Interop mechanism** | Subprocess + CSV files | HTTP/JSON REST | In-process (rpy2) |
| **Serialisation overhead** | High | Medium | Low |
| **Model Registry integration** | Manual | No (UDF-based) | Native |
| **Versioning** | Via Registry | Manual (image tags) | Native |
| **Metrics tracking** | Via Registry | Manual | Native |
| **Any R package** | Yes | Yes | Yes (via conda) |
| **Infrastructure** | SPCS | SPCS + Docker build | SPCS (automated) |
| **Maturity** | Proven pattern | Proven pattern | Prototype/passion project |
| **Official support** | Blog example | Blog example | Not yet |

**Honest assessment:**
- snowflakeR is the simplest developer experience
- The subprocess approach gives more control over the R runtime
- The Docker approach gives maximum flexibility (any language, any framework)
- snowflakeR's rpy2 dependency adds a layer that may have edge cases
- All three ultimately run on SPCS for inference

### 7. Cleanup (~100 words)

```r
sfr_undeploy_model(mv, service_name = "MTCARS_LM_SERVICE")
sfr_delete_model(reg, "R_MTCARS_LM")
```

### 8. Gotchas & Tips (~300 words)

Pull from master list: G10, G19, G20, G21, G22, G24, T04

### 9. Summary & What's Next (~200 words)

What we covered:
- Complete model lifecycle in R: train → test → register → deploy → serve
- Two inference paths (Python bridge and REST)
- Comparison with alternative approaches

What's next (Blog 5):
- End-to-end pipeline: Feature Store → Training → Registry → Serving
- SPCS administration from R
- Series wrap-up and future directions

---

## Key Code References

| Source File | Sections Used |
|-------------|---------------|
| `R/registry.R` | Sections 2-5, 7 |
| `R/rest_inference.R` | Section 4.3-4.4 |
| `R/admin.R` | Section 4.1 (compute pool, image repo) |
| `inst/python/sfr_registry_bridge.py` | Section 2 (architecture) |
| `inst/notebooks/workspace_model_registry.ipynb` | All sections |

---

## SPCS Resources Needed for Testing

- [ ] Compute pool created and active
- [ ] Image repository created
- [ ] External access integration (EAI) if needed
- [ ] Sufficient SPCS quota

---

## Screenshots Needed

- [ ] sfr_log_model output
- [ ] Model version details
- [ ] SPCS service status during deployment
- [ ] Prediction results (both paths)
- [ ] Benchmark output
- [ ] Comparison table (formatted nicely for Medium)

---

## Review Notes

*(Add feedback and revision notes here)*
