# Design: Integrating Snowflake and DuckDB

## 1\. Overview

This document describes integration patterns between **Snowflake** and **DuckDB** for analytical and ML workflows, focusing on:

- Using **Snowflake Dataset** (and the underlying Parquet files) as a source/sink for DuckDB.  
- Using **Snowflake Storage for Iceberg Tables** with **DuckDB’s Iceberg REST Catalog** support.  
- Trade-offs, constraints, and recommended patterns for read and write paths.

The target audience is engineers and data platform architects familiar with Snowflake, DuckDB, and open table formats (Iceberg).

---

## 2\. Goals and Non‑Goals

### 2.1 Goals

- Enable **efficient interoperability** between Snowflake and DuckDB for:  
  - Local experimentation / ad‑hoc analytics.  
  - ML feature engineering and training.  
  - Cross‑engine lakehouse patterns using Iceberg.  
- Provide **clear, code‑level patterns** for:  
  - Reading Snowflake data into DuckDB.  
  - Writing DuckDB results back in a Snowflake‑native way.  
- Leverage **first‑class Snowflake ML abstractions**:  
  - `snowflake.ml.dataset.Dataset` (the successor to FileSet).  
  - Snowflake Storage for Iceberg Tables \+ Horizon IRC.

### 2.2 Non‑Goals

- Build a fully managed “Snowflake \<–\> DuckDB service” or bi‑directional replication product.  
- Provide exhaustive performance benchmarking.  
- Cover every possible external catalog/storage configuration (focus is Snowflake‑native options plus standard Iceberg REST).

---

## 3\. Background

### 3.1 From FileSet to Dataset

Historically, **FileSet** exposed query results as files on internal stages and provided a Python API that behaved like a filesystem (via the `sfc://` protocol and an fsspec filesystem). FileSet is now deprecated in favor of **Snowflake Dataset**:

- `snowflake.ml.fileset.FileSet` is marked deprecated, with guidance to use `snowflake.ml.dataset.Dataset` and `snowflake.ml.data.DataConnector` instead.  
- `DatasetVersion` represents an immutable, versioned snapshot of data stored as Parquet files in Snowflake-managed internal stages.

### 3.2 Snowflake Dataset API (high level)

Key abstractions (Python):

- `Dataset` and `DatasetVersion` from `snowflake.ml.dataset`.  
- Factory helpers:  
  - `create_from_dataframe(session, name, version, input_dataframe, ...)`  
  - `load_dataset(session, name, version)`.

A `Dataset` has a **selected version**, and `DatasetVersion.read` exposes a `DatasetReader` that provides:

- `files()` – list of data file URIs for that version (Parquet).  
- `filesystem()` – fsspec-compatible filesystem to read those files.

This is the spiritual successor to “FileSet as filesystem”.

### 3.3 Snowflake Storage for Iceberg Tables

**Snowflake Storage for Iceberg Tables** is a newer offering that:

- Stores Iceberg data in **Snowflake-managed storage**, like native tables.  
- Exposes tables via **Iceberg REST Catalog (IRC) APIs**, implemented in Horizon / Open Catalog.  
- Supports **open access from external engines** (Spark, Flink, Trino, etc.) via an IRC‑compatible REST endpoint and vended credentials.

This is critical because **DuckDB’s Iceberg extension supports Iceberg REST Catalogs** (including Polaris-style catalogs) for read/write operations.

---

## 4\. Integration Scenarios

We consider two primary integration scenarios:

1. **Dataset \+ fsspec \+ DuckDB**  
     
   - Use Snowflake Dataset as a versioned Parquet snapshot.  
   - Read those Parquet files via an fsspec filesystem into DuckDB.  
   - Write results back via Snowpark DataFrame into a new Dataset version.

   

2. **Snowflake Storage for Iceberg Tables \+ DuckDB Iceberg REST Catalog**  
     
   - Use Snowflake-managed Iceberg tables.  
   - Let both Snowflake and DuckDB access the same Iceberg tables via Iceberg REST (Horizon IRC).

We also briefly mention **external Iceberg** as a variant pattern (Snowflake \+ DuckDB as clients of a shared Iceberg catalog on customer storage).

---

## 5\. Option 1 – Snowflake Dataset \+ DuckDB

### 5.1 Architecture

**Read path:**

1. Snowflake: create or select a `Dataset` version (backed by Parquet on internal stages).  
2. Python: use `Dataset.read.files()` and `Dataset.read.filesystem()` to get:  
   - A list of `snow://dataset/.../data_*.snappy.parquet` URLs.  
   - An fsspec filesystem that can read those URLs.  
