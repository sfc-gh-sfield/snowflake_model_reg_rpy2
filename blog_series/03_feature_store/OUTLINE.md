# Blog 3: Feature Engineering in Snowflake with R -- The Feature Store

**Status:** Planning
**Target length:** ~12-15 min read (~3000-4000 words)
**Companion notebook:** `snowflakeR/inst/notebooks/workspace_feature_store.ipynb`
**Draft location:** `drafts/`

---

## Progress Tracker

- [ ] Outline finalised
- [ ] Draft v1 written
- [ ] Code snippets tested in Workspace
- [ ] Screenshots captured
- [ ] Internal review
- [ ] Draft v2 (post-review)
- [ ] Final review
- [ ] Published to Medium
- [ ] Link added to SERIES_PLAN.md

---

## Key Messages

1. Feature engineering is naturally SQL/dplyr -- R users are already doing this
2. Snowflake Feature Store adds versioning, reuse, and point-in-time correctness
3. snowflakeR provides the same Feature Store capabilities as the Python SDK, in R
4. Training data generation with correct temporal joins is the killer feature

## Target Reader

- Data scientists building ML pipelines in R
- ML engineers interested in feature management
- R users who want reproducible, reusable feature pipelines

---

## Detailed Outline

### Title & Header

Working title: **"Feature Engineering in Snowflake with R -- The Feature Store"**
Alternative: **"From dplyr Pipelines to Production Features: R and Snowflake Feature Store"**

### Disclaimer & Setup

Brief disclaimer + standard setup cells.
Additional setup: `sfr_feature_store(conn, create = TRUE)`

### 1. Introduction (~400 words)

**Opening:** Feature engineering is where data scientists spend most of their time.
R users are already excellent at this with dplyr, tidyr, and SQL. But managing
features at scale -- versioning, sharing, point-in-time correctness -- is harder.

**What the Feature Store provides:**
- Centralised feature definitions
- Automatic point-in-time correct joins for training data
- Feature versioning and lineage
- Reuse across models and teams

**Why this matters for R users:**
- Feature engineering logic (SQL or dplyr) maps directly to Feature Store views
- `snowflakeR` wraps the Python Feature Store SDK in idiomatic R
- No need to rewrite feature pipelines in Python

### 2. Feature Store Concepts (~300 words)

Brief overview (with link to Snowflake docs for details):
- **Entity:** The business object being described (e.g., customer, product)
- **Feature View:** A versioned, managed set of features derived from source data
- **Training Data:** Point-in-time correct joins of features with labels/targets
- **Feature Retrieval:** Getting current feature values for inference

### 3. Setting Up the Feature Store (~300 words)

```r
# Connect and create Feature Store context
conn <- sfr_connect()
conn <- sfr_load_notebook_config(conn)

fs <- sfr_feature_store(conn, create = TRUE)
fs
```

