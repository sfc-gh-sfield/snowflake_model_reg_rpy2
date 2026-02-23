"""
Scala Environment Helpers for Snowflake Workspace Notebooks

This module provides:
- JVM startup via JPype (in-process, shared memory)
- Scala REPL initialization (IMain or Ammonite)
- %%scala IPython magic for Scala cell execution
- Snowpark session credential injection
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

After setup with Snowpark session:
    from scala_helpers import inject_session_credentials
    inject_session_credentials(session)

    # %%scala
    # import com.snowflake.snowpark._
    # val sf = Session.builder.configs(Map(
    #   "URL" -> sys.env("SNOWFLAKE_URL"), ...
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

    # --- Start JVM ---
    if not jpype.isJVMStarted():
        try:
            classpath = _build_classpath(metadata, include_ammonite=prefer_ammonite)
            jvm_options = metadata.get("jvm_options", ["-Xmx1g"])

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

    result["success"] = len(result["errors"]) == 0
    return result


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

def _register_scala_magic() -> None:
    """Register the %%scala cell magic with IPython."""
    try:
        get_ipython()  # type: ignore[name-defined]  # noqa: F841
    except NameError:
        raise RuntimeError("Not in an IPython environment")

    from IPython.core.magic import register_cell_magic

    @register_cell_magic
    def scala(line, cell):
        """
        Execute Scala code in the embedded JVM interpreter.

        Usage:
            %%scala
            val x = 42
            println(s"The answer is $x")

        Flags (on the %%scala line):
            --silent    Suppress REPL variable-binding output
            --time      Print execution time
        """
        import time

        show_time = "--time" in line
        silent = "--silent" in line

        t0 = time.time()
        success, output, errors = execute_scala(cell)
        elapsed = time.time() - t0

        if output and not silent:
            print(output)
        if errors:
            print(errors, file=sys.stderr)
        if not success and not errors:
            print("Scala execution failed (no error details captured)", file=sys.stderr)
        if show_time:
            print(f"\n[Scala cell executed in {elapsed:.2f}s]")

    _scala_state["magic_registered"] = True


# =============================================================================
# Snowpark Session Management
# =============================================================================

def inject_session_credentials(session) -> Dict[str, str]:
    """
    Extract credentials from a Python Snowpark session and set them as
    environment variables so Scala code can read them via sys.env(...).

    Args:
        session: Active Snowpark Python session (from get_active_session())

    Returns:
        Dict of environment variable names to values that were set
    """
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
        lambda: session.sql("SELECT CURRENT_ACCOUNT()").collect()[0][0]
    )
    creds["SNOWFLAKE_USER"] = _safe_get(
        lambda: session.sql("SELECT CURRENT_USER()").collect()[0][0]
    )
    creds["SNOWFLAKE_ROLE"] = _safe_get(session.get_current_role)
    creds["SNOWFLAKE_DATABASE"] = _safe_get(session.get_current_database)
    creds["SNOWFLAKE_SCHEMA"] = _safe_get(session.get_current_schema)
    creds["SNOWFLAKE_WAREHOUSE"] = _safe_get(session.get_current_warehouse)

    # Build the URL that Snowpark Scala expects
    account = creds["SNOWFLAKE_ACCOUNT"]
    if account:
        host = os.environ.get("SNOWFLAKE_HOST", "")
        if host:
            creds["SNOWFLAKE_URL"] = f"https://{host}"
        else:
            creds["SNOWFLAKE_URL"] = f"https://{account}.snowflakecomputing.com"

    for key, val in creds.items():
        if val:
            os.environ[key] = val

    return creds


def create_snowpark_scala_session_code(use_pat: bool = True) -> str:
    """
    Generate Scala code to create a Snowpark session using credentials
    from environment variables.

    Args:
        use_pat: Use PAT authentication (default). Otherwise uses AUTHENTICATOR=oauth.

    Returns:
        Scala code string ready for %%scala execution
    """
    if use_pat:
        auth_lines = """\
  "TOKEN"         -> sys.env("SNOWFLAKE_PAT"),
  "AUTHENTICATOR" -> "oauth\""""
    else:
        auth_lines = """\
  "TOKEN"         -> sys.env.getOrElse("SNOWFLAKE_PAT", ""),
  "AUTHENTICATOR" -> sys.env.getOrElse("SNOWFLAKE_AUTH_TYPE", "oauth")"""

    return f"""\
import com.snowflake.snowpark._
import com.snowflake.snowpark.functions._

val session = Session.builder.configs(Map(
  "URL"       -> sys.env("SNOWFLAKE_URL"),
  "USER"      -> sys.env("SNOWFLAKE_USER"),
  "ROLE"      -> sys.env("SNOWFLAKE_ROLE"),
  "DB"        -> sys.env("SNOWFLAKE_DATABASE"),
  "SCHEMA"    -> sys.env("SNOWFLAKE_SCHEMA"),
  "WAREHOUSE" -> sys.env("SNOWFLAKE_WAREHOUSE"),
  {auth_lines}
)).create

println("Snowpark Scala session created")
println(s"  User:      ${{session.sql("SELECT CURRENT_USER()").collect()(0).getString(0)}}")
println(s"  Role:      ${{session.sql("SELECT CURRENT_ROLE()").collect()(0).getString(0)}}")
println(s"  Database:  ${{session.sql("SELECT CURRENT_DATABASE()").collect()(0).getString(0)}}")
"""


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
        "SNOWFLAKE_SCHEMA", "SNOWFLAKE_WAREHOUSE", "SNOWFLAKE_PAT",
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

    # Check for PAT
    if not os.environ.get("SNOWFLAKE_PAT"):
        return False, (
            "SNOWFLAKE_PAT not set. Create a PAT first:\n"
            "  from r_helpers import PATManager\n"
            "  pat_mgr = PATManager(session)\n"
            "  pat_mgr.create_pat()"
        )

    code = create_snowpark_scala_session_code(use_pat=True)
    success, output, errors = execute_scala(code)

    if success:
        return True, output
    else:
        return False, errors or output or "Session creation failed"
