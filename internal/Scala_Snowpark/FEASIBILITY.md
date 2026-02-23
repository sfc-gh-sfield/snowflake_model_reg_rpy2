# Scala / Snowpark Scala in Snowflake Workspace Notebooks

## Feasibility Study

**Date:** February 2026
**Status:** Research / Feasibility Assessment
**Analogous to:** R integration via rpy2 + `%%R` magic

---

## 1. Objective

Evaluate whether we can replicate the approach used for R (install runtime + bridge library + Jupyter magic) to enable **Scala execution** and **Snowpark Scala** usage within Snowflake Workspace Notebooks, using a `%%scala` cell magic from a Python kernel.

---

## 2. Recap: How the R Approach Works

Our R integration uses a three-layer architecture:

| Layer | R Solution | Purpose |
|-------|-----------|---------|
| **Runtime** | R installed via micromamba into `~/micromamba/envs/r_env` | Language execution environment |
| **Bridge** | rpy2 (pip-installed into kernel venv) | Python-to-R interprocess bridge |
| **Magic** | `%%R` from `rpy2.ipython.rmagic` | Jupyter cell magic for R cells |

The bridge (rpy2) is the critical enabler. It embeds the R interpreter within the Python process via C-level bindings, allowing bidirectional object transfer without serialization overhead.

---

## 3. Workspace Notebook Constraints (Known)

These constraints were learnt during R integration development and apply equally here:

| Constraint | Impact on Scala |
|-----------|----------------|
| **No custom Jupyter kernels** | Cannot install Almond (Scala kernel) as a selectable kernel |
| **Python kernel only** | Must use a magic or bridge from within the Python kernel |
| **Ephemeral user space** | `$HOME` is wiped on restart; everything must be reinstalled (2-5 min) |
| **PERSISTENT_DIR available** | Block storage survives restarts; ideal for JDK/Scala/JARs |
| **No root access** | All installs must be user-space; micromamba works fine for this |
| **linux/amd64** | Standard architecture; JDK and Scala binaries available |
| **pip install allowed** | Can install Python bridge libraries into kernel venv |
| **Outbound HTTP** | Can download JARs from Maven Central, conda-forge, coursier |
| **Limited disk (~2-5 GB usable)** | R + dependencies ~500MB-1.5GB; must budget similarly for JDK+Scala |

---

## 4. What Needs to Be Installed

### 4.1 JVM (Java Development Kit)

Snowpark Scala requires Java 11 or 17.

| Install Method | Size | Pros | Cons |
|---------------|------|------|------|
| `micromamba install openjdk` | ~200-300 MB | Same toolchain as R install; reproducible | Larger than minimal JRE |
| Manual tarball download | ~170 MB | Smaller; more control | More scripting needed |

**Recommendation:** micromamba, consistent with the R approach.

### 4.2 Scala Compiler / Runtime

| Component | Version | Size |
|-----------|---------|------|
| Scala 2.12.x | Required for Snowpark (primary) | ~30 MB |
| Scala 2.13.x | Supported from Snowpark 1.17.0+ (preview) | ~30 MB |

Install via micromamba (`micromamba install -c conda-forge scala`) or coursier.

### 4.3 Snowpark Scala JAR

| Artifact | Size | Source |
|----------|------|--------|
| `snowpark-<version>-with-dependencies.jar` | ~76 MB | Maven Central / Snowflake |

This single JAR contains Snowpark and all transitive dependencies. Can be downloaded via `curl` or coursier.

### 4.4 Python Bridge Library

This is the critical component. See Section 5 for detailed options.

### Total Estimated Disk Footprint

| Component | Size |
|-----------|------|
| OpenJDK 11/17 | ~250 MB |
| Scala 2.12 compiler | ~30 MB |
| Snowpark uber-JAR | ~76 MB |
| Python bridge (JPype or Py4J) | ~5 MB |
| Scala REPL libs (if using embedded interpreter) | ~30 MB |
| **Total** | **~400 MB** |

This is comparable to the R installation footprint and within Workspace Notebook limits.

---

## 5. Snowflake's Official Jupyter Approach (Almond Kernel)

Before evaluating our bridge options, it is important to note that Snowflake's
[official documentation for Snowpark Scala in Jupyter](https://docs.snowflake.com/en/developer-guide/snowpark/scala/quickstart-jupyter)
recommends the **Almond kernel** — a Scala Jupyter kernel built on the **Ammonite REPL**.

The documented workflow looks like this:

```scala
// Ammonite-specific: pull Snowpark from Maven inline
import $ivy.`com.snowflake:snowpark_2.12:1.18.0`
import com.snowflake.snowpark._
import com.snowflake.snowpark.functions._

// REPL class directory (required for UDFs)
val replClassPathObj = os.Path("replClasses", os.pwd)
if (!os.exists(replClassPathObj)) os.makeDir(replClassPathObj)
val replClassPath = replClassPathObj.toString()

// Ammonite-specific compiler configuration
interp.configureCompiler(_.settings.outputDirs.setSingleOutput(replClassPath))
interp.configureCompiler(_.settings.Yreplclassbased)
interp.load.cp(replClassPathObj)

// Create session and register REPL directory for UDF upload
val session = Session.builder.configs(Map(...)).create
session.addDependency(replClassPath)
```

**Why we can't use Almond directly:** Workspace Notebooks only expose a Python
kernel.  We cannot register Almond as a selectable kernel.  But the patterns
above reveal important requirements we must satisfy regardless of which bridge
option we choose:

| Requirement from Official Docs | Implication for Bridge |
|-------------------------------|----------------------|
| `import $ivy` for dependency resolution | Ammonite-specific; raw IMain does not support this |
| `interp.configureCompiler(...)` | Ammonite API; needed for UDF compilation |
| `replClasses` directory | Both IMain and Ammonite need a REPL class output directory |
| `session.addDependency(replClassPath)` | UDF development requires the compiled class directory be registered |
| Ammonite kernel classes as session deps | `ammonite.repl.ReplBridge$`, `ammonite.interp.api.APIHolder`, etc. |

This means any approach we build should either (a) embed Ammonite to match the
official path, or (b) replicate the equivalent configuration in raw IMain. Both
are viable but with different trade-offs.

---

## 6. Python-to-Scala Bridge Options (Analogous to rpy2)

This is the most critical design decision. There is **no single library** that provides the same level of integration as rpy2 does for R. Instead, there are several approaches with different trade-offs.

### Option A: JPype + Embedded Scala IMain (Simplest In-Process)

**Approach:** Use JPype to start a JVM in-process, load the Scala compiler JARs, and embed a raw Scala REPL (`IMain`) that can evaluate arbitrary Scala code strings. Build a custom `%%scala` IPython magic around this.

```
┌─────────────────────────────────────────────────────┐
│  Python Kernel                                      │
│  ┌──────────────┐    ┌───────────────────────────┐  │
│  │  IPython      │    │  JVM (via JPype/JNI)      │  │
│  │  %%scala magic│───►│  ┌─────────────────────┐  │  │
│  │               │    │  │ Scala IMain (REPL)   │  │  │
│  │  Python code  │◄──►│  │  - scala-compiler    │  │  │
│  │               │    │  │  - snowpark JAR       │  │  │
│  └──────────────┘    │  └─────────────────────┘  │  │
│                       └───────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**How it works:**

1. `jpype.startJVM()` starts a JVM within the Python process (shared memory)
2. Load `scala-compiler`, `scala-library`, and `snowpark-with-dependencies.jar` on the classpath
3. Instantiate `scala.tools.nsc.interpreter.IMain` (the Scala REPL interpreter)
4. Configure output directory and compiler settings to mirror the Almond setup
5. The `%%scala` magic sends cell contents to `IMain.interpret(code_string)`
6. Capture output and return it to the notebook cell

**Pros:**
- In-process JVM: fast, shared memory, no serialization for primitives
- JPype is actively maintained and available on pip and conda-forge
- Full Scala REPL capabilities (imports, vals, defs persist across cells)
- Can transfer data between Python and Scala via JPype type conversions
- The Scala `IMain` is the official embeddable interpreter
- Smallest dependency footprint of the in-process options

**Cons:**
- JVM can only be started once per Python session (no restart without kernel restart)
- IMain is a Scala 2.x feature; Scala 3 removed it (fine for Snowpark which uses 2.12/2.13)
- **No `import $ivy`** — dependencies must be pre-loaded on the classpath at JVM start
- **No `interp.configureCompiler`** — must configure IMain's `Settings` object directly (possible but different API)
- Requires building a custom IPython magic (moderate development effort)
- Scala compilation within REPL has warm-up time on first use (~5-10 seconds)
- Error handling and output capture need careful implementation
- JPype's Scala interop can be tricky with Scala-specific bytecode patterns (companion objects, implicits)
- UDFs work but require manual REPL class directory setup (IMain supports `outputDirs` via `Settings`)

**Feasibility: HIGH** - All components are available and proven; requires moderate custom development.

---

### Option A2: JPype + Embedded Ammonite REPL (Recommended)

**Approach:** Same as Option A but embed the **Ammonite** interpreter instead of raw IMain. This gives us the exact same REPL environment that Snowflake's official Jupyter documentation uses, including `import $ivy`, `interp.configureCompiler`, and all Ammonite niceties.

```
┌─────────────────────────────────────────────────────────┐
│  Python Kernel                                          │
│  ┌──────────────┐    ┌─────────────────────────────┐    │
│  │  IPython      │    │  JVM (via JPype/JNI)        │    │
│  │  %%scala magic│───►│  ┌───────────────────────┐  │    │
│  │               │    │  │ Ammonite REPL          │  │    │
│  │  Python code  │◄──►│  │  - import $ivy         │  │    │
│  │               │    │  │  - interp.configure..  │  │    │
│  │               │    │  │  - snowpark JAR         │  │    │
│  └──────────────┘    │  └───────────────────────┘  │    │
│                       └─────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

**How it works:**

1. `jpype.startJVM()` starts a JVM with Ammonite JARs + Scala + Snowpark on the classpath
2. Instantiate Ammonite's `ammonite.Main` or `ammonite.repl.Repl` programmatically via JPype
3. Use Ammonite's `ReplAPI.eval()` to execute code strings
4. Users get the **exact same syntax** as Snowflake's official docs (including `import $ivy`, `interp.*`)
5. The `%%scala` magic wraps Ammonite evaluation with output capture

**Key advantage:** Users can follow Snowflake's official Snowpark Scala Jupyter
documentation almost verbatim. The `import $ivy`, `interp.configureCompiler`,
and `interp.load.cp` calls all work because the underlying REPL is the same
Ammonite engine that the Almond kernel uses.

**Pros:**
- Everything from Option A (in-process, fast, shared memory)
- **`import $ivy` works** — can pull additional Maven dependencies at runtime
- **`interp.configureCompiler` works** — matches Snowflake's documented UDF setup exactly
- Users can copy-paste code from Snowflake's Jupyter docs
- Better pretty-printing and error messages than raw IMain
- Ammonite is actively maintained (version 3.0.x)

**Cons:**
- Everything from Option A re: JVM singleton, Scala 2.x only
- **Larger classpath**: Ammonite pulls additional JARs (~50 MB total for ammonite-repl, ammonite-interp, etc.)
- Ammonite's programmatic embedding API is less documented than IMain's
- Must resolve Ammonite JARs (via coursier or pre-download) during install
- Slightly more complex initialization than raw IMain
- Ammonite's `import $ivy` triggers network requests to Maven Central (needs outbound HTTP)

**Feasibility: HIGH** - Same JPype base as Option A; Ammonite adds a richer REPL at the cost of more JARs. This is the recommended approach because it aligns with Snowflake's documented path.

**Additional disk footprint vs Option A:**

| Component | Size |
|-----------|------|
| Ammonite JARs (ammonite-repl, ammonite-interp, etc.) | ~50 MB |
| Coursier (for resolving Ammonite + runtime deps) | ~20 MB |
| **Total additional** | **~70 MB** |

---

### Option B: Py4J + External Scala Gateway Process (PySpark Pattern)

**Approach:** Start a separate JVM process running a Py4J gateway server with an embedded Scala REPL. The Python side connects via Py4J's socket protocol. This is the architecture PySpark and spylon-kernel used.

```
┌────────────────────┐          ┌──────────────────────────┐
│  Python Kernel     │  TCP/IP  │  JVM Process             │
│  ┌──────────────┐  │  socket  │  ┌────────────────────┐  │
│  │ %%scala magic│──┼─────────►│  │ Py4J GatewayServer │  │
│  │              │  │          │  │ + Scala IMain/REPL  │  │
│  │ Py4J client  │◄─┼──────────│  │ + Snowpark JARs    │  │
│  └──────────────┘  │          │  └────────────────────┘  │
└────────────────────┘          └──────────────────────────┘
```

**How it works:**

1. Start a JVM subprocess running a Py4J `GatewayServer`
2. The gateway exposes a Scala interpreter entry point
3. The `%%scala` magic sends code strings over the socket to be evaluated
4. Results are marshalled back to Python

**Pros:**
- Py4J is well-established (powers PySpark)
- JVM process is isolated; crashes don't take down the Python kernel
- JVM can be restarted independently
- Known architecture pattern (spylon-kernel used exactly this)

**Cons:**
- Data transfer involves serialization over sockets (slower than JPype for large datasets)
- Requires managing a subprocess (lifecycle, cleanup, error propagation)
- Two processes = more memory overhead
- Must build or adapt a gateway server JAR (moderate-to-significant effort)
- spylon-kernel (the reference implementation) is unmaintained since 2018
- Debugging is harder with cross-process communication

**Feasibility: MEDIUM-HIGH** - Proven architecture but more moving parts and the reference implementation is dead.

---

### Option C: Subprocess Execution (Simplest / Limited)

**Approach:** Execute Scala code by writing it to a temporary file and running it via the `scala` command or `java -jar` in a subprocess. Capture stdout/stderr.

```python
# Pseudocode for %%scala magic
def scala_magic(cell_code):
    with tempfile.NamedTemporaryFile(suffix='.scala') as f:
        f.write(cell_code)
        result = subprocess.run(['scala', '-cp', classpath, f.name],
                                capture_output=True)
    return result.stdout
```

**Pros:**
- Simplest to implement
- No bridge library needed
- Complete isolation between Python and Scala
- Each cell is a fresh Scala invocation

**Cons:**
- **No state persistence between cells** (each cell is a fresh process)
- Slow: JVM startup overhead for every cell execution (~3-5 seconds)
- No data sharing between Python and Scala (must use files/serialization)
- No interactive REPL feel
- Cannot build on previous cell definitions
- Not suitable for Snowpark sessions (connection per cell)

**Feasibility: LOW** - Works technically but the UX is too poor for practical use.

---

### Option D: Ammonite REPL via Subprocess (Persistent Session)

**Approach:** Start an Ammonite Scala REPL as a long-running subprocess. Send code to it via stdin/pipes. Ammonite maintains state between evaluations.

**Pros:**
- Ammonite is actively maintained and feature-rich
- State persists across cell evaluations
- Can import Maven dependencies on-the-fly (`import $ivy`)
- Better Scala experience than raw IMain
- Isolation from Python process

**Cons:**
- Pipe-based communication is fragile (output parsing, prompt detection)
- No easy bidirectional data transfer (must serialize via stdout/files)
- Subprocess management complexity
- Ammonite has its own dependency resolution which may conflict with pre-loaded JARs
- Harder to integrate cleanly as a Jupyter magic

**Feasibility: MEDIUM** - Better than raw subprocess but pipe management is error-prone.

---

### Option E: GraalVM Polyglot (Future / Experimental)

**Approach:** Use GraalVM's polyglot capabilities to run Scala and Python in the same runtime with shared objects.

**Pros:**
- True polyglot: share objects without serialization
- Official Oracle-backed technology
- Used by Polynote for multi-language notebooks

**Cons:**
- Would require replacing the Workspace Notebook's Python runtime with GraalPy
- GraalVM is large (~500+ MB)
- Scala on Truffle is not production-ready
- Operator overloading and magic methods have known issues
- Fundamentally changes the runtime environment
- **Not compatible** with the Workspace Notebook's managed Python kernel

**Feasibility: VERY LOW** - Requires replacing the kernel runtime; impractical.

---

## 7. Comparison Matrix

| Criterion | A: JPype + IMain | A2: JPype + Ammonite | B: Py4J + Gateway | C: Subprocess | D: Ammonite Pipe | E: GraalVM |
|-----------|:-:|:-:|:-:|:-:|:-:|:-:|
| **Feasibility** | HIGH | HIGH | MEDIUM-HIGH | LOW | MEDIUM | VERY LOW |
| **Matches SF docs** | Partial | **Full** | Partial | No | Full | No |
| **`import $ivy`** | No | **Yes** | No | No | Yes | N/A |
| **UDF support** | Manual config | **Matches docs** | Manual config | No | Possible | N/A |
| **State across cells** | Yes | Yes | Yes | No | Yes | Yes |
| **Data Python <-> Scala** | Good (shared mem) | Good (shared mem) | OK (serialized) | Poor (files) | Poor (stdout) | Excellent |
| **Performance** | Fast | Fast | Moderate | Slow (JVM start) | Moderate | Fast |
| **Development effort** | Moderate | Moderate | High | Low | Moderate | Very High |
| **Maintenance burden** | Low-Medium | Low-Medium | Medium-High | Low | Medium | High |
| **Snowpark session reuse** | Yes (in-process) | Yes (in-process) | Yes (persistent) | No | Possible | N/A |
| **JVM crash impact** | Kills kernel | Kills kernel | Recoverable | None | Recoverable | Kills kernel |
| **Active dependencies** | JPype (active) | JPype + Ammonite | Py4J (active) | None | Ammonite (active) | GraalVM |
| **Disk footprint (bridge)** | ~5 MB | ~75 MB | ~10 MB | 0 | ~50 MB | ~500+ MB |

---

## 8. Recommended Approach: Option A2 (JPype + Embedded Ammonite)

### 8.1 Why JPype + Ammonite

1. **Matches Snowflake's official docs:** The [Snowpark Scala Jupyter setup guide](https://docs.snowflake.com/en/developer-guide/snowpark/scala/quickstart-jupyter) assumes an Ammonite-based REPL (Almond). By embedding Ammonite, users can follow the official documentation verbatim.
2. **Closest analogy to rpy2:** Just as rpy2 embeds R in the Python process via C bindings, JPype embeds the JVM via JNI. The architecture is directly parallel.
3. **`import $ivy` support:** Users can pull additional Maven dependencies interactively without restarting the JVM — essential for iterative development.
4. **UDF development path:** The `interp.configureCompiler` and `interp.load.cp` calls from Snowflake's docs work because the same Ammonite engine is running.
5. **In-process = fast:** No serialization overhead for calling Scala methods or transferring data.
6. **Proven components:** JPype is actively maintained; Ammonite is actively maintained (v3.0.x).

**Fallback strategy:** If embedding Ammonite via JPype proves too complex, fall back to **Option A** (raw IMain) which is simpler but loses `import $ivy` and requires manual compiler settings. The `%%scala` magic and JPype bridge work identically either way.

### 8.2 Proposed Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                 Snowflake Workspace Notebook                     │
│                    (SPCS Container)                               │
├──────────────────────────────────────────────────────────────────┤
│  ┌──────────────────┐    ┌───────────────────────────────────┐   │
│  │  Python Kernel   │    │   micromamba jvm_env              │   │
│  │  (managed venv)  │    │   - openjdk 11 or 17             │   │
│  │  - JPype1        │    │   - scala 2.12.x                 │   │
│  │  - pandas        │◄──►│                                   │   │
│  │  - snowpark-py   │    │   Downloaded JARs (via coursier): │   │
│  │  - scala_helpers │    │   - snowpark-with-dependencies   │   │
│  │    (custom magic)│    │   - ammonite-repl JARs           │   │
│  └──────────────────┘    │   - scala-compiler/library       │   │
│           │               └───────────────────────────────────┘   │
│           ▼                                                       │
│  ┌──────────────────┐                                            │
│  │ get_active_      │    JVM (in-process via JPype/JNI)          │
│  │ session()        │    ┌───────────────────────────────────┐   │
│  │ (internal OAuth) │    │  Ammonite REPL (interpreter)      │   │
│  └────────┬─────────┘    │  - import $ivy (Maven resolution) │   │
│           │               │  - interp.configureCompiler       │   │
│           │               │  - Snowpark Session               │   │
│           │               │  - User code execution            │   │
│           │               └──────────────┬────────────────────┘   │
└───────────┼──────────────────────────────┼───────────────────────┘
            │                              │
            ▼                              ▼
     ┌──────────────────────────────────────────┐
     │            Snowflake Account              │
     └──────────────────────────────────────────┘
```

### 8.3 Installation Script Outline

Analogous to `setup_r_environment.sh`:

```bash
#!/usr/bin/env bash
# setup_scala_environment.sh

# Step 1: Install micromamba (reuse existing if present from R setup)
# Step 2: Create jvm_env with openjdk and scala
micromamba create -n jvm_env -c conda-forge openjdk=17 scala=2.12

# Step 3: Install coursier (for resolving Ammonite + Snowpark JARs)
curl -fL "https://github.com/coursier/launchers/raw/master/cs-x86_64-pc-linux.gz" \
  | gzip -d > "${ENV_PREFIX}/bin/cs"
chmod +x "${ENV_PREFIX}/bin/cs"

# Step 4: Resolve Ammonite JARs via coursier
cs fetch com.lihaoyi:ammonite_2.12.20:3.0.0 \
  -p > "${JAR_DIR}/ammonite_classpath.txt"

# Step 5: Download Snowpark uber-JAR
SNOWPARK_VERSION="1.18.0"
curl -L -o "${JAR_DIR}/snowpark.jar" \
  "https://repo1.maven.org/maven2/com/snowflake/snowpark/${SNOWPARK_VERSION}/snowpark-${SNOWPARK_VERSION}-bundle.jar"

# Step 6: Set environment variables
export JAVA_HOME="${ENV_PREFIX}"
export PATH="${ENV_PREFIX}/bin:${PATH}"
```

### 8.4 Python Helper Module Outline (`scala_helpers.py`)

Analogous to `r_helpers.py`:

```python
"""
Scala Environment Helpers for Snowflake Workspace Notebooks

Usage:
    from scala_helpers import setup_scala_environment
    setup_scala_environment()

After setup, use %%scala magic in cells:
    %%scala
    import $ivy.`com.snowflake:snowpark_2.12:1.18.0`
    import com.snowflake.snowpark._
    val session = Session.builder.configs(Map(...)).create()
    val df = session.sql("SELECT 1")
    df.show()
"""

import jpype
import jpype.imports
from IPython.core.magic import register_cell_magic

JVM_ENV_PREFIX = "/root/.local/share/mamba/envs/jvm_env"

def setup_scala_environment():
    """Start JVM with Ammonite and register %%scala magic."""
    # Build classpath: Ammonite JARs + Scala + Snowpark
    classpath = build_classpath()

    # Start JVM via JPype
    jpype.startJVM(
        jpype.getDefaultJVMPath(),
        classpath=classpath,
        convertStrings=True
    )

    # Create Ammonite interpreter programmatically
    # ... (instantiate ammonite.Main or ammonite.repl.Repl)

    # Register %%scala magic
    @register_cell_magic
    def scala(line, cell):
        """Execute Scala code in the Ammonite interpreter."""
        result = ammonite_eval(cell)
        # Capture and display output
        return result
```

### 8.5 Snowpark Scala Session Management

The key challenge is creating and managing a Snowpark Scala session. Two approaches:

**Approach A: Via `import $ivy` (Ammonite-native, matches Snowflake docs)**

```scala
// %%scala
// Pull Snowpark from Maven (Ammonite resolves this automatically)
import $ivy.`com.snowflake:snowpark_2.12:1.18.0`
import com.snowflake.snowpark._
import com.snowflake.snowpark.functions._

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
```

**Approach B: Pre-loaded on classpath (works with both IMain and Ammonite)**

If the Snowpark uber-JAR is already on the classpath at JVM startup, `import $ivy` is not needed:

```scala
// %%scala
import com.snowflake.snowpark._
val session = Session.builder.configs(Map(...)).create
```

**Approach C: PAT authentication (like R/ADBC)**

Same PAT-based approach already implemented for R. The PATManager creates the
token from Python; the `SNOWFLAKE_PAT` env var is visible to Scala via
`sys.env`.

---

## 9. Key Risks and Challenges

### 9.1 JVM Singleton Limitation

JPype can only start one JVM per Python process. If the JVM crashes or needs reconfiguration, the entire notebook kernel must restart. This is similar to how rpy2 works with R (R also cannot be restarted within a process), so users familiar with the R workflow will find this expected.

### 9.2 Scala IMain / Ammonite Warm-up

The Scala interpreter (IMain) takes ~5-10 seconds for initial compilation on the first cell execution. Subsequent cells are faster. Mitigation: pre-warm the interpreter during setup.

### 9.3 Snowpark Scala Authentication in SPCS

The same authentication challenges discovered during R/ADBC integration apply:
- The SPCS OAuth token (`/snowflake/session/token`) may not work with the Snowpark Scala JDBC driver
- PAT authentication should work (already proven with ADBC)
- Key pair authentication should also work

### 9.4 Output Capture

Scala/JVM output goes to `System.out`/`System.err`, which JPype can redirect. However, rich output (DataFrames, charts) requires custom formatting—similar to the `rprint()`/`rview()` helpers we built for R.

### 9.5 Data Transfer Between Python and Scala

| Transfer Type | Mechanism | Complexity |
|--------------|-----------|------------|
| Python DataFrame -> Scala | JPype array conversion or Arrow | Medium |
| Scala DataFrame -> Python | Arrow serialization | Medium |
| Scalar values | JPype auto-conversion | Easy |
| Snowpark DataFrames | Both sides query Snowflake directly | Easy (no transfer needed) |

The most practical pattern: both Python Snowpark and Scala Snowpark connect to the same Snowflake account. Data stays in Snowflake; only references (table names, SQL) are shared.

### 9.6 Scala 2 vs Scala 3

The embedded REPL (`IMain`) is a **Scala 2.x** feature. Scala 3 replaced it with a different REPL architecture. Since Snowpark Scala requires Scala 2.12 (with 2.13 in preview), this is not an issue today. However, if Snowpark eventually moves to Scala 3, the REPL approach would need to be revisited.

---

## 10. Development Effort Estimate

| Task | Effort | Notes |
|------|--------|-------|
| Installation script (`setup_scala_environment.sh`) | 1-2 days | Adapt from R script; micromamba + JDK + Scala + coursier + JAR download |
| JPype JVM startup + Ammonite initialization | 2-3 days | Core bridge; output capture; error handling |
| `%%scala` IPython magic implementation | 2-3 days | Magic registration; state management; display |
| Snowpark session management (auth) | 1-2 days | PAT integration; session creation helpers |
| Python <-> Scala data transfer utilities | 2-3 days | DataFrame conversion; variable passing |
| Helper module (`scala_helpers.py`) | 1-2 days | Diagnostics; environment checks; setup function |
| Ammonite embedding PoC & troubleshooting | 2-3 days | Ammonite programmatic API is less documented |
| Testing and documentation | 2-3 days | Notebook examples; edge cases |
| **Total** | **~14-21 days** | |

---

## 11. Comparison with the R Approach

| Aspect | R (rpy2) | Scala (JPype + Ammonite) |
|--------|----------|--------------------------|
| Bridge maturity | rpy2 is 20+ years old, battle-tested | JPype is mature; Ammonite embedding is less common |
| Magic availability | `%%R` is built into rpy2 | Must build custom `%%scala` magic |
| Official SF Jupyter docs | No official R+Jupyter docs | [Snowpark Scala Jupyter guide](https://docs.snowflake.com/en/developer-guide/snowpark/scala/quickstart-jupyter) (uses Almond/Ammonite) |
| Install complexity | micromamba + R + rpy2 | micromamba + JDK + Scala + coursier + JARs + JPype |
| Disk footprint | ~500 MB - 1.5 GB | ~470 MB |
| Setup time | 2-5 minutes | 2-4 minutes (estimated) |
| Data interop | Excellent (rpy2 converters) | Good (JPype type conversion) |
| Community precedent | rpy2 in Jupyter is common | Scala in Python Jupyter is uncommon |
| Snowpark integration | Via ADBC/PAT (external connection) | Via Snowpark Scala JAR (native, `import $ivy`) |
| UDF development | N/A (R UDFs not supported in Snowpark) | Supported (REPL class dir pattern from SF docs) |

---

## 12. Alternative: "Why Not Just Use Snowpark Python?"

It's worth asking: what would motivate using Snowpark Scala in a Workspace Notebook when Snowpark Python is natively available?

**Legitimate use cases for Scala:**

1. **Existing Scala codebases** that teams want to test/prototype in notebooks before deploying
2. **Scala-specific features** not yet available in Snowpark Python
3. **Performance-sensitive UDFs** written in Scala that need interactive development
4. **Java/Scala library integration** (e.g., ML libraries written for JVM)
5. **Polyglot teams** with Scala expertise wanting notebook access
6. **Migration path evaluation** for teams considering Python vs Scala

**When Snowpark Python is sufficient:**

- Most data engineering and ML workflows
- Users without existing Scala investment
- Prototyping and exploration

---

## 13. Recommendation and Next Steps

### Verdict: FEASIBLE with Moderate Effort

The JPype + embedded Ammonite REPL approach (Option A2) is technically feasible,
follows the same architectural pattern as our R/rpy2 integration, and aligns
with Snowflake's official Snowpark Scala Jupyter documentation. The development
effort (~14-21 days) is reasonable.

### Recommended Next Steps

1. **Proof of Concept — Phase 1: Raw IMain (3-5 days)**
   - Install JDK + Scala via micromamba in a Workspace Notebook
   - `pip install JPype1` in the kernel venv
   - Start JVM via JPype and instantiate `scala.tools.nsc.interpreter.IMain`
   - Execute basic Scala code and capture output
   - Load Snowpark uber-JAR and create a session with PAT auth
   - Register a basic `%%scala` magic

2. **Proof of Concept — Phase 2: Ammonite Upgrade (2-3 days)**
   - Install coursier and resolve Ammonite JARs
   - Replace IMain with Ammonite's programmatic API via JPype
   - Verify `import $ivy` and `interp.configureCompiler` work
   - Test UDF development following [Snowflake's Jupyter guide](https://docs.snowflake.com/en/developer-guide/snowpark/scala/quickstart-jupyter)

3. **If Phase 2 succeeds, build out:**
   - `setup_scala_environment.sh` (adapt from R script)
   - `scala_helpers.py` with `setup_scala_environment()` and `%%scala` magic
   - Snowpark session management with PAT auth
   - Example notebook mirroring Snowflake's official examples

4. **If Phase 2 fails (Ammonite embedding too complex):**
   - Stay with Phase 1 (raw IMain) which still provides full Scala execution
   - Pre-load Snowpark JAR on classpath (no `import $ivy` needed)
   - Configure compiler settings via IMain's `Settings` API directly
   - Document which parts of Snowflake's Jupyter docs don't apply

5. **If Phase 1 fails:**
   - Fall back to Option B (Py4J + Gateway) which is more complex but has PySpark as proven reference
   - Document specific failure points for future reference

---

## 14. References

### Snowpark Scala
- [Snowpark Scala Developer Guide](https://docs.snowflake.com/en/developer-guide/snowpark/scala/index)
- [Setting Up Jupyter Notebook for Snowpark Scala](https://docs.snowflake.com/en/developer-guide/snowpark/scala/quickstart-jupyter) — **Key reference:** official Almond/Ammonite-based Jupyter setup
- [Snowpark Scala Prerequisites](https://docs.snowflake.com/en/developer-guide/snowpark/scala/prerequisites)
- [Snowpark Scala Setup](https://docs.snowflake.com/en/developer-guide/snowpark/scala/setup)
- [Maven Central: com.snowflake:snowpark](https://central.sonatype.com/artifact/com.snowflake/snowpark)

### Bridge Libraries
- [JPype Documentation](https://jpype.readthedocs.io/en/latest/userguide.html)
- [Py4J Documentation](https://www.py4j.org/)
- [Scala Embedded REPL (IMain)](https://docs.scala-lang.org/overviews/repl/embedding.html)

### Jupyter / Kernel
- [Almond Scala Kernel](https://almond.sh/)
- [spylon-kernel (archived)](https://github.com/vericast/spylon-kernel)
- [Ammonite REPL](https://ammonite.io/)

### Workspace Notebooks
- [Notebooks in Workspaces](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks-on-spcs)
- [Notebooks on Container Runtime](https://docs.snowflake.com/en/release-notes/2026/other/2026-02-05-notebooks-in-workspaces)

### Internal Documentation
- `internal/R_Integration_Summary_and_Recommendations.md` - R approach reference
- `internal/R_Persistence_Proposal_NotebooksTeam.md` - Persistence strategy (applies to Scala too)
- `internal/micromamb_r_installation.md` - Micromamba patterns
- `internal/spcs_persistent_storage.md` - Storage architecture
