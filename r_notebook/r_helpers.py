"""
R Environment Helpers for Snowflake Workspace Notebooks

This module provides helper functions for:
- PAT (Programmatic Access Token) management
- Environment diagnostics
- R/rpy2 setup validation

Usage:
    from r_helpers import setup_r_environment, create_pat, check_environment
"""

import os
import sys
import subprocess
import shutil
from datetime import datetime, timedelta
from typing import Optional, Dict, Any, Tuple
import json


# =============================================================================
# Configuration
# =============================================================================

R_ENV_PREFIX = "/root/.local/share/mamba/envs/r_env"
PAT_TOKEN_NAME = "r_adbc_pat"


# =============================================================================
# Environment Setup
# =============================================================================

def setup_r_environment(install_rpy2: bool = True, register_magic: bool = True) -> Dict[str, Any]:
    """
    Configure the Python environment to use R from micromamba.
    
    This function:
    1. Sets PATH and R_HOME environment variables
    2. Optionally installs rpy2 into the notebook kernel
    3. Optionally registers the %%R magic
    
    Args:
        install_rpy2: Whether to install rpy2 (default: True)
        register_magic: Whether to register %%R magic (default: True)
    
    Returns:
        Dict with setup status and any errors
    
    Example:
        >>> result = setup_r_environment()
        >>> if result['success']:
        ...     print("R ready!")
    """
    result = {
        'success': False,
        'r_home': None,
        'r_version': None,
        'rpy2_installed': False,
        'magic_registered': False,
        'errors': []
    }
    
    # Check if R environment exists
    if not os.path.isdir(R_ENV_PREFIX):
        result['errors'].append(
            f"R environment not found at {R_ENV_PREFIX}. "
            "Run 'bash setup_r_environment.sh' first."
        )
        return result
    
    # Configure environment variables
    os.environ["PATH"] = f"{R_ENV_PREFIX}/bin:" + os.environ.get("PATH", "")
    os.environ["R_HOME"] = f"{R_ENV_PREFIX}/lib/R"
    result['r_home'] = os.environ["R_HOME"]
    
    # Verify R is accessible
    r_path = shutil.which('R')
    if not r_path:
        result['errors'].append("R binary not found in PATH after configuration")
        return result
    
    # Get R version
    try:
        r_version = subprocess.run(
            ['R', '--version'],
            capture_output=True,
            text=True,
            timeout=10
        )
        if r_version.returncode == 0:
            result['r_version'] = r_version.stdout.split('\n')[0]
    except Exception as e:
        result['errors'].append(f"Failed to get R version: {e}")
    
    # Install rpy2 if requested
    if install_rpy2:
        try:
            subprocess.run(
                [sys.executable, "-m", "pip", "install", "rpy2", "-q"],
                check=True,
                capture_output=True,
                timeout=120
            )
            result['rpy2_installed'] = True
        except subprocess.CalledProcessError as e:
            result['errors'].append(f"Failed to install rpy2: {e}")
        except subprocess.TimeoutExpired:
            result['errors'].append("rpy2 installation timed out")
    
    # Register magic if requested
    if register_magic and result['rpy2_installed']:
        try:
            from rpy2.ipython import rmagic
            ip = get_ipython()
            ip.register_magics(rmagic.RMagics)
            result['magic_registered'] = True
        except NameError:
            # Not in IPython/Jupyter
            result['errors'].append("Not in IPython environment, cannot register magic")
        except Exception as e:
            result['errors'].append(f"Failed to register magic: {e}")
    
    result['success'] = len(result['errors']) == 0
    return result


# =============================================================================
# PAT Management
# =============================================================================

