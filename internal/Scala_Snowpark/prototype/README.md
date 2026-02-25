# Scala & Java / Snowpark Prototype for Workspace Notebooks

**Status:** Prototype / Proof of Concept — **Working** in Snowflake Workspace Notebooks
**Date:** February 2026
**See also:** `../FEASIBILITY.md`, `../OPTION_A_JPYPE_DEEP_DIVE.md`

---

## Overview

This prototype enables **Scala execution**, **Java execution**,
**Snowpark Scala**, **Snowpark Java**, and **Snowpark Connect for Scala**
within Snowflake Workspace Notebooks using `%%scala` / `%%java` cell magics
powered by JPype. It follows the same architectural pattern as the R/rpy2
integration:

| Layer | R Solution | Scala / Java Solution (this prototype) |
|-------|-----------|-------------------------------|
| Runtime | R via micromamba | OpenJDK 17 + Scala 2.12 via micromamba |
| Bridge | rpy2 (embeds R in Python) | JPype1 (embeds JVM in Python via JNI) |
| Magic | `%%R` from rpy2 | `%%scala` / `%%java` (custom, in `scala_helpers.py`) |
| REPL | R interpreter | Scala IMain (Ammonite-lite) + JShell (Java) |
| Auth | ADBC + PAT | Snowpark Scala/Java + **SPCS OAuth token** |
| Spark Connect | N/A | Snowpark Connect gRPC proxy (opt-in) |

**Three languages, one notebook:** Both `%%scala` and `%%java` magics share
the same in-process JVM, classpath, and credential injection. When Spark
Connect is enabled, users additionally get `spark.sql(...)` in `%%scala` cells.

---

## File Structure

```
prototype/
├── README.md                              # This file
├── scala_packages.yaml                    # Version configuration
├── setup_scala_environment.sh             # Installation script
├── scala_helpers.py                       # Python helper module (Scala + Java)
├── workspace_scala_quickstart.ipynb       # Scala example notebook
└── workspace_java_quickstart.ipynb        # Java example notebook
```

---

## Quick Start

### 1. Upload files to Workspace Notebook

Upload all files in this directory to your Workspace Notebook's working
directory (alongside your `.ipynb` file).

### 2. Run the setup script

```python
!bash setup_scala_environment.sh
```

This installs (~30s, or ~2-4 minutes on first cold start):
- **micromamba** (if not already present from R setup)
- **OpenJDK 17** via micromamba (~174MB, largest single download)
- **coursier JAR launcher** (JVM dependency resolver, JAR-based to avoid GraalVM native image issues)
- **Scala 2.12** compiler JARs via coursier
- **Ammonite** REPL JARs via coursier
- **Snowpark 1.18.0** + all transitive dependencies via coursier
- **slf4j-nop** (silences SLF4J 1.x binding warning from Ammonite)
- **JPype1** into the kernel's Python venv
- **(If Spark Connect enabled):** `snowpark-connect[jdk]`, `pyspark`, `opentelemetry-exporter-otlp`, Spark Connect client JARs

### 3. Initialize and use %%scala

```python
from scala_helpers import setup_scala_environment
result = setup_scala_environment()
```

```python
%%scala
println("Hello from Scala!")
val x = (1 to 10).sum
println(s"Sum 1..10 = $x")
```

Single-line Scala is also supported:

```python
%scala println(s"Quick: ${1 + 1}")
```

### 3b. Use %%java (available alongside %%scala)

The same `setup_scala_environment()` call also initializes JShell (JDK 17's
built-in Java REPL) and registers `%%java` / `%java` magics:

```python
%%java
System.out.println("Hello from Java " + System.getProperty("java.version"));
```

```python
%java System.out.println("2 + 2 = " + (2 + 2));
```

Both `%%scala` and `%%java` share the same JVM, classpath, and System
properties. No extra installation is needed — JShell ships with JDK 17.

### 4. Connect to Snowflake

Inside a Workspace Notebook, the SPCS OAuth token at
`/snowflake/session/token` is detected automatically — **no PAT needed**.

```python
from snowflake.snowpark.context import get_active_session
from scala_helpers import inject_session_credentials

session = get_active_session()
inject_session_credentials(session)
```