3. Arrow/Pandas: read those Parquet files via `pyarrow.parquet`.  
4. DuckDB: register the Arrow table and query it.

**Write path:**

1. DuckDB: produce a local result (Arrow or Pandas).  
2. Snowpark: create a Snowpark `DataFrame` from Arrow/Pandas.  
3. Snowflake: materialize a new Dataset version via `create_from_dataframe`.

Dataset versions are immutable; writes are modeled as **new versions**.

### 5.2 Detailed Read Flow (Dataset → DuckDB)

#### 5.2.1 Create or load Dataset in Snowflake

Python (Snowpark \+ Snowflake ML):

```py
from snowflake.snowpark import Session
from snowflake.ml import dataset

session = Session.builder.configs({
    "account": "<ACCOUNT>",
    "user": "<USER>",
    "password": "<PASSWORD>",
    "role": "<ROLE>",
    "warehouse": "<WAREHOUSE>",
    "database": "<DB>",
    "schema": "<SCHEMA>",
}).create()

# Example: create dataset from an existing table
ds = dataset.create_from_dataframe(
    session=session,
    name="MYDB.MYSCHEMA.MYDATASET",
    version="v1",
    input_dataframe=session.table("MYDB.MYSCHEMA.SOURCE_TABLE"),
)
# ds is a Dataset with version v1 selected
```

Alternatively, load an existing Dataset version:

```py
ds = dataset.load_dataset(
    session=session,
    name="MYDB.MYSCHEMA.MYDATASET",
    version="v1",
)
```

#### 5.2.2 Enumerate files and filesystem

```py
files = ds.read.files()          # ["snow://dataset/DB.SCHEMA.MYDATASET/versions/v1/data_0_0_0.snappy.parquet", ...]
fs    = ds.read.filesystem()     # fsspec-compatible SnowFileSystem
```

Under the hood, `DatasetReader` uses `get_dataset_filesystem` and `get_dataset_files` to discover and expose files on internal stages.

#### 5.2.3 Read into Arrow, then DuckDB

```py
import pyarrow.parquet as pq
import duckdb

# 1) Arrow table from Parquet + fsspec FS
arrow_tbl = pq.read_table(files, filesystem=fs)  # Arrow table with full dataset

# 2) DuckDB: register Arrow and query
con = duckdb.connect("local.db")
con.register("sf_dataset_arrow", arrow_tbl)

# Optionally persist as DuckDB table
con.execute("CREATE TABLE sf_dataset AS SELECT * FROM sf_dataset_arrow")

# Query in DuckDB
res = con.execute("SELECT COUNT(*) FROM sf_dataset").fetchall()
print(res)
```

This pattern:

- Preserves Snowflake’s optimized file layout.  
- Avoids round‑tripping through CSV or COPY.  
- Makes Dataset usable as a **versioned, file-backed source** for DuckDB.

### 5.3 Detailed Write Flow (DuckDB → new Dataset version)

The reverse path uses Arrow to bridge DuckDB and Snowpark.

```py
import duckdb
from snowflake.snowpark import Session
from snowflake.ml import dataset

# Existing connections
con = duckdb.connect("local.db")
session = Session.builder.configs({ ... }).create()

# 1) Get data out of DuckDB as Arrow
arrow_back = con.execute("SELECT * FROM sf_dataset").arrow()

# 2) Create Snowpark DataFrame
sp_df = session.create_dataframe(arrow_back)

# 3) Create new Dataset version
new_ds = dataset.create_from_dataframe(
    session=session,
    name="MYDB.MYSCHEMA.MYDATASET",
    version="v2",
    input_dataframe=sp_df,
)
print(new_ds.read.files()[:3])
```

Key points:

- Datasets are **immutable**; `v2` is a new snapshot.  
- This is the supported write path; there is no API to write via the Dataset filesystem (i.e., no “mount and mutate” semantics).

### 5.4 Comparison to Legacy FileSet

- FileSet exposed `sfc://` paths and a `SnowflakeFileSystem` (via `sfcfs`) for fsspec.  
- Dataset \+ `DatasetReader.filesystem()` is the intended replacement, using `snow://dataset/...` URLs and `SnowFileSystem` under the hood.  
- For **DuckDB**, the practical interop is identical in spirit: use fsspec \+ Parquet to bridge.

### 5.5 Pros and Cons

**Pros**

- Native to Snowflake ML ecosystem (Feature Store, ML pipelines).  
- Clean **versioning** semantics for training/test snapshots.  
- Simple Python integration; no need to reason about Iceberg catalogs.

**Cons**

- Not directly accessible as a table by other open engines (beyond fsspec \+ Parquet).  
- Write path must go through Snowpark / `create_from_dataframe`; no direct “append via filesystem”.

