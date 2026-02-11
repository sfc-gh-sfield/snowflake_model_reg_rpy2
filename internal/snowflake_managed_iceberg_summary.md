Here’s a concise snapshot you can drop into Cursor, plus links.

---

### 1. Current status: Horizon Catalog + Snowflake‑managed Iceberg

**Terminology**

- **“Snowflake‑managed Iceberg” (CATALOG = 'SNOWFLAKE') and “Horizon‑managed Iceberg” are effectively the same thing** from the external‑engine perspective – Horizon Catalog is the control plane that exposes those tables via Iceberg REST (IRC).  

**External engine reads via Horizon Catalog**

- **External engine READs to Snowflake‑managed Iceberg tables via Horizon’s Iceberg REST Catalog are GA** (announced around Build ’26).  
- External engines (Spark, Trino, Flink, DuckDB, etc.) connect to **Horizon’s Iceberg REST Catalog endpoint** and see a standard Iceberg REST Catalog: list namespaces/tables, load table metadata, and read data using vended storage credentials.  
- Reads are **warehouse‑free**: billing for the REST API is **Cloud Services only**, no warehouse usage; during preview, billing has been deferred, with normal Cloud Services pricing expected once fully GA.  

**External engine writes**

- **Writes from external engines into Snowflake‑managed Iceberg via Horizon are in Private Preview**, targeting Iceberg v2 tables only.  
- Today, for production you should treat Horizon + Snowflake‑managed Iceberg as **read‑anywhere, write‑primarily‑from Snowflake** (or from explicitly enrolled preview engines).

---

### 2. What Horizon Iceberg REST Catalog actually gives you

For **Snowflake‑managed Iceberg tables (CATALOG = 'SNOWFLAKE')**:

- **Single catalog endpoint** in Horizon that:
  - Enumerates Iceberg namespaces/tables.
  - Returns Iceberg table metadata (snapshots, manifests, schemas, partitions) via standard Iceberg REST APIs.
  - **Vends storage credentials** so external engines can read the underlying Parquet/ORC files directly from storage (S3/ADLS/GCS or Snowflake‑managed internal storage exposed via S3/Blob semantics).  
- **Multi‑engine story**: Horizon is explicitly positioned as **“multi‑engine READ/WRITE to Iceberg tables with one catalog”**, with Snowflake‑managed Iceberg as the primary pattern.  
- **Governance**:
  - RBAC and (in the roadmap) fine‑grained policies enforced at the catalog layer for external engines as they call the REST API.  
  - For now, external reads GA; FGAC and external writes are in staged rollouts (PrPr / PuPr depending on feature).  

Operationally, an external engine just sees “an Iceberg REST Catalog that happens to be Horizon.”

---

### 3. DuckDB reading Snowflake‑managed Iceberg via Horizon

From the DuckDB side (Iceberg extension):

1. **Enable DuckDB’s Iceberg + HTTPFS extensions**:

   ```sql
   INSTALL httpfs;
   INSTALL iceberg;
   LOAD httpfs;
   LOAD iceberg;
   ```  

2. **Configure authentication** as a DuckDB secret, using either:
   - An existing Snowflake **access token** (e.g. PAT / OAuth token tied to a Horizon service user), or  
   - **OAuth2 client credentials** if you want DuckDB to obtain tokens itself.

   Example (bearer token):

   ```sql
   CREATE SECRET snowflake_irc_secret (
     TYPE iceberg,
     TOKEN '<SNOWFLAKE_ACCESS_TOKEN>'
   );
   ```  

3. **Attach the Horizon Iceberg REST endpoint as a catalog**:

   ```sql
   ATTACH 'sf_iceberg' AS sf_iceberg_catalog (
     TYPE iceberg,
     ENDPOINT '<HORIZON_ICEBERG_REST_ENDPOINT>',
     SECRET 'snowflake_irc_secret'
   );
   ```  

   - The `ENDPOINT` is the **Horizon Iceberg REST Catalog URL** for your account/region (same one you’d use from Spark/Trino).  

4. **Query Snowflake‑managed Iceberg tables**:

   ```sql
   SELECT *
   FROM sf_iceberg_catalog."MYDB"."MYSCHEMA"."MY_ICEBERG_TABLE"
   LIMIT 10;
   ```  

5. **Storage‑layer caveats** (from DuckDB’s side):
   - DuckDB’s Iceberg docs historically note that **REST catalogs backed by non‑S3 storage are not fully supported yet**, which aligns cleanly with **AWS S3‑backed** Storage for Iceberg today; Azure/GCP variants depend on DuckDB’s own roadmap.  
   - For “Snowflake managed storage” behind Horizon, Polaris/Horizon **vend S3/Blob‑style credentials** even when the backing is an internal stage, so DuckDB still sees familiar S3/Blob URLs, not `snow://` paths.  

In practice, once you have the Horizon Iceberg REST endpoint and a token, DuckDB treats this exactly like any other Polaris‑style catalog.