class PATManager:
    """
    Manager for Programmatic Access Tokens (PAT) for ADBC authentication.
    
    Example:
        >>> from r_helpers import PATManager
        >>> pat_mgr = PATManager(session)
        >>> pat_mgr.create_pat(days_to_expiry=1)
        >>> if pat_mgr.is_valid():
        ...     print("PAT is valid")
    """
    
    def __init__(self, session, token_name: str = PAT_TOKEN_NAME):
        """
        Initialize PAT manager.
        
        Args:
            session: Snowpark session
            token_name: Name for the PAT (default: 'r_adbc_pat')
        """
        self.session = session
        self.token_name = token_name
        self._token_secret: Optional[str] = None
        self._created_at: Optional[datetime] = None
        self._expires_at: Optional[datetime] = None
        self._role_restriction: Optional[str] = None
        self._user: Optional[str] = None
    
    @property
    def token(self) -> Optional[str]:
        """Get the current PAT token (if created)."""
        return self._token_secret
    
    @property
    def is_expired(self) -> bool:
        """Check if the PAT has expired."""
        if self._expires_at is None:
            return True
        return datetime.now() > self._expires_at
    
    def is_valid(self) -> bool:
        """Check if PAT exists and is not expired."""
        return self._token_secret is not None and not self.is_expired
    
    def time_remaining(self) -> Optional[timedelta]:
        """Get time remaining until PAT expires."""
        if self._expires_at is None:
            return None
        remaining = self._expires_at - datetime.now()
        return remaining if remaining.total_seconds() > 0 else timedelta(0)
    
    def create_pat(
        self,
        days_to_expiry: int = 1,
        role_restriction: Optional[str] = None,
        network_policy_bypass_mins: int = 240,
        force_recreate: bool = False
    ) -> Dict[str, Any]:
        """
        Create a new Programmatic Access Token.
        
        Args:
            days_to_expiry: Token validity in days (default: 1)
            role_restriction: Role to restrict token to (default: current role)
            network_policy_bypass_mins: Minutes to bypass network policy (default: 240)
            force_recreate: Remove existing PAT first (default: False)
        
        Returns:
            Dict with creation status and token info
        """
        result = {
            'success': False,
            'user': None,
            'role_restriction': None,
            'expires_at': None,
            'error': None
        }
        
        try:
            # Get current user
            self._user = self.session.sql('SELECT CURRENT_USER()').collect()[0][0]
            result['user'] = self._user
            
            # Get role restriction
            if role_restriction is None:
                role_restriction = self.session.get_current_role().replace('"', '')
            self._role_restriction = role_restriction
            result['role_restriction'] = role_restriction
            
            # Remove existing PAT if requested or if it exists
            if force_recreate:
                self.remove_pat()
            
            # Create new PAT
            pat_result = self.session.sql(f'''
                ALTER USER {self._user}
                ADD PROGRAMMATIC ACCESS TOKEN {self.token_name}
                  ROLE_RESTRICTION = '{role_restriction}'
                  DAYS_TO_EXPIRY = {days_to_expiry}
                  MINS_TO_BYPASS_NETWORK_POLICY_REQUIREMENT = {network_policy_bypass_mins}
                  COMMENT = 'PAT for R/ADBC from Workspace Notebook'
            ''').collect()
            
            # Store token
            self._token_secret = pat_result[0]['token_secret']
            self._created_at = datetime.now()
            self._expires_at = self._created_at + timedelta(days=days_to_expiry)
            
            # Set environment variable
            os.environ["SNOWFLAKE_PAT"] = self._token_secret
            
            result['success'] = True
            result['expires_at'] = self._expires_at.isoformat()
            
        except Exception as e:
            error_msg = str(e)
            # Check for common errors
            if "already exists" in error_msg.lower():
                result['error'] = (
                    f"PAT '{self.token_name}' already exists. "
                    "Use force_recreate=True to replace it."
                )
            else:
                result['error'] = error_msg
        
        return result
    
    def remove_pat(self) -> bool:
        """Remove the PAT from the user."""
        try:
            if self._user is None:
                self._user = self.session.sql('SELECT CURRENT_USER()').collect()[0][0]
            
            self.session.sql(f'''
                ALTER USER {self._user} 
                REMOVE PROGRAMMATIC ACCESS TOKEN {self.token_name}
            ''').collect()
            
            # Clear local state
            self._token_secret = None
            self._created_at = None
            self._expires_at = None
            
            # Clear environment variable
            if "SNOWFLAKE_PAT" in os.environ:
                del os.environ["SNOWFLAKE_PAT"]
            
            return True
        except Exception:
            return False
    
    def get_status(self) -> Dict[str, Any]:
        """Get current PAT status."""
        remaining = self.time_remaining()
        return {
            'exists': self._token_secret is not None,
            'is_valid': self.is_valid(),
            'user': self._user,
            'role_restriction': self._role_restriction,
            'created_at': self._created_at.isoformat() if self._created_at else None,
            'expires_at': self._expires_at.isoformat() if self._expires_at else None,
            'time_remaining': str(remaining) if remaining else None,
            'env_var_set': 'SNOWFLAKE_PAT' in os.environ
        }
    
    def refresh_if_needed(self, min_remaining_hours: float = 1.0) -> Dict[str, Any]:
        """
        Refresh PAT if it will expire soon.
        
        Args:
            min_remaining_hours: Refresh if less than this many hours remain
        
        Returns:
            Dict with refresh status
        """
        result = {'refreshed': False, 'reason': None}
        
        remaining = self.time_remaining()
        if remaining is None:
            result['reason'] = 'No existing PAT'
            self.create_pat()
            result['refreshed'] = True
        elif remaining.total_seconds() < min_remaining_hours * 3600:
            result['reason'] = f'Less than {min_remaining_hours}h remaining'
            self.create_pat(force_recreate=True)
            result['refreshed'] = True
        else:
            result['reason'] = f'{remaining} remaining, no refresh needed'
        
        return result


