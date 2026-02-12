"""
Snowflake Admin Utilities Python Bridge
========================================
SQL-based wrappers for EAI, compute pools, and image repositories.
Called from R via reticulate.
"""

import json
from typing import Any, Dict, List, Optional


def _pandas_to_r_dict(pdf):
    """Convert a pandas DataFrame to a column-oriented dict with native Python
    types via JSON round-trip.  This avoids NumPy ABI issues with reticulate."""
    _NA = "NA_SENTINEL_"
    clean_cols = [c.strip('"') for c in pdf.columns]
    pdf.columns = clean_cols
    cols = list(clean_cols)
    nrows = len(pdf)

    if nrows == 0:
        return {"columns": cols, "data": {c: [] for c in cols}, "nrows": 0}

    records = json.loads(pdf.to_json(orient="records", date_format="iso"))
    data = {}
    for col in cols:
        vals = [r.get(col) for r in records]
        data[col] = [v if v is not None else _NA for v in vals]

    return {"columns": cols, "data": data, "nrows": nrows}


def _run_sql(session, sql: str) -> Any:
    """Execute SQL and return dict for safe R conversion."""
    return _pandas_to_r_dict(session.sql(sql).to_pandas())


def _run_ddl(session, sql: str) -> None:
    """Execute DDL/DML SQL (no result set)."""
    session.sql(sql).collect()


# =============================================================================
# External Access Integrations (EAI)
# =============================================================================

def create_eai(
    session,
    name: str,
    allowed_network_rules: List[str],
    allowed_api_authentication_integrations: Optional[List[str]] = None,
    enabled: bool = True,
    comment: Optional[str] = None,
) -> None:
    """Create an External Access Integration."""
    rules = ", ".join(allowed_network_rules)
    sql = f"CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION {name}"
    sql += f"\n  ALLOWED_NETWORK_RULES = ({rules})"

    if allowed_api_authentication_integrations:
        auth = ", ".join(allowed_api_authentication_integrations)
        sql += f"\n  ALLOWED_API_AUTHENTICATION_INTEGRATIONS = ({auth})"

    sql += f"\n  ENABLED = {str(enabled).upper()}"

    if comment:
        sql += f"\n  COMMENT = '{comment}'"

    _run_ddl(session, sql)


def list_eais(session) -> Any:
    """List External Access Integrations."""
    return _run_sql(session, "SHOW EXTERNAL ACCESS INTEGRATIONS")


def describe_eai(session, name: str) -> Any:
    """Describe an External Access Integration."""
    return _run_sql(session, f"DESCRIBE EXTERNAL ACCESS INTEGRATION {name}")


def delete_eai(session, name: str) -> None:
    """Drop an External Access Integration."""
    _run_ddl(session, f"DROP EXTERNAL ACCESS INTEGRATION IF EXISTS {name}")


# =============================================================================
# Compute Pools
# =============================================================================

def create_compute_pool(
    session,
    name: str,
    instance_family: str,
    min_nodes: int = 1,
    max_nodes: int = 1,
    auto_resume: bool = True,
    auto_suspend_secs: int = 3600,
    comment: Optional[str] = None,
) -> None:
    """Create a compute pool."""
    sql = f"""CREATE COMPUTE POOL IF NOT EXISTS {name}
  INSTANCE_FAMILY = {instance_family}
  MIN_NODES = {min_nodes}
  MAX_NODES = {max_nodes}
  AUTO_RESUME = {str(auto_resume).upper()}
  AUTO_SUSPEND_SECS = {auto_suspend_secs}"""

    if comment:
        sql += f"\n  COMMENT = '{comment}'"

    _run_ddl(session, sql)


def list_compute_pools(session) -> Any:
    """List compute pools."""
    return _run_sql(session, "SHOW COMPUTE POOLS")


def describe_compute_pool(session, name: str) -> Any:
    """Describe a compute pool."""
    return _run_sql(session, f"DESCRIBE COMPUTE POOL {name}")


def delete_compute_pool(session, name: str) -> None:
    """Drop a compute pool."""
    _run_ddl(session, f"DROP COMPUTE POOL IF EXISTS {name}")


def suspend_compute_pool(session, name: str) -> None:
    """Suspend a compute pool."""
    _run_ddl(session, f"ALTER COMPUTE POOL {name} SUSPEND")


def resume_compute_pool(session, name: str) -> None:
    """Resume a compute pool."""
    _run_ddl(session, f"ALTER COMPUTE POOL {name} RESUME")


# =============================================================================
# Image Repositories
# =============================================================================

def create_image_repo(
    session,
    name: str,
) -> None:
    """Create an image repository."""
    _run_ddl(session, f"CREATE IMAGE REPOSITORY IF NOT EXISTS {name}")


def list_image_repos(session) -> Any:
    """List image repositories."""
    return _run_sql(session, "SHOW IMAGE REPOSITORIES")


def describe_image_repo(session, name: str) -> Any:
    """Describe an image repository."""
    return _run_sql(session, f"SHOW IMAGE REPOSITORIES LIKE '{name}'")


def delete_image_repo(session, name: str) -> None:
    """Drop an image repository."""
    _run_ddl(session, f"DROP IMAGE REPOSITORY IF EXISTS {name}")