---

### 4. Snowflake‑managed Iceberg on internal Snowflake storage

Your second question:

> “I understood that Snowflake‑managed Iceberg tables can be stored on internal Snowflake storage now, rather than requiring external cloud‑storage?”

**Yes.** There is now support for **Iceberg tables on Snowflake‑managed internal storage**, sometimes described as *“Lakehouse Storage”* or *“Iceberg tables on Snowflake managed storage.”*  

Key points:

- Historically, **Snowflake‑managed Iceberg** required:
  ```sql
  CREATE ICEBERG TABLE ... 
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'my_external_volume';
  ```
  with `EXTERNAL_VOLUME` pointing at customer cloud storage (S3/GCS/ADLS).  

- The new design introduces **external volumes that can use an internal stage as the storage location**, via `STORAGE_PROVIDER = 'SNOWFLAKE'`:
  ```sql
  CREATE OR REPLACE EXTERNAL VOLUME exvol1
    STORAGE_LOCATIONS = (
      NAME = 'my-internal-stage-location'
      STORAGE_PROVIDER = 'SNOWFLAKE'
      -- optionally other locations
    );
  ```
  - **All Iceberg tables created on such an external volume are stored on a hidden internal stage**, and **they are still Snowflake‑managed Iceberg tables**.  

- Longer‑term direction (“Lakehouse Storage”):
  - Make Snowflake‑managed Iceberg tables feel like **native tables**: `CREATE ICEBERG TABLE t1 (col1 int);` with **no explicit storage or catalog location**, and Snowflake manages files in internal storage behind the scenes.  
  - Support this same Snowflake‑managed storage from **Open Catalog / Polaris**, including credential vending to external engines for tables stored on internal stages.  

- Public docs already reference **Iceberg tables on Snowflake internal storage** as an option alongside customer‑managed storage.  

Availability is still going through Limited‑Access / preview phases in some regions and clouds; practically, if you don’t see the internal‑storage options in your account, you’ll need feature enablement.

---

### 5. Useful reference links

**Public / customer‑facing docs**

- **Snowflake‑managed Iceberg overview & creation**
  - Snowflake Iceberg tables (user guide):  
    `https://docs.snowflake.com/en/user-guide/tables-iceberg`  
  - Creating Snowflake‑managed Iceberg tables (CATALOG = 'SNOWFLAKE'):  
    `https://docs.snowflake.com/en/user-guide/tables-iceberg-create#snowflake-managed`  

- **External engine reads via Horizon Catalog (Iceberg REST)**
  - *Query Apache Iceberg tables with an external engine using Snowflake Horizon Catalog*:  
    `https://docs.snowflake.com/en/user-guide/tables-iceberg-query-using-external-query-engine-snowflake-horizon`  
  - *Create CATALOG INTEGRATION (Apache Iceberg REST)*:  
    `https://docs.snowflake.com/en/sql-reference/sql/create-catalog-integration#apache-iceberg-rest`  

- **Iceberg tables on Snowflake internal storage**
  - *Iceberg tables on Snowflake internal storage* (Limited Access):  
    `https://docs.snowflake.com/LIMITEDACCESS/iceberg/tables-iceberg-internal-storage`  

- **Snowflake‑managed Iceberg + Polaris/Open Catalog**
  - *Sync Snowflake‑managed Iceberg tables to Open Catalog*:  
    `https://docs.snowflake.com/en/user-guide/tables-iceberg-open-catalog-sync`  

- **Blog / positioning**
  - “Open by Design: Snowflake's Commitment to Iceberg and Interoperability” (Horizon + Iceberg + Open Catalog story).  

**Internal / Snowflake‑only (for deeper design context)**

- *Design: Integrating Snowflake and DuckDB* – includes detailed DuckDB + Horizon IRC config and examples (your GDrive doc):  
  `https://docs.google.com/document/d/1Y3VuIkpxDWMDyVadf6a_8nuEnTseZomZM3k8z3yeD3s`  
- *Product review: Iceberg tables on Snowflake managed storage* – internal storage + Polaris integration details:  
  `https://docs.google.com/document/d/1Hl2N9KOENvfnlmCJjoJOKFSuQEO1oO1shlWkMkPXAzY`  
- *Externally Managed Iceberg* – very good ecosystem framing and mentions of internal storage option:  
  `https://snowflakecomputing.atlassian.net/wiki/spaces/SKE/pages/4719345697`  
- *Horizon Catalog Monthly Updates – FY26* – roadmap slides for external engine reads/writes and FGAC:  
  `https://docs.google.com/presentation/d/1PBeGFKC2E_MuCeybJCJG57JHGHURvz_IltqRkFkitJg`  

This should be enough context for you to wire DuckDB up via Horizon’s Iceberg REST endpoint and to document both the current GA capabilities and the emerging internal‑storage story in Cursor.

