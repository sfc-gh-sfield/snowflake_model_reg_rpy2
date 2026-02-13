# Architecture Diagrams

## Blog 1: Overall Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  Snowflake Workspace Notebook                │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │               Python Kernel (Jupyter)                 │   │
│  │                                                       │   │
│  │   ┌─────────┐     ┌─────────────────────────────┐    │   │
│  │   │  rpy2   │◄───►│        R Session             │    │   │
│  │   │ bridge  │     │                               │    │   │
│  │   └────┬────┘     │  ┌─────────────────────────┐ │    │   │
│  │        │          │  │      snowflakeR          │ │    │   │
│  │        │          │  │  (idiomatic R API)       │ │    │   │
│  │   %%R magic       │  │                          │ │    │   │
│  │                   │  │  ┌────────────────────┐  │ │    │   │
│  │                   │  │  │    reticulate       │  │ │    │   │
│  │                   │  │  │  (R calls Python)   │  │ │    │   │
│  │                   │  │  └────────┬───────────┘  │ │    │   │
│  │                   │  └───────────┼──────────────┘ │    │   │
│  │                   └──────────────┼────────────────┘    │   │
│  │                                  │                      │   │
│  │   ┌──────────────────────────────▼──────────────────┐  │   │
│  │   │         snowflake-ml-python SDK                  │  │   │
│  │   │  (Model Registry, Feature Store, Snowpark)       │  │   │
│  │   └──────────────────────────────┬──────────────────┘  │   │
│  └──────────────────────────────────┼─────────────────────┘   │
│                                     │                          │
│                    Snowpark Session  │  (auto-detected)        │
│                                     ▼                          │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │                Snowflake Platform                         │ │
│  │  ┌──────────┐  ┌───────────────┐  ┌──────────────────┐  │ │
│  │  │ Virtual   │  │ Feature Store │  │ Model Registry   │  │ │
│  │  │ Warehouse │  │               │  │      + SPCS      │  │ │
│  │  └──────────┘  └───────────────┘  └──────────────────┘  │ │
│  └──────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Blog 4: Model Registry Architecture

```
     R User (Workspace Notebook)
              │
              │  sfr_log_model(reg, model, ...)
              ▼
     ┌─────────────────┐
     │   snowflakeR     │  1. saveRDS(model) → temp file
     │   registry.R     │  2. Auto-generate Python CustomModel wrapper
     │                   │  3. Wrapper uses rpy2 to call R predict()
     └────────┬─────────┘
              │  (via reticulate)
              ▼
     ┌─────────────────┐
     │  sfr_registry    │  4. Calls snowflake.ml.registry.Registry
     │  _bridge.py      │  5. log_model() with conda_deps including r-base
     └────────┬─────────┘
              │
              ▼
     ┌─────────────────┐
     │  Snowflake Model │  Stored model: R .rds + Python wrapper
     │  Registry        │  Versioned, with metadata & metrics
     └────────┬─────────┘
              │  sfr_deploy_model()
              ▼
     ┌─────────────────┐
     │  SPCS Container  │  Container with R + Python + rpy2
     │  Service         │  HTTP endpoint for inference
     └────────┬─────────┘
              │
              ▼
     ┌─────────────────┐
     │  Inference       │  Option A: sfr_predict() via Python bridge
     │  (2 paths)       │  Option B: sfr_predict_rest() direct HTTP
     └─────────────────┘            (lower latency, no rpy2)
```

## Blog 2: Data Flow Patterns

```
                    ┌──────────────────────┐
                    │   Snowflake Tables    │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
     ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
     │  SQL Query    │ │ dplyr+dbplyr │ │  Snowpark    │
     │  sfr_query()  │ │  pushdown    │ │  DataFrame   │
     │  DBI::dbGet   │ │  tbl(conn,..)│ │  conn$session│
     │  Query()      │ │  %>% collect │ │  $sql(...)   │
     └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
            │                │                │
            ▼                ▼                ▼
     ┌──────────────────────────────────────────────┐
     │              R data.frame                     │
     │  (via bridge_dict_to_df / pandas2ri / collect)│
     └──────────────────────────────────────────────┘
            │                                │
            ▼                                ▼
     ┌──────────────┐              ┌──────────────┐
     │  R Processing │              │ Write Back   │
     │  (dplyr, base │              │ sfr_write    │
     │   R, ggplot2) │              │ _table()     │
     └──────────────┘              └──────────────┘
```

---

## Notes

- These are text-based diagrams for inclusion in blog posts
- For Medium, consider recreating as images (e.g., using draw.io, Excalidraw,
  or Mermaid rendered to PNG)
- The text versions work well for README files and code documentation