```python
%%scala
import com.snowflake.snowpark._

def prop(k: String): String = {
  val v = System.getProperty(k)
  require(v != null, s"System property '$k' not set.")
  v
}

val sfSession = Session.builder.configs(Map(
  "URL"           -> prop("SNOWFLAKE_URL"),
  "USER"          -> prop("SNOWFLAKE_USER"),
  "ROLE"          -> prop("SNOWFLAKE_ROLE"),
  "DB"            -> prop("SNOWFLAKE_DATABASE"),
  "SCHEMA"        -> prop("SNOWFLAKE_SCHEMA"),
  "WAREHOUSE"     -> prop("SNOWFLAKE_WAREHOUSE"),
  "TOKEN"         -> prop("SNOWFLAKE_TOKEN"),
  "AUTHENTICATOR" -> prop("SNOWFLAKE_AUTH_TYPE")
)).create

sfSession.sql("SELECT CURRENT_USER(), CURRENT_ROLE()").show()
```

For **Snowpark Java**, the pattern is similar:

```python
%%java
import com.snowflake.snowpark_java.*;
import java.util.HashMap;
import java.util.Map;

Map<String, String> props = new HashMap<>();
props.put("URL",       System.getProperty("SNOWFLAKE_URL"));
props.put("USER",      System.getProperty("SNOWFLAKE_USER"));
props.put("ROLE",      System.getProperty("SNOWFLAKE_ROLE"));
props.put("DB",        System.getProperty("SNOWFLAKE_DATABASE"));
props.put("SCHEMA",    System.getProperty("SNOWFLAKE_SCHEMA"));
props.put("WAREHOUSE", System.getProperty("SNOWFLAKE_WAREHOUSE"));
props.put("TOKEN",     System.getProperty("SNOWFLAKE_TOKEN"));
props.put("AUTHENTICATOR", System.getProperty("SNOWFLAKE_AUTH_TYPE"));

Session javaSession = Session.builder().configs(props).create();
javaSession.sql("SELECT CURRENT_USER(), CURRENT_ROLE()").show();
```

---

## Magic Flags

### %%scala flags

The `%%scala` cell magic supports flags modelled on rpy2's `%%R`:

| Flag | Description | Example |
|------|-------------|---------|
| `-i var1,var2` | Push Python variables into Scala (auto-detect DF type) | `%%scala -i name,count` |
| `-i:spark var` | Force push as Spark DataFrame (cross-API for Snowpark DFs) | `%%scala -i:spark py_df` |
| `-i:snowpark var` | Force push as Snowpark DataFrame (default for Snowpark DFs) | `%%scala -i:snowpark py_df` |
| `-o var1,var2` | Pull Scala variables into Python (auto-detect DF type) | `%%scala -o result` |
| `-o:spark var` | Force pull as PySpark DataFrame | `%%scala -o:spark result` |
| `-o:snowpark var` | Force pull as Snowpark Python DataFrame (cross-API for Spark DFs) | `%%scala -o:snowpark result` |
| `--silent` | Suppress REPL variable-binding echo | `%%scala --silent` |
| `--time` | Print wall-clock execution time | `%%scala --time` |

DataFrames passed via `-i` / `-o` are **auto-detected** — both Snowpark
and PySpark DataFrames are handled automatically. See
[DataFrame Interop](#dataframe-interop).

**Type hints** (`-i:spark`, `-o:snowpark`) enable cross-API transfers between
Snowpark and Spark Connect DataFrames. Without a hint, same-API transfers are
used (Snowpark→Snowpark, PySpark→Spark).

Flags can be combined:

```python
count = 100
```

```python
%%scala -i count -o total --time
val total = (1 to count.asInstanceOf[Int]).sum
println(s"Sum = $total")
```

```python
print(f"total from Scala: {total}")
```

The `%scala` line magic executes a single Scala expression:

```python
%scala println("2 + 2 = " + (2 + 2))
```

**Caveat:** IPython expands `${expr}` in line magic arguments *before*
Scala sees them (e.g. `${2 + 2}` becomes `$4`). Use `$varName` (no braces)
or string concatenation for `%scala`. For `s"${...}"` interpolation, use
`%%scala` cells which pass the body through unmodified.

### %%java flags

The `%%java` cell magic supports the same flag syntax:

| Flag | Description | Example |
|------|-------------|---------|
| `-i var1,var2` | Push Python variables into Java (primitives, strings, Snowpark DFs) | `%%java -i name,count` |
| `-o var1,var2` | Pull Java variables into Python (primitives, strings, Snowpark DFs) | `%%java -o result` |
| `--silent` | Suppress output | `%%java --silent` |
| `--time` | Print wall-clock execution time | `%%java --time` |

**Snowpark Java DFs:** When `-i` receives a Snowpark Python DataFrame, it is
pushed into JShell as a `com.snowflake.snowpark_java.DataFrame` via SQL plan
transfer. When `-o` detects a Snowpark Java DataFrame, it is pulled back as a
Snowpark Python DataFrame via a temp view.

```python
py_df = session.table("customers")
```

```python
%%java -i py_df -o high_value --time
import com.snowflake.snowpark_java.Functions;
DataFrame high_value = py_df.filter(Functions.col("SPEND").gt(Functions.lit(1000)));
high_value.show();
```

```python
high_value.show()  # Snowpark Python DataFrame
```

---

## Authentication

### Inside Workspace Notebooks (SPCS)

Workspace Notebooks run inside SPCS containers. The container provides an
OAuth token at `/snowflake/session/token`. 

`inject_session_credentials()` detects this automatically and sets:
- `SNOWFLAKE_TOKEN` → contents of `/snowflake/session/token`
- `SNOWFLAKE_AUTH_TYPE` → `"oauth"`

These are set as **Java System properties** (not environment variables)
because Java's `System.getenv()` caches the process environment at JVM
startup, making `os.environ` changes invisible to Scala after
`jpype.startJVM()`. Scala reads them via `System.getProperty(key)`.

For the Scala/Java Snowpark path, no PAT creation step is needed — the
container's OAuth token is auto-detected and injected. (The R integration
uses PATs for ADBC authentication, which also works inside SPCS.)

