# Java Guide — Snowpark Java in Workspace Notebooks

**Notebook:** `workspace_java_quickstart.ipynb`
**Back to:** [README.md](README.md)

---

## %%java Magic Flags

The `%%java` cell magic supports the same flag syntax as `%%scala`:

| Flag | Description | Example |
|------|-------------|---------|
| `-i var1,var2` | Push Python variables into Java (primitives, strings, Snowpark DFs) | `%%java -i name,count` |
| `-o var1,var2` | Pull Java variables into Python (primitives, strings, Snowpark DFs) | `%%java -o result` |
| `--silent` | Suppress output | `%%java --silent` |
| `--time` | Print wall-clock execution time | `%%java --time` |

**Snowpark Java DFs:** When `-i` receives a Snowpark Python DataFrame, it is
pushed into JShell as a `com.snowflake.snowpark_java.DataFrame` via SQL plan
transfer. When `-o` detects a Snowpark Java DataFrame, it is pulled back as a
Snowpark Python DataFrame via a transient table.

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

The `%java` line magic executes a single Java expression:

```python
%java System.out.println("2 + 2 = " + (2 + 2));
```

---

## Snowpark Java Session

After `inject_session_credentials(session)`, create a Snowpark Java session:

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

Or use the convenience helper:

```python
from scala_helpers import create_snowpark_java_session_code
code = create_snowpark_java_session_code()
```

```python
%%java
// Paste or execute the generated code
```

---

## DataFrame Interop

### Snowpark Java Transfers

| Direction | Source | Target | Mechanism |
|-----------|--------|--------|-----------|
| `-i` push | Snowpark Python DF | Snowpark Java DF | SQL plan → `javaSession.sql()` |
| `-o` pull | Snowpark Java DF | Snowpark Python DF | Transient table → `session.table()` |

The Java interop uses the same SQL plan transfer mechanism as Scala for
Snowpark DataFrames. The Java Snowpark API (`com.snowflake.snowpark_java.*`)
ships in the same JAR as the Scala API — no extra dependencies needed.

### Example

```python
# Python → Java
py_df = session.sql("SELECT 1 AS id, 'hello' AS msg")
```

```python
%%java -i py_df -o result_df --time
// py_df is now a Snowpark Java DataFrame
DataFrame result_df = py_df.select(
    Functions.col("ID"),
    Functions.upper(Functions.col("MSG")).as("MSG_UPPER")
);
result_df.show();
```

```python
# Java → Python: result_df pulled back automatically
result_df.show()
```

---

## UDF and Stored Procedure Registration

JShell keeps compiled classes **in memory** (unlike Scala's IMain which writes
`.class` files to a configurable directory on disk). This means Snowpark Java's
`registerTemporary` / `registerPermanent` lambda serialization won't work from
JShell — Snowpark can't locate the class files to package into a UDF JAR.

We provide two **custom magics** that solve this cleanly:

| Magic | Workflow | Description |
|---|---|---|
| `%%java_udf` | Single cell | Write, test, and register in one cell |
| `%register_java_udf` | Two cells | Define & test in `%%java`, then register with a one-liner |

Both magics extract the handler class source from JShell's snippet history and
register it via the **Snowflake Python API** (`snowflake.core`), falling back
to `CREATE FUNCTION` SQL if the Python API is unavailable.

### %%java_udf — Single-cell workflow

Write the handler class, test it locally in JShell, and register it as a UDF
— all in one cell. The magic:

1. Executes the cell in JShell (so `System.out.println` works for local testing)
2. Extracts the handler class source from JShell's snippet history
3. Registers the UDF in Snowflake

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

**Flags:**

| Flag | Required | Description |
|------|:---:|-------------|
| `--name` | Yes | UDF name in Snowflake |
| `--args` | Yes | Argument list (quoted), e.g. `"x INT, y VARCHAR"` |
| `--returns` | Yes | Return SQL type, e.g. `INT`, `VARCHAR`, `DOUBLE` |
| `--handler` | Yes | `ClassName.methodName` of the static handler |
| `--permanent` | No | Create as a permanent UDF (default: temporary) |

### %register_java_udf — Two-cell workflow

For more complex handlers, define and test the class first in a `%%java` cell,
then register it with a one-liner:

**Cell 1 — Define and test:**

```python
%%java
class ReverseHandler {
    public static String compute(String s) {
        return new StringBuilder(s).reverse().toString();
    }
}

System.out.println("Local test: " + ReverseHandler.compute("Snowflake"));
System.out.println("Local test: " + ReverseHandler.compute("Hello World"));
```

**Cell 2 — Register:**

```python
%register_java_udf --name java_reverse_str --args "s VARCHAR" --returns VARCHAR --handler ReverseHandler.compute
```

```python
%%java
javaSession.sql("SELECT java_reverse_str('Snowflake') AS reversed").show();
```

### Permanent UDFs

Add `--permanent` to create a UDF that survives session restarts:

```python
%%java_udf --name java_celsius_to_f --args "c DOUBLE" --returns DOUBLE --handler TempConvert.toFahrenheit --permanent
class TempConvert {
    public static double toFahrenheit(double c) {
        return c * 9.0 / 5.0 + 32.0;
    }
}

System.out.println("Local test: 100C = " + TempConvert.toFahrenheit(100.0) + "F");
```

### How it works under the hood

1. **JShell snippet history:** Every class, method, or expression evaluated in
   JShell is stored as a `Snippet` object. The magic walks `jshell.snippets()`
   looking for `TypeDeclSnippet` entries whose name matches the handler class,
   and takes the **last** matching definition (so redefinitions are handled).

2. **Snowflake Python API:** The extracted source is passed to
   `snowflake.core.user_defined_function.UserDefinedFunction` with a
   `JavaFunction` language config. This creates/replaces the function via the
   managed API.

3. **SQL fallback:** If `snowflake.core` is unavailable, the magic falls back
   to `CREATE [OR REPLACE] [TEMPORARY] FUNCTION ... AS $$ <body> $$` via the
   active Snowpark Python session.

> **Why not `registerTemporary()` / `registerPermanent()`?**
> These Snowpark Java methods serialize the lambda closure and need to find
> the enclosing class file on disk. JShell compiles snippets to an in-memory
> classloader with no disk output, so Snowpark reports
> *"Unable to detect the location of the enclosing class"*. Our magic-based
> approach bypasses this entirely — the handler source is sent directly to
> Snowflake's server-side Java runtime.
>
> **Note:** The Snowflake docs provide REPL/notebook UDF guidance
> [only for Scala](https://docs.snowflake.com/en/developer-guide/snowpark/scala/quickstart-jupyter)
> (IMain writes `.class` files to disk, which Snowpark can find). There is
> no equivalent "Setting Up JShell for Snowpark Java" page — the
> [Java setup docs](https://docs.snowflake.com/en/developer-guide/snowpark/java/setup)
> only cover IntelliJ / Maven. The magics documented here are our
> workaround for this gap.

---

## Spark Connect for Java (Opt-in)

When Spark Connect is enabled (see [README.md](README.md#spark-connect-for-scala-opt-in)),
you can also use Spark SQL from `%%java` cells by creating a Java SparkSession
connected to the same local gRPC server:

```python
%%java
import org.apache.spark.sql.SparkSession;

SparkSession javaSpark = SparkSession.builder()
    .remote("sc://localhost:15002")
    .config("spark.sql.session.timeZone", "UTC")
    .getOrCreate();

javaSpark.sql("SELECT 1 AS id, 'hello from Java Spark' AS msg").show();
```

The Java Spark client shares the same gRPC server and Snowflake connection
as the Scala Spark client and PySpark.

---

## Alternatives for managing UDFs/procedures

| Tool | What it does | Installed in Workspace? |
|------|-------------|:---:|
| **`%%java_udf` / `%register_java_udf`** | Register Java UDFs from real, testable JShell code | Yes (built into `scala_helpers.py`) |
| **Snowflake Python API** | `root.databases[...].functions.create(...)` across languages | Likely (ships with `snowflake-snowpark-python`) |
| **Snowflake CLI** (`snow snowpark`) | Build, deploy, and manage Snowpark functions/procedures from the command line | No (but could be installed) |

The custom magics are the recommended path for interactive notebook use.
The **Snowflake Python API** (`snowflake.core`) is what the magics use
internally and can also be called directly from Python cells for
programmatic deployments.