- `create = TRUE` creates the schema/tags if they don't exist
- The Feature Store lives in a database/schema (defaults to session's current)

### 4. Entities (~400 words)

```r
# Create an entity
entity <- sfr_create_entity(fs,
  name = "CUSTOMER",
  join_keys = c("CUSTOMER_ID"),
  desc = "Unique customer identifier"
)

# List entities
sfr_list_entities(fs) |> rprint()

# Get entity details
sfr_get_entity(fs, "CUSTOMER") |> rprint()
```

### 5. Feature Views (~800 words)

**5.1 Define source data**
```r
# Option A: SQL query as source
source_query <- paste(
  "SELECT CUSTOMER_ID, TIMESTAMP,",
  "  AVG(ORDER_AMOUNT) OVER (PARTITION BY CUSTOMER_ID) AS AVG_ORDER_AMT,",
  "  COUNT(*) OVER (PARTITION BY CUSTOMER_ID) AS ORDER_COUNT",
  "FROM", sfr_fqn(conn, "ORDERS")
)

# Option B: Could also derive this from a dplyr pipeline that generates SQL
```

**5.2 Create a feature view (two-step pattern)**
```r
# Step 1: Create the definition
fv <- sfr_create_feature_view(
  name = "CUSTOMER_ORDER_FEATURES",
  entity = entity,
  feature_df = source_query,  # SQL string or Snowpark DataFrame
  timestamp_col = "TIMESTAMP",
  desc = "Customer order aggregation features"
)

# Step 2: Register in the Feature Store
fv <- sfr_register_feature_view(fs, fv)
fv
```

**Gotcha callout:** G17 (two-step process), G18 (timestamp columns required)

**5.3 Read and inspect**
```r
# Read the feature view data
fv_data <- sfr_read_feature_view(fs, fv)
rview(fv_data, n = 10)

# Check refresh history
sfr_get_refresh_history(fs, fv) |> rprint()
```

**5.4 Refresh and manage**
```r
sfr_refresh_feature_view(fs, fv)
sfr_list_feature_views(fs) |> rprint()
```

### 6. Training Data Generation (~600 words)

**The killer feature:** point-in-time correct joins.

```r
# Define a spine (entities + timestamps for which we want features)
spine_query <- paste(
  "SELECT CUSTOMER_ID, EVENT_TIMESTAMP, CHURNED",
  "FROM", sfr_fqn(conn, "CUSTOMER_EVENTS")
)

# Generate training data with temporal join
training_data <- sfr_generate_training_data(
  fs = fs,
  spine = spine_query,
  features = list(fv),  # List of feature views to join
  spine_timestamp_col = "EVENT_TIMESTAMP",
  output_table = sfr_fqn(conn, "TRAINING_DATA_V1")
)

# Read into R for model training
train_df <- sfr_read_dataset(conn, training_data)
rview(train_df, n = 10)
```

**Why this matters:**
- Prevents data leakage (features from the future don't leak into training)
- Reproducible -- same spine + features = same training data
- Scalable -- Snowflake does the heavy lifting

### 7. Feature Retrieval for Inference (~400 words)

```r
# At inference time, get current feature values
inference_data <- sfr_retrieve_features(
  fs = fs,
  spine = inference_spine_query,
  features = list(fv)
)

rview(inference_data, n = 5)
```

### 8. Datasets: Versioned Snapshots (~400 words)

```r
# Create a versioned dataset from training data
ds <- sfr_create_dataset(conn,
  name = "CHURN_TRAINING",
  version = "V1",
  query = paste("SELECT * FROM", sfr_fqn(conn, "TRAINING_DATA_V1"))
)

# Read it back (immutable snapshot)
ds_df <- sfr_read_dataset(conn, ds)
rview(ds_df, n = 5)

# List all datasets
sfr_list_datasets(conn) |> rprint()
```

### 9. Gotchas & Tips (~200 words)

Pull from master list: G08, G11, G17, G18

### 10. Summary & What's Next (~200 words)

What we covered:
- Feature Store concepts and API
- Entity and feature view management
- Training data with point-in-time correct joins
- Versioned datasets for reproducibility

What's next (Blog 4):
- Model Registry integration
- Train an R model on Feature Store data
- Register, deploy, and serve from R

---

## Key Code References

| Source File | Sections Used |
|-------------|---------------|
| `R/features.R` | Sections 3-7 |
| `R/datasets.R` | Section 8 |
| `inst/python/sfr_features_bridge.py` | Internal (all sections) |
| `inst/python/sfr_datasets_bridge.py` | Section 8 |
| `inst/notebooks/workspace_feature_store.ipynb` | All sections |

---

## Data Setup Needed

For the walkthrough, we need sample data in Snowflake. Options:
- [ ] Use Snowflake sample data (TPCH, like the Hex blog)
- [ ] Create synthetic data in the notebook (self-contained)
- [ ] Use a public dataset (Kaggle churn, like Mats' blog)

Decision: **TBD** -- self-contained synthetic data is most portable.

---

## Screenshots Needed

- [ ] Feature Store context (sfr_feature_store output)
- [ ] Feature view details
- [ ] Training data output showing point-in-time correctness
- [ ] Dataset listing

---

## Review Notes

*(Add feedback and revision notes here)*
