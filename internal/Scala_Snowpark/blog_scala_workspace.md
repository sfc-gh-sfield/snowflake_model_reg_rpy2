# Scala & Java in Snowflake Workspace Notebooks: Snowpark, Spark Connect, and JVM Magics

*A standalone guide to adding Scala and Java support to Snowflake Workspace
Notebooks -- Snowpark Scala/Java, Spark Connect, UDF registration, and
cross-language interoperability*

---

> **Heads up:** The Scala & Java prototype described in this post is an
> experimental project. It is **not officially supported by Snowflake**.
> It demonstrates what's possible today within the existing building blocks
> available in Workspace Notebooks and is shared to demonstrate the principles
> and as-is for those that may find it useful. APIs and behaviour may change. 
> The full working prototype is available on
> [GitHub](https://github.com/sfc-gh-sfield/snowflake-workspace-scala-prototype).

---

Snowflake Workspace Notebooks provide a managed, containerised notebook
environment running on Snowpark Container Services. They're powerful for
Python and SQL, but what if your team works in Scala or Java? Snowpark has
first-class Scala and Java SDKs, and many data engineering teams prefer
these languages for their type safety, performance, and expressiveness.

In this post I'll show how you can easily add both Scala and Java support to
Workspace Notebooks -- including Snowpark Scala/Java for direct Snowflake 
operations, UDF registration from notebook cells, and optionally Spark Connect 
for the full Spark DataFrame API. By the end you'll be able to write `%%scala` 
and `%%java` cells in a Workspace Notebook, query Snowflake with
`sfSession.sql(...)` or `javaSession.sql(...)`, register UDFs from real
testable code, use the Spark DataFrame API via `spark.sql(...)`, and pass
DataFrames seamlessly between Python, Scala, and Java.

The full working prototype -- including the installer, helper module, and
example notebooks -- is published as a self-contained repo that you can clone
into any Workspace.

## The Approach: JPype as a JVM Bridge

Workspace Notebooks run a Python kernel. There's no JVM, Scala kernel, or
Java kernel available. But where there's Python, there's a path to other
runtimes. We use [JPype](https://jpype.readthedocs.io/) to embed a full JVM.

JPype connects Python to Java/Scala via JNI (Java Native Interface), running
the JVM **in-process** with shared memory. There's no subprocess overhead, no
serialisation, no network calls. Python, Scala, and Java share the same
address space.

On top of JPype, we run two REPLs side by side in the same JVM:

- **Scala IMain** (Ammonite-lite mode) for `%%scala` cells
- **JShell** (JDK 17 built-in) for `%%java` cells

Both are registered as IPython cell magics. The result: you write Scala or
Java code in notebook cells, and it executes natively with full access to
Snowpark, the standard libraries, and any JARs on the classpath.

```
   ┌──────────────────────────────────────────────────────────────┐
   │               Snowflake Workspace Notebook                   │
   │                                                              │
   │   Python Kernel                                              │
   │   ├── %%scala magic  ──►  JPype (JNI)  ──►  JVM              │
   │   │                                          ├── Scala REPL  │
   │   ├── %%java magic   ──►                     │   (IMain)     │
   │   │                                          ├── Java REPL   │
   │   │                                          │   (JShell)    │
   │   │                                          ├── Snowpark    │
   │   │                                          │   Scala+Java  │
   │   │                                          └── Spark       │
   │   │                                              Connect     │
   │   │                                              Client      │
   │   ├── Snowpark Python (direct)                               │
   │   └── snowpark_connect gRPC server (opt-in)                  │
   │        └──► Snowflake (SPCS OAuth)                           │
   └──────────────────────────────────────────────────────────────┘
```

The key components:

| Layer | What |
|-------|------|
| Runtime | OpenJDK 17 + Scala 2.12, installed via micromamba |
| Bridge | JPype -- embeds JVM in the Python process via JNI |
| Magics | `%%scala` / `%%java` -- custom IPython magics in `scala_helpers.py` |
| REPLs | Scala IMain (Ammonite-lite) + JDK 17 JShell |
| Auth | SPCS OAuth token (auto-detected from the Workspace container) |

## Getting Started

The prototype consists of a handful of files. Upload them to your Workspace
Notebook's working directory:

```
scala_packages.yaml               # Version configuration (Java, Scala, Snowpark)
setup_scala_environment.sh        # Installation script
scala_helpers.py                  # Python helper module (magics, interop, JVM management)
workspace_scala_quickstart.ipynb  # Scala example notebook
workspace_java_quickstart.ipynb   # Java example notebook
```

### Step 1: Install the JVM and Dependencies

```python
!bash setup_scala_environment.sh
```

The script is **idempotent** -- it detects what's already installed and skips
those steps. First run takes 2-4 minutes; subsequent runs (e.g. after a kernel
restart) are faster. It installs:

- **micromamba** -- lightweight conda-compatible package manager
- **OpenJDK 17** via micromamba (~174 MB)
- **coursier** -- JVM dependency resolver (JAR launcher, not native binary)
- **Scala 2.12** compiler and library JARs
- **Ammonite** REPL JARs
- **Snowpark 1.18.0** and all transitive dependencies
- **JPype** (`pip install JPype1`) into the kernel's Python environment
- **(If Spark Connect enabled - optional):** `snowpark-connect`, `pyspark`,
  `opentelemetry-exporter-otlp`, and the Spark Connect client JARs

Everything is configured declaratively in `scala_packages.yaml`:

```yaml
java_version: "17"
scala_version: "2.12"
snowpark_version: "1.18.0"
ammonite_version: "3.0.8"

jvm_heap: "auto"           # 25% of container RAM, clamped 1-4 GB
jvm_options:
  - "-Xms256m"
  - "--add-opens=java.base/java.nio=ALL-UNNAMED"  # Required for Arrow/Java 17

spark_connect:
  enabled: true            # Set to false to skip Spark Connect entirely
  pyspark_version: "3.5.6"
  server_port: 15002
```

### Adding Extra Dependencies

Need additional Java or Scala libraries? Add their Maven coordinates to
`extra_dependencies` in the YAML:

```yaml
extra_dependencies:
  - "org.slf4j:slf4j-nop:1.7.36"
  - "com.google.guava:guava:33.0.0-jre"
  - "org.apache.commons:commons-math3:3.6.1"
```

Re-run the setup script and coursier resolves them (including transitive
dependencies) from Maven Central. They're available in `%%scala` cells after
`setup_scala_environment()`.

One constraint: there's no runtime `import $ivy`. All JARs must be declared
up front because the JVM classpath is fixed at startup. Adding a dependency
after the JVM has started requires a container restart.

### Step 2: Initialize the Scala Environment

```python
from scala_helpers import setup_scala_environment

result = setup_scala_environment()
print(f"Scala {result['scala_version']} | {result['interpreter_type']} | JVM: {result['jvm_started']}")
```

This starts the JVM (with the full classpath), initializes both the Scala
REPL (IMain) and Java REPL (JShell), registers the `%%scala`, `%%java`,
`%scala`, and `%java` magics, and -- if Spark Connect is enabled -- starts
the local gRPC server.

### Step 3: Write Scala or Java

```python
%%scala
println(s"Hello from Scala ${util.Properties.versionString}")
val sum = (1 to 100).sum
println(s"Sum 1..100 = $sum")
```

```python
%%java
System.out.println("Hello from Java " + System.getProperty("java.version"));
int sum = java.util.stream.IntStream.rangeClosed(1, 100).sum();
System.out.println("Sum 1..100 = " + sum);
```

That's it. Three steps, and you have working Scala and Java environments
inside a Snowflake Workspace Notebook.

## Connecting to Snowflake with Snowpark Scala

Workspace Notebooks run inside SPCS containers, which provide an OAuth token
at `/snowflake/session/token`. This is the simplest authentication path --
no PAT, or other authentication method needed.

```python
from snowflake.snowpark.context import get_active_session
from scala_helpers import inject_session_credentials

session = get_active_session()
inject_session_credentials(session)
```

Credentials are injected as **Java System properties** (not environment
variables) because Java's `System.getenv()` caches the process environment at
JVM startup, making later `os.environ` changes invisible to Scala.

Then we can create a Snowpark Scala session:

```scala
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

You now have a full Snowpark Scala session. All the Snowpark Scala APIs work:
`sfSession.sql(...)`, `sfSession.table(...)`, DataFrame transformations,
UDFs -- everything.

## Connecting to Snowflake with Snowpark Java

The same credential injection works for Java. Create a Snowpark Java session
in a `%%java` cell:

```java
%%java
import com.snowflake.snowpark_java.*;
import java.util.HashMap;

var props = new HashMap<String, String>();
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

Or use the convenience helper:

```python
from scala_helpers import bootstrap_snowpark_java
success, msg = bootstrap_snowpark_java(session)
print(msg)
```

The Java and Scala sessions share the same JVM but maintain **separate JDBC
connections** to Snowflake. This means temporary tables and temporary
functions created in one session aren't visible to the other -- use transient
tables for cross-session sharing.

## Python-Scala-Java DataFrame Interop

One of the most useful features is the ability to pass DataFrames between
Python and Scala using `-i` (input) and `-o` (output) flags on the `%%scala`
magic.

### Snowpark DataFrames (Scala)

Snowpark DataFrames are transferred via their **SQL query plan** -- the
underlying SQL string crosses the JPype bridge, but no data is copied:

```python
# Python: create a Snowpark DataFrame
py_df = session.sql("""
    SELECT * FROM VALUES (1, 'Alice', 95.0), (2, 'Bob', 87.5)
    AS t(id, name, score)
""")
```

```python
%%scala -i py_df -o result_df --time
// py_df is now a Snowpark Scala DataFrame
val result_df = py_df.filter(col("SCORE") > 90.0).select(col("NAME"), col("SCORE"))
result_df.show()
```

```python
# result_df is back in Python as a Snowpark Python DataFrame
result_df.to_pandas()
```

The `-i py_df` pushes the Python DataFrame's SQL plan into Scala via
`sfSession.sql(...)`. The `-o result_df` pulls the Scala result back by
extracting its SQL plan and creating a Python Snowpark DataFrame. No data
materialisation at any point.

### Primitives and Scalars

Simple types work too:

```python
count = 100
```

```python
%%scala -i count -o total --time
val total = (1 to count.asInstanceOf[Int]).sum
println(s"Sum = $total")
```

```python
print(f"total from Scala: {total}")  # 5050
```

### Snowpark DataFrames (Java)

The `%%java` magic supports the same `-i`/`-o` flags. Snowpark Python
DataFrames are pushed into JShell as `com.snowflake.snowpark_java.DataFrame`
objects:

```python
py_df = session.sql("SELECT 1 AS id, 'hello' AS msg")
```

```python
%%java -i py_df -o result_df --time
import com.snowflake.snowpark_java.Functions;
DataFrame result_df = py_df.select(
    Functions.col("ID"),
    Functions.upper(Functions.col("MSG")).as("MSG_UPPER")
);
result_df.show();
```

```python
# result_df is a Snowpark Python DataFrame
result_df.show()
```

Java pull (`-o`) materialises through a Snowflake transient table (unlike
Scala which can extract the SQL plan directly), because the Java DataFrame
API doesn't expose query plans in a way we can extract from JShell.

## UDF Registration

One of the most powerful features is the ability to register UDFs directly
from notebook cells -- write real, testable code and deploy it to Snowflake
without leaving the notebook.

### Scala UDFs

Snowpark Scala provides native APIs for UDF registration. The REPL needs
some configuration to make lambdas serialisable, which
`enable_udf_registration()` handles:

```python
from scala_helpers import enable_udf_registration
success, msg = enable_udf_registration()
print(msg)
```

Then register UDFs using standard Snowpark APIs:

```scala
%%scala
import com.snowflake.snowpark.functions.{col, udf}

// Simple temporary UDF
val doubleIt = udf((x: Int) => x * 2)
sfSession.sql("SELECT 21 AS val")
  .select(doubleIt(col("val")).as("doubled"))
  .show()
```

For permanent UDFs that persist across sessions, wrap the function in a
`Serializable` class:

```scala
%%scala
import com.snowflake.snowpark.functions.callUDF

class DoubleUDF extends Serializable {
  val func = (x: Int) => x * 2
}

sfSession.udf.registerPermanent(
  "double_it",
  (new DoubleUDF).func,
  "@~/scala_udfs"
)

sfSession.sql("SELECT double_it(42) AS result").show()
```

### Java UDFs

Java UDF registration is trickier. JShell compiles classes to an **in-memory
classloader** (unlike Scala's IMain which writes `.class` files to disk).
This means Snowpark Java's `registerTemporary()` / `registerPermanent()`
can't find the class files to serialize -- it reports *"Unable to detect the
location of the enclosing class"*.

We solve this with two custom magics that extract the handler class source
from JShell's snippet history and register the UDF via `CREATE FUNCTION`
SQL:

**`%%java_udf` -- single-cell workflow:**

Write, test, and register in one cell. The magic executes the code in JShell
first (so local testing works), then extracts the class source and registers
it:

```python
%%java_udf --name java_double_it --args "x INT" --returns INT --handler DoubleHandler.compute
class DoubleHandler {
    public static int compute(int x) {
        return x * 2;
    }
}

// Test locally before it gets registered
System.out.println("Local test: compute(21) = " + DoubleHandler.compute(21));
```

```python
%%java
// Verify it works in Snowflake
javaSession.sql("SELECT java_double_it(21) AS doubled").show();
```

**`%register_java_udf` -- two-cell workflow:**

For more complex handlers, define and test first, then register with a
one-liner:

```python
%%java
class ReverseHandler {
    public static String compute(String s) {
        return new StringBuilder(s).reverse().toString();
    }
}

System.out.println("Test: " + ReverseHandler.compute("Snowflake"));
```

```python
%register_java_udf --name java_reverse_str --args "s VARCHAR" --returns VARCHAR --handler ReverseHandler.compute
```

Both magics support `--permanent` for UDFs that persist across sessions.
Under the hood, they extract the class source from JShell's snippet API and
execute `CREATE FUNCTION` through `javaSession` so the UDF is immediately
callable from `%%java` cells.

## Error Handling

When a `%%scala` or `%%java` cell encounters an error, the magic raises a
`MagicExecutionError` Python exception. This is important for the "Run All"
workflow in Workspace Notebooks -- without a proper exception, Jupyter
continues executing subsequent cells even when earlier ones failed.

The error messages include the REPL's diagnostic output (compiler errors,
runtime exceptions, Snowflake SQL errors) so you can debug directly from the
notebook output.

## Spark Connect for Scala (Opt-in)

When `spark_connect.enabled: true` is set in `scala_packages.yaml`, the
prototype also provides a native **Spark SQL** experience alongside Snowpark.
This gives you the full Spark DataFrame API -- `filter`, `groupBy`, `agg`,
`join`, `createDataFrame`, and everything else from the Spark ecosystem --
executing against Snowflake data.

### How It Works

The architecture adds a local gRPC proxy:

```
%%scala cell
    ├── sfSession.sql(...)  →  Snowpark Scala (direct JDBC)
    │
    └── spark.sql(...)      →  Spark Connect client (Scala)
                                   │ gRPC (localhost:15002)
                                   ▼
                              snowpark_connect server (Python)
                                   │ SPCS OAuth
                                   ▼
                              Snowflake
```

The [Snowpark Connect](https://docs.snowflake.com/en/developer-guide/snowpark/scala/spark-connect)
library runs a local Python-based gRPC server that translates Spark Connect
protocol messages into Snowpark operations, using the Workspace's SPCS OAuth
token. The Scala Spark Connect client in the JVM connects to
`sc://localhost:15002`.

**Both APIs share a single JVM.** This was one of the trickier challenges -- `snowpark_connect` normally starts its own JVM and refuses to
run if one is already active. We solve this by starting our JVM first (with
the complete classpath including PySpark's bundled JARs) and monkey-patching
`snowpark_connect`'s `start_jvm` function to reuse the existing one.

### Setup

After `setup_scala_environment()` has started the Spark Connect server, one
additional call binds the Scala `SparkSession`:

```python
from scala_helpers import setup_spark_connect
sc_result = setup_spark_connect()
```

### Using Spark SQL

```scala
%%scala
// Spark SQL via the gRPC proxy -- executes in Snowflake
spark.sql("SELECT 1 AS id, 'hello from Scala Spark' AS msg").show()
```

```scala
%%scala
// Full Spark DataFrame API on Snowflake data
import org.apache.spark.sql.functions._

val employees = spark.sql("""
    SELECT * FROM VALUES
        ('Alice', 'Engineering', 120000),
        ('Bob', 'Engineering', 110000),
        ('Carol', 'Marketing', 95000),
        ('Dave', 'Marketing', 105000),
        ('Eve', 'Engineering', 130000)
    AS t(name, department, salary)
""")

val result = employees
  .filter(col("SALARY") > 100000)
  .select(col("NAME"), col("DEPARTMENT"), (col("SALARY") / 1000).as("salary_k"))
  .orderBy(col("salary_k").desc)

result.show()
```

### Spark DataFrame Interop

The `-i`/`-o` flags also work with PySpark DataFrames. Since Spark Connect
clients get separate server-side sessions (temp views aren't shared), the
interop materialises through Snowflake tables:

```python
# Create a PySpark DataFrame
from scala_helpers import _scala_state
spark_py = _scala_state["pyspark_session"]

pyspark_df = spark_py.sql("""
    SELECT * FROM VALUES
        ('London', 'UK', 9000000),
        ('Paris', 'France', 2100000),
        ('Berlin', 'Germany', 3600000)
    AS t(city, country, population)
""")
```

```python
%%scala -i pyspark_df -o big_cities
import org.apache.spark.sql.functions._

val big_cities = pyspark_df
  .filter(col("POPULATION") > 3000000)
  .select(col("CITY"), col("COUNTRY"), (col("POPULATION") / 1000000).as("pop_millions"))
  .orderBy(col("pop_millions").desc)

big_cities.show()
```

```python
# big_cities is a PySpark DataFrame in Python
big_cities.show()
```

### Cross-API Transfers

Type hints enable transfers across the Snowpark/Spark boundary:

- **`-i:spark`** pushes a Snowpark Python DataFrame into Scala as a Spark
  DataFrame (the SQL plan works in both `sfSession.sql()` and `spark.sql()`
  because the proxy forwards Snowflake SQL)
- **`-o:snowpark`** pulls a Scala Spark DataFrame back to Python as a Snowpark
  DataFrame (materialises to a transient table)

```python
# Snowpark Python DataFrame
snowpark_df = session.sql("""
    SELECT * FROM VALUES
        ('Widget A', 'Hardware', 15000),
        ('Service X', 'Software', 45000)
    AS t(product, category, revenue)
""")
```

```python
%%scala -i:spark snowpark_df -o:snowpark category_totals
import org.apache.spark.sql.functions._

// snowpark_df arrived as a Spark DataFrame (via -i:spark)
val category_totals = snowpark_df
  .groupBy("CATEGORY")
  .agg(sum("REVENUE").as("total_revenue"))
  .orderBy(col("total_revenue").desc)

category_totals.show()
```

```python
# category_totals is a Snowpark Python DataFrame (via -o:snowpark)
category_totals.show()
```

A cleanup function drops any interop tables at the end of the notebook:

```python
from scala_helpers import cleanup_interop_views
cleanup_interop_views()
```

## Interop Summary

| Magic | Flag | Source | Target | Mechanism |
|-------|------|--------|--------|-----------|
| `%%scala` | `-i` (auto) | Snowpark Python DF | Snowpark Scala DF | SQL plan transfer |
| `%%scala` | `-i` (auto) | PySpark DF | Spark Scala DF | Materialise to table |
| `%%scala` | `-i:spark` | Snowpark Python DF | Spark Scala DF | SQL plan → `spark.sql()` |
| `%%scala` | `-o` (auto) | Snowpark Scala DF | Snowpark Python DF | SQL plan transfer |
| `%%scala` | `-o` (auto) | Spark Scala DF | PySpark DF | Materialise to table |
| `%%scala` | `-o:snowpark` | Spark Scala DF | Snowpark Python DF | Materialise to transient table |
| `%%java` | `-i` | Snowpark Python DF | Snowpark Java DF | SQL plan → `javaSession.sql()` |
| `%%java` | `-o` | Snowpark Java DF | Snowpark Python DF | Transient table → `session.table()` |

Snowpark Scala transfers are zero-copy (only the SQL string crosses the
bridge). Java pulls and Spark Connect transfers materialise through Snowflake
tables because those paths involve separate sessions or APIs that don't
expose extractable SQL plans.

## Gotchas & Learnings

Here are the practical things discovered during development.

**JVM cannot be restarted.** Once JPype starts the JVM, you cannot change
classpath or JVM options without restarting the entire container (not just
the kernel). This is inherent to JNI.

**First Scala cell can be slow (~5-10s).** The Scala compiler needs to warm up.
Subsequent cells are fast.

**`System.getenv()` is invisible after JVM startup.** Java caches environment
variables when the JVM starts. Use `System.setProperty()` (which we do for
credentials) instead of `os.environ` for anything Scala needs to read.

**Coursier native binary crashes in containers.** The GraalVM native image
binary fails with `PhysicalMemory.size` errors. We use the JAR launcher
(`java -jar coursier.jar`) instead.

**Arrow and Java 17 module system.** Spark Connect's Arrow-based
serialisation requires `--add-opens=java.base/java.nio=ALL-UNNAMED`. We set
this via `JAVA_TOOL_OPTIONS` so it applies regardless of which component
starts the JVM.

**`TEMPORARY TABLE` isn't visible across different sessions e.g. python Snowpark, and scala Snowpark.** The Python Snowpark
session and the Scala session are separate Snowflake connections. Use
`TRANSIENT TABLE` for sharing data between them.

**Spark Connect: currently in preview - does not support all Snowflake SQL functions.** The Snowpark Connect proxy
doesn't map every Snowflake system function. `CURRENT_ROLE()` and
`SHOW TABLES` aren't supported -- use Snowpark Scala (`sfSession`) for those.

**Spark Connect: column names get uppercased.** When data passes through
Snowflake (via materialisation), column names are uppercased - standard Snowflake behaviour. Reference
columns as `col("CITY")` not `col("city")` in Scala cells that operate on
materialised data.

**`%scala` line magic and string interpolation.** IPython expands `${expr}`
in line magic arguments before Scala sees them. Use `%%scala` cells for
`s"${...}"` string interpolation, or use `$varName` (no braces) with
`%scala`.

**JShell compiles to memory, not disk.** Unlike Scala's IMain (which writes
`.class` files to a configurable directory), JShell uses an in-memory
classloader. This means Snowpark Java's `registerTemporary()` /
`registerPermanent()` can't find class files to serialize. The `%%java_udf`
magic works around this by extracting the handler source from JShell's
snippet history and sending it directly to Snowflake via `CREATE FUNCTION`.

**JShell `eval()` only processes the first snippet.** By default,
`jshell.eval(code)` evaluates only the first complete statement. Multi-statement
cells require iterative parsing with `sourceCodeAnalysis().analyzeCompletion()`
in a loop.

**JShell streams vs iterators.** JShell API methods like `diagnostics()` and
`snippets()` return Java `Stream` objects, not `Iterator`s. In JPype, you
must call `.iterator()` on the stream before traversing.

**`TEMPORARY FUNCTION` is session-scoped.** A temporary UDF created by one
Snowflake session (e.g. the Python Snowpark session) is invisible to a
separate session (e.g. `javaSession`). Java UDFs registered via `%%java_udf`
execute the `CREATE FUNCTION` through `javaSession` so the UDF is
immediately callable from `%%java` cells.

**Failing magic cells don't stop "Run All" by default.** IPython magics that
print errors but don't raise exceptions won't stop Jupyter's "Run All"
execution. We raise `MagicExecutionError` (a Python exception) from
`%%scala` and `%%java` magics to ensure proper error propagation.

## What's in the Repo

The [companion repository](https://github.com/sfc-gh-sfield/snowflake-workspace-scala-prototype)
contains everything needed to get started:

| File | Purpose |
|------|---------|
| `scala_packages.yaml` | Version configuration -- edit to change Java/Scala/Snowpark versions or enable Spark Connect |
| `setup_scala_environment.sh` | Idempotent installer -- handles micromamba, JDK, coursier, JARs, pip packages |
| `scala_helpers.py` | Python module -- JVM management, Scala + Java REPLs, `%%scala`/`%%java` magics, DataFrame interop, UDF registration, auth |
| `workspace_scala_quickstart.ipynb` | Scala example notebook -- Snowpark Scala, Spark Connect, UDFs, interop |
| `workspace_java_quickstart.ipynb` | Java example notebook -- Snowpark Java, UDFs via `%%java_udf`, interop |
| `README.md` | Architecture overview and shared configuration |
| `README_SCALA.md` | Scala-specific guide (flags, interop, UDFs, Spark Connect) |
| `README_JAVA.md` | Java-specific guide (flags, interop, `%%java_udf` magics) |

Upload the files to your Workspace Notebook's working directory and run the
notebook top-to-bottom. Everything is self-contained and idempotent.

## Summary

With a handful of files and three setup cells, you get:

- **`%%scala` and `%%java` magics** -- write Scala and Java directly in
  Workspace Notebook cells
- **Snowpark Scala** -- full access to `sfSession.sql(...)`, DataFrame
  transformations, and all Snowpark Scala APIs
- **Snowpark Java** -- full access to `javaSession.sql(...)` and the
  Snowpark Java API
- **UDF registration** -- create Scala UDFs with native Snowpark APIs, and
  Java UDFs with `%%java_udf` / `%register_java_udf` magics that let you
  write real, testable code
- **Spark Connect** (opt-in) -- the full Spark DataFrame API executing
  against Snowflake data via a local gRPC proxy
- **DataFrame interop** -- pass Snowpark and PySpark DataFrames between
  Python, Scala, and Java with `-i`/`-o` flags, including cross-API transfers
- **Error handling** -- `MagicExecutionError` propagation ensures "Run All"
  stops on the first failing cell

The pattern is straightforward: install a runtime, bridge it into the Python
kernel, and provide cell magics for a native coding experience. It's not a
supported product feature, but it works today and demonstrates what a
Scala/Java-native Workspace Notebook experience could look like.

---

**Resources:**
- [GitHub: Scala & Java Workspace Prototype](https://github.com/sfc-gh-sfield/snowflake-workspace-scala-prototype)
- [Snowpark Scala Developer Guide](https://docs.snowflake.com/en/developer-guide/snowpark/scala/index)
- [Snowpark Java Developer Guide](https://docs.snowflake.com/en/developer-guide/snowpark/java/index)
- [Snowpark Connect for Scala](https://docs.snowflake.com/en/developer-guide/snowpark/scala/spark-connect)
- [Snowflake Python API (snowflake.core)](https://docs.snowflake.com/en/developer-guide/snowflake-python-api/snowflake-python-overview)
- [JPype Documentation](https://jpype.readthedocs.io/)
- [Snowflake Workspace Notebooks](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks)

---

*Tags: Scala, Java, Snowflake, Snowpark, Spark Connect, JPype, JShell, UDF, Workspace Notebooks*
