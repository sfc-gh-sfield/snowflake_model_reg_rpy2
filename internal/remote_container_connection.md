> Is it possible to use a remote IDE (VSCode for example) to connect and work in an ML container runtime?  Rather than having to use the Workspace Notebook, that is currently not on the same merged runtime/container image.  I'm sure I read some documentation on this somewhere. I may still be in preview.  I'm interested in installing R (via MicroMamba) and being able to connect and use etierh Posit/RStudio, or VSCode to remotely run R in the container

Yes – this is exactly what **Container Runtime Remote Dev** is for, and it runs on the **ML Container Runtime image** rather than the Workspace Notebook image.

### 1. Remote IDE → ML Container Runtime

Snowflake has a *remote development* mode where:

- A **Container Runtime instance** is started as a Snowpark Container Services service over a compute pool.  
- You connect from a **local IDE (VS Code / Cursor) over SSH** to that service.  
- Your home directory is backed by a **stage**, so code and settings persist across sessions.  

From the onboarding guide:

> “Container Runtime Remote Dev is a remote execution service that runs inside Snowpark Container Services executing a **Container Runtime image**… develop locally (VSCode or Cursor) and execute directly in the Container Runtime ecosystem… connect your local VS Code/Cursor to a Container Runtime instance (via SSH).”

It’s currently **in private preview**, with PuPr targeted around Feb 2026 according to the ML Slack threads.

The doc you’re remembering is:

- **`[Onboarding Guide] Container Runtime Remote Dev`** (ML_Benchmarking folder / shared in `#feat-snowflake-ml`).  

At a high level you:

1. Install the **SnowCLI remote_dev branch** + `websocat`.  
2. Ensure you have a **compute pool** + any needed **External Access Integrations** (for pip/conda, VS Code extensions, HF, etc.).  
3. Start a remote dev service, e.g.:

   ```bash
   snow remote start \
     my_remote_dev \
     --compute-pool YOUR_COMPUTE_POOL \
     --eai-name EAI_IDE_BOOTSTRAP \
     --stage YOUR_SSE_STAGE \
     --ssh
   ```
   

4. In **VS Code**, install *Remote-SSH* and connect to the generated SSH host (`SNOW_REMOTE_ADMIN_MY_REMOTE_DEV`), then open `/root/user-default` as your working folder.

That gives you a **pure ML Container Runtime** environment, independent of Workspace Notebooks.

---

### 2. Running R in that remote ML container (via micromamba)

Inside that remote dev container you can use the same pattern you’ve already documented for Workspace Notebooks:

- Use **micromamba / conda in user space** to install:
  - `r-base` and R packages.
  - Any extra system libs you need (e.g. `libz`, `liblzma`) into the env and fix up symlinks as needed.  

Your “Workspace Notebooks R & ADBC Setup” and “Using ODBC with Snowflake in Workspace Notebooks” docs explicitly recommend this pattern for Notebook containers; the same constraints apply in ML Container Runtime because it’s also SPCS-based and you don’t own the Dockerfile.

**Caveat on connectivity from R** (same as in your docs):

- The internal SPCS OAuth token in `/snowflake/session/token` is **not accepted** by generic clients like ODBC/ADBC today; only “blessed” clients (Snowpark, etc.) can use it.  
- So from R inside the ML container, you either:
  - Treat R as an **external client** hitting the public endpoint using OAuth / PAT, or  
  - Use **Python Snowpark** inside the container as the Snowflake client, and bridge to R via **rpy2** (your current recommended pattern for Notebook containers).

Functionally: yes, you can be in VS Code, connected to ML Container Runtime Remote Dev, and run R via micromamba in that same container.

---

### 3. Posit / RStudio vs VS Code

**VS Code / Cursor**

- Fully in scope for **Container Runtime Remote Dev** today:
  - Local VS Code / Cursor over SSH.  
  - Or a **web-hosted VS Code** served entirely from within Snowflake, if you prefer a browser IDE.

This is the most straightforward way to get “R in ML container runtime with a remote IDE” right now: install R with micromamba in the remote dev container and use the VS Code R tooling on top.

**Posit / RStudio**

For a true **RStudio/Posit** experience today, the documented, supportable pattern is still:

- Build a **custom SPCS service** image that includes:
  - R, Snowflake ODBC/ADBC, dbplyr, etc.
  - **RStudio Server** (or JupyterLab) as the web IDE.  
- Deploy it as an SPCS service with an HTTPS endpoint, and connect via browser.  

You’ve already done exactly this for “OSS R Tooling in Snowflake Container Services” with RStudio Server + JupyterLab, ODBC, Snowpark Python and Scala.

**Bringing RStudio directly into ML Container Runtime** (as the same runtime image used for notebooks / jobs) depends on the **Custom ML Runtime Images** / “Container Runtime Environments” work that is in design / in-flight (PGAP-1236). That’s the path to having blessed custom images (e.g. “CR + R + RStudio”) surfaced natively to notebooks, jobs, and presumably remote dev—but it’s not GA yet.

---

### 4. TL;DR for your specific question