---

## 6\. Option 2 – Snowflake Storage for Iceberg Tables \+ DuckDB

### 6.1 Architecture

With Snowflake Storage for Iceberg Tables:

- Snowflake manages Iceberg table storage (file layout, compaction, security, etc.).  
- Horizon / Open Catalog exposes these tables via **Iceberg REST Catalog (IRC)**.  
- External engines (Spark, Trino, Flink, and **DuckDB**) connect via IRC and receive **vended storage credentials** to read/write data.

On the DuckDB side:

- The **Iceberg extension** supports attaching Iceberg REST Catalogs via `ATTACH ... TYPE iceberg ... ENDPOINT ... SECRET ...`.  
- Once attached, DuckDB supports:  
  - `CREATE/DROP SCHEMA`  
  - `CREATE/DROP TABLE`  
  - `INSERT`, `UPDATE`, `DELETE`, `SELECT`  
  - Bulk copy between DuckDB and Iceberg `<-> DuckDB` via `COPY FROM DATABASE`.

### 6.2 DuckDB–Horizon IRC Configuration

#### 6.2.1 Enable Iceberg extension in DuckDB

```sql
INSTALL httpfs;
INSTALL iceberg;

LOAD httpfs;
LOAD iceberg;
```

Requires DuckDB version that includes the **Iceberg REST Catalogs** feature.

#### 6.2.2 Configure authentication as a DuckDB secret

Two typical patterns:

**A. Existing Snowflake access token (Bearer)**

```sql
CREATE SECRET snowflake_irc_secret (
  TYPE  iceberg,
  TOKEN '<SNOWFLAKE_ACCESS_TOKEN>'
);
```

**B. OAuth2 client credentials**

```sql
CREATE SECRET snowflake_irc_secret (
  TYPE               iceberg,
  CLIENT_ID          '<CLIENT_ID>',
  CLIENT_SECRET      '<CLIENT_SECRET>',
  OAUTH2_SERVER_URI  '<SNOWFLAKE_OAUTH2_TOKEN_URL>'
  -- Optionally: OAUTH2_GRANT_TYPE, OAUTH2_SCOPE
);
```

DuckDB’s Iceberg docs explicitly support OAuth2 with `CLIENT_ID`, `CLIENT_SECRET`, and `OAUTH2_SERVER_URI` for REST catalogs.

#### 6.2.3 Attach the Snowflake Iceberg catalog

```sql
ATTACH 'sf_iceberg' AS sf_iceberg_catalog (
  TYPE     iceberg,
  ENDPOINT '<HORIZON_ICEBERG_REST_ENDPOINT>',
  SECRET   'snowflake_irc_secret'
);
```

Where `ENDPOINT` is the **Horizon IRC URL** for Snowflake’s Iceberg catalog in the relevant account/region, as documented in Snowflake’s Storage for Iceberg / Horizon integration docs.

#### 6.2.4 Discover and query tables

```sql
SHOW ALL TABLES;

SELECT *
FROM sf_iceberg_catalog."MYDB"."MYSCHEMA"."MY_ICEBERG_TABLE"
LIMIT 10;
```

From DuckDB’s perspective, this is just another Iceberg catalog; from Snowflake’s perspective, it’s Snowflake‑managed storage exposed via an open interface.

### 6.3 Supported Operations

Given DuckDB Iceberg’s REST support, the following should work (subject to Snowflake permissions, preview limits, and Iceberg spec version):

```sql
-- Create table through DuckDB (if allowed by catalog policy)
CREATE TABLE sf_iceberg_catalog."MYDB"."MYSCHEMA"."NEW_TABLE" AS
SELECT * FROM some_local_duckdb_table;

-- Insert data
INSERT INTO sf_iceberg_catalog."MYDB"."MYSCHEMA"."NEW_TABLE"
SELECT * FROM some_local_duckdb_table;

-- Update/delete (with current DuckDB limitations on partitioned/sorted tables)
UPDATE sf_iceberg_catalog."MYDB"."MYSCHEMA"."NEW_TABLE"
SET col = col + 1
WHERE id < 100;

DELETE FROM sf_iceberg_catalog."MYDB"."MYSCHEMA"."NEW_TABLE"
WHERE id < 0;
```

DuckDB’s Iceberg docs list limitations (e.g., UPDATE/DELETE only on non‑partitioned, non‑sorted tables; merge‑on‑read semantics only).

### 6.4 Constraints and Caveats

- DuckDB Iceberg currently notes: *“Reading from Iceberg REST Catalogs backed by remote storage that is not S3 or S3 Tables is not yet supported.”*  
  - This aligns well with **Snowflake Storage for Iceberg on AWS** (S3-backed).  
  - For Azure/GCP variants, support depends on future DuckDB Iceberg enhancements.  