def create_pat(
    session,
    days_to_expiry: int = 1,
    role_restriction: Optional[str] = None,
    force_recreate: bool = True
) -> Tuple[bool, str]:
    """
    Convenience function to create a PAT.
    
    Args:
        session: Snowpark session
        days_to_expiry: Token validity in days
        role_restriction: Role to restrict token to
        force_recreate: Remove existing PAT first
    
    Returns:
        Tuple of (success, message)
    
    Example:
        >>> success, msg = create_pat(session, days_to_expiry=1)
        >>> print(msg)
    """
    mgr = PATManager(session)
    result = mgr.create_pat(
        days_to_expiry=days_to_expiry,
        role_restriction=role_restriction,
        force_recreate=force_recreate
    )
    
    if result['success']:
        msg = (
            f"PAT created successfully\n"
            f"  User: {result['user']}\n"
            f"  Role: {result['role_restriction']}\n"
            f"  Expires: {result['expires_at']}"
        )
        return True, msg
    else:
        return False, f"PAT creation failed: {result['error']}"


# =============================================================================
# Diagnostics
# =============================================================================

def check_environment() -> Dict[str, Any]:
    """
    Run comprehensive environment diagnostics.
    
    Returns:
        Dict with diagnostic results for each component
    
    Example:
        >>> diag = check_environment()
        >>> for component, status in diag.items():
        ...     print(f"{component}: {'✓' if status['ok'] else '✗'}")
    """
    diagnostics = {}
    
    # 1. Check R environment
    diagnostics['r_environment'] = _check_r_environment()
    
    # 2. Check rpy2
    diagnostics['rpy2'] = _check_rpy2()
    
    # 3. Check ADBC
    diagnostics['adbc'] = _check_adbc()
    
    # 4. Check Snowflake environment variables
    diagnostics['snowflake_env'] = _check_snowflake_env()
    
    # 5. Check disk space
    diagnostics['disk_space'] = _check_disk_space()
    
    # 6. Check network connectivity
    diagnostics['network'] = _check_network()
    
    return diagnostics


def _check_r_environment() -> Dict[str, Any]:
    """Check R environment setup."""
    result = {'ok': False, 'details': {}, 'errors': []}
    
    # Check if env directory exists
    env_exists = os.path.isdir(R_ENV_PREFIX)
    result['details']['env_exists'] = env_exists
    
    if not env_exists:
        result['errors'].append(f"R environment not found at {R_ENV_PREFIX}")
        return result
    
    # Check R_HOME
    r_home = os.environ.get('R_HOME')
    result['details']['r_home'] = r_home
    if not r_home:
        result['errors'].append("R_HOME not set")
    
    # Check R binary
    r_path = shutil.which('R')
    result['details']['r_binary'] = r_path
    if not r_path:
        result['errors'].append("R binary not in PATH")
    
    # Get R version
    if r_path:
        try:
            r_ver = subprocess.run(
                ['R', '--version'],
                capture_output=True,
                text=True,
                timeout=10
            )
            if r_ver.returncode == 0:
                result['details']['r_version'] = r_ver.stdout.split('\n')[0]
        except Exception as e:
            result['errors'].append(f"Failed to get R version: {e}")
    
    result['ok'] = len(result['errors']) == 0
    return result


def _check_rpy2() -> Dict[str, Any]:
    """Check rpy2 installation."""
    result = {'ok': False, 'details': {}, 'errors': []}
    
    try:
        import rpy2
        
        # Get version - handle different rpy2 versions
        try:
            # Try modern approach first (Python 3.8+)
            from importlib.metadata import version as get_version
            rpy2_version = get_version('rpy2')
        except Exception:
            # Fall back to checking module attributes
            rpy2_version = getattr(rpy2, '__version__', 'unknown')
        
        result['details']['version'] = rpy2_version
        result['details']['installed'] = True
        
        # Check if rpy2 can connect to R
        import rpy2.robjects as ro
        r_version = ro.r('R.version.string')[0]
        result['details']['r_connection'] = True
        result['details']['r_version_via_rpy2'] = r_version
        result['ok'] = True
        
    except ImportError:
        result['details']['installed'] = False
        result['errors'].append("rpy2 not installed")
    except Exception as e:
        result['details']['r_connection'] = False
        result['errors'].append(f"rpy2 cannot connect to R: {e}")
    
    return result


def _check_adbc() -> Dict[str, Any]:
    """Check ADBC installation in R."""
    result = {'ok': False, 'details': {}, 'errors': []}
    
    try:
        import rpy2.robjects as ro
        
        # Check if adbcsnowflake is installed
        check_code = '''
        list(
            adbcdrivermanager = requireNamespace("adbcdrivermanager", quietly = TRUE),
            adbcsnowflake = requireNamespace("adbcsnowflake", quietly = TRUE)
        )
        '''
        r_result = ro.r(check_code)
        
        result['details']['adbcdrivermanager'] = bool(r_result[0][0])
        result['details']['adbcsnowflake'] = bool(r_result[1][0])
        
        if not result['details']['adbcdrivermanager']:
            result['errors'].append("adbcdrivermanager not installed")
        if not result['details']['adbcsnowflake']:
            result['errors'].append("adbcsnowflake not installed")
        
        result['ok'] = all([
            result['details']['adbcdrivermanager'],
            result['details']['adbcsnowflake']
        ])
        
    except ImportError:
        result['errors'].append("rpy2 not available, cannot check ADBC")
    except Exception as e:
        result['errors'].append(f"Error checking ADBC: {e}")
    
    return result


def _check_snowflake_env() -> Dict[str, Any]:
    """Check Snowflake environment variables."""
    result = {'ok': False, 'details': {}, 'errors': []}
    
    required_vars = [
        'SNOWFLAKE_ACCOUNT',
        'SNOWFLAKE_USER',
        'SNOWFLAKE_DATABASE',
        'SNOWFLAKE_SCHEMA'
    ]
    
    optional_vars = [
        'SNOWFLAKE_WAREHOUSE',
        'SNOWFLAKE_ROLE',
        'SNOWFLAKE_PUBLIC_HOST',
        'SNOWFLAKE_PAT'
    ]
    
    missing_required = []
    for var in required_vars:
        value = os.environ.get(var)
        result['details'][var] = 'SET' if value else 'NOT SET'
        if not value:
            missing_required.append(var)
    
    for var in optional_vars:
        value = os.environ.get(var)
        result['details'][var] = 'SET' if value else 'NOT SET'
    
    if missing_required:
        result['errors'].append(f"Missing required vars: {', '.join(missing_required)}")
    
    result['ok'] = len(missing_required) == 0
    return result


def _check_disk_space() -> Dict[str, Any]:
    """Check available disk space."""
    result = {'ok': False, 'details': {}, 'errors': []}
    
    try:
        import shutil
        total, used, free = shutil.disk_usage('/')
        
        result['details']['total_gb'] = round(total / (1024**3), 2)
        result['details']['used_gb'] = round(used / (1024**3), 2)
        result['details']['free_gb'] = round(free / (1024**3), 2)
        result['details']['percent_used'] = round(used / total * 100, 1)
        
        # Warn if less than 1GB free
        min_free_gb = 1.0
        if result['details']['free_gb'] < min_free_gb:
            result['errors'].append(
                f"Low disk space: {result['details']['free_gb']}GB free "
                f"(minimum {min_free_gb}GB recommended)"
            )
        
        result['ok'] = len(result['errors']) == 0
        
    except Exception as e:
        result['errors'].append(f"Failed to check disk space: {e}")
    
    return result


def _check_network() -> Dict[str, Any]:
    """Check network connectivity to required endpoints."""
    result = {'ok': False, 'details': {}, 'errors': []}
    
    # Use URLs that reliably return 200 OK for GET requests
    # Some servers don't support HEAD requests or return non-200 for root paths
    endpoints = {
        'conda-forge': 'https://conda.anaconda.org/conda-forge/noarch/repodata.json',
        'cran': 'https://cloud.r-project.org',
        'pypi': 'https://pypi.org/simple/',
    }
    
    import urllib.request
    import urllib.error
    
    for name, url in endpoints.items():
        try:
            req = urllib.request.Request(
                url, 
                headers={'User-Agent': 'Mozilla/5.0 (diagnostic check)'}
            )
            response = urllib.request.urlopen(req, timeout=10)
            # Accept any 2xx status code
            if 200 <= response.status < 300:
                result['details'][name] = 'reachable'
            else:
                result['details'][name] = f'status: {response.status}'
        except urllib.error.HTTPError as e:
            # HTTP errors (4xx, 5xx) - server responded, so network works
            # But we still consider it an issue if we can't access resources
            if e.code in (401, 403):
                # Auth issues mean network works, server is reachable
                result['details'][name] = 'reachable (auth required)'
            else:
                result['details'][name] = f'http error: {e.code}'
                result['errors'].append(f"HTTP {e.code} from {name} ({url})")
        except urllib.error.URLError as e:
            result['details'][name] = f'unreachable: {e.reason}'
            result['errors'].append(f"Cannot reach {name} ({url})")
        except Exception as e:
            result['details'][name] = f'error: {e}'
            result['errors'].append(f"Error checking {name}: {e}")
    
    result['ok'] = len(result['errors']) == 0
    return result


def print_diagnostics(diagnostics: Optional[Dict[str, Any]] = None) -> None:
    """
    Print formatted diagnostic results.
    
    Args:
        diagnostics: Output from check_environment(), or None to run diagnostics
    """
    if diagnostics is None:
        diagnostics = check_environment()
    
    print("=" * 60)
    print("R Environment Diagnostics")
    print("=" * 60)
    
    for component, result in diagnostics.items():
        status = "✓" if result['ok'] else "✗"
        print(f"\n{status} {component.upper().replace('_', ' ')}")
        
        for key, value in result['details'].items():
            print(f"    {key}: {value}")
        
        if result['errors']:
            for error in result['errors']:
                print(f"    ERROR: {error}")
    
    print("\n" + "=" * 60)
    all_ok = all(r['ok'] for r in diagnostics.values())
    if all_ok:
        print("All checks passed!")
    else:
        failed = [k for k, v in diagnostics.items() if not v['ok']]
        print(f"Issues found in: {', '.join(failed)}")
    print("=" * 60)


def validate_adbc_connection() -> Tuple[bool, str]:
    """
    Validate that ADBC connection can be established.
    
    Returns:
        Tuple of (success, message)
    """
    errors = []
    
    # Check PAT
    pat = os.environ.get('SNOWFLAKE_PAT')
    if not pat:
        errors.append("SNOWFLAKE_PAT not set - create PAT first")
    
    # Check required env vars
    required = ['SNOWFLAKE_ACCOUNT', 'SNOWFLAKE_USER']
    for var in required:
        if not os.environ.get(var):
            errors.append(f"{var} not set")
    
    # Check ADBC packages
    try:
        import rpy2.robjects as ro
        check = ro.r('requireNamespace("adbcsnowflake", quietly = TRUE)')
        if not check[0]:
            errors.append("adbcsnowflake R package not installed")
    except Exception as e:
        errors.append(f"Cannot verify ADBC packages: {e}")
    
    if errors:
        return False, "ADBC validation failed:\n  - " + "\n  - ".join(errors)
    
    return True, "ADBC connection prerequisites validated"


