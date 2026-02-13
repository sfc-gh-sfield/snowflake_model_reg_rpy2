# Blog 5: End-to-End ML with R in Snowflake -- Feature Store to Model Serving

**Status:** Planning
**Target length:** ~12-15 min read (~3000-4000 words)
**Companion notebooks:** `workspace_feature_store.ipynb` (Section 7) + `workspace_model_registry.ipynb`
**Draft location:** `drafts/`

---

## Progress Tracker

- [ ] Outline finalised
- [ ] Realistic example dataset chosen
- [ ] Draft v1 written
- [ ] Code snippets tested in Workspace (full pipeline)
- [ ] Screenshots captured
- [ ] Internal review
- [ ] Draft v2 (post-review)
- [ ] Final review
- [ ] Published to Medium
- [ ] Link added to SERIES_PLAN.md

---

## Key Messages

1. The full ML lifecycle in R, inside Snowflake, is now possible
2. Feature Store + Model Registry integration eliminates manual glue code
3. SPCS administration is manageable from R
4. This is just the beginning -- call for feedback and contributions

## Target Reader

- Readers who have followed the series and want to see it all come together
- ML engineers evaluating the snowflakeR approach for real workloads
- Anyone interested in the complete picture

---

## Detailed Outline

### Title & Header

Working title: **"End-to-End ML with R in Snowflake -- Feature Store to Model Serving"**
Alternative: **"The Complete R-in-Snowflake ML Pipeline"**

### Disclaimer & Setup

Brief disclaimer + standard setup cells.

### 1. Introduction (~300 words)

**Recap the series:**
- Blog 1: Got R running in Snowflake Workspaces
- Blog 2: Learned to move data between R, Python, and Snowflake
- Blog 3: Used the Feature Store for feature engineering
- Blog 4: Registered and served R models
- Now: **put it all together** in a realistic end-to-end workflow

**The pipeline:**
```
Data → Feature Engineering → Training Data → Model Training →
Local Test → Registration → Deployment → Inference
```

### 2. The Example: [Realistic Use Case] (~400 words)