- Snowflake’s Storage for Iceberg is in **Private Preview**; features like Iceberg V3, lifecycle management, and certain security options are evolving.

### 6.5 Pros and Cons

**Pros**

- True **open table** semantics: Snowflake and DuckDB operate on the same Iceberg tables.  
- No data copy required beyond normal Iceberg write semantics.  
- Aligns with **Horizon / Open Catalog / Apache Polaris** strategy, and with DuckDB’s Iceberg REST support.

**Cons**

- Requires Storage for Iceberg to be enabled and configured (currently PrPr).  
- DuckDB Iceberg REST support is relatively new; some operations (MERGE, ALTER TABLE, certain partitioned UPDATE/DELETE) have limitations.  
- For non‑AWS deployments, there may be temporary gaps until DuckDB adds support for non‑S3 remote stores.

---

## 7\. Option 3 – External Iceberg (Shared Object Storage)

For completeness, there is a third model where:

- Customer manages Iceberg data in their own object store (S3/GCS/Azure).  
- Snowflake defines **external Iceberg tables** on those locations.  
- DuckDB connects directly to the same external Iceberg catalog (e.g., Polaris in customer infra, Glue, Lakekeeper) via REST or file-based metadata.

This pattern:

- Is conceptually similar to Option 2 (shared Iceberg), but **storage is customer‑managed** rather than Snowflake‑managed.  
- Is attractive when customers want maximum control over storage and catalog, with Snowflake and DuckDB as peers.

Trade‑offs are the usual external Iceberg ones: more operational responsibility on the customer, but strong cross‑engine compatibility.

---

## 8\. Recommended Patterns

### 8.1 For ML / Feature Engineering inside Snowflake

Use **Snowflake Dataset \+ fsspec \+ DuckDB**:

- Treat Dataset as the authoritative, versioned training/eval snapshot.  
- Use the Dataset read path to hydrate DuckDB for local experimentation, feature analysis, or model prototyping.  
- Write back derived features or labels as new Dataset versions via `create_from_dataframe`.

This integrates cleanly with Snowflake Feature Store, Dynamic Tables, and ML pipelines that already produce Datasets.

### 8.2 For Lakehouse / Multi‑engine Analytics

When **Snowflake Storage for Iceberg Tables** is available on AWS:

- Prefer **Iceberg REST integration**:  
  - Use Snowflake-managed Iceberg tables as the central lakehouse storage.  
  - Attach DuckDB to Horizon’s Iceberg REST Catalog via `ATTACH ... TYPE iceberg ...`.  
- Use Dataset only when you need:  
  - Rich ML metadata and lineage.  
  - Versioned snapshots tied tightly to Feature Store or Snowflake ML pipelines.

### 8.3 When Storage for Iceberg Is Not Available

- Use **Dataset \+ fsspec** as the primary interop mechanism.  
- For more open interop, consider **external Iceberg tables** on customer S3, with both Snowflake and DuckDB attached to a shared catalog (e.g., Polaris, Glue, Lakekeeper).

---

## 9\. Open Questions and Next Steps

1. **Auth patterns for Horizon IRC \+ DuckDB**  
     
   - Document concrete examples for:  
     - Snowflake PAT/Bearer token.  
     - OAuth2 client‑credentials flow with Horizon.  
   - Verify token lifetimes and refresh behavior for long‑running DuckDB sessions.

   

2. **Operational guidance for UPDATE/DELETE on Iceberg via DuckDB**  
     
   - Clarify supported patterns for partitioned Iceberg tables under DuckDB’s current limitations (merge‑on‑read, no copy‑on‑write yet).

   

3. **Performance characterization**  
     
   - Benchmark:  
     - Dataset → DuckDB (Arrow) path vs.  
     - DuckDB Iceberg REST direct scan against Storage for Iceberg.  
   - Include cost/latency trade‑offs and caching strategies.

   

4. **Tooling & UX**  
     
   - Potential helpers:  
     - A Snowflake‑hosted notebook template that:  
       - Creates a Dataset.  
       - Spawns a DuckDB session.  
       - Bridges data automatically via Arrow.  
     - A small CLI or Python helper library to configure DuckDB’s Iceberg REST integration against Horizon.

These items can be tracked and refined as part of a broader “Snowflake & DuckDB Interop” initiative, and folded into external docs once Storage for Iceberg and Dataset usage patterns stabilize.

*Written with Glean Assistant*

# Using R with DuckDB to integrate with Snowflake

