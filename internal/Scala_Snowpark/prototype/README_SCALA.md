# Scala Guide — Snowpark Scala in Workspace Notebooks

**Notebook:** `workspace_scala_quickstart.ipynb`
**Back to:** [README.md](README.md)

---

## %%scala Magic Flags

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
[DataFrame Interop](#dataframe-interop) below.

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

---

## Snowpark Scala Session

After `inject_session_credentials(session)`, create a Snowpark Scala session:

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

Or use the convenience helper:

```python
from scala_helpers import bootstrap_snowpark_scala
success, msg = bootstrap_snowpark_scala(session)
print(msg)
```

---

## DataFrame Interop

The `-i` / `-o` flags auto-detect DataFrame types and pick the right
transfer strategy. Both **Snowpark** and **PySpark** DataFrames are
supported, plus cross-API transfers when Spark Connect is enabled.

### Same-API Transfers (default)

| Direction | Source | Target | Mechanism |
|-----------|--------|--------|-----------|
| `-i` push | Snowpark Python DF | Snowpark Scala DF | SQL plan → `sfSession.sql()` |
| `-i` push | PySpark DF | Spark Scala DF | Temp view → `spark.table()` |
| `-o` pull | Snowpark Scala DF | Snowpark Python DF | SQL plan → `session.sql()` |
| `-o` pull | Spark Scala DF | PySpark DF | Temp view → `spark_py.table()` |

No data is copied for Snowpark transfers — only the SQL string crosses
the JPype bridge. PySpark transfers use Spark temp views (both Python and
Scala talk to the same Spark Connect server).

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

## UDF and Stored Procedure Registration

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

## Alternatives for managing UDFs/procedures

If you need more advanced lifecycle management (versioning, deployment
pipelines, CI/CD), consider these complementary tools:

| Tool | What it does | Installed in Workspace? |
|------|-------------|:---:|
| **Snowpark Native API** | `session.udf.register*` / `session.sproc.register*` | Yes (Snowpark Scala/Java JARs) |
| **Snowflake Python API** | `root.databases[...].functions.create(...)` across languages | Likely (ships with `snowflake-snowpark-python`) |
| **Snowflake CLI** (`snow snowpark`) | Build, deploy, and manage Snowpark functions/procedures from the command line | No (but could be installed) |

The **Snowpark Native API** (what `enable_udf_registration` enables) is the
simplest path for interactive notebook use. The **Snowflake Python API**
(`snowflake.core`) can also create functions targeting any handler language
and is worth exploring for programmatic deployments from Python cells.
The **Snowflake CLI** is oriented toward CI/CD pipelines and project-based
workflows rather than interactive notebook use.