- **Is it possible to use a remote IDE (VS Code) on ML Container Runtime instead of Workspace Notebooks?**  
  Yes – via **Container Runtime Remote Dev** (SnowCLI `snow remote start ... --ssh` + VS Code Remote-SSH). It runs on the **ML Container Runtime image** and is currently **PrPr**, moving towards PuPr.

- **Can you install R in that container and use VS Code to drive it?**  
  Yes – use **micromamba** inside the remote dev container to install `r-base` and your R stack, just as you’ve done in Workspace Notebooks; then use VS Code as the front-end. Connectivity from R to Snowflake follows the same constraints you documented (external OAuth/PAT or Snowpark+`rpy2` bridge).

- **Can you do the same with Posit/RStudio?**  
  Today the *clean* way is still a **dedicated SPCS RStudio Server service** (your OSS R Tooling container), not the managed ML Container Runtime. First-class “custom ML runtime images” that could bake RStudio into the ML runtime itself are in progress but not yet fully productized.

> How can I get access to the preview functionality, or does anyone in Snowflake have it already

  You (and other Snowflakes) can already use it; there’s nothing to “turn on” in the account today.

### 1. Access model right now

From the ML Slack threads and the onboarding guide:

- **Remote Dev is PrPr**, but:
  - **There is no server-side feature flag** – it’s built on top of existing **Container Runtime + SPCS + compute pools**.  
  - Field folks have been **demoing it in SE demo accounts** with no backend enablement, just by using the special SnowCLI build and following the guide.

Caleb on `#feat-snowflake-ml` when asked “can I demo this?”:

> “yes you can demo it in your SE demo account, nothing needs to be enabled on the account just follow the instructions here …”

Vinay, later:

> “Yes nothing to enable. Customer can follow the instructions.”

So: as long as you have **ML Container Runtime + compute pool + EAI** in the account, you can use Remote Dev. The “preview” aspect is mostly:

- You must use the **remote_dev branch of SnowCLI**.  
- You’re expected to coordinate with the ML runtime team so they can track feedback / issues.

---

### 2. How *you* can start using it

For you personally:

1. **Use the onboarding guide you already have**  
   - `[Onboarding Guide] Container Runtime Remote Dev` in your **ML_Benchmarking** folder, and the copy shared into `#feat-snowflake-ml`.  

2. **Install the PrPr SnowCLI + dependencies** (per the guide):

   - Clone SnowCLI and check out the **`remote_dev_prpr`** branch, then install with `hatch`.  
   - Configure a `snow` connection in `~/.snowflake/config.toml` if you haven’t already.  
   - Install **`websocat`** locally for VS Code integration.  

3. **Ensure infra in the target account:**

   - A **compute pool** suitable for Container Runtime.  
   - At least one **External Access Integration** that allows:
     - VS Code / Cursor remote extensions and  
     - any Python/R/ML package repos you want (PyPI, conda-forge, CRAN mirrors, HF, etc.).  

4. **Start a remote dev service:**

   ```bash
   snow remote start \
     my_remote_dev \
     --compute-pool YOUR_COMPUTE_POOL \
     --eai-name EAI_IDE_BOOTSTRAP \
     --stage YOUR_SSE_STAGE \
     --ssh
   ```
   This stands up a **Container Runtime instance + Ray** with a mounted stage and SSH enabled.

5. **Connect from VS Code:**

   - Install **Remote-SSH** or Remote Development pack.  
   - Use “Remote-SSH: Connect to Host” and pick the generated host (`SNOW_REMOTE_ADMIN_MY_REMOTE_DEV`).  
   - Open `/root/user-default` as your working folder (persists via the stage).  

Once you’re in, you can follow the same micromamba→R pattern you’ve already validated for Notebook containers, but now in this ML container runtime.

---

### 3. Who already has it / who to coordinate with

**People / teams actively using or owning it:**

- **PM / “owner”:** **Vinay Sridhar** (ML Container Runtime & Remote Dev).  
- **Eng leads / close collaborators:** Haowei Lu, Yavor Georgiev, Shulin Chen, etc. (per ML runtime + jobs docs and Slack threads).  
- **Field users already hands-on:**  
  - **Marcel Castro**, **Kaitlyn Wells**, and a handful of SEs working with customers like Sparebank 1, Tools for Humanity, etc., have been demoing/using Remote Dev from VS Code.

There is also a **customer / internal tracker sheet** for “VSCode Container Runtime” that Vinay maintains:

- `18LBRspawZ2OoU85vZdiz_RsWRgVPXMOaZUCPeQ19sCA` (linked in Slack by Vinay).

**Practically:**  

- To be “on the radar” as a preview user and to get support:
  - DM / tag **Vinay Sridhar** and **Haowei Lu** in `#feat-snowflake-ml` referencing the Remote Dev onboarding guide.  
  - Optionally ask Vinay to add you to the tracker sheet and any PGAP/customer lists relevant to ML Remote Dev.

From there you can:

- Start using it immediately in your **SnowCAT / ML benchmarking accounts** following your own onboarding guide.
- Coordinate with Vinay/Haowei if you want to pull a specific customer into the PrPr / PuPr program.

Would you like a concise, account-specific checklist to get you started with Remote Dev?