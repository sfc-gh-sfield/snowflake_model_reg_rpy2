Here’s what we know today, mapped to your specific questions.

---

### 1\. How a Scala Spark Connect client talks to Snowpark Connect

**Managed service endpoint**

Snowpark Connect exposes a Spark Connect gRPC endpoint per account at a Snowflake‑managed host, e.g.:

- `sc://{account_locator}.snowpark.{shard}.snowflakecomputing.com:443/...`citation\_16:117-124  
- Earlier design docs also describe the public endpoint as `sc://{account-uri}:15002` over TLScitation\_19:91-93,citation\_19:101-103.

Connect is **language‑agnostic** at the protocol level: any Spark 3.5+ Spark Connect client (Scala, Java, Python, etc.) can call `SparkSession.builder().remote(scUrl).getOrCreate()` and talk directly to this endpoint.citation\_19:12-15,citation\_19:83-92

**No Python proxy required in principle**

Architecturally, the intended flow is:

1. **Vanilla Spark Connect client (Scala/Java/Python)** sends logical plans over gRPC to the Snowpark Connect endpoint.citation\_19:83-92  
2. The **Spark Connect Endpoint** (on Apps Cluster) terminates gRPC and translates to Snowflake REST, including auth, then hands off to the Dataframe Frontend / Dataframe Processor (TCM) that ultimately runs on the warehouse.citation\_19:69-75,citation\_19:110-118,citation\_19:136-145

In other words, **a Scala Spark Connect client can connect directly to the managed endpoint**; a local Python-based server is *not* a fundamental requirement.

The **Python “Snowpark Connect Client”** package (`snowpark-connect-client`) *does* start a small Spark Connect server locally (e.g. on `localhost:15002`) and then uses a Snowpark session to talk to Snowflake, but that’s an optional convenience for Python environments, not the only path.citation\_17:49-57,citation\_17:63-72,citation\_18:10-18,citation\_18:26-29

For a Scala client running inside an SPCS container, the “clean” design is:

```
val pat = sys.env("SNOWFLAKE_PAT")          // PAT you provision
val account = "<account_locator>"
val shard = "<shard_from_SYSTEM$ALLOWLIST>"
val urlSafeToken = java.net.URLEncoder.encode(pat, "UTF-8")
val scUrl =
  s"sc://$account.snowpark.$shard.snowflakecomputing.com:443/;token=$urlSafeToken;token_type=PAT"

val spark = org.apache.spark.sql.SparkSession
  .builder()
  .remote(scUrl)
  .getOrCreate()
```

That’s exactly the same pattern as the PySpark example, just in Scala.citation\_16:117-124

---

### 2\. Local Spark Connect server inside SPCS / Workspace

The Python APIs you mention are real:

- OSS/dev: `snowflake.snowpark_connect.start_session(remote_url="sc://localhost:15002")` starts a local Spark Connect server that listens on that URL and talks to Snowflake using your configured Snowflake session/connection.toml.citation\_17:49-57,citation\_17:63-72  
- Packaged client: `snowflake.snowpark_connect.client.start_session(...)` is a thin wrapper that starts the same kind of local server off a Snowpark `Session` (or connection parameters).citation\_18:6-8,citation\_18:10-13,citation\_18:26-29

From an SPCS/Workspace perspective:

- The container is just Linux; you *can* open a local gRPC listener on `127.0.0.1:15002` from Python.  
- A Scala Spark Connect client running in the **same container** (e.g. via JPype/JNI or a separate `java` process) can happily connect to `sc://localhost:15002`.

So **yes, starting a local Spark Connect server inside an SPCS container works in principle**. It’s the same mechanism we use in various internal dev flows; there’s nothing SPCS‑specific in the library.citation\_17:49-57,citation\_18:10-23

However:

- It’s not the **primary, documented “Workspace Notebooks” story** today; that story focuses on PySpark clients via `snowpark_connect` and/or direct PAT‑based remote endpoints.citation\_16:88-107,citation\_23:12-17  
- Using a local proxy is effectively an **experimental pattern** if you want Scala in Workspace: it will work, but you’re stitching it together yourself.

If your goal is to *reuse the Notebook’s Snowpark/SCPS auth* without issuing a PAT, the sidecar-server pattern is the only way today to have Scala “ride along” on the blessed Snowpark auth path.

---

### 3\. Authentication options for Scala Spark Connect clients

There are three relevant auth surfaces:

#### 3.1 PAT in the remote URL (recommended for external / SPCS clients)

The user guide’s Jupyter example connects to the managed service like this:citation\_16:117-124

```py
from pyspark.sql import SparkSession

pat_token = "<programmatic access token>"
sc_url = f"sc://{account_locator}.snowpark.{shard}.snowflakecomputing.com:443/;token={pat_token};token_type=PAT"
spark = SparkSession.builder.remote(sc_url).getOrCreate()
```

Key points:

- `token=<PAT>` and `token_type=PAT` are part of the **Spark Connect remote URL**.  
- The host `...snowpark.{shard}.snowflakecomputing.com:443` is the managed endpoint; `{shard}` is discoverable via `SYSTEM$ALLOWLIST`.citation\_16:119-121

This is fully compatible with **Scala** Spark Connect clients, since the URL and protocol are the same.

For a Scala client inside an SPCS Notebook container, this is the **supported way** to talk directly to the managed endpoint: treat the container as an external client, use PAT to the public Snowpark Connect host.

#### 3.2 Snowflake credentials via Spark session configs

The architecture design also supports sending Snowflake credentials as Spark session configs with `snowflake.connection.*` keys, e.g.:citation\_19:83-95,citation\_19:324-337

- `snowflake.connection.account`  
- `snowflake.connection.user`  
- `snowflake.connection.password` (plus MFA variants)  
- `snowflake.connection.warehouse`, `database`, `schema`  
- Optional `snowflake.connection.sessionParameters`, PrivateLink settings, etc.

These are transmitted as Spark session configs in any Spark Connect client (Scala/Java/Python), and the Snowpark Connect endpoint turns them into a normal Snowflake REST login (supporting **password** and **OAuth** auth flows).citation\_19:121-125,citation\_19:275-288

In Scala you’d set them with:

```
val spark = SparkSession.builder()
  .remote(scUrl)                                     // sc://{account-uri}:15002 or Snowpark host
  .config("snowflake.connection.account", "...")
  .config("snowflake.connection.user", "...")
  .config("snowflake.connection.password", "...")
  .config("snowflake.connection.warehouse", "...")
  .config("snowflake.connection.database", "...")
  .config("snowflake.connection.schema", "...")
  .getOrCreate()
```

In practice, for *non‑SPCS* environments this is a valid alternative to PAT‑in‑URL; for SPCS, see 3.3.

#### 3.3 `/snowflake/session/token` (SPCS internal) — *not* usable by generic Scala clients

For SPCS/Workspace, there is a **special internal token file** at `/snowflake/session/token`, but:

- It is accepted only by a small set of “blessed” clients (Snowpark, some official connectors).citation\_31:0-3  
- Generic ODBC/JDBC/ADBC‑style clients *cannot* just point their OAuth/token config at this file; the platform rejects it for internal connections.citation\_31:12-16

That same restriction applies conceptually to **raw Scala Spark Connect clients** running inside the container:

- There is **no supported way today** to have a Scala Spark Connect client read `/snowflake/session/token` and present it directly to the managed Snowpark Connect endpoint as an internal auth token.  
- From the platform’s perspective, a Scala Connect client in SPCS is just another external client unless it’s wrapped by a blessed library.

So for Scala Connect in Workspace:

- **PAT in the connect URL** is the clean, supported route.  
- If you don’t want PAT, your alternative is the **local Python proxy server** pattern (Section 2), which uses Snowpark to consume `/snowflake/session/token` and then exposes a local Spark Connect gRPC endpoint on `localhost`.

---

### 4\. Undocumented ways to pass creds in the remote URL

Two patterns exist:

1. **PAT in URL** (documented, supported for customers):  
   `sc://...snowpark...:443/;token=<PAT>;token_type=PAT`citation\_16:117-124  
   This is what you should assume for any external Scala Spark Connect client, including those running inside SPCS.  
     
2. **Session token from `snowflake-connector-python` in URL** (internal TCM path):  
   The SAS README shows a TCM example: get a Snowflake REST token from the Python connector and then:citation\_17:153-155

```py
token = conn.rest.token
url_safe_token = urllib.parse.quote(token, safe="")
spark = SparkSession.builder.remote(
    f"sc://{ACCOUNT}.{SPARK_CONNECT_HOST}/;token={url_safe_token}"
).getOrCreate()
```

   This is an **internal integration pattern** used when the client is already a Snowflake‑aware Python process (TCM / Snowpark). It is *not* documented as a supported mechanism for arbitrary external Scala clients.

Net: for your Scala evaluation, **assume PAT‑in‑URL is the only supported “creds in remote URL” option** against the managed Snowpark Connect service.

---

### 5\. Scala Spark Connect roadmap / status

We need to separate:

- **Snowpark Connect product (PySpark)** vs.  
- **Scala/Java clients for Snowpark Connect.**

Current status from internal sources:

- **Snowpark Connect for Apache Spark (overall feature) is GA** as of late 2025 (launch review “Snowpark Connect for Spark (GA)” completed, 2025‑09‑30).citation\_12:6-7  
- Scala‑specific guidance in the FAQ explicitly says:  
  “Customers who are on Scala Spark – our Scala Spark support is in preview so if the migration is time‑sensitive consider using Snowpark \[native\].”citation\_23:similar\_results  
- There is a dedicated PLT epic **“SCOS – Scala/Java client”** with:  
  - `currentavailability = Private Preview`  
  - `targetavailability = Public Preview`  
  - Status: Not Started as of 2026‑02‑05.citation\_21:13-14,citation\_21:40-44

