"""
Scala Environment Helpers for Snowflake Workspace Notebooks

This module provides:
- JVM startup via JPype (in-process, shared memory)
- Scala REPL initialization (IMain or Ammonite)
- %%scala cell magic and %scala line magic for Scala execution
- -i / -o flags for Python <-> Scala variable transfer
- Automatic Snowpark DataFrame interop via SQL plan transfer
- Snowpark session credential injection (SPCS OAuth + PAT fallback)
- Snowpark Connect for Scala (opt-in): local Spark Connect gRPC server
  + Scala SparkSession bound as `spark` in %%scala cells
- Environment diagnostics

Architecture:
    Python Kernel  <-->  JVM (in-process via JPype/JNI)
                            - Scala IMain or Ammonite REPL
                            - Snowpark Scala session
                            - User Scala code execution

Usage:
    from scala_helpers import setup_scala_environment

    result = setup_scala_environment()

    # Then in notebook cells:
    # %%scala
    # val x = 42
    # println(s"The answer is $x")

    # Single-line:
    # %scala println("Hello!")

    # With variable transfer (like rpy2's %%R -i / -o):
    # %%scala -i count -o total
    # val total = (1 to count.asInstanceOf[Int]).sum

    # Snowpark DataFrame interop (auto-detected):
    # py_df = session.table("my_table")   # Python Snowpark DF
    # %%scala -i py_df -o result_df
    # val result_df = py_df.filter(col("id") > 10)
    # # result_df is now a Snowpark Python DataFrame in the notebook

After setup with Snowpark session:
    from scala_helpers import inject_session_credentials
    inject_session_credentials(session)

    # %%scala
    # import com.snowflake.snowpark._
    # val sf = Session.builder.configs(Map(
    #   "URL" -> System.getProperty("SNOWFLAKE_URL"), ...
    # )).create
    # sf.sql("SELECT CURRENT_USER()").show()
"""

import os
import sys
import json
import subprocess
import shutil
from typing import Optional, Dict, Any, Tuple, List


# =============================================================================
# Configuration
# =============================================================================

DEFAULT_JAR_DIR = os.path.expanduser("~/scala_jars")
DEFAULT_METADATA_FILE = os.path.join(DEFAULT_JAR_DIR, "scala_env_metadata.json")
DEFAULT_JVM_ENV_PREFIX = os.path.expanduser("~/micromamba/envs/jvm_env")

# Populated after setup
_scala_state = {
    "jvm_started": False,
    "interpreter": None,
    "interpreter_type": None,  # "imain" or "ammonite"
    "output_stream": None,
    "magic_registered": False,
    "metadata": None,
}


# =============================================================================
# Environment Setup
# =============================================================================