# =============================================================================
# R Connection Management
# =============================================================================

# R code for connection management - stored as string for execution via rpy2
R_CONNECTION_CODE = '''
# =============================================================================
# Snowflake ADBC Connection Management for R
# =============================================================================
# This code provides connection pooling/reuse for ADBC connections.
# The connection is stored in the global environment as `r_sf_con`.
# =============================================================================

library(adbcdrivermanager)
library(adbcsnowflake)

#' Get or create a Snowflake ADBC connection
#' 
#' Returns the existing connection if valid, or creates a new one.
#' Connection is stored globally as `r_sf_con`.
#' 
#' @param force_new If TRUE, close existing connection and create new one
#' @return The ADBC connection object
get_snowflake_connection <- function(force_new = FALSE) {
  # Check if we need to create a new connection
  needs_new <- force_new || 
               !exists("r_sf_con", envir = .GlobalEnv) || 
               is.null(get0("r_sf_con", envir = .GlobalEnv))
  
  if (!needs_new) {
    # Verify existing connection is still valid
    tryCatch({
      con <- get("r_sf_con", envir = .GlobalEnv)
      # Simple test query to verify connection
      test <- con |> read_adbc("SELECT 1")
      return(con)
    }, error = function(e) {
      message("Existing connection invalid, creating new one...")
      needs_new <<- TRUE
    })
  }
  
  if (needs_new) {
    # Close existing connection if present
    close_snowflake_connection(silent = TRUE)
    
    # Read connection parameters from environment
    account      <- Sys.getenv("SNOWFLAKE_ACCOUNT")
    user         <- Sys.getenv("SNOWFLAKE_USER")
    database     <- Sys.getenv("SNOWFLAKE_DATABASE")
    schema       <- Sys.getenv("SNOWFLAKE_SCHEMA")
    warehouse    <- Sys.getenv("SNOWFLAKE_WAREHOUSE")
    role         <- Sys.getenv("SNOWFLAKE_ROLE")
    pat          <- Sys.getenv("SNOWFLAKE_PAT")
    public_host  <- Sys.getenv("SNOWFLAKE_PUBLIC_HOST")
    
    # Validate PAT
    if (identical(pat, "")) {
      stop("SNOWFLAKE_PAT not set. Create PAT first using PATManager.")
    }
    
    # Create database handle
    r_sf_db <<- adbc_database_init(
      adbcsnowflake::adbcsnowflake(),
      username                          = user,
      `adbc.snowflake.sql.account`      = account,
      `adbc.snowflake.sql.uri.host`     = public_host,
      `adbc.snowflake.sql.db`           = database,
      `adbc.snowflake.sql.schema`       = schema,
      `adbc.snowflake.sql.warehouse`    = warehouse,
      `adbc.snowflake.sql.role`         = role,
      `adbc.snowflake.sql.auth_type`                = "auth_pat",
      `adbc.snowflake.sql.client_option.auth_token` = pat
    )
    
    # Create connection
    r_sf_con <<- adbc_connection_init(r_sf_db)
    
    message("Snowflake ADBC connection established (r_sf_con)")
  }
  
  return(get("r_sf_con", envir = .GlobalEnv))
}

#' Close the Snowflake ADBC connection
#' 
#' Releases connection and database handles.
#' 
#' @param silent If TRUE, suppress messages
close_snowflake_connection <- function(silent = FALSE) {
  # Close connection
  if (exists("r_sf_con", envir = .GlobalEnv) && !is.null(get0("r_sf_con", envir = .GlobalEnv))) {
    tryCatch({
      adbc_connection_release(get("r_sf_con", envir = .GlobalEnv))
      if (!silent) message("ADBC connection closed")
    }, error = function(e) {
      if (!silent) message("Error closing connection: ", e$message)
    })
    rm("r_sf_con", envir = .GlobalEnv)
  }
  
  # Release database handle
  if (exists("r_sf_db", envir = .GlobalEnv) && !is.null(get0("r_sf_db", envir = .GlobalEnv))) {
    tryCatch({
      adbc_database_release(get("r_sf_db", envir = .GlobalEnv))
      if (!silent) message("ADBC database handle released")
    }, error = function(e) {
      if (!silent) message("Error releasing database: ", e$message)
    })
    rm("r_sf_db", envir = .GlobalEnv)
  }
  
  invisible(NULL)
}

#' Check if Snowflake connection exists and is valid
#' 
#' @return TRUE if connection exists and is valid
is_snowflake_connected <- function() {
  if (!exists("r_sf_con", envir = .GlobalEnv) || is.null(get0("r_sf_con", envir = .GlobalEnv))) {
    return(FALSE)
  }
  
  tryCatch({
    con <- get("r_sf_con", envir = .GlobalEnv)
    test <- con |> read_adbc("SELECT 1")
    return(TRUE)
  }, error = function(e) {
    return(FALSE)
  })
}

#' Get connection status
#' 
#' @return List with connection status details
snowflake_connection_status <- function() {
  list(
    connected = is_snowflake_connected(),
    con_exists = exists("r_sf_con", envir = .GlobalEnv),
    db_exists = exists("r_sf_db", envir = .GlobalEnv),
    account = Sys.getenv("SNOWFLAKE_ACCOUNT"),
    user = Sys.getenv("SNOWFLAKE_USER"),
    database = Sys.getenv("SNOWFLAKE_DATABASE"),
    pat_set = !identical(Sys.getenv("SNOWFLAKE_PAT"), "")
  )
}

message("R connection management functions loaded:")
message("  - get_snowflake_connection()    : Get or create connection (stored as r_sf_con)")
message("  - close_snowflake_connection()  : Close and release connection")
message("  - is_snowflake_connected()      : Check if connected")
message("  - snowflake_connection_status() : Get detailed status")
'''