So, as of now:

- **Core Snowpark Connect is GA**, but:  
- **First‑class Scala/Java client support is still in Private Preview, heading to Public Preview; there is no committed GA date in the trackers yet.**citation\_21:13-14,citation\_21:40-44

Practically, that means:

- Scala Spark Connect clients *can* technically talk to the endpoint (it’s just Spark Connect), but:  
  - API coverage, error mapping, and docs for Scala are **not yet at GA polish**.  
  - If you rely on this path in Workspace, you’re squarely in **preview / best‑effort** territory.

---

### 6\. Relevant internal docs / threads for deeper dives

If you want to go deeper on architecture and DevEx for Scala & SPCS:

- **Architecture / Auth / Endpoint design**  
  - *Snowflake Accelerated Spark Architecture* — core RFC covering endpoint location, Spark Connect client behavior (Scala/Java/Python/etc.), auth via `snowflake.connection.*` configs, and how the gRPC endpoint maps to REST \+ TCM.citation\_19  
- **Usage & examples**  
  - *Snowpark Connect for Apache Spark – User Guide* — user‑facing docs including:  
    - PAT‑in‑URL connect pattern.citation\_16:117-124  
    - Snowflake Notebook / Workspace‑style flows using `snowpark_connect`.citation\_16:88-107,citation\_16:592-602  
    - snowpark‑submit options for Scala JARs on SPCS.citation\_16:877-883,citation\_16:968-975  
  - *SAS GitHub README* — dev‑oriented details on:  
    - Running a local Snowpark Connect server on `localhost:15002`.citation\_17:49-57,citation\_17:63-72  
    - TCM example with session token in URL.citation\_17:153-155  
- **Client‑side Python proxy**  
  - *Snowpark Connect Client (packaging/snowpark-connect-client/README.md)* — describes `start_session` / `get_session` APIs and parameters (including `remote_url`, `tcp_port`, `unix_domain_socket`).citation\_18:6-8,citation\_18:10-24  
- **DevEx / Notebooks / SPCS integration**  
  - *Snowpark Project Objects \[Tabbed\]* — discussion of how Spark Connect / Classic jobs fit into Workspace/Notebooks and SPCS, including that Notebook Python runtimes are SPCS‑only and external code needs to be orchestrated around that.citation\_6:1-5,citation\_6:17-20  
  - *Snowpark/Spark DevEx Team* — backlog and Q1 planning doc with Snowpark Connect DevEx work, doc rewrites for Workspaces, and links to other SCOS UX audits.citation\_13:7-13,18-22  
- **Scala‑specific roadmap / chatter**  
  - *feat-accelerated-spark* Slack thread around Scala 2.13 and Scala Spark Connect demand (Royal Bank of Canada, SBB, etc.), with repeated confirmation that Scala 2.13 and Scala Spark support are in preview and being prioritized but not yet GA.citation\_30:10-12,citation\_30:23-27

---

### 7\. Implications for your Workspace Scala options

Given all of the above, for **Scala in Workspace Notebooks** today:

- **Snowpark Scala via JPype/JNI** (your current prototype):  
    
  - Uses the GA Snowpark Java/Scala client once Scala 2.13 support lands; that path is being brought to GA separately.citation\_20:52-60,citation\_22:28-36  
  - Auth still has the same SPCS constraints: generic clients don’t get to use `/snowflake/session/token` directly; you’ll need PAT/OAuth to the public endpoint, or route through an internal Snowpark session in Python (similar shape to your existing R/ODBC notes).citation\_31:0-6,citation\_31:14-16


- **Scala \+ Spark Connect options:**  
    
  1. **Direct Scala Spark Connect → Snowpark endpoint**  
     - Treat the container as an external client.  
     - Use PAT‑in‑URL (or session configs) against `...snowpark.{shard}.snowflakecomputing.com:443`.  
     - This aligns with the GA Snowpark Connect product, but Scala coverage is still preview‑level.  
  2. **Local Python “Snowpark Connect Client” server \+ Scala client on localhost**  
     - Start `snowpark-connect-client` inside the Notebook (or a companion Python process) to consume Snowpark/Workspace auth and expose `sc://localhost:15002`.  
     - Point a Scala Spark Connect client at `sc://localhost:15002`.  
     - This avoids PAT but is not yet a documented, supported “Workspace Scala” story; it’s best treated as an internal prototype pattern.

Given the current **preview status of Scala Spark Connect** and the SPCS auth model, your existing JPype/JNI Snowpark‑Scala path is still the **more controlled and supportable option** for serious Workspace work right now. Snowpark Connect becomes compelling for Scala in Workspace once:

- Scala/Java client epic (PLT‑52340) moves beyond Private Preview, and  
- We have a first‑class, documented story for Scala clients in SPCS (either via PAT or an official sidecar pattern).

