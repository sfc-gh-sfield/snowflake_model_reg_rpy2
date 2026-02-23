# Scala / Snowpark Scala Prototype for Workspace Notebooks

**Status:** Prototype / Proof of Concept
**Date:** February 2026
**See also:** `../FEASIBILITY.md`, `../OPTION_A_JPYPE_DEEP_DIVE.md`

---

## Overview

This prototype enables **Scala execution** and **Snowpark Scala** within
Snowflake Workspace Notebooks using a `%%scala` cell magic. It follows
the same architectural pattern as the R/rpy2 integration:

| Layer | R Solution | Scala Solution (this prototype) |
|-------|-----------|-------------------------------|
| Runtime | R via micromamba | OpenJDK + Scala via micromamba |
| Bridge | rpy2 (embeds R in Python) | JPype1 (embeds JVM in Python) |
| Magic | `%%R` from rpy2 | `%%scala` (custom, in `scala_helpers.py`) |
| REPL | R interpreter | Scala IMain / Ammonite |
| Snowflake | ADBC + PAT | Snowpark Scala JAR + PAT |

---

## File Structure

```
prototype/
├── README.md                              # This file
├── scala_packages.yaml                    # Version configuration
├── setup_scala_environment.sh             # Installation script
├── scala_helpers.py                       # Python helper module
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
- **Snowpark** uber-JAR from Maven Central
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

### 4. Connect to Snowflake (optional)

```python
from snowflake.snowpark.context import get_active_session
from scala_helpers import inject_session_credentials

session = get_active_session()
inject_session_credentials(session)

# Create PAT for Scala/Snowpark authentication
from pat_manager import PATManager
PATManager(session).create_pat(days_to_expiry=1, force_recreate=True)
```

```python
%%scala
import com.snowflake.snowpark._

val sf = Session.builder.configs(Map(
  "URL"           -> sys.props("SNOWFLAKE_URL"),
  "USER"          -> sys.props("SNOWFLAKE_USER"),
  "ROLE"          -> sys.props("SNOWFLAKE_ROLE"),
  "DB"            -> sys.props("SNOWFLAKE_DATABASE"),
  "SCHEMA"        -> sys.props("SNOWFLAKE_SCHEMA"),
  "WAREHOUSE"     -> sys.props("SNOWFLAKE_WAREHOUSE"),
  "TOKEN"         -> sys.props("SNOWFLAKE_PAT"),
  "AUTHENTICATOR" -> "oauth"
)).create

sf.sql("SELECT CURRENT_USER(), CURRENT_ROLE()").show()
```

---

## Configuration

Edit `scala_packages.yaml` to change versions:

```yaml
java_version: "17"            # OpenJDK version
scala_version: "2.12"         # Must match Snowpark artifact
snowpark_version: "1.18.0"    # Snowpark Scala version
ammonite_version: "3.0.8"
jvm_options:
  - "-Xmx1g"                  # JVM heap (shared with Python process)
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

## Known Limitations (Prototype)

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| JVM cannot be restarted | Must restart kernel to change classpath | Inherent to JNI |
| First cell is slow (~5-10s) | Scala compiler warm-up | Pre-warm during setup |
| No `import $ivy` at runtime | Must pre-load JARs via setup script | Full Ammonite embedding |
| Output formatting | Raw text, no rich display | Build `sprint()` helpers like R |
| Ephemeral install | Reinstall on kernel restart | Use `PERSISTENT_DIR` |
| Ammonite API undocumented | "ammonite-lite" mode as workaround | Investigate Ammonite `Main` API |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Metadata file not found` | Setup script not run | Run `!bash setup_scala_environment.sh` |
| `Failed to start JVM` | JAVA_HOME wrong or JDK not installed | Check `java -version` works |
| `No Scala interpreter initialized` | `setup_scala_environment()` not called | Call it before using `%%scala` |
| `OutOfMemoryError` | JVM heap too small | Increase `-Xmx` in `scala_packages.yaml` |
| `class not found: snowpark` | Snowpark JAR not on classpath | Re-run setup script with `--force` |

---

## Relationship to R Integration

This prototype reuses infrastructure from the R integration:

- **micromamba** — same installer, can coexist in the same container
- **PATManager** — same PAT authentication (from `r_helpers.py`)
- **PERSISTENT_DIR** — same persistence strategy applies
- **Architecture pattern** — same "install runtime + bridge + magic" approach