*\> I have an alternative approach Id like us to explore.  DuckDB has a Snowflake adaptor that enables it to query data in Snowflake via ADBC or Arrow I believe. Could we install DuckDB in the user-space of the Notebook linux.  And then use the R API for DuckDB to work with DuckDB to query Snowflake via dplyr/dbplyr*

Yes, in principle this stack is viable:

**R (dbplyr) → DuckDB R API → DuckDB “snowflake” extension → ADBC Snowflake driver → Snowflake**

…but it comes with the same **SPCS auth constraints** as your earlier ADBC experiments, plus the usual “community extension, not Snowflake‑supported” caveats.

I’ll break it down.

---

### **1\. What the DuckDB Snowflake extension actually does**

The DuckDB community **`snowflake`** extension:

* Is a community extension published via the DuckDB extension repo.  
* Connects to Snowflake using the **Apache Arrow ADBC Snowflake driver** (C library).  
* Provides:  
  * `snowflake_query(sql, secret_name)` – pass-through SQL against Snowflake.  
  * `ATTACH '' AS sf (TYPE snowflake, SECRET my_snowflake, READ_ONLY …)` – mount Snowflake as a DuckDB catalog.  
  * Support for several auth methods: password, OAuth, key pair, external browser/SSO, Okta/MFA, etc.  
  * Optional **predicate pushdown** from DuckDB into Snowflake when enabled on `ATTACH`.

Install/load from DuckDB:

```sql
INSTALL snowflake FROM community;
LOAD snowflake;
```

This is all standard DuckDB extension plumbing; the **prerequisite** is that the **ADBC Snowflake driver** shared lib is installed in the expected DuckDB extensions directory (they document install scripts that drop `libadbc_driver_snowflake.so` under `~/.duckdb/extensions/vX.Y.Z/linux_amd64`).

From there, you can:

```sql
CREATE SECRET my_snowflake (
  TYPE snowflake,
  ACCOUNT 'xy12345.eu-west-1',
  USER 'SFIELD',
  PASSWORD '…',
  DATABASE 'DB',
  WAREHOUSE 'WH'
);

SELECT * FROM snowflake_query(
  'SELECT * FROM MY_DB.MY_SCHEMA.MYTABLE LIMIT 100',
  'my_snowflake'
);

ATTACH '' AS sf (TYPE snowflake, SECRET my_snowflake, READ_ONLY);

SELECT * FROM sf.MY_SCHEMA.MYTABLE WHERE COL > 10;
```

---

### **2\. Mapping that into Workspace Notebooks \+ R/dbplyr**

Your desired chain:

* **R \+ dbplyr** targeting **DuckDB** (not Snowflake directly).  
  * This is well‑trodden: dbplyr has a DuckDB backend via the `duckdb` R package.  
* DuckDB internally uses the **snowflake** extension \+ ADBC to talk to Snowflake.

In a Workspace Notebook container, that would look like:

1. **User-space environment setup (once per container image / session)**

    In the Notebook terminal:

```shell
# micromamba / conda-forge env for R + DuckDB
export MAMBA_ROOT_PREFIX=$HOME/micromamba
export PATH=$MAMBA_ROOT_PREFIX/bin:$PATH

micromamba create -y -n duckdb_r_env -c conda-forge r-base r-duckdb
micromamba activate duckdb_r_env
```

2.   
   (Or install `duckdb` from CRAN inside that env.)

3. **Install DuckDB snowflake extension \+ ADBC driver into user-space**

    From inside that env:

```shell
duckdb -c "INSTALL snowflake FROM community; LOAD snowflake;"
```

4.   
   Then install the ADBC Snowflake driver into DuckDB’s extension dir; the extension’s README gives a ready-made script that:

   * Detects DuckDB version (e.g. `v1.4.3`).  
   * Downloads the right `adbc_driver_snowflake-*.whl`.  
   * Extracts `libadbc_driver_snowflake.so`.  
   * Places it in `~/.duckdb/extensions/v1.4.3/linux_amd64/` (for Linux x86\_64).  
5. **R side: connect to DuckDB and use dbplyr**

    In R (inside that env):

```
library(DBI)
library(duckdb)
library(dplyr)
library(dbplyr)

con <- dbConnect(duckdb::duckdb(), dbdir = ":memory:")  # or a file
```

6.   
   Wire up Snowflake from R via SQL:

```
DBI::dbExecute(con, "LOAD snowflake")

DBI::dbExecute(con, "
  CREATE SECRET my_snowflake (
    TYPE snowflake,
    ACCOUNT 'xy12345.eu-west-1',
    USER 'SFIELD',
    PASSWORD '…',
    DATABASE 'DB',
    WAREHOUSE 'WH'
  )
")

DBI::dbExecute(con, "
  ATTACH '' AS sf (TYPE snowflake, SECRET my_snowflake, READ_ONLY)
")
```

