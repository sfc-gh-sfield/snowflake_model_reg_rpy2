# Scala / Snowpark Scala Prototype for Workspace Notebooks

**Status:** Prototype / Proof of Concept — **Working** in Snowflake Workspace Notebooks
**Date:** February 2026
**See also:** `../FEASIBILITY.md`, `../OPTION_A_JPYPE_DEEP_DIVE.md`

---

## Overview

This prototype enables **Scala execution** and **Snowpark Scala** within
Snowflake Workspace Notebooks using `%%scala` and `%scala` cell/line magics.
It follows the same architectural pattern as the R/rpy2 integration:

| Layer | R Solution | Scala Solution (this prototype) |
|-------|-----------|-------------------------------|
| Runtime | R via micromamba | OpenJDK 17 + Scala 2.12 via micromamba |
| Bridge | rpy2 (embeds R in Python) | JPype1 (embeds JVM in Python via JNI) |
| Magic | `%%R` from rpy2 | `%%scala` / `%scala` (custom, in `scala_helpers.py`) |
| REPL | R interpreter | Scala IMain (Ammonite-lite mode) |
| Auth | ADBC + PAT | Snowpark Scala + **SPCS OAuth token** |

---

## File Structure

```
prototype/
├── README.md                              # This file
├── scala_packages.yaml                    # Version configuration
├── setup_scala_environment.sh             # Installation script
├── scala_helpers.py                       # Python helper module
├── pat_manager.py                         # PAT management (external use)
└── workspace_scala_quickstart.ipynb       # Example notebook
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

This installs (~2-4 minutes first time, seconds on subsequent runs):
- **micromamba** (if not already present from R setup)
- **OpenJDK 17** via micromamba
- **coursier** (JVM dependency resolver)
- **Scala 2.12** compiler JARs via coursier
- **Ammonite** REPL JARs via coursier
- **Snowpark 1.18.0** + all transitive dependencies via coursier
- **slf4j-nop** (suppresses SLF4J binding warnings)
- **JPype1** into the kernel's Python venv

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

---

## Magic Flags

The `%%scala` cell magic supports flags modelled on rpy2's `%%R`:

| Flag | Description | Example |
|------|-------------|---------|
| `-i var1,var2` | Push Python variables into Scala before execution | `%%scala -i name,count` |
| `-o var1,var2` | Pull Scala variables back into Python after execution | `%%scala -o result` |
| `--silent` | Suppress REPL variable-binding echo | `%%scala --silent` |
| `--time` | Print wall-clock execution time | `%%scala --time` |

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
%scala println(s"2 + 2 = ${2 + 2}")
```

---

## Authentication

### Inside Workspace Notebooks (SPCS)

Workspace Notebooks run inside SPCS containers. The container provides an
OAuth token at `/snowflake/session/token`. This is the **only** accepted
authentication method — PATs are explicitly blocked from inside SPCS.

`inject_session_credentials()` detects this automatically and sets:
- `SNOWFLAKE_TOKEN` → contents of `/snowflake/session/token`
- `SNOWFLAKE_AUTH_TYPE` → `"oauth"`

These are set as **Java System properties** (not environment variables)
because Java's `System.getenv()` caches the process environment at JVM
startup, making `os.environ` changes invisible to Scala after
`jpype.startJVM()`. Scala reads them via `System.getProperty(key)`.

### Outside Workspace (e.g. local Jupyter)

For external use, create a PAT and set it in the environment:

```python
from pat_manager import PATManager
pat_mgr = PATManager(session)
pat_mgr.create_pat()
```

`inject_session_credentials()` falls back to `os.environ["SNOWFLAKE_PAT"]`
when the SPCS token file is not present.

---

## Cross-language Data Sharing

The Python and Scala Snowpark sessions are **separate Snowflake connections**.
This has important implications:

| Table Type | Visible across sessions? | Use case |
|------------|:---:|---------|
| `TEMPORARY TABLE` | No (session-scoped) | Not suitable for cross-language sharing |
| `TRANSIENT TABLE` | Yes | Recommended for sharing, drop after use |
| Permanent `TABLE` | Yes | Persistent data, standard cleanup needed |

Use `TRANSIENT TABLE` for sharing data between Python and Scala, and drop
it when done to avoid accumulating objects.

---

## Configuration

Edit `scala_packages.yaml` to change versions:

```yaml
java_version: "17"            # OpenJDK version (11 or 17)
scala_version: "2.12"         # Must match Snowpark artifact suffix
snowpark_version: "1.18.0"    # Snowpark Scala version
ammonite_version: "3.0.8"     # Ammonite REPL version
jvm_options:
  - "-Xmx1g"                  # JVM heap (shared with Python process)
  - "-Xms256m"
  - "--add-opens=java.base/java.nio=ALL-UNNAMED"   # Required for Arrow/Java 17
extra_dependencies:
  - "org.slf4j:slf4j-nop:1.7.36"   # Suppress SLF4J binding warning
```

---

## Interpreter Modes

The prototype supports two REPL backends:

| Mode | Description | `import $ivy` | UDF Support |
|------|-------------|:---:|:---:|
| **ammonite-lite** | IMain with Ammonite JARs pre-loaded (default) | Pre-loaded only | Via Settings API |
| **imain** | Raw Scala IMain (fallback) | No | Via Settings API |

Full Ammonite embedding (with runtime `import $ivy`) is a stretch goal.
The current "ammonite-lite" mode pre-loads all JARs at JVM startup and
uses IMain for code evaluation, giving access to Ammonite classes but not
Ammonite's interactive features like dynamic dependency resolution.

---

## Key Learnings

Issues discovered and resolved during prototype development:

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| `System.getenv()` invisible to Scala | Java caches env vars at JVM startup | Use `System.setProperty()` for credentials instead of `os.environ` |
| PAT rejected inside Workspace | SPCS containers require OAuth only | Auto-detect `/snowflake/session/token` and use `oauth` authenticator |
| `MemoryUtil` init failure (Arrow) | Java 17 module system blocks reflective access | Add `--add-opens=java.base/java.nio=ALL-UNNAMED` to JVM options |
| SLF4J binding warning | No SLF4J implementation on classpath | Add `slf4j-nop:1.7.36` to `extra_dependencies` |
| `TEMPORARY TABLE` invisible to Scala | Temp tables are session-scoped | Use `TRANSIENT TABLE` for cross-session sharing |
| `import jpype.imports` needed | JPype's Java import hooks not auto-registered | Call `import jpype.imports` immediately after `jpype.startJVM()` |
| Ammonite snapshot version 404 | Pre-release versions are not on Maven Central | Use stable release `3.0.8` |
| Snowpark uber-JAR 404 | Artifact ID changed to include Scala suffix | Use coursier with `com.snowflake:snowpark_2.12:1.18.0` |
| Scala string interpolation errors | Nested quotes in `s"..."` blocks | Extract SQL results into intermediate `val` bindings |
| Kernel restart not enough | JVM persists in SPCS container process | Full container restart required for JVM option changes |

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
| Separate Snowflake sessions | Python and Scala sessions are independent | Use transient tables for sharing |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Metadata file not found` | Setup script not run | Run `!bash setup_scala_environment.sh` |
| `Failed to start JVM` | JAVA_HOME wrong or JDK not installed | Check `java -version` works |
| `No Scala interpreter initialized` | `setup_scala_environment()` not called | Call it before using `%%scala` |
| `OutOfMemoryError` | JVM heap too small | Increase `-Xmx` in `scala_packages.yaml` |
| `class not found: snowpark` | Snowpark JAR not on classpath | Re-run setup script with `--force` |
| `Failed to initialize MemoryUtil` | Missing `--add-opens` JVM flag | Add flag to `scala_packages.yaml`, restart container |
| `Invalid OAuth access token` | SPCS token expired or PAT used in Workspace | Restart container (refreshes token) |
| `NullPointerException` on session | Credentials not set as System properties | Run `inject_session_credentials(session)` before Scala session |
| `SLF4J: Failed to load class` | No SLF4J binding on classpath | Add `slf4j-nop` to `extra_dependencies`, re-run setup |
| `Object 'X' does not exist` | Temp table from different session | Use `TRANSIENT TABLE` instead of `TEMPORARY TABLE` |

---

## Relationship to R Integration

This prototype reuses infrastructure from the R integration:

- **micromamba** — same installer, can coexist in the same container
- **SPCS OAuth token** — same authentication mechanism (R uses ADBC,
  Scala uses Snowpark JDBC, but both use the SPCS OAuth token)
- **PERSISTENT_DIR** — same persistence strategy applies
- **Architecture pattern** — same "install runtime + bridge + magic" approach

Key difference: R authentication uses ADBC with PAT, while Scala/Snowpark
in Workspace Notebooks **must** use the SPCS OAuth token. This is actually
simpler — no PAT creation needed, the token is injected by the container.
