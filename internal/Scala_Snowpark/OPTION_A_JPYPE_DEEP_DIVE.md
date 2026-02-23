# Options A / A2 Deep Dive: JPype + Embedded Scala REPL

## Technical Implementation Details

**Date:** February 2026
**Parent:** `FEASIBILITY.md`

---

## 0. Context: Snowflake's Official Jupyter Approach

Snowflake's [Setting Up a Jupyter Notebook for Snowpark Scala](https://docs.snowflake.com/en/developer-guide/snowpark/scala/quickstart-jupyter)
documents using the **Almond kernel** (built on Ammonite) for Snowpark Scala in
Jupyter. The documented workflow relies on Ammonite-specific features:

- `import $ivy.`com.snowflake:snowpark_2.12:1.18.0`` — Maven dependency resolution
- `interp.configureCompiler(...)` — compiler settings for REPL class output
- `interp.load.cp(...)` — dynamic classpath additions
- REPL class directory (`replClasses`) — required for UDF upload

Since we cannot install Almond as a kernel in Workspace Notebooks, we embed the
same underlying engine (Ammonite or IMain) within the Python kernel via JPype.

**This document covers two variants:**
- **Option A** — JPype + raw `scala.tools.nsc.interpreter.IMain` (simpler, no `import $ivy`)
- **Option A2** — JPype + Ammonite REPL (matches SF docs, has `import $ivy`)

The JPype bridge layer is identical for both; they differ only in which Scala
interpreter is instantiated inside the JVM.

---

## 1. JPype Fundamentals

JPype bridges Python and Java at the native level using JNI (Java Native Interface). Unlike Py4J (socket-based), JPype runs the JVM **within** the Python process, providing:

- Direct memory access between Python and JVM heaps
- No serialization for primitive types and arrays
- Java exceptions propagate as Python exceptions
- Java classes importable like Python modules

### Key Constraint

The JVM can only be started **once** per Python process. After `jpype.shutdownJVM()`, it cannot be restarted. This matches rpy2's behavior (R also cannot be restarted within a process).

---

## 2. PoC Code Sketch

### 2.1 Starting the JVM

```python
import jpype
import jpype.imports
import os

JVM_ENV = os.path.expanduser("~/micromamba/envs/jvm_env")
SNOWPARK_JAR = os.path.expanduser("~/scala_jars/snowpark-with-dependencies.jar")

# Build classpath: Scala compiler/library + Snowpark
classpath = [
    f"{JVM_ENV}/share/scala-2.12/lib/scala-compiler.jar",
    f"{JVM_ENV}/share/scala-2.12/lib/scala-library.jar",
    f"{JVM_ENV}/share/scala-2.12/lib/scala-reflect.jar",
    SNOWPARK_JAR,
]

# Find the JVM shared library
# On Linux (Workspace Notebooks): libjvm.so
jvm_path = jpype.getDefaultJVMPath()  # or explicit path

jpype.startJVM(
    jvm_path,
    classpath=classpath,
    convertStrings=True,  # auto-convert Java strings to Python strings
)
```

### 2.2 Creating the Scala Interpreter (IMain)

```python
from java.io import PrintWriter, StringWriter, ByteArrayOutputStream
from scala.tools.nsc import Settings as ScalaSettings
from scala.tools.nsc.interpreter import IMain

# Configure Scala compiler settings
settings = ScalaSettings()
settings.usejavacp().tryToSetFromPropertyValue("true")
# Alternatively set classpath explicitly:
# settings.classpath().tryToSetFromPropertyValue(":".join(classpath))

# Create output capture
output_stream = ByteArrayOutputStream()
print_writer = PrintWriter(output_stream)

# Create the interpreter
interpreter = IMain(settings, print_writer)

# Warm up (first interpretation is slow due to compilation)
interpreter.interpret("1 + 1")
```

### 2.3 Executing Scala Code

```python
def execute_scala(code: str) -> tuple:
    """Execute Scala code and return (success, output)."""
    output_stream.reset()

    # IMain.interpret() returns an enum:
    # Success, Error, Incomplete
    result = interpreter.interpret(code)
    output = output_stream.toString()

    # Check result type
    result_str = str(result)
    success = "Success" in result_str

    return success, output
```

### 2.4 IPython Magic Registration

```python
from IPython.core.magic import register_cell_magic, register_line_cell_magic
from IPython import display

@register_cell_magic
def scala(line, cell):
    """Execute Scala code in the embedded interpreter.

    Usage:
        %%scala
        val x = 42
        println(s"The answer is $x")
    """
    success, output = execute_scala(cell)

    if output.strip():
        print(output)

    if not success:
        # Could raise an exception or just print error
        pass
```

---

## 2B. Option A2: Ammonite Embedding via JPype

### 2B.1 Why Ammonite Instead of IMain

The raw IMain approach (Section 2) works for basic Scala execution but diverges
from Snowflake's official documentation. Key gaps:

| Feature | IMain | Ammonite |
|---------|-------|----------|
| `import $ivy` (Maven resolution) | No | Yes |
| `interp.configureCompiler(...)` | Must use `Settings` directly | Yes (Almond API) |
| `interp.load.cp(...)` | Must pre-load at JVM start | Yes (dynamic) |
| Pretty-printing | Basic `toString` | Customizable `pprint` |
| UDF REPL class pattern | Manual setup | Matches SF docs verbatim |

### 2B.2 Additional JARs Required

Ammonite is distributed as a set of JARs. The easiest way to resolve them is
via **coursier** during the installation phase:

```bash
# During setup (setup_scala_environment.sh)
cs fetch com.lihaoyi:ammonite_2.12.20:3.0.0 \
  --classpath > /path/to/ammonite_classpath.txt
```

This produces a colon-separated classpath containing ~50 JARs totaling ~50 MB.

### 2B.3 Starting Ammonite Programmatically

```python
# After jpype.startJVM() with Ammonite JARs on classpath

from ammonite import Main as AmmoniteMain
from ammonite.util import Colors

# Create an Ammonite instance
# Note: Ammonite's programmatic API is less documented than IMain's.
# The exact initialization sequence may require experimentation.
# Key classes to investigate:
#   - ammonite.Main (entry point)
#   - ammonite.repl.Repl (REPL engine)
#   - ammonite.interp.Interpreter (code evaluation)

# Pseudocode — actual API may differ:
amm = AmmoniteMain.builder()
    .predefCode("import com.snowflake.snowpark._")
    .build()

# Evaluate code
result = amm.runCode("val x = 1 + 1; println(x)")
```

### 2B.4 Fallback Strategy

If Ammonite's programmatic API proves too difficult to embed via JPype (e.g.,
initialization is too complex, or Ammonite assumes it owns the process), the
fallback is:

1. **Stay with raw IMain** (Option A) — still provides full Scala execution
2. **Pre-load all JARs at startup** — eliminates the need for `import $ivy`
3. **Replicate compiler settings** — configure IMain's `Settings` to match
   what `interp.configureCompiler` would do:

```python
# Option A equivalent of interp.configureCompiler
settings = ScalaSettings()
settings.outputDirs().setSingleOutput(repl_class_path)
settings.Yreplclassbased().value_$eq(True)  # JPype syntax for Scala setter
```

This covers the UDF development path without Ammonite.

---

## 3. Snowpark Scala Session Creation

### 3.1 Using PAT Authentication (Proven with R/ADBC)