7.   
   Now **DuckDB sees Snowflake tables** under the `sf` catalog, and **R/dbplyr sees a DuckDB database**:

```
sf_tbl <- tbl(con, in_schema("sf.MY_SCHEMA", "MYTABLE"))

# dbplyr pipeline, executed via DuckDB (with some pushdown into Snowflake):
result <- sf_tbl %>%
  filter(col_a > 10, status == "O") %>%
  group_by(group_key) %>%
  summarise(total = sum(metric), .groups = "drop") %>%
  collect()
```

8.   
   Under the hood:

   * dbplyr generates DuckDB SQL.  
   * DuckDB’s planner plus the `snowflake` extension decide what to push down as ADBC queries vs what to execute locally.

So **yes**: conceptually you get “dbplyr on DuckDB” with DuckDB transparently using **ADBC → Snowflake**, all from inside the Notebook container.

---

### **3\. SPCS / Workspace Notebook constraints that still apply**

All the auth and topology constraints we hit with **R \+ ADBC directly in Workspace Notebooks** still apply here, because the DuckDB extension uses **the same ADBC Snowflake C driver**:

* The extension wants to talk to **`<account>.snowflakecomputing.com`** using standard ADBC auth (password, key pair, OAuth, etc.).  
* It does **not** know about the special SPCS `/snowflake/session/token`, and that token is only accepted by a narrow set of “blessed” clients.  
* Username/password or PAT to the **internal** SPCS endpoint is blocked; internal connections must use OAuth and an allowed client.

Implications for this design:

* You must treat DuckDB+ADBC as a **fully external client**:  
  * Network egress from the Notebook container to `https://<account>.snowflakecomputing.com` must be allowed.  
  * Auth must be something like **PAT** or **key pair** or **OAuth** issued for your app, not the SPCS token.  
  * PAT will still have the normal **network policy** requirements unless relaxed via auth policy, same as your earlier ADBC experiments.

Nothing about wrapping ADBC inside DuckDB magically bypasses the SPCS auth model.

---

### **4\. Practical caveats**

A few things to be very clear about:

1. **Support status**

   * The DuckDB `snowflake` extension is **community-maintained** (iqea‑ai), not a Snowflake product.  
   * It depends on the **Snowflake ADBC driver**, which is itself currently preview-ish from our side in many contexts and not yet a fully supported, first-class driver for all languages/use cases.  
   * If something breaks, you’re in GitHub‑issues land (extension \+ ADBC), not Salesforce cases.  
2. **Two planners in the loop**

   * dbplyr’s DuckDB backend emits DuckDB dialect SQL.  
   * DuckDB \+ the extension decide what to push down to Snowflake.  
   * That means:  
     * Some operations will run in Snowflake (good).  
     * Some may run inside DuckDB on data pulled from Snowflake (could be large).  
     * Edge‑case type mappings / functions may need tuning; the extension already has non‑trivial Arrow↔DuckDB↔Snowflake type translation logic.  
3. **Operational complexity inside Notebooks**

   * You need:  
     * micromamba/conda env for R \+ DuckDB.  
     * DuckDB extension installation \+ ADBC driver deployment into `~/.duckdb/extensions/...`.  
     * Outbound network to GitHub (for driver & extension downloads) and to Snowflake.  
   * All of this is **within a managed Notebook container** that may be recreated; you’d likely want to script setup in a single `!bash setup_duckdb_snowflake.sh` cell, similar to your micromamba+R scripts.

---

### **5\. My take**

**Conceptually** this is a nice pattern:

* It gives you **dbplyr** on top of DuckDB.  
* It leverages **ADBC** \+ Arrow for efficient transfer.  
* It keeps all the complex Snowflake connectivity in one place (DuckDB+extension), which R just sees as another DBI source.

But for **Workspace Notebook containers specifically**:

* It’s **possible** as an **internal PoC / lab experiment**, if you’re happy to:  
  * Use external‑style auth (PAT or key pair) to the public endpoint.  
  * Accept that the entire stack (DuckDB extension \+ ADBC) is non‑Snowflake‑supported.  
* It’s **not something I’d recommend as a customer‑facing pattern** today, for the same reasons we were cautious about ODBC/ADBC inside Notebooks directly.

For your own workbench and internal demos, it’s an interesting avenue to try; for anything we’d put into an “official” guide, I’d still favour:

* **R \+ ODBC \+ dbplyr in a dedicated SPCS R service**, and  
* **Workspace Notebooks → Snowpark \+ rpy2** for R inside the Notebook container.