**Choose a realistic example** (not mtcars). Options:
- Customer churn prediction (aligns with Mats' blog)
- Demand forecasting (time series)
- Credit risk scoring

Whatever we choose, it should:
- Use enough data to make the Snowflake processing meaningful
- Have clear features that benefit from Feature Store management
- Produce a model that's interesting to deploy and serve

**Set up the source data in Snowflake.**

### 3. Feature Engineering (~600 words)

Walk through the full Feature Store workflow:
```r
# Create Feature Store
fs <- sfr_feature_store(conn, create = TRUE)

# Define entities
customer_entity <- sfr_create_entity(fs, "CUSTOMER", join_keys = "CUSTOMER_ID")

# Create feature views from SQL/dplyr pipelines
# ... (2-3 feature views)

# Register
fv1 <- sfr_register_feature_view(fs, fv1)
fv2 <- sfr_register_feature_view(fs, fv2)
```

### 4. Training Data Generation (~400 words)

```r
# Generate point-in-time correct training data
training_data <- sfr_generate_training_data(
  fs = fs,
  spine = spine_query,
  features = list(fv1, fv2),
  spine_timestamp_col = "EVENT_TIMESTAMP",
  output_table = sfr_fqn(conn, "CHURN_TRAINING_V1")
)

# Create versioned dataset
ds <- sfr_create_dataset(conn, "CHURN_TRAINING", "V1", ...)

# Read into R
train_df <- sfr_read_dataset(conn, ds)
rglimpse(train_df)
```

### 5. Model Training & Local Testing (~500 words)

```r
# Train in R as usual
model <- glm(churned ~ ., data = train_df, family = binomial)
summary(model)

# Test locally
test_data <- sfr_retrieve_features(fs, test_spine, features = list(fv1, fv2))
local_preds <- sfr_predict_local(model, test_data)
rprint(local_preds)

# Evaluate
# ... (confusion matrix, AUC, etc.)
```

### 6. Register & Deploy (~500 words)

```r
# Register
reg <- sfr_model_registry(conn)
mv <- sfr_log_model(reg, model, "CHURN_MODEL",
  version_name = "V1",
  conda_dependencies = c("r-base>=4.1"),
  sample_input = head(test_data),
  comment = "Logistic regression churn model"
)

# Set metrics
sfr_set_model_metric(mv, "auc", 0.82)

# Deploy
sfr_deploy_model(mv,
  service_name = "CHURN_MODEL_SVC",
  compute_pool = "R_MODEL_POOL",
  image_repo = "R_MODEL_IMAGES"
)

sfr_wait_for_service(mv, "CHURN_MODEL_SVC")
```

### 7. Inference at Scale (~500 words)

```r
# Get features for new customers
new_customer_features <- sfr_retrieve_features(fs, new_spine, features = list(fv1, fv2))

# Predict via REST (production path)
endpoint <- sfr_service_endpoint(mv, "CHURN_MODEL_SVC")
predictions <- sfr_predict_rest(endpoint, new_customer_features)
rprint(predictions)

# Benchmark
sfr_benchmark_rest(endpoint, new_customer_features, n = 10)
```

### 8. SPCS Administration from R (~400 words)

Brief overview of the admin functions:

```r
# Compute pools
sfr_list_compute_pools(conn) |> rview()
sfr_describe_compute_pool(conn, "R_MODEL_POOL") |> rprint()

# Image repositories
sfr_list_image_repos(conn) |> rview()

# External access integrations
sfr_list_eais(conn) |> rview()
```

### 9. Monitoring & Observability (~300 words)

```r
# Service status
sfr_get_service_status(mv, "CHURN_MODEL_SVC") |> rprint()

# Model versions and metrics
sfr_show_model_versions(reg, "CHURN_MODEL") |> rview()
sfr_show_model_metrics(mv) |> rprint()
```

### 10. Cleanup (~200 words)

```r
# Undeploy and clean up
sfr_undeploy_model(mv, "CHURN_MODEL_SVC")

# Optionally: remove feature views, entities, datasets, model
# sfr_delete_feature_view(fs, fv1)
# sfr_delete_entity(fs, "CUSTOMER")
# sfr_delete_model(reg, "CHURN_MODEL")
```

### 11. Series Wrap-Up (~500 words)

**What we've built:**
- A complete R-in-Snowflake ML workflow
- From data exploration through to production inference
- All in R, all inside Snowflake

**The snowflakeR package today:**
- Connectivity, querying, DBI/dbplyr integration
- Feature Store: entities, feature views, training data, datasets
- Model Registry: log, deploy, serve, REST inference
- SPCS administration
- Workspace and local environment support

**What's coming:**
- Pre-installed R in Workspace runtime images (simplifies setup)
- ADBC + DuckDB integration (direct DB access from R)
- Tidymodels integration
- Additional model types and serving patterns
- Community contributions welcome

**Call for feedback:**
- Try it out: [GitHub link]
- File issues: [GitHub issues link]
- Feedback helps prioritise what to build next
- Special interest areas: what R packages matter most? What workflows are blockers?

**Acknowledgements:**
- Kaitlyn Wells for the Model Registry + R inspiration
- Mats Stellwall for the SPCS + R pioneering work
- The Snowflake ML team for the SDK
- The rpy2 and reticulate maintainers

---

## Key Code References

| Source File | Sections Used |
|-------------|---------------|
| All R source files | Various |
| All Python bridge files | Various |
| `inst/notebooks/workspace_feature_store.ipynb` (Section 7) | Sections 3-4 |
| `inst/notebooks/workspace_model_registry.ipynb` | Sections 5-7 |
| `R/admin.R` | Section 8 |

---

## Example Data Decision

**Options (decide before drafting):**
- [ ] Customer churn (synthetic -- self-contained, no external data needed)
- [ ] Demand forecasting (time series -- good Feature Store showcase)
- [ ] Adapt from Mats' blog (Kaggle bank churn -- reader familiarity)
- [ ] Use Snowflake sample data (TPCH derivative -- available in all accounts)

**Decision:** TBD

---

## Screenshots Needed

- [ ] Full pipeline execution (highlights of each step)
- [ ] Feature Store with registered views
- [ ] Model Registry with deployed model
- [ ] REST inference results
- [ ] Benchmark output
- [ ] SPCS admin view

---

## Review Notes

*(Add feedback and revision notes here)*