### Outside Workspace (e.g. local Jupyter)

For external use, set a PAT in the environment before calling
`inject_session_credentials()`:

```python
import os
os.environ["SNOWFLAKE_PAT"] = "<your-pat-token>"
```

`inject_session_credentials()` falls back to `os.environ["SNOWFLAKE_PAT"]`
when the SPCS token file is not present.

---

## DataFrame Interop

The `-i` / `-o` flags auto-detect DataFrame types and pick the right
transfer strategy. Both **Snowpark** and **PySpark** DataFrames are
supported, plus cross-API transfers when Spark Connect is enabled.

### %%scala: Same-API Transfers (default)

| Direction | Source | Target | Mechanism |
|-----------|--------|--------|-----------|
| `-i` push | Snowpark Python DF | Snowpark Scala DF | SQL plan → `sfSession.sql()` |
| `-i` push | PySpark DF | Spark Scala DF | Temp view → `spark.table()` |
| `-o` pull | Snowpark Scala DF | Snowpark Python DF | SQL plan → `session.sql()` |
| `-o` pull | Spark Scala DF | PySpark DF | Temp view → `spark_py.table()` |

No data is copied for Snowpark transfers — only the SQL string crosses
the JPype bridge. PySpark transfers use Spark temp views (both Python and
Scala talk to the same Spark Connect server).

### %%java: Snowpark Java Transfers

| Direction | Source | Target | Mechanism |
|-----------|--------|--------|-----------|
| `-i` push | Snowpark Python DF | Snowpark Java DF | SQL plan → `javaSession.sql()` |
| `-o` pull | Snowpark Java DF | Snowpark Python DF | Temp view → `session.table()` |

The Java interop uses the same SQL plan transfer mechanism as Scala for
Snowpark DataFrames. The Java Snowpark API (`com.snowflake.snowpark_java.*`)
ships in the same JAR as the Scala API — no extra dependencies needed.

### Cross-API Transfers (type hints)

| Flag | Source | Target | Mechanism |
|------|--------|--------|-----------|
| `-i:spark` | Snowpark Python DF | Spark Scala DF | SQL plan → `spark.sql()` |
| `-o:snowpark` | Spark Scala DF | Snowpark Python DF | Materialise to transient table |

Cross-API works because the Spark Connect proxy forwards Snowflake SQL,
so the same query plan is valid in both `sfSession.sql()` and `spark.sql()`.

### Examples

**Snowpark interop (same-API):**

```python
py_df = session.table("customers")
```

```python
%%scala -i py_df -o high_value
val high_value = py_df.filter(col("SPEND") > 1000)
high_value.show()
```

```python
high_value.to_pandas()  # Snowpark Python DataFrame
```

**PySpark interop (same-API):**

```python
pyspark_df = spark_py.sql("SELECT * FROM my_table")
```

```python
%%scala -i pyspark_df -o result
val result = pyspark_df.filter(col("value") > 100)
```

```python
result.toPandas()  # PySpark DataFrame
```