Would you like a step-by-step notebook setup script (micromamba \+ DuckDB extension \+ ADBC) to try this in your Workspace Notebook?

*\> The users are already using R in Snowflake Workspace that is not officially supported.  This is provided as-is, for experimentation so I think the community support aspect is OK.*  

*I think the typical user will use Snowflake for the heavy-lifting and then want to use DuckDB for local processing within the container of a smaller dataset returned to DuckDB.  Can you read from Snowflake and write to a DuckDB table in the Workspace.*  

*If the user wanted to persist those smaller 'result tables' e.g. data for freature-engineering for training pipeline in R, what are the options?*

Yes, this is exactly the kind of pattern the DuckDB Snowflake extension was built for, and it fits your “Snowflake \= heavy lifting, DuckDB \= local subset” story quite well.

I’ll split it into:

1. **Can we read from Snowflake and write into a local DuckDB table?**  
2. **How to persist those “result tables” for feature engineering.**

---

## **1\. Snowflake → DuckDB table inside the Workspace container**

With the DuckDB **`snowflake`** extension:

* Queries are executed **in Snowflake** via the ADBC driver, using Arrow for the result stream.  
* The extension is **read‑only** with respect to Snowflake (SELECTs only), but that’s fine; you just `CREATE TABLE` in DuckDB from the result.

So your “heavy lifting in Snowflake, small result in DuckDB” flow is:

1. In R, open a DuckDB connection *backed by a file* (so you can persist):

```
library(DBI)
library(duckdb)

# Put this on whatever path you consider “persistent” in the Notebook filesystem
con <- dbConnect(duckdb::duckdb(), dbdir = "feature_store.duckdb")
```

2.   
   Load the Snowflake extension and define a Snowflake secret:

```
DBI::dbExecute(con, "INSTALL snowflake FROM community;")
DBI::dbExecute(con, "LOAD snowflake;")

DBI::dbExecute(con, "
  CREATE SECRET my_snowflake_secret (
    TYPE snowflake,
    ACCOUNT 'xy12345.eu-west-1',
    USER 'SFIELD',
    PASSWORD '...',
    DATABASE 'DB',
    WAREHOUSE 'WH'
  )
")
```

3.   
   Either use `snowflake_query(...)` directly:

```
DBI::dbExecute(
  con,
  "
  CREATE TABLE features_train AS
  SELECT *
  FROM snowflake_query(
    'SELECT * FROM FSTORE.FEATURE_VIEW_X WHERE TRAINING_DATE >= DATEADD(DAY,-30,CURRENT_DATE)',
    'my_snowflake_secret'
  )
  "
)
```

4.   
   or `ATTACH` Snowflake as a catalog and query it:

```
DBI::dbExecute(
  con,
  "ATTACH '' AS sf (TYPE snowflake, SECRET my_snowflake_secret, READ_ONLY);"
)

DBI::dbExecute(
  con,
  "
  CREATE TABLE features_train AS
  SELECT *
  FROM sf.FSTORE.FEATURE_VIEW_X
  WHERE TRAINING_DATE >= DATEADD(DAY,-30,CURRENT_DATE)
  "
)
```

Now `features_train` is a **pure DuckDB table** in your local `feature_store.duckdb` file:

```
head(DBI::dbGetQuery(con, "SELECT * FROM features_train LIMIT 10"))
```

From here, you can:

* Use `dbplyr` with DuckDB as the backend:

```
library(dplyr)
library(dbplyr)

features_tbl <- tbl(con, "features_train")

agg <- features_tbl %>%
  group_by(segment) %>%
  summarise(
    cnt = n(),
    avg_y = mean(label),
    .groups = "drop"
  ) %>%
  collect()
```

*   
  Or pull into a local R `data.frame` and run base / tidyverse / modelling code.

This gives you exactly the **“Snowflake does the big scan/join; DuckDB holds a narrower training set”** pattern you’re after.

SPCS/Workspace constraints: this still uses ADBC under the hood, so it must authenticate to the **public Snowflake endpoint** (PAT/OAuth/keypair, etc.), not the internal SPCS token. But since you already accepted that for experimentation, this is consistent with the earlier ADBC work.

---

## **2\. Persistence options for those smaller “result tables”**

Once you’ve created DuckDB tables like `features_train` in the Notebook container, you’ve got three realistic persistence tiers:

### **2.1. Local DuckDB file (within the Workspace container)**

This is the **simplest** for R training:

* You already used:

```
con <- dbConnect(duckdb::duckdb(), dbdir = "feature_store.duckdb")
```

*   
  Every time you reopen that Notebook (and the container’s filesystem is still around), you just reconnect:

```
con <- dbConnect(duckdb::duckdb(), dbdir = "feature_store.duckdb")
features_tbl <- tbl(con, "features_train")
```

Pros:

* Very fast, zero-network training loops.  
* Perfect for **iterative feature engineering and model prototyping**.  
* dbplyr works cleanly against DuckDB.

Caveats:

* Durability is limited by whatever persistence guarantees the Workspace filesystem gives you:  
  * Files **inside the container** (e.g. under `/root` or `$HOME`) typically live as long as the Workspace instance, but not beyond a full teardown / re‑provisioning.  
  * If Workspaces exposes a **mounted persistent volume** (e.g. a project directory backed by a stage), point `dbdir` there instead so the `.duckdb` file survives kernel/container restarts.  
* This is **per‑user, per‑Workspace**; it’s not a shared asset other users can see.

For your “R user iterating on a training pipeline in a single Workspace” persona, this is likely the **primary** pattern.

---

### **2.2. Local Parquet (or other files) plus DuckDB**

If you want something slightly more “open” than a `.duckdb` file:

* Materialise features as Parquet in the container:

```
DBI::dbExecute(
  con,
  "
  COPY (SELECT * FROM features_train)
  TO 'features_train.parquet' (FORMAT PARQUET)
  "
)
```

*   
  Later, in the same or another session, you can either:

  * Query directly from DuckDB:

```
DBI::dbExecute(con, "CREATE TABLE features_train AS SELECT * FROM 'features_train.parquet'")
```

  *   
    Or read into R with `arrow` or `vroom` etc.

This doesn’t solve persistence beyond the container lifecycle, but it’s nice if you want to keep the storage format **tool‑agnostic**.

---

### **2.3. Persist back into Snowflake (for sharing / durability)**

If you want those engineered feature tables to live beyond the Notebook container (e.g. as part of a training pipeline reproducibly), you ultimately want them **in Snowflake** again:

Patterns:

1. **Write from DuckDB → Parquet files → upload to a stage via Snowpark**:

   * Step 1: use DuckDB to write Parquet:

```
DBI::dbExecute(
  con,
  "
  COPY (SELECT * FROM features_train)
  TO 'features_train.parquet' (FORMAT PARQUET)
  "
)
```

   *   
     Step 2: in a Python cell (Snowpark) using `get_active_session()`:

```py
import os
from snowflake.snowpark import Session

session = Session.builder.getOrCreate()

# Adjust path if needed – here we assume the Notebook can see the same filesystem path.
local_path = "/root/feature_store/features_train.parquet"

session.file.put(
    local_path,
    "@MY_STAGE/features/",
    auto_compress=False,
    overwrite=True,
)
```

   *   
     Step 3: in SQL:

```sql
CREATE OR REPLACE TABLE TRAINING_FEATURES AS
SELECT *
FROM @MY_STAGE/features/features_train.parquet
(FILE_FORMAT => (TYPE = PARQUET));
```

2.   
   Now your “experimentally engineered” features are in a **proper Snowflake table** you can use from pipelines, dynamic tables, Feature Store, etc.

3. **Recompute in Snowflake using SQL** (once the feature transformations stabilize)

   * Treat DuckDB/R as the **playground** for new transformation logic.  
   * Once happy, port the final transformations back into:  
     * Snowflake SQL / dynamic tables, or  
     * Feature Store transformation DAG.  
   * Then Snowflake becomes the system of record for those features; DuckDB is just a local cache for experimenting.

---

### **3\. How I’d position it for your users**

Given your constraints (“R in Workspace is already unofficial, this is for experimentation”):

* **For exploratory feature engineering:**

  * Use **DuckDB \+ snowflake extension** inside the Notebook to:  
    * Run **big SELECTs in Snowflake**, but  
    * Materialise **narrow, training‑size tables** into a local `feature_store.duckdb`.  
  * Have R/dbplyr run against that DuckDB file for modelling.  
* **For persistence:**

  * Short‑to‑medium term (single user, same Workspace):  
    * Use a **file‑backed DuckDB database** on whatever path is most persistent in the Notebook environment.  
  * Longer term / reproducible pipelines / sharing:  
    * Export from DuckDB to Parquet and PUT to a stage, then **CREATE TABLE** in Snowflake, or  
    * Reimplement the final transformation logic in **Snowflake SQL / Feature Store**.

That gives users exactly what you described: **Snowflake for heavy lifting, DuckDB as a local workbench for R**, with an escape hatch back into Snowflake once the features are “real”.

Would you like a ready-to-run notebook script (micromamba setup, DuckDB extension install, read/write examples, and Parquet→stage steps)?

