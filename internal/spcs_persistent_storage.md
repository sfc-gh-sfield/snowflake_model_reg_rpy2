Snowpark Container Services *does* support a persistent filesystem, but only via specific **volume types** – the container’s root filesystem itself is **ephemeral**.

### What’s available today

From a container’s point of view, you have these volume types:

1. **Block storage volumes (persistent)**
   - **What it is:** Snowflake-managed block storage (EBS‑like for AWS) exposed as a POSIX filesystem inside your container.  
   - **Persistence:**  
     - Data **survives container restarts**, service restarts, and jobs.  
     - Volumes are **only deleted when the service is dropped** (or you explicitly drop the volume).  
     - You can **snapshot** a block volume for backup/rollback.  
   - **Semantics:**  
     - General-purpose filesystem: supports **random reads/writes**, appends, etc.  
     - Recommended for workloads that need a “real” filesystem (checkpoints, big binaries, model artifacts, caches, etc.).  

   **Spec example (YAML fragment):**
   ```yaml
   spec:
     containers:
       - name: app
         image: /db/schema/repo/app_image
         volumeMounts:
           - name: data-vol
             mountPath: /mnt/data
     volumes:
       - name: data-vol
         type: block
         size: 100Gi
   ```
   This gives your container a **persistent filesystem at `/mnt/data`**.

2. **Stage volumes / stage mounts (backed by internal stages)**
   - Mount an **internal stage** into the container as a filesystem path.  
   - Underlying persistence is the **stage**, but:
     - No **random writes or appends** – object-store semantics; those operations error.  
     - There can be **propagation delay / cache effects** when multiple services read/write via stage mounts, so it’s not a fully consistent shared filesystem.  
   - Good for **streaming reads/writes of large files** and simpler file-style access to stage objects, but **not a general persistent POSIX FS**.

3. **Local volumes (ephemeral)**
   - Per‑instance local storage, scoped to a given service instance; useful for **sharing files between containers in the same service instance only**.  
   - **Not persistent** across restarts.

4. **Memory volumes (ephemeral)**
   - RAM-backed tmpfs-style volumes, wiped on restart.  

### Practical guidance

- If you mean “I want a **true persistent filesystem** for containers” → **use block storage volumes**. That’s the closest SPCS has to a persistent disk today.
- If you just want **persisted objects** and can live with object-store semantics → use **stages** (with or without stage mounts) and `PUT`/`GET` / `COPY INTO` patterns; this is usually better for interop with external stages, etc.  
- Avoid treating **stage mounts** as a fully consistent shared filesystem between services; they’re optimized for throughput, not cache-coherence.  

### Public docs (for quick reference)

- **Supported volume types:**  
  `developer-guide/snowpark-container-services/specification-reference#about-the-supported-volume-types`  
- **Block storage volumes (persistent filesystem):**  
  `developer-guide/snowpark-container-services/block-storage-volume`  
- **Stage volumes / stage mounts:**  
  `developer-guide/snowpark-container-services/snowflake-stage-volume`  

If you tell me your exact use case (e.g. model checkpoints, intermediate features, notebooks, etc.), I can sketch the storage pattern and a concrete SPCS spec for it.

# Which of the above does Workspace Notebooks, particularly when configured using GIT backed workspace ?
For **Workspace Notebooks (vNext)** — including when the Workspace is **Git‑backed** — the storage story is:

### 1. What backs the “persistent filesystem” for the running notebook?

Workspace Notebooks run **only on Container Runtime / SPCS services**.  
Each notebook service has a **Snowpark Container Services block storage volume** attached:

- **Type:** SPCS **block storage volume** (persistent disk)  
- **Mounts:** Under a `pd0/` directory, with a per‑notebook subfolder; exposed via `PERSISTENT_DIR`:
  - `.../pd0/` – persistent block volume  
  - `.../pd0/$notebookuuid/` – “files that persist across restarts (get environment variable PERSISTENT_DIR)”.  
- **Usage:** 
  - Stores **virtual env / installed packages** and any files you explicitly put under `PERSISTENT_DIR`.  
  - Data persists across notebook/kernel restarts and service suspend/resume; only deleted when you delete the notebook/service (or disable persistent storage in the newer PS feature).  

So from the list I gave earlier, **Workspace Notebooks use:**

- ✅ **Block storage volumes** for persistent FS  
- 🚫 **Not** stage volumes for notebook persistence  
- 🚫 **Not** local/memory volumes for anything you should rely on long‑term (those remain ephemeral `/tmp`‑style)

The separate **“Notebooks Persistent Storage on SPCS”** feature is explicitly built on **SPCS block storage + snapshots** (“Warm storage: stored in Block Storage”).  

### 2. Where do Workspace / Git‑backed files live?

The **Workspace files themselves** (including `.ipynb`, `.py`, config, etc.) live in the **Workspaces file backend (FBE)**, not on the SPCS volume:

- In the notebook container, these are mounted under `/filesystem/<hash>` with symlinks under `/workspace/WS_NAME` (or similar).  
- Those paths are **synced two‑way with the Workspace UI** (with some staged limitations / roadmap notes about write‑back behavior).  

For **Git‑backed Workspaces specifically**:

- Git integration operates on the **Workspace tree**, not on the SPCS `pd0` volume:
  - Notebooks are just files in the Workspace; Git pull/push tracks those files and respects `.gitignore` (with some known issues).  
  - Anything you write into `PERSISTENT_DIR` / `pd0` is **not part of the Git working tree**.

### 3. Effective mental model

For a Workspace Notebook (Git‑backed or not), think of two separate storage layers:

1. **Workspace storage (FBE + optional Git)**  
   - Source of truth for **notebook and project files**  
   - Visible in Snowsight’s Workspace file browser  
   - Git‑backed → synced to your remote repo

2. **Notebook persistent FS on SPCS block volume**  
   - Per‑notebook (per‑service) **persistent filesystem** for:
     - Large artifacts (models, checkpoints, logs)  
     - Installed packages  
   - Access via `PERSISTENT_DIR` / `pd0` paths in the container  
   - Not synced to Workspace or Git

So: **Workspace Notebooks’ persistent filesystem is backed by SPCS block storage volumes; Git‑backed Workspaces affect the Workspace file tree, not the SPCS volume.**
