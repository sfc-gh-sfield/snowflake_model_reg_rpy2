"""
Snowflake Connection Bridge
============================

Python backend for snowflakeR::R/connect.R.

Handles Snowpark session creation and active session detection
for Workspace Notebooks.
"""

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
