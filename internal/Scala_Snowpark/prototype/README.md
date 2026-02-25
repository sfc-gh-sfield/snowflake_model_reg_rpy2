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

**Language-specific documentation:**
- **[Scala Guide](README_SCALA.md)** — `%%scala` flags, DataFrame interop, UDFs, Spark Connect
- **[Java Guide](README_JAVA.md)** — `%%java` flags, DataFrame interop, UDF magics

---

## File Structure

```
prototype/
├── README.md                              # This file (architecture & shared config)
├── README_SCALA.md                        # Scala-specific guide
├── README_JAVA.md                         # Java-specific guide
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

See [README_SCALA.md](README_SCALA.md) for full Scala coverage.

### 3b. Use %%java (available alongside %%scala)

The same `setup_scala_environment()` call also initializes JShell (JDK 17's
built-in Java REPL) and registers `%%java` / `%java` magics:

```python
%%java
System.out.println("Hello from Java " + System.getProperty("java.version"));
```

See [README_JAVA.md](README_JAVA.md) for full Java coverage.

### 4. Connect to Snowflake

Inside a Workspace Notebook, the SPCS OAuth token at
`/snowflake/session/token` is detected automatically — **no PAT needed**.

```python
from snowflake.snowpark.context import get_active_session
from scala_helpers import inject_session_credentials

session = get_active_session()
inject_session_credentials(session)
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
| JShell in-memory classloader | JShell compiles to memory, not disk | SQL inline UDFs / `%%java_udf` magic extracts source from snippet history |

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