**Option A2 (Ammonite — matches Snowflake's Jupyter docs):**

```scala
// %%scala
// Pull Snowpark from Maven (only needed if not pre-loaded on classpath)
import $ivy.`com.snowflake:snowpark_2.12:1.18.0`
import com.snowflake.snowpark._
import com.snowflake.snowpark.functions._

// REPL class directory for UDFs (matches Snowflake docs)
val replClassPathObj = os.Path("replClasses", os.pwd)
if (!os.exists(replClassPathObj)) os.makeDir(replClassPathObj)
val replClassPath = replClassPathObj.toString()

interp.configureCompiler(_.settings.outputDirs.setSingleOutput(replClassPath))
interp.configureCompiler(_.settings.Yreplclassbased)
interp.load.cp(replClassPathObj)

val session = Session.builder.configs(Map(
  "URL"       -> s"https://${sys.env("SNOWFLAKE_ACCOUNT")}.snowflakecomputing.com",
  "USER"      -> sys.env("SNOWFLAKE_USER"),
  "ROLE"      -> sys.env("SNOWFLAKE_ROLE"),
  "DB"        -> sys.env("SNOWFLAKE_DATABASE"),
  "SCHEMA"    -> sys.env("SNOWFLAKE_SCHEMA"),
  "WAREHOUSE" -> sys.env("SNOWFLAKE_WAREHOUSE"),
  "TOKEN"     -> sys.env("SNOWFLAKE_PAT"),
  "AUTHENTICATOR" -> "oauth"
)).create

session.addDependency(replClassPath)
session.sql("SELECT CURRENT_USER(), CURRENT_ROLE()").show()
```

**Option A (raw IMain — Snowpark pre-loaded on classpath):**

```scala
// %%scala
import com.snowflake.snowpark._

val session = Session.builder.configs(Map(
  "URL"       -> (sys.env("SNOWFLAKE_ACCOUNT") + ".snowflakecomputing.com"),
  "USER"      -> sys.env("SNOWFLAKE_USER"),
  "ROLE"      -> sys.env("SNOWFLAKE_ROLE"),
  "DB"        -> sys.env("SNOWFLAKE_DATABASE"),
  "SCHEMA"    -> sys.env("SNOWFLAKE_SCHEMA"),
  "WAREHOUSE" -> sys.env("SNOWFLAKE_WAREHOUSE"),
  "TOKEN"     -> sys.env("SNOWFLAKE_PAT"),
  "AUTHENTICATOR" -> "oauth"
)).create()

session.sql("SELECT CURRENT_USER(), CURRENT_ROLE()").show()
```

### 3.2 Injecting Credentials from Python

The Python helper can extract credentials from the active Snowpark Python session and set them as environment variables before the Scala code runs:

```python
def inject_session_credentials(session):
    """Extract credentials from Python Snowpark session for Scala use."""
    os.environ["SNOWFLAKE_ACCOUNT"] = session.get_current_account()
    os.environ["SNOWFLAKE_USER"] = session.sql("SELECT CURRENT_USER()").collect()[0][0]
    os.environ["SNOWFLAKE_ROLE"] = session.get_current_role().strip('"')
    os.environ["SNOWFLAKE_DATABASE"] = session.get_current_database().strip('"')
    os.environ["SNOWFLAKE_SCHEMA"] = session.get_current_schema().strip('"')
    os.environ["SNOWFLAKE_WAREHOUSE"] = session.get_current_warehouse().strip('"')
    # PAT must still be created separately (PATManager)
```

---

## 4. Data Transfer Patterns

### 4.1 Python -> Scala (Variable Passing)

JPype allows direct Java/Scala object creation from Python:

```python
# Create a Scala/Java collection from Python
from java.util import ArrayList, HashMap

java_list = ArrayList()
java_list.add("item1")
java_list.add("item2")

# Pass to Scala interpreter by binding
interpreter.bind("myList", "java.util.List[String]", java_list)
```

Then in Scala:
```scala
// %%scala
myList.forEach(println)
```

### 4.2 Scala -> Python (Result Extraction)

After Scala code executes, values in the interpreter's namespace can be extracted:

```python
# Get a value from the Scala interpreter
result = interpreter.valueOfTerm("myVar")
# Returns a Java object that JPype can convert
```

### 4.3 Snowpark DataFrames (No Transfer Needed)

The most common pattern: both Python and Scala Snowpark sessions point to the same Snowflake account. Data stays in Snowflake:

```python
# Python: create a temp table
session.sql("CREATE TEMP TABLE my_data AS SELECT * FROM source LIMIT 100").collect()
```

```scala
// %%scala: read the same temp table
val df = session.table("my_data")
df.show()
```

---

## 5. Known JPype + Scala Gotchas

### 5.1 Scala Companion Objects

Scala companion objects compile to a class with `$` suffix:

```python
# To access Scala object Foo:
Foo = jpype.JClass("com.example.Foo$")
instance = Foo.MODULE$  # Scala singleton instance
```

### 5.2 Scala Implicits

Scala implicits don't automatically resolve when calling from Python. You may need to pass implicit parameters explicitly.

### 5.3 Scala Collections

Scala collections are not Java collections. Use `scala.jdk.CollectionConverters` for interop:

```scala
import scala.jdk.CollectionConverters._
val javaList: java.util.List[String] = scalaList.asJava
```

### 5.4 String Encoding

JPype's `convertStrings=True` flag auto-converts `java.lang.String` to Python `str`, which helps but may cause issues if Scala code expects Java strings in certain contexts.

---

## 6. Risks Specific to This Approach

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| IMain fails to initialize with Snowpark JARs on classpath | Medium | Blocks PoC | Test with minimal classpath first; add JARs incrementally |
| JVM memory pressure (kernel + JVM in same process) | Medium | OOM kills | Set JVM heap limits (`-Xmx512m`); monitor memory |
| JPype version incompatibility with Workspace Python | Low | Blocks install | JPype supports Python 3.8+; Workspace uses 3.11+ |
| Scala compilation errors crash interpreter | Low | Poor UX | IMain handles errors gracefully (returns Error enum) |
| Snowpark JDBC driver conflicts with container's JDBC | Low | Connection failures | Use uber-JAR with isolated classloader |

---

## 7. PoC Validation Checklist

### Phase 1: Raw IMain (Option A)

- [ ] Install OpenJDK 17 via micromamba in Workspace Notebook
- [ ] Install Scala 2.12 via micromamba
- [ ] Download Snowpark uber-JAR via curl
- [ ] `pip install JPype1` in kernel venv
- [ ] Start JVM with `jpype.startJVM()`
- [ ] Instantiate `scala.tools.nsc.interpreter.IMain`
- [ ] Execute `interpreter.interpret("println(1 + 1)")` and capture output
- [ ] Load Snowpark classes: `import com.snowflake.snowpark._`
- [ ] Create Snowpark session with PAT auth
- [ ] Execute `session.sql("SELECT 1").show()`
- [ ] Register `%%scala` magic and test from a notebook cell

### Phase 2: Ammonite Upgrade (Option A2)

- [ ] Install coursier in jvm_env
- [ ] Resolve Ammonite JARs via `cs fetch`
- [ ] Restart JVM with Ammonite JARs on classpath
- [ ] Instantiate Ammonite interpreter via JPype
- [ ] Verify `import $ivy` resolves a Maven dependency
- [ ] Verify `interp.configureCompiler(...)` sets REPL output directory
- [ ] Run Snowflake's official Jupyter setup code verbatim
- [ ] Test UDF creation following SF docs (define + call anonymous UDF)
- [ ] Verify Ammonite kernel classes are addable as session dependencies