def setup_scala_environment(
    register_magic: bool = True,
    prefer_ammonite: bool = True,
    install_jpype: bool = True,
    metadata_file: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Configure the Python environment for Scala execution via JPype.

    This function:
    1. Loads environment metadata from the setup script
    2. Sets JAVA_HOME and PATH
    3. Installs JPype if needed
    4. Starts the JVM with the correct classpath
    5. Initializes a Scala REPL (Ammonite or IMain)
    6. Registers the %%scala IPython magic

    Args:
        register_magic: Whether to register the %%scala magic (default: True)
        prefer_ammonite: Try Ammonite first, fall back to IMain (default: True)
        install_jpype: Whether to pip-install JPype1 if missing (default: True)
        metadata_file: Path to scala_env_metadata.json (default: auto-detect)

    Returns:
        Dict with setup status and details
    """
    result = {
        "success": False,
        "java_home": None,
        "java_version": None,
        "scala_version": None,
        "interpreter_type": None,
        "jpype_installed": False,
        "jvm_started": False,
        "magic_registered": False,
        "spark_connect_enabled": False,
        "errors": [],
    }

    # --- Load metadata ---
    meta_path = metadata_file or DEFAULT_METADATA_FILE
    metadata = _load_metadata(meta_path)
    if metadata is None:
        result["errors"].append(
            f"Metadata file not found at {meta_path}. "
            "Run 'bash setup_scala_environment.sh' first."
        )
        return result

    _scala_state["metadata"] = metadata
    result["java_home"] = metadata.get("java_home")
    result["scala_version"] = metadata.get("scala_full_version") or metadata.get("scala_version")

    # --- Set environment variables ---
    env_prefix = metadata["env_prefix"]
    os.environ["JAVA_HOME"] = metadata["java_home"]
    os.environ["PATH"] = f"{env_prefix}/bin:" + os.environ.get("PATH", "")

    # Verify Java
    java_path = shutil.which("java")
    if not java_path:
        result["errors"].append("Java binary not found in PATH after configuration")
        return result

    try:
        java_ver = subprocess.run(
            ["java", "-version"], capture_output=True, text=True, timeout=10
        )
        result["java_version"] = java_ver.stderr.split("\n")[0]
    except Exception as e:
        result["errors"].append(f"Failed to get Java version: {e}")

    # --- Install JPype ---
    if install_jpype:
        try:
            import jpype
        except ImportError:
            try:
                subprocess.run(
                    [sys.executable, "-m", "pip", "install", "JPype1", "-q"],
                    check=True, capture_output=True, timeout=120,
                )
            except Exception as e:
                result["errors"].append(f"Failed to install JPype1: {e}")
                return result

    try:
        import jpype  # noqa: F811
        result["jpype_installed"] = True
    except ImportError:
        result["errors"].append(
            "JPype1 not available after install attempt"
        )
        return result

    # --- Set JAVA_TOOL_OPTIONS (must happen before any JVM start) ---
    # When Spark Connect is enabled, spc.start_session() may start the JVM
    # before our jpype.startJVM() call. JAVA_TOOL_OPTIONS ensures --add-opens
    # flags are applied regardless of who triggers JVM startup.
    _add_opens = [
        "--add-opens=java.base/java.nio=ALL-UNNAMED",
        "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED",
        "--add-opens=java.base/java.lang=ALL-UNNAMED",
        "--add-opens=java.base/java.util=ALL-UNNAMED",
    ]
    os.environ["JAVA_TOOL_OPTIONS"] = " ".join(_add_opens)

    # --- Start JVM ---
    if not jpype.isJVMStarted():
        try:
            classpath = _build_classpath(metadata, include_ammonite=prefer_ammonite)
            jvm_options = _resolve_jvm_options(metadata)
            result["jvm_options"] = jvm_options

            jpype.startJVM(
                jpype.getDefaultJVMPath(),
                *jvm_options,
                classpath=classpath,
                convertStrings=True,
            )
            import jpype.imports  # noqa: F811 — registers Java import hooks
            _scala_state["jvm_started"] = True
            result["jvm_started"] = True
        except Exception as e:
            result["errors"].append(f"Failed to start JVM: {e}")
            return result
    else:
        _scala_state["jvm_started"] = True
        result["jvm_started"] = True

    # --- Initialize Scala interpreter ---
    if prefer_ammonite and _has_ammonite_jars(metadata):
        try:
            _init_ammonite(metadata)
            result["interpreter_type"] = "ammonite"
        except Exception as e:
            result["errors"].append(
                f"Ammonite init failed ({e}); falling back to IMain"
            )
            try:
                _init_imain(metadata)
                result["interpreter_type"] = "imain"
                # Clear the non-fatal Ammonite error
                result["errors"] = [
                    err for err in result["errors"]
                    if "Ammonite init failed" not in err
                ]
            except Exception as e2:
                result["errors"].append(f"IMain init also failed: {e2}")
                return result
    else:
        try:
            _init_imain(metadata)
            result["interpreter_type"] = "imain"
        except Exception as e:
            result["errors"].append(f"IMain init failed: {e}")
            return result

    # --- Register magic ---
    if register_magic:
        try:
            _register_scala_magic()
            result["magic_registered"] = True
            _scala_state["magic_registered"] = True
        except Exception as e:
            result["errors"].append(f"Failed to register %%scala magic: {e}")

    result["spark_connect_enabled"] = metadata.get("spark_connect_enabled", False)
    result["success"] = len(result["errors"]) == 0
    return result


# =============================================================================
# JVM Heap Sizing
# =============================================================================

def _detect_total_memory_mb() -> Optional[int]:
    """Read total physical memory from /proc/meminfo (Linux only)."""
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) // 1024  # kB -> MB
    except (OSError, ValueError):
        pass
    return None


def _compute_heap_size(
    fraction: float = 0.25,
    min_mb: int = 1024,
    max_mb: int = 4096,
) -> str:
    """
    Compute a JVM -Xmx heap size as a fraction of total system RAM.

    The JVM shares the process with Python + Scala compiler +
    Snowpark, so we default to 25% of total memory, clamped
    between 1GB and 4GB.

    Returns:
        Heap string like "2g" or "1536m"
    """
    total = _detect_total_memory_mb()
    if total is None:
        return f"{min_mb}m"

    heap_mb = int(total * fraction)
    heap_mb = max(min_mb, min(heap_mb, max_mb))

    if heap_mb >= 1024 and heap_mb % 1024 == 0:
        return f"{heap_mb // 1024}g"
    return f"{heap_mb}m"


def _resolve_jvm_options(metadata: Dict[str, Any]) -> List[str]:
    """
    Build the final JVM option list from metadata, resolving any
    'auto' heap sizing.
    """
    opts = metadata.get("jvm_options", [
        "--add-opens=java.base/java.nio=ALL-UNNAMED",
    ])

    heap_setting = metadata.get("jvm_heap", "auto")

    has_xmx = any(o.startswith("-Xmx") for o in opts)

    if heap_setting == "auto" and not has_xmx:
        heap = _compute_heap_size()
        opts = [f"-Xmx{heap}"] + opts
    elif heap_setting != "auto" and not has_xmx:
        opts = [f"-Xmx{heap_setting}"] + opts

    return opts


# =============================================================================
# Metadata & Classpath
# =============================================================================

def _load_metadata(path: str) -> Optional[Dict[str, Any]]:
    """Load the environment metadata JSON written by the setup script."""
    if not os.path.isfile(path):
        return None
    with open(path, "r") as f:
        return json.load(f)


def _read_classpath_file(path: str) -> List[str]:
    """Read a colon-separated classpath file into a list of paths."""
    if not path or not os.path.isfile(path):
        return []
    with open(path, "r") as f:
        content = f.read().strip()
    if not content:
        return []
    return [p for p in content.split(":") if p and os.path.exists(p)]


def _build_classpath(
    metadata: Dict[str, Any], include_ammonite: bool = True
) -> List[str]:
    """Build the full classpath from metadata files."""
    cp = []

    # Scala compiler/library
    cp.extend(_read_classpath_file(metadata.get("scala_classpath_file", "")))

    # Ammonite (if requested and available)
    if include_ammonite:
        cp.extend(_read_classpath_file(metadata.get("ammonite_classpath_file", "")))

    # Snowpark and its transitive dependencies
    cp.extend(_read_classpath_file(metadata.get("snowpark_classpath_file", "")))

    # Extra dependencies
    cp.extend(_read_classpath_file(metadata.get("extra_classpath_file", "")))

    # Spark Connect client JARs (opt-in)
    if metadata.get("spark_connect_enabled"):
        cp.extend(_read_classpath_file(
            metadata.get("spark_connect_classpath_file", "")
        ))

    return cp


def _has_ammonite_jars(metadata: Dict[str, Any]) -> bool:
    """Check whether Ammonite JARs were resolved during setup."""
    amm_file = metadata.get("ammonite_classpath_file", "")
    if not amm_file or not os.path.isfile(amm_file):
        return False
    with open(amm_file, "r") as f:
        content = f.read().strip()
    return len(content) > 10  # non-empty classpath


# =============================================================================
# Scala Interpreter: IMain (Option A)
# =============================================================================

def _init_imain(metadata: Dict[str, Any]) -> None:
    """Initialize the Scala IMain interpreter via JPype."""
    import jpype

    from java.io import PrintWriter, ByteArrayOutputStream
    Settings = jpype.JClass("scala.tools.nsc.Settings")
    IMain = jpype.JClass("scala.tools.nsc.interpreter.IMain")

    settings = Settings()
    settings.usejavacp().tryToSetFromPropertyValue("true")

    # Configure REPL class output directory for UDF support
    repl_class_dir = os.path.join(
        metadata.get("jar_dir", DEFAULT_JAR_DIR), "replClasses"
    )
    os.makedirs(repl_class_dir, exist_ok=True)

    output_stream = ByteArrayOutputStream()
    print_writer = PrintWriter(output_stream, True)

    interpreter = IMain(settings, print_writer)

    _scala_state["interpreter"] = interpreter
    _scala_state["interpreter_type"] = "imain"
    _scala_state["output_stream"] = output_stream
    _scala_state["_repl_class_dir"] = repl_class_dir

    # Warm up the interpreter (first compilation is slow)
    _execute_scala_imain('println("IMain ready")')


def _execute_scala_imain(code: str) -> Tuple[bool, str, str]:
    """
    Execute Scala code via IMain.

    Returns:
        (success, stdout_output, error_output)
    """
    import jpype

    interpreter = _scala_state["interpreter"]
    output_stream = _scala_state["output_stream"]

    # Capture System.out/System.err for println output
    from java.io import ByteArrayOutputStream as BAOS, PrintStream
    old_out = jpype.JClass("java.lang.System").out
    old_err = jpype.JClass("java.lang.System").err
    sys_out_capture = BAOS()
    sys_err_capture = BAOS()
    jpype.JClass("java.lang.System").setOut(PrintStream(sys_out_capture, True))
    jpype.JClass("java.lang.System").setErr(PrintStream(sys_err_capture, True))

    try:
        output_stream.reset()
        result = interpreter.interpret(code)
        result_str = str(result)
        success = "Success" in result_str
    finally:
        jpype.JClass("java.lang.System").setOut(old_out)
        jpype.JClass("java.lang.System").setErr(old_err)

    repl_output = str(output_stream.toString()).strip()
    stdout_text = str(sys_out_capture.toString()).strip()
    stderr_text = str(sys_err_capture.toString()).strip()

    # Combine all output sources
    parts = []
    if stdout_text:
        parts.append(stdout_text)
    if repl_output:
        parts.append(repl_output)
    combined = "\n".join(parts)

    return success, combined, stderr_text


# =============================================================================
# Scala Interpreter: Ammonite (Option A2)
# =============================================================================

def _init_ammonite(metadata: Dict[str, Any]) -> None:
    """
    Initialize the Ammonite REPL interpreter via JPype.

    Ammonite's programmatic embedding API is less documented than IMain's.
    This function attempts several initialization strategies.
    """
    import jpype

    # Strategy: Use Ammonite's Main class to create an interpreter.
    # The exact API depends on the Ammonite version.
    #
    # Ammonite 3.x provides ammonite.Main with methods:
    #   - Main.main(args) — CLI entry point (not useful for embedding)
    #   - Instantiate via constructor and use runCode/runScript
    #
    # Alternatively, we can access the underlying IMain that Ammonite wraps
    # and use it directly, getting the best of both worlds.

    try:
        jpype.JClass("ammonite.Main")
    except Exception:
        raise RuntimeError(
            "Ammonite classes not found on classpath. "
            "Ensure Ammonite JARs were resolved by setup."
        )

    # Ammonite's Main has various static factory methods and constructors.
    # We try to create a headless instance suitable for programmatic use.
    #
    # For the prototype, we use a pragmatic approach:
    # 1. Try to instantiate Ammonite's Main and call its run* methods
    # 2. If that fails, extract the underlying Scala IMain from Ammonite
    # 3. Last resort: fall back to plain IMain

    # Attempt: Use ammonite.main.Scripts or ammonite.interp.Interpreter
    # Pragmatic approach: Use IMain but with Ammonite JARs on the
    # classpath so that Ammonite classes are accessible. This is
    # "ammonite-lite" — IMain + pre-loaded Ammonite/Snowpark JARs.
    # Full Ammonite embedding (runtime import $ivy) is a stretch goal.
    try:
        _init_imain(metadata)
        _scala_state["interpreter_type"] = "ammonite-lite"

        snowpark_cp = metadata.get("snowpark_classpath_file", "")
        if snowpark_cp and os.path.isfile(snowpark_cp):
            _execute_scala_imain(
                "import com.snowflake.snowpark._\n"
                "import com.snowflake.snowpark.functions._"
            )
        return

    except Exception as e:
        raise RuntimeError(
            f"Ammonite-lite initialization failed: {e}"
        )


# =============================================================================
# Unified Execution Interface
# =============================================================================

def execute_scala(code: str) -> Tuple[bool, str, str]:
    """
    Execute Scala code in the active interpreter.

    Returns:
        (success, output, errors)
    """
    itype = _scala_state.get("interpreter_type")
    if itype in ("imain", "ammonite-lite"):
        return _execute_scala_imain(code)
    elif itype == "ammonite":
        # Full Ammonite — use its eval API
        return _execute_scala_imain(code)  # same for now
    else:
        return False, "", "No Scala interpreter initialized. Call setup_scala_environment() first."


# =============================================================================
# %%scala IPython Magic
# =============================================================================

def _parse_magic_args(line: str) -> Dict[str, Any]:
    """
    Parse flags from the ``%%scala`` / ``%scala`` magic line.

    Supported flags (modelled on rpy2's ``%%R``):
        -i var1,var2    Push Python variables into Scala before execution
        -o var1,var2    Pull Scala variables back into Python after execution
        --silent        Suppress REPL variable-binding echo
        --time          Print wall-clock execution time

    Returns:
        Dict with keys: inputs, outputs, silent, show_time
    """
    import shlex

    args: Dict[str, Any] = {
        "inputs": [],
        "outputs": [],
        "silent": False,
        "show_time": False,
    }

    try:
        tokens = shlex.split(line)
    except ValueError:
        tokens = line.split()

    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-i" and i + 1 < len(tokens):
            args["inputs"].extend(
                v.strip() for v in tokens[i + 1].split(",") if v.strip()
            )
            i += 2
        elif tok == "-o" and i + 1 < len(tokens):
            args["outputs"].extend(
                v.strip() for v in tokens[i + 1].split(",") if v.strip()
            )
            i += 2
        elif tok == "--silent":
            args["silent"] = True
            i += 1
        elif tok == "--time":
            args["show_time"] = True
            i += 1
        else:
            i += 1

    return args


def _push_inputs(names: List[str]) -> None:
    """Push Python variables into the Scala interpreter by name.

    Snowpark Python DataFrames are detected automatically and transferred
    via their SQL query plan (no data materialisation).
    """
    ip = get_ipython()  # type: ignore[name-defined]  # noqa: F821
    for name in names:
        if name not in ip.user_ns:
            print(
                f"Warning: Python variable '{name}' not found, skipping",
                file=sys.stderr,
            )
            continue

        value = ip.user_ns[name]
        if _is_snowpark_python_df(value):
            _push_snowpark_df(name, value)
        else:
            push_to_scala(name, value)


def _pull_outputs(names: List[str]) -> None:
    """Pull Scala variables back into the Python namespace.

    If a Scala variable is a Snowpark DataFrame, it is transferred via
    its SQL query plan and materialised as a Snowpark Python DataFrame.
    """
    ip = get_ipython()  # type: ignore[name-defined]  # noqa: F821
    for name in names:
        if _is_snowpark_scala_df(name):
            py_df = _pull_snowpark_df(name)
            if py_df is not None:
                ip.user_ns[name] = py_df
                continue

        val = pull_from_scala(name)
        if val is None:
            print(f"Warning: Scala variable '{name}' not found, skipping",
                  file=sys.stderr)
        else:
            ip.user_ns[name] = val


def _register_scala_magic() -> None:
    """Register the ``%%scala`` cell magic and ``%scala`` line magic."""
    try:
        get_ipython()  # type: ignore[name-defined]  # noqa: F841
    except NameError:
        raise RuntimeError("Not in an IPython environment")

    from IPython.core.magic import register_cell_magic, register_line_magic

    @register_cell_magic
    def scala(line, cell):
        """
        Execute Scala code in the embedded JVM interpreter.

        Usage:
            %%scala
            val x = 42
            println(s"The answer is $x")

        Flags (on the %%scala line):
            -i var1,var2   Push Python variables into Scala before execution
            -o var1,var2   Pull Scala variables into Python after execution
            --silent       Suppress REPL variable-binding output
            --time         Print execution time

        Examples:
            %%scala -i df_name -o result --time
            val total = df_name.toInt + 10
            val result = total * 2
            println(s"result = $result")
        """
        import time

        args = _parse_magic_args(line)

        if args["inputs"]:
            _push_inputs(args["inputs"])

        t0 = time.time()
        success, output, errors = execute_scala(cell)
        elapsed = time.time() - t0

        if output and not args["silent"]:
            print(output)
        if errors:
            print(errors, file=sys.stderr)
        if not success and not errors:
            print("Scala execution failed (no error details captured)",
                  file=sys.stderr)

        if success and args["outputs"]:
            _pull_outputs(args["outputs"])

        if args["show_time"]:
            print(f"\n[Scala cell executed in {elapsed:.2f}s]")

    @register_line_magic
    def scala(line):  # noqa: F811 — intentional re-use of name for %scala
        """
        Execute a single line of Scala code.

        Usage:
            %scala println("Hello from Scala!")
            %scala val x = 42
        """
        if not line.strip():
            print("Usage: %scala <scala expression>", file=sys.stderr)
            return

        success, output, errors = execute_scala(line)
        if output:
            print(output)
        if errors:
            print(errors, file=sys.stderr)
        if not success and not errors:
            print("Scala execution failed (no error details captured)",
                  file=sys.stderr)

    _scala_state["magic_registered"] = True


# =============================================================================
# Snowpark Session Management
# =============================================================================

def inject_session_credentials(session) -> Dict[str, str]:
    """
    Extract credentials from a Python Snowpark session and make them
    available to Scala code via Java System properties.

    Java's System.getenv() caches the process environment at JVM
    startup, so os.environ changes made after jpype.startJVM() are
    invisible to Scala's sys.env(). We therefore also set Java System
    properties via System.setProperty(), which Scala reads as
    sys.props("key").

    Args:
        session: Active Snowpark Python session

    Returns:
        Dict of credential names to values that were set
    """
    _scala_state["python_session"] = session

    creds = {}

    def _safe_get(fn, strip_quotes=True):
        try:
            val = fn()
            if strip_quotes and val:
                val = val.strip('"')
            return val or ""
        except Exception:
            return ""

    creds["SNOWFLAKE_ACCOUNT"] = _safe_get(
        lambda: session.sql(
            "SELECT CURRENT_ACCOUNT()"
        ).collect()[0][0]
    )
    creds["SNOWFLAKE_USER"] = _safe_get(
        lambda: session.sql(
            "SELECT CURRENT_USER()"
        ).collect()[0][0]
    )
    creds["SNOWFLAKE_ROLE"] = _safe_get(
        session.get_current_role
    )
    creds["SNOWFLAKE_DATABASE"] = _safe_get(
        session.get_current_database
    )
    creds["SNOWFLAKE_SCHEMA"] = _safe_get(
        session.get_current_schema
    )
    creds["SNOWFLAKE_WAREHOUSE"] = _safe_get(
        session.get_current_warehouse
    )

    account = creds["SNOWFLAKE_ACCOUNT"]
    if account:
        host = os.environ.get("SNOWFLAKE_HOST", "")
        if host:
            creds["SNOWFLAKE_URL"] = f"https://{host}"
        else:
            creds["SNOWFLAKE_URL"] = (
                f"https://{account}.snowflakecomputing.com"
            )

    # Authentication token: inside SPCS (Workspace Notebooks) we must
    # use the container's OAuth token; PAT is blocked from inside SPCS.
    spcs_token_path = "/snowflake/session/token"
    if os.path.isfile(spcs_token_path):
        with open(spcs_token_path) as f:
            creds["SNOWFLAKE_TOKEN"] = f.read().strip()
        creds["SNOWFLAKE_AUTH_TYPE"] = "oauth"
    else:
        pat = os.environ.get("SNOWFLAKE_PAT", "")
        if pat:
            creds["SNOWFLAKE_TOKEN"] = pat
            creds["SNOWFLAKE_AUTH_TYPE"] = (
                "programmatic_access_token"
            )

    # Set in Python os.environ (for Python-side reads)
    for key, val in creds.items():
        if val:
            os.environ[key] = val

    # Set as Java System properties so Scala can read them
    # via sys.props("SNOWFLAKE_URL") etc., bypassing the
    # cached System.getenv() map.
    try:
        import jpype
        if jpype.isJVMStarted():
            System = jpype.JClass("java.lang.System")
            for key, val in creds.items():
                if val:
                    System.setProperty(key, val)
    except Exception:
        pass

    return creds


def create_snowpark_scala_session_code() -> str:
    """
    Generate Scala code to create a Snowpark session using credentials
    from Java System properties (set by inject_session_credentials).

    Authentication is determined automatically:
    - Inside SPCS/Workspace: uses the container's OAuth token
    - External: uses PAT with programmatic_access_token authenticator

    Returns:
        Scala code string ready for %%scala execution
    """
    auth_config = (
        '  "TOKEN"         -> prop("SNOWFLAKE_TOKEN"),\n'
        '  "AUTHENTICATOR" -> prop("SNOWFLAKE_AUTH_TYPE")'
    )

    return (
        "import com.snowflake.snowpark._\n"
        "import com.snowflake.snowpark.functions._\n"
        "\n"
        "def prop(k: String): String = {\n"
        "  val v = System.getProperty(k)\n"
        "  require(v != null, "
        's"Java System property \'$k\' not set. '
        "Run inject_session_credentials(session) first.\")\n"
        "  v\n"
        "}\n"
        "\n"
        "val sfSession = Session.builder.configs(Map(\n"
        '  "URL"       -> prop("SNOWFLAKE_URL"),\n'
        '  "USER"      -> prop("SNOWFLAKE_USER"),\n'
        '  "ROLE"      -> prop("SNOWFLAKE_ROLE"),\n'
        '  "DB"        -> prop("SNOWFLAKE_DATABASE"),\n'
        '  "SCHEMA"    -> prop("SNOWFLAKE_SCHEMA"),\n'
        '  "WAREHOUSE" -> prop("SNOWFLAKE_WAREHOUSE"),\n'
        f"  {auth_config}\n"
        ")).create\n"
        "\n"
        'println("Snowpark Scala session created")\n'
        "val _user = sfSession.sql("
        '"SELECT CURRENT_USER()")'
        ".collect()(0).getString(0)\n"
        "val _role = sfSession.sql("
        '"SELECT CURRENT_ROLE()")'
        ".collect()(0).getString(0)\n"
        "val _db = sfSession.sql("
        '"SELECT CURRENT_DATABASE()")'
        ".collect()(0).getString(0)\n"
        'println(s"  User:      ${_user}")\n'
        'println(s"  Role:      ${_role}")\n'
        'println(s"  Database:  ${_db}")\n'
    )


# =============================================================================
# Spark Connect (opt-in)
# =============================================================================

def setup_spark_connect(
    session,
    port: int = 15002,
    timeout: int = 30,
) -> Dict[str, Any]:
    """
    Start a local Spark Connect gRPC server and create a Scala SparkSession.

    The server runs in a background thread, consumes the Workspace's Snowpark
    session (SPCS OAuth), and proxies requests to Snowflake. The Scala
    SparkSession connects to sc://localhost:<port> and is bound as ``spark``
    in the REPL so %%scala cells can use ``spark.sql(...)``.

    Args:
        session: Active Snowpark Python session (for auth)
        port: gRPC server port (default: 15002)
        timeout: Seconds to wait for server startup

    Returns:
        Dict with setup status and details
    """
    import socket
    import threading

    result = {
        "success": False,
        "server_port": port,
        "pyspark_version": None,
        "scala_spark_session": False,
        "errors": [],
    }

    # Check if server is already listening (idempotent)
    def _port_open():
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect(("127.0.0.1", port))
            s.close()
            return True
        except (socket.error, OSError):
            return False

    if not _port_open():
        try:
            import snowflake.snowpark_connect as spc
        except ImportError:
            result["errors"].append(
                "snowpark-connect not installed. "
                "Set spark_connect.enabled: true in scala_packages.yaml "
                "and re-run setup_scala_environment.sh"
            )
            return result

        server_error = [None]

        def _start_server():
            try:
                spc.start_session(
                    is_daemon=False,
                    remote_url=f"sc://localhost:{port}",
                    snowpark_session=session,
                )
            except Exception as e:
                server_error[0] = str(e)

        thread = threading.Thread(target=_start_server, daemon=True)
        thread.start()

        import time
        for attempt in range(timeout):
            time.sleep(1)
            if server_error[0]:
                result["errors"].append(
                    f"Spark Connect server failed: {server_error[0]}"
                )
                return result
            if _port_open():
                break
        else:
            result["errors"].append(
                f"Spark Connect server did not start within {timeout}s"
            )
            return result

    try:
        import pyspark
        result["pyspark_version"] = pyspark.__version__
    except ImportError:
        pass

    # Create a Scala SparkSession connected to the local server
    import jpype
    if not jpype.isJVMStarted():
        result["errors"].append("JVM not started — call setup_scala_environment() first")
        return result

    spark_code = (
        "import org.apache.spark.sql.{SparkSession => SparkS}\n"
        f'val spark = SparkS.builder().remote("sc://localhost:{port}")'
        '.config("spark.sql.session.timeZone", "UTC").getOrCreate()\n'
        'println("Spark Connect session ready: spark")'
    )
    success, output, errors = execute_scala(spark_code)
    if success:
        result["scala_spark_session"] = True
        if output:
            print(output)
    else:
        result["errors"].append(
            f"Failed to create Scala SparkSession: {errors or output}"
        )
        return result

    result["success"] = True
    return result


# =============================================================================
# Variable Transfer: Python <-> Scala
# =============================================================================

def push_to_scala(name: str, value: Any, type_hint: str = "Any") -> bool:
    """
    Bind a Python value into the Scala interpreter's namespace.

    Supports primitive types, strings, and Java-compatible objects via JPype.

    Args:
        name: Variable name in Scala
        value: Python value (auto-converted by JPype for primitives/strings)
        type_hint: Scala type hint (default: "Any")

    Returns:
        True if successful
    """
    itype = _scala_state.get("interpreter_type")
    if itype not in ("imain", "ammonite-lite"):
        return False

    interpreter = _scala_state["interpreter"]
    try:
        interpreter.bind(name, type_hint, value)
        return True
    except Exception:
        # Fallback: define via code execution
        if isinstance(value, str):
            escaped = value.replace("\\", "\\\\").replace('"', '\\"')
            success, _, _ = execute_scala(f'val {name}: String = "{escaped}"')
            return success
        elif isinstance(value, (int, float, bool)):
            success, _, _ = execute_scala(f"val {name} = {value}")
            return success
        return False


def pull_from_scala(name: str) -> Any:
    """
    Extract a value from the Scala interpreter's namespace.

    Returns the value (JPype auto-converts primitives/strings) or None if
    the variable does not exist.
    """
    itype = _scala_state.get("interpreter_type")
    if itype not in ("imain", "ammonite-lite"):
        return None

    interpreter = _scala_state["interpreter"]
    try:
        opt = interpreter.valueOfTerm(name)
        if opt.isDefined():
            return opt.get()
        return None
    except Exception:
        return None


# =============================================================================
# Snowpark DataFrame Interop: Python <-> Scala via SQL Plan
# =============================================================================
#
# Snowpark DataFrames are lazy SQL query plans — they don't hold data in
# memory.  This lets us transfer DataFrames between Python and Scala by
# passing the underlying SQL string instead of materialising data through
# temp tables.
#
#   Python → Scala:  df.queries['queries'][-1]  →  sfSession.sql(sql)
#   Scala  → Python: df.queries (Scala API)     →  session.sql(sql)
#
# When -i / -o flags reference a Snowpark DataFrame, the magic auto-detects
# it and transfers the SQL plan rather than the raw JVM/Python object.

_interop_views: List[str] = []


def _is_snowpark_python_df(obj) -> bool:
    """Check if *obj* is a Snowpark Python DataFrame."""
    try:
        from snowflake.snowpark import DataFrame
        return isinstance(obj, DataFrame)
    except ImportError:
        return False


def _push_snowpark_df(name: str, df) -> bool:
    """
    Push a Snowpark Python DataFrame into Scala by transferring its SQL
    query plan.  No data is materialised — only the SQL string crosses
    the bridge, and Scala creates its own lazy DataFrame from it.

    The SQL is passed through a Java System property to avoid all
    string-escaping issues.
    """
    import jpype

    try:
        queries = df.queries.get("queries", [])
        if not queries:
            print(f"Warning: DataFrame '{name}' has no SQL queries",
                  file=sys.stderr)
            return False
        sql = queries[-1]
    except (AttributeError, KeyError, IndexError) as e:
        print(f"Warning: Could not extract SQL plan from '{name}': {e}",
              file=sys.stderr)
        return False

    prop_key = f"_interop_sql_{name}"
    System = jpype.JClass("java.lang.System")
    System.setProperty(prop_key, sql)

    code = f'val {name} = sfSession.sql(System.getProperty("{prop_key}"))'
    success, output, errors = execute_scala(code)

    System.clearProperty(prop_key)

    if not success:
        msg = errors or output
        print(f"Warning: Failed to create Scala DataFrame '{name}': {msg}",
              file=sys.stderr)
    return success


def _is_snowpark_scala_df(name: str) -> bool:
    """Check if a Scala variable is a Snowpark DataFrame."""
    code = (
        f"val _isdf_{name}: Boolean = "
        f"try {{ {name}.isInstanceOf[com.snowflake.snowpark.DataFrame] }} "
        f"catch {{ case _: Throwable => false }}"
    )
    success, _, _ = execute_scala(code)
    if not success:
        return False
    val = pull_from_scala(f"_isdf_{name}")
    try:
        return bool(val)
    except Exception:
        return False


def _pull_snowpark_df(name: str) -> Optional[Any]:
    """
    Pull a Snowpark Scala DataFrame into Python by extracting the SQL
    query plan.

    Strategies (in order of preference):
      1. Extract SQL via the Scala DataFrame.queries API and transfer
         through a Java System property.
      2. Fall back to creating a non-temporary VIEW and reading it from
         the Python session (the view is tracked for cleanup).
    """
    import jpype

    session = _scala_state.get("python_session")
    if session is None:
        print(
            "Warning: No Python Snowpark session stored. "
            "Call inject_session_credentials(session) first.",
            file=sys.stderr,
        )
        return None

    # Strategy 1 — extract SQL plan via Scala .queries API
    prop_key = f"_interop_sql_{name}"
    for extract_expr in [
        f"{name}.queries.last",
        f"{name}.queries.apply({name}.queries.length - 1)",
    ]:
        code = f'System.setProperty("{prop_key}", {extract_expr})'
        success, _, _ = execute_scala(code)
        if success:
            System = jpype.JClass("java.lang.System")
            sql = str(System.getProperty(prop_key))
            System.clearProperty(prop_key)
            if sql and sql != "null":
                try:
                    return session.sql(sql)
                except Exception:
                    continue

    # Strategy 2 — view-based fallback
    view_name = f"_INTEROP_{name.upper()}"
    code = f'{name}.createOrReplaceView("{view_name}")'
    success, _, errors = execute_scala(code)
    if success:
        _interop_views.append(view_name)
        return session.table(view_name)

    print(
        f"Warning: Could not transfer Scala DataFrame '{name}' to Python"
        + (f": {errors}" if errors else ""),
        file=sys.stderr,
    )
    return None


def cleanup_interop_views() -> int:
    """
    Drop any non-temporary views created during Scala → Python DataFrame
    transfers.  Call this at the end of a notebook to tidy up.

    Returns the number of views dropped.
    """
    session = _scala_state.get("python_session")
    if not session:
        return 0

    dropped = 0
    for view in _interop_views[:]:
        try:
            session.sql(f"DROP VIEW IF EXISTS {view}").collect()
            _interop_views.remove(view)
            dropped += 1
        except Exception:
            pass
    return dropped


# =============================================================================
# Diagnostics
# =============================================================================

def check_environment() -> Dict[str, Any]:
    """Run comprehensive environment diagnostics."""
    diag = {}

    # JVM
    diag["jvm"] = _check_jvm()

    # Scala interpreter
    diag["interpreter"] = _check_interpreter()

    # Snowpark
    diag["snowpark"] = _check_snowpark()

    # Snowflake env vars
    diag["snowflake_env"] = _check_snowflake_env()

    # Disk space
    diag["disk_space"] = _check_disk_space()

    return diag


def _check_jvm() -> Dict[str, Any]:
    result = {"ok": False, "details": {}, "errors": []}
    try:
        import jpype
        result["details"]["jpype_installed"] = True
        result["details"]["jvm_started"] = jpype.isJVMStarted()
        if jpype.isJVMStarted():
            result["details"]["jvm_path"] = jpype.getDefaultJVMPath()
        result["ok"] = jpype.isJVMStarted()
    except ImportError:
        result["details"]["jpype_installed"] = False
        result["errors"].append("JPype1 not installed")
    return result


def _check_interpreter() -> Dict[str, Any]:
    result = {"ok": False, "details": {}, "errors": []}
    itype = _scala_state.get("interpreter_type")
    result["details"]["type"] = itype or "not initialized"
    result["details"]["magic_registered"] = _scala_state.get("magic_registered", False)

    if itype:
        try:
            success, output, _ = execute_scala("1 + 1")
            result["details"]["test_eval"] = success
            result["ok"] = success
        except Exception as e:
            result["errors"].append(f"Test eval failed: {e}")
    else:
        result["errors"].append("No interpreter initialized")
    return result


def _check_snowpark() -> Dict[str, Any]:
    result = {"ok": False, "details": {}, "errors": []}
    meta = _scala_state.get("metadata")
    if meta:
        cp_file = meta.get("snowpark_classpath_file", "")
        result["details"]["classpath_file"] = cp_file
        result["details"]["classpath_exists"] = os.path.isfile(cp_file)
        result["details"]["version"] = meta.get("snowpark_version", "unknown")
        if cp_file and os.path.isfile(cp_file):
            jars = _read_classpath_file(cp_file)
            result["details"]["jar_count"] = len(jars)
            result["ok"] = len(jars) > 0
        else:
            result["errors"].append(f"Classpath file not found: {cp_file}")
    else:
        result["errors"].append("No metadata loaded")
    return result


def _check_snowflake_env() -> Dict[str, Any]:
    result = {"ok": False, "details": {}, "errors": []}
    required = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER"]
    optional = [
        "SNOWFLAKE_URL", "SNOWFLAKE_ROLE", "SNOWFLAKE_DATABASE",
        "SNOWFLAKE_SCHEMA", "SNOWFLAKE_WAREHOUSE",
        "SNOWFLAKE_TOKEN", "SNOWFLAKE_AUTH_TYPE",
    ]
    missing = []
    for var in required:
        val = os.environ.get(var)
        result["details"][var] = "SET" if val else "NOT SET"
        if not val:
            missing.append(var)
    for var in optional:
        result["details"][var] = "SET" if os.environ.get(var) else "NOT SET"
    if missing:
        result["errors"].append(f"Missing required vars: {', '.join(missing)}")
    result["ok"] = len(missing) == 0
    return result


def _check_disk_space() -> Dict[str, Any]:
    result = {"ok": False, "details": {}, "errors": []}
    try:
        total, used, free = shutil.disk_usage("/")
        result["details"]["free_gb"] = round(free / (1024**3), 2)
        result["details"]["used_pct"] = round(used / total * 100, 1)
        result["ok"] = result["details"]["free_gb"] >= 0.5
        if not result["ok"]:
            result["errors"].append(f"Low disk: {result['details']['free_gb']}GB free")
    except Exception as e:
        result["errors"].append(f"Disk check failed: {e}")
    return result


def print_diagnostics(diagnostics: Optional[Dict[str, Any]] = None) -> None:
    """Print formatted diagnostic results."""
    if diagnostics is None:
        diagnostics = check_environment()

    print("=" * 60)
    print("Scala/JVM Environment Diagnostics")
    print("=" * 60)

    for component, result in diagnostics.items():
        status = "[OK]" if result["ok"] else "[FAIL]"
        print(f"\n{status} {component.upper().replace('_', ' ')}")
        for key, value in result["details"].items():
            print(f"    {key}: {value}")
        if result.get("errors"):
            for error in result["errors"]:
                print(f"    ERROR: {error}")

    print("\n" + "=" * 60)
    all_ok = all(r["ok"] for r in diagnostics.values())
    if all_ok:
        print("All checks passed!")
    else:
        failed = [k for k, v in diagnostics.items() if not v["ok"]]
        print(f"Issues found in: {', '.join(failed)}")
    print("=" * 60)


# =============================================================================
# Convenience: One-line session bootstrap
# =============================================================================

def bootstrap_snowpark_scala(session) -> Tuple[bool, str]:
    """
    All-in-one: inject credentials from Python session and create a
    Snowpark Scala session in the interpreter.

    Args:
        session: Active Snowpark Python session

    Returns:
        (success, message)
    """
    creds = inject_session_credentials(session)
    if not creds.get("SNOWFLAKE_ACCOUNT"):
        return False, "Failed to extract account from session"

    if not creds.get("SNOWFLAKE_TOKEN"):
        return False, (
            "No auth token available. Inside a Workspace the "
            "SPCS token at /snowflake/session/token should be "
            "auto-detected. For external use, set "
            "os.environ['SNOWFLAKE_PAT'] before calling this."
        )

    code = create_snowpark_scala_session_code()
    success, output, errors = execute_scala(code)

    if success:
        return True, output
    else:
        return False, errors or output or "Session creation failed"