def init_r_connection_management() -> Tuple[bool, str]:
    """
    Initialize R connection management functions.
    
    This loads helper functions into R that provide connection pooling/reuse.
    The connection is stored as `r_sf_con` in R's global environment.
    
    Functions available after initialization:
    - get_snowflake_connection(): Get or create connection
    - close_snowflake_connection(): Close connection
    - is_snowflake_connected(): Check connection status
    - snowflake_connection_status(): Get detailed status
    
    Returns:
        Tuple of (success, message)
    
    Example:
        >>> success, msg = init_r_connection_management()
        >>> print(msg)
    """
    try:
        import rpy2.robjects as ro
        ro.r(R_CONNECTION_CODE)
        return True, "R connection management initialized"
    except Exception as e:
        return False, f"Failed to initialize R connection management: {e}"


def get_r_connection_status() -> Dict[str, Any]:
    """
    Get the status of the R Snowflake connection.
    
    Returns:
        Dict with connection status details
    """
    try:
        import rpy2.robjects as ro
        
        # Check if functions are loaded
        if not ro.r('exists("is_snowflake_connected")')[0]:
            return {
                'initialized': False,
                'error': 'Connection management not initialized. Call init_r_connection_management() first.'
            }
        
        # Get status from R
        status = ro.r('snowflake_connection_status()')
        return {
            'initialized': True,
            'connected': bool(status[0][0]),
            'con_exists': bool(status[1][0]),
            'db_exists': bool(status[2][0]),
            'account': str(status[3][0]),
            'user': str(status[4][0]),
            'database': str(status[5][0]),
            'pat_set': bool(status[6][0])
        }
    except Exception as e:
        return {
            'initialized': False,
            'error': str(e)
        }


def close_r_connection() -> Tuple[bool, str]:
    """
    Close the R Snowflake connection from Python.
    
    Returns:
        Tuple of (success, message)
    """
    try:
        import rpy2.robjects as ro
        
        if not ro.r('exists("close_snowflake_connection")')[0]:
            return False, "Connection management not initialized"
        
        ro.r('close_snowflake_connection()')
        return True, "R Snowflake connection closed"
    except Exception as e:
        return False, f"Error closing connection: {e}"
