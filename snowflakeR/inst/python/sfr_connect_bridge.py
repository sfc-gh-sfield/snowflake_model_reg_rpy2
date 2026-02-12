"""
Snowflake Connection Bridge
============================

Python backend for snowflakeR::R/connect.R.

Handles Snowpark session creation, active session detection
for Workspace Notebooks, and robust pandas → R data conversion.
"""

import json
import os
from typing import Optional


def get_active_session():
    """
    Get the active Snowpark session (works in Workspace Notebooks).

    Returns:
        Snowpark Session object

    Raises:
        Exception if no active session is available
    """
    from snowflake.snowpark.context import get_active_session
    return get_active_session()


def _load_private_key(key_path: str) -> bytes:
    """
    Load a PEM private key file and return the DER-encoded bytes.

    Snowpark Session.builder requires the private key as DER bytes
    in the 'private_key' parameter.

    Args:
        key_path: Path to PEM-encoded private key (.p8 file)

    Returns:
        DER-encoded private key bytes
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.backends import default_backend

    key_path = os.path.expanduser(key_path)
    with open(key_path, "rb") as f:
        key_data = f.read()

    private_key = serialization.load_pem_private_key(
        key_data,
        password=None,
        backend=default_backend(),
    )

    return private_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def create_session(
    account: str,
    user: Optional[str] = None,
    warehouse: Optional[str] = None,
    database: Optional[str] = None,
    schema: Optional[str] = None,
    role: Optional[str] = None,
    authenticator: Optional[str] = None,
    private_key_file: Optional[str] = None,
    **kwargs,
):
    """
    Create a new Snowpark session from explicit parameters.

    Supports multiple auth methods:
    - Key-pair (SNOWFLAKE_JWT): pass private_key_file path
    - External browser: authenticator="externalbrowser"
    - Username/password: authenticator="snowflake" + password in kwargs

    Args:
        account: Snowflake account identifier
        user: Username
        warehouse: Default warehouse
        database: Default database
        schema: Default schema
        role: Role to use
        authenticator: Authentication method
        private_key_file: Path to PEM private key (.p8 file)
        **kwargs: Additional connection parameters

    Returns:
        Snowpark Session object
    """
    from snowflake.snowpark import Session

    conn_params = {"account": account}

    if user:
        conn_params["user"] = user
    if warehouse:
        conn_params["warehouse"] = warehouse
    if database:
        conn_params["database"] = database
    if schema:
        conn_params["schema"] = schema
    if role:
        conn_params["role"] = role

    # Handle key-pair authentication
    if private_key_file:
        conn_params["private_key"] = _load_private_key(private_key_file)
        # Don't pass authenticator for key-pair; Snowpark auto-detects
    elif authenticator:
        conn_params["authenticator"] = authenticator

    conn_params.update(kwargs)

    session = Session.builder.configs(conn_params).create()
    return session


def pandas_to_r_dict(pdf):
    """
    Convert a pandas DataFrame to a column-oriented Python dict
    with native Python types (no numpy arrays).

    The NumPy 1.x / 2.x ABI break can cause reticulate to leave
    numpy.ndarray objects unconverted when going pandas → R.
    This function round-trips through JSON to guarantee native
    Python floats/ints/strings that reticulate always handles.

    Args:
        pdf: A pandas DataFrame.

    Returns:
        dict[str, list]: Column name → list of native Python values.
    """
    records = json.loads(pdf.to_json(orient="records", date_format="iso"))
    cols = list(pdf.columns)
    return {col: [r.get(col) for r in records] for col in cols}


def query_to_dict(session, sql):
    """
    Execute a SQL query and return the result as a column-oriented dict
    with native Python types only (safe for reticulate conversion to R).

    This keeps the entire pandas/numpy interaction on the Python side,
    avoiding reticulate's NumPy version checks which can fail with
    NumPy 1.x/2.x ABI mismatches.

    None values are converted to the string "NA_SENTINEL_" so that
    R's as.data.frame() sees consistent column lengths.  The R side
    replaces these sentinels with proper NA values.

    Args:
        session: Snowpark Session object.
        sql: SQL query string.

    Returns:
        dict with keys:
            - "columns": list of column names
            - "data": dict[str, list] of column name → values
            - "nrows": int
    """
    _NA = "NA_SENTINEL_"

    pdf = session.sql(sql).to_pandas()
    # Strip surrounding quotes from column names (SHOW/DESCRIBE commands
    # return quoted identifiers like '"name"' which R's make.names mangles)
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
        # Replace None with sentinel so R sees a uniform-length character
        # vector rather than a list of NULLs (which collapses to length 0).
        data[col] = [v if v is not None else _NA for v in vals]

    return {"columns": cols, "data": data, "nrows": nrows}