**Cross-API (Snowpark → Spark → Snowpark):**

```python
snowpark_df = session.sql("SELECT * FROM sales")
```

```python
%%scala -i:spark snowpark_df -o:snowpark aggregated
import org.apache.spark.sql.functions._
val aggregated = snowpark_df.groupBy("region").agg(sum("revenue").as("total"))
```

```python
aggregated.show()  # Back as Snowpark Python DataFrame
```

### How it works

1. **Snowpark Python → Scala:** `_push_snowpark_df()` extracts the last SQL from
   `df.queries['queries']` and passes it through a Java System property
   (avoiding all string-escaping issues). Scala receives it via
   `sfSession.sql(System.getProperty(...))`.

2. **PySpark → Scala:** `_push_pyspark_df()` registers the PySpark DF as a temp
   view on the shared Spark Connect server, then reads it in Scala with
   `spark.table(view_name)`.

3. **Cross-API push (`-i:spark`):** `_push_snowpark_df_as_spark()` extracts the
   SQL plan from the Snowpark DF but passes it to `spark.sql()` instead of
   `sfSession.sql()`, "lifting" the DF into the Spark world.

4. **Snowpark Scala → Python:** `_pull_snowpark_df()` tries the Scala
   `DataFrame.queries` API first. If that isn't available, it falls back to
   `createOrReplaceView()` (non-temporary, tracked for cleanup).

5. **Spark Scala → Python:** `_pull_spark_df()` registers the Scala Spark DF as a
   temp view and reads it from the Python PySpark session.

6. **Cross-API pull (`-o:snowpark`):** `_pull_spark_df_as_snowpark()` materialises
   the Spark DF to a Snowflake transient table, then reads it from the Python
   Snowpark session.

7. **Cleanup:** Call `cleanup_interop_views()` at the end of the notebook to drop
   any interop views and transient tables.

---

## Cross-language Data Sharing (Tables)

For cases where SQL plan transfer isn't suitable (e.g. materialised results,
ad-hoc exploration), you can use tables directly.

The Python, Scala, and Java Snowpark sessions are **separate Snowflake
connections**. This has important implications:

| Table Type | Visible across sessions? | Use case |
|------------|:---:|---------|
| `TEMPORARY TABLE` | No (session-scoped) | Not suitable for cross-language sharing |
| `TRANSIENT TABLE` | Yes | Recommended for sharing, drop after use |
| Permanent `TABLE` | Yes | Persistent data, standard cleanup needed |

Use `TRANSIENT TABLE` for sharing data between Python, Scala, and Java,
and drop it when done to avoid accumulating objects.

---

## UDF and Stored Procedure Registration (Scala)

Snowpark Scala provides native APIs for registering UDFs and stored procedures.
The challenge in a REPL (notebook) context is that Snowpark must be able to find
the compiled class files for your lambda/closure when it serialises the UDF JAR
for upload to Snowflake.

The setup handles three things that the
[Snowpark Jupyter notebook docs](https://docs.snowflake.com/en/developer-guide/snowpark/scala/quickstart-jupyter)
require:

1. **`-Yrepl-class-based`** — IMain wraps REPL code in classes (not objects)
   so lambdas can be serialized
2. **`outputDirs.setSingleOutput(replClassDir)`** — compiled `.class` files go
   to a known directory
3. **`sfSession.addDependency(replClassDir)`** — Snowpark can find those
   classes when packaging the UDF JAR

Items 1 and 2 are configured automatically by `setup_scala_environment()`.
Item 3 (plus JDBC driver dependency) is done by `enable_udf_registration()`.

### Enabling UDF support

Call `enable_udf_registration()` once (after `bootstrap_snowpark_scala`) to wire
up the REPL class directory and required JARs:

```python
from scala_helpers import enable_udf_registration
success, msg = enable_udf_registration()
print(msg)
```

### Creating a temporary UDF (simple lambda)

Simple lambdas work for UDFs that don't reference variables from other cells:

```scala
%%scala
import com.snowflake.snowpark.functions.{col, udf}

val doubleIt = udf((x: Int) => x * 2)
sfSession.sql("SELECT 21 AS val").select(doubleIt(col("val")).as("doubled")).show()
```

### Creating a permanent UDF (Serializable class pattern)

For robust serialization in notebooks — especially when the UDF references
variables defined in other cells — wrap the function in a class that extends
`Serializable` ([recommended by the Snowpark docs](https://docs.snowflake.com/en/developer-guide/snowpark/scala/creating-udfs)):

```scala
%%scala
import com.snowflake.snowpark.functions.callUDF

class DoubleUDF extends Serializable {
  val func = (x: Int) => x * 2
}

sfSession.udf.registerPermanent(
  "double_it",
  (new DoubleUDF).func,
  "@~/scala_udfs"          // stage location for the UDF JAR
)

// Call by name
sfSession.sql("SELECT double_it(42) AS result").show()
```

## UDF and Stored Procedure Registration (Java)

JShell keeps compiled classes **in memory** (unlike Scala's IMain which writes
`.class` files to a configurable directory on disk).  This means Snowpark Java's
`registerTemporary` / `registerPermanent` lambda serialization won't work from
JShell — Snowpark can't locate the class files to package into a UDF JAR.

The solution is to use **SQL inline UDFs** via `javaSession.sql()`, which embeds
the Java handler code directly in the `CREATE FUNCTION` statement.  This avoids
the classpath/serialization problem entirely and works cleanly from JShell cells.

### Creating a temporary UDF (SQL inline handler)

```java
%%java
javaSession.sql(
    "CREATE OR REPLACE TEMPORARY FUNCTION java_double_it(x INT) " +
    "RETURNS INT " +
    "LANGUAGE JAVA " +
    "RUNTIME_VERSION = '17' " +
    "HANDLER = 'Handler.compute' " +
    "AS 'class Handler { " +
    "  public static int compute(int x) { return x * 2; } " +
    "}'"
).collect();

javaSession.sql("SELECT java_double_it(21) AS doubled").show();
```

### Creating a permanent UDF

```java
%%java
javaSession.sql(
    "CREATE OR REPLACE FUNCTION java_celsius_to_f(c DOUBLE) " +
    "RETURNS DOUBLE " +
    "LANGUAGE JAVA " +
    "RUNTIME_VERSION = '17' " +
    "HANDLER = 'Handler.compute' " +
    "AS 'class Handler { " +
    "  public static double compute(double c) { return c * 9.0 / 5.0 + 32.0; } " +
    "}'"
).collect();

javaSession.sql("SELECT java_celsius_to_f(100.0) AS fahrenheit").show();
```

> **Why not `registerTemporary()` / `registerPermanent()`?**
> These Snowpark Java methods serialize the lambda closure and need to find
> the enclosing class file on disk.  JShell compiles snippets to an in-memory
> classloader with no disk output, so Snowpark reports
> *"Unable to detect the location of the enclosing class"*.  The SQL inline
> approach bypasses this entirely — the handler source is sent directly to
> Snowflake's server-side Java runtime.
>
> **Note:** The Snowflake docs provide REPL/notebook UDF guidance
> [only for Scala](https://docs.snowflake.com/en/developer-guide/snowpark/scala/quickstart-jupyter)
> (IMain writes `.class` files to disk, which Snowpark can find).  There is
> no equivalent "Setting Up JShell for Snowpark Java" page — the
> [Java setup docs](https://docs.snowflake.com/en/developer-guide/snowpark/java/setup)
> only cover IntelliJ / Maven.  The SQL inline approach documented here is
> the workaround for this gap.

### Alternatives for managing UDFs/procedures

If you need more advanced lifecycle management (versioning, deployment
pipelines, CI/CD), consider these complementary tools:

| Tool | What it does | Installed in Workspace? |
|------|-------------|:---:|
| **Snowpark Native API** | `session.udf.register*` / `session.sproc.register*` | Yes (Snowpark Scala/Java JARs) |
| **Snowflake Python API** | `root.databases[...].functions.create(...)` across languages | Likely (ships with `snowflake-snowpark-python`) |
| **Snowflake CLI** (`snow snowpark`) | Build, deploy, and manage Snowpark functions/procedures from the command line | No (but could be installed) |

The **Snowpark Native API** (what `enable_udf_registration` enables) is the
simplest path for interactive notebook use.  The **Snowflake Python API**
(`snowflake.core`) can also create functions targeting any handler language
and is worth exploring for programmatic deployments from Python cells.
The **Snowflake CLI** is oriented toward CI/CD pipelines and project-based
workflows rather than interactive notebook use.

---

## Configuration

Edit `scala_packages.yaml` to change versions:

```yaml
java_version: "17"            # OpenJDK version (11 or 17)
scala_version: "2.12"         # Must match Snowpark artifact suffix
snowpark_version: "1.18.0"    # Snowpark Scala version
ammonite_version: "3.0.8"     # Ammonite REPL version

jvm_heap: "auto"              # "auto" = 25% of RAM (1-4GB), or e.g. "2g"
jvm_options:
  - "-Xms256m"
  - "--add-opens=java.base/java.nio=ALL-UNNAMED"   # Required for Arrow/Java 17

extra_dependencies:
  - "org.slf4j:slf4j-nop:1.7.36"   # Silences SLF4J 1.x StaticLoggerBinder warning
```

### Adding Extra Java/Scala Dependencies

To use additional Java or Scala libraries in your `%%scala` or `%%java` cells,
add their Maven coordinates to the `extra_dependencies` list in `scala_packages.yaml`:

```yaml
extra_dependencies:
  - "org.slf4j:slf4j-nop:1.7.36"
  - "com.google.guava:guava:33.0.0-jre"
  - "org.apache.commons:commons-math3:3.6.1"
```

Then re-run the setup script:

```python
!bash setup_scala_environment.sh
```

Coursier resolves each artifact and its transitive dependencies from Maven
Central and adds them to the JVM classpath. They become available in
`%%scala` and `%%java` cells after calling `setup_scala_environment()`.

**Format:** `"<groupId>:<artifactId>:<version>"` -- standard Maven
coordinates. You can find these on [Maven Central](https://search.maven.org/)
or the library's documentation.

**Important:** There is no runtime `import $ivy` support. All dependencies
must be declared in the YAML and resolved at install time, because the JVM
classpath is fixed once `jpype.startJVM()` is called. If you add dependencies
after the JVM has already started in the current session, you must restart
the container (not just the kernel) for the new JARs to take effect.

### JVM Heap Sizing

The `jvm_heap` setting controls the maximum JVM heap (`-Xmx`):

| Value | Behaviour |
|-------|-----------|
| `"auto"` (default) | Detect container memory via `/proc/meminfo`, allocate ~25% (clamped 1-4 GB) |
| `"2g"` | Fixed 2 GB heap |
| `"1536m"` | Fixed 1536 MB heap |

The JVM shares the process with Python, the Scala compiler, and Snowpark,
so 25% is a reasonable default. On your container with ~140 GB disk / large
memory, `auto` will likely select 4 GB (the configured cap).

---

## Spark Connect for Scala (Opt-in)

When `spark_connect.enabled: true` is set in `scala_packages.yaml`, the
prototype also sets up **Snowpark Connect for Scala**, providing a native
Spark SQL experience alongside Snowpark Scala.

### Architecture

```
%%scala cell
    │
    ├── sfSession.sql(...)  →  Snowpark Scala (direct JDBC to Snowflake)
    │
    └── spark.sql(...)      →  Spark Connect client (Scala)
                                   │ gRPC (localhost:15002)
                                   ▼
                              snowpark_connect server (Python)
                                   │ SPCS OAuth token
                                   ▼
                              Snowflake
```

### How It Works

1. **Single JVM:** Snowpark Scala, Snowpark Java, and the Spark Connect client
   all share the same in-process JVM. The JVM classpath includes Snowpark JARs
   (both Scala and Java APIs), Scala compiler, Ammonite, JShell, Spark Connect
   client JARs, and PySpark's bundled JARs (spark-sql, spark-catalyst, etc.).

2. **Python gRPC server:** `snowpark_connect` runs a local gRPC server
   (port 15002) that translates Spark Connect protocol messages into
   Snowpark Python operations, consuming the Workspace's SPCS OAuth token.

3. **JVM sharing challenge:** `snowpark_connect.start_session()` normally
   starts its own JVM and refuses to run when one is already active.
   We solve this by:
   - Starting **our** JVM first (with the full classpath)
   - Monkey-patching `spc.server.start_jvm` to be a no-op
   - The gRPC server then reuses the existing JVM

4. **Auth flow:** No additional credentials needed. The Python proxy
   consumes the same SPCS OAuth token used by Snowpark Python.

### Configuration

```yaml
spark_connect:
  enabled: true           # Set to true to enable
  pyspark_version: "3.5.6"
  server_port: 15002
```

### Usage

After `setup_scala_environment()` (which starts the Spark Connect server
automatically when enabled), run the setup function:

```python
from scala_helpers import setup_spark_connect
sc_result = setup_spark_connect()
```

Then use `spark` in `%%scala` cells:

```python
%%scala
spark.sql("SELECT 1 AS id, 'hello from Spark Connect' AS msg").show()
```

### Spark Connect Limitations

| Limitation | Details |
|------------|---------|
| `CURRENT_ROLE()` unsupported | Snowpark Connect error 4001; use `CURRENT_USER()` |
| `SHOW TABLES` unsupported | Use `INFORMATION_SCHEMA.TABLES` instead |
| Some system functions missing | Proxy translates Spark SQL to Snowpark; not all functions mapped |
| Adds ~30s install time | pip installs snowpark-connect, pyspark (~200MB) |
| Server startup ~5s | Local gRPC server takes a few seconds to become ready |

---

## Interpreter Modes

The prototype supports three REPL backends:

| Mode | Language | Description | Notes |
|------|----------|-------------|-------|
| **ammonite-lite** | Scala | IMain with Ammonite JARs pre-loaded (default) | Pre-loaded JARs only, no runtime `import $ivy` |
| **imain** | Scala | Raw Scala IMain (fallback) | Fallback if Ammonite resolution fails |
| **jshell** | Java | JDK 17 built-in JShell with `LocalExecutionControl` | Ships with JDK, no extra JARs |

The Scala and Java interpreters run side by side in the same JVM process.
JShell uses `LocalExecutionControl`, which means it executes code in the
same process (sharing System properties, classpath, and memory with the
Scala REPL and JPype).

Full Ammonite embedding (with runtime `import $ivy`) is a stretch goal.
The current "ammonite-lite" mode pre-loads all JARs at JVM startup and
uses IMain for code evaluation, giving access to Ammonite classes but not
Ammonite's interactive features like dynamic dependency resolution.

---

## Licensing

All components are open-source with permissive or standard licenses:

| Component | License | Notes |
|-----------|---------|-------|
| micromamba | BSD-3-Clause | Permissive |
| OpenJDK 17 | GPL v2 + Classpath Exception | Classpath Exception allows unrestricted use |
| JPype1 | Apache 2.0 | Permissive |
| coursier | Apache 2.0 | Permissive, build-time only |
| Scala | Apache 2.0 | Permissive |
| Ammonite | MIT | Permissive |
| Snowpark Scala | Apache 2.0 | Snowflake's open-source SDK |
| SLF4J | MIT | Included transitively via Snowpark |
| Snowpark Connect | Snowflake proprietary | Snowflake's Spark Connect proxy |
| PySpark | Apache 2.0 | Spark Connect client + bundled JARs |

---

## Key Learnings

Issues discovered and resolved during prototype development:

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| `System.getenv()` invisible to Scala | Java caches env vars at JVM startup | Use `System.setProperty()` for credentials instead of `os.environ` |
| PAT rejected inside Workspace | SPCS containers require OAuth only | Auto-detect `/snowflake/session/token` and use `oauth` authenticator |
| `MemoryUtil` init failure (Arrow) | Java 17 module system blocks reflective access | Add `--add-opens=java.base/java.nio=ALL-UNNAMED` to JVM options |
| SLF4J binding warning | Ammonite brings SLF4J 1.x API; Snowpark's 2.x binding doesn't satisfy 1.x lookup | Add `slf4j-nop:1.7.36` to `extra_dependencies` |
| `TEMPORARY TABLE` invisible to Scala | Temp tables are session-scoped | Use `TRANSIENT TABLE` for cross-session sharing |
| `import jpype.imports` needed | JPype's Java import hooks not auto-registered | Call `import jpype.imports` immediately after `jpype.startJVM()` |
| Ammonite snapshot version 404 | Pre-release versions are not on Maven Central | Use stable release `3.0.8` |
| Snowpark uber-JAR 404 | Artifact ID changed to include Scala suffix | Use coursier with `com.snowflake:snowpark_2.12:1.18.0` |
| Scala string interpolation errors | Nested quotes in `s"..."` blocks | Extract SQL results into intermediate `val` bindings |
| Kernel restart not enough | JVM persists in SPCS container process | Full container restart required for JVM option changes |
| PySpark DF interop via temp views | Both Python and Scala connect to the same Spark Connect server | Register temp view from one side, read with `spark.table()` from the other |
| Cross-API Snowpark→Spark via SQL plan | Spark Connect proxies Snowflake SQL, so same query plan works | Pass SQL to `spark.sql()` instead of `sfSession.sql()` with `-i:spark` |
| Cross-API Spark→Snowpark materialisation | Spark DFs don't expose a simple SQL plan for Snowpark | Materialise to transient table, read from Snowpark, track for cleanup |

---

## Known Limitations (Prototype)

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| JVM cannot be restarted | Must restart container to change classpath/JVM flags | Inherent to JNI |
| First cell is slow (~5-10s) | Scala compiler warm-up | Pre-warm during setup |
| No `import $ivy` at runtime | Must pre-load JARs via setup script | Full Ammonite embedding |
| Output formatting | Raw text, no rich display | Build `sprint()` helpers like R |
| Ephemeral install | Reinstall on container restart | Use `PERSISTENT_DIR` |
| Ammonite API undocumented | "ammonite-lite" mode as workaround | Investigate Ammonite `Main` API |
| Separate Snowflake sessions | Python and Scala sessions are independent | SQL plan transfer via `-i`/`-o`, or transient tables |
| `%scala` can't use `s"${...}"` | IPython expands `${expr}` before Scala sees it | Use `%%scala` cells for string interpolation |
| `%%java` no PySpark DF interop | JShell interop targets Snowpark Java only | Use `%%scala` for PySpark DataFrame operations |
| JShell variable pull limited | Only primitives, strings, and Snowpark DFs pull cleanly | Complex Java objects stay in JShell |
| Spark Connect: limited SQL functions | Proxy doesn't map all Snowflake system functions | Use Snowpark Scala (`sfSession`) for full Snowflake SQL |
| Spark Connect: single JVM constraint | Both Snowpark + Spark Connect must share one JVM | Handled by monkey-patching `start_jvm`; fragile across spc versions |
| `-o:snowpark` materialises data | Cross-API pull writes a transient table then reads it back | Inherent — Spark DFs don't expose a SQL plan Snowpark can consume directly |
| PySpark→Snowpark push not supported | No direct path from PySpark DF to Scala Snowpark DF | Warn and push as Spark DF instead; user can convert in Scala |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Metadata file not found` | Setup script not run | Run `!bash setup_scala_environment.sh` |
| `Failed to start JVM` | JAVA_HOME wrong or JDK not installed | Check `java -version` works |
| `No Scala interpreter initialized` | `setup_scala_environment()` not called | Call it before using `%%scala` |
| `JShell not initialized` | `setup_scala_environment()` not called or JShell init failed | Call `setup_scala_environment()` before using `%%java` |
| `OutOfMemoryError` | JVM heap too small | Set `jvm_heap: "4g"` in `scala_packages.yaml`, restart container |
| `class not found: snowpark` | Snowpark JAR not on classpath | Re-run setup script with `--force` |
| `Failed to initialize MemoryUtil` | Missing `--add-opens` JVM flag | Add flag to `jvm_options`, restart container |
| `Invalid OAuth access token` | SPCS token expired | Restart container (refreshes token) |
| `NullPointerException` on session | Credentials not set as System properties | Run `inject_session_credentials(session)` before Scala session |
| `Object 'X' does not exist` | Temp table from different session | Use `TRANSIENT TABLE` instead of `TEMPORARY TABLE` |
| Spark Connect: "JVM must not be running" | `spc.start_session()` refuses existing JVM | Monkey-patch `spc.server.start_jvm` to no-op; start our JVM first |
| Spark Connect: `SQLConf not found` | PySpark JARs missing from classpath | Include `pyspark/jars/*.jar` in classpath when Spark Connect enabled |
| Spark Connect: null context class loader | When spc starts JVM in background thread | Start our JVM first (avoids the issue entirely) |
| Coursier native binary crashes | GraalVM `PhysicalMemory.size` failure in containers | Use coursier JAR launcher (`java -jar coursier.jar`) instead |
| OpenTelemetry warning on import | Optional telemetry exporters not installed | pip install `opentelemetry-exporter-otlp` |
| `spark.sql.session.timeZone` missing | Spark Connect requires explicit timezone | Set `.config("spark.sql.session.timeZone", "UTC")` on SparkSession |

---

## Relationship to R Integration

This prototype reuses infrastructure from the R integration:

- **micromamba** — same installer, can coexist in the same container
- **Authentication** — R uses ADBC with a PAT (created via `PATManager`),
  Scala/Java use Snowpark JDBC with the SPCS OAuth token injected by the
  container. The Scala/Java path is simpler since no PAT creation step is needed.
- **PERSISTENT_DIR** — same persistence strategy applies
- **Architecture pattern** — same "install runtime + bridge + magic" approach
