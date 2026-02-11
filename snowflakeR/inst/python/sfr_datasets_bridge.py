"""
Snowflake Datasets Python Bridge
=================================
Called from R via reticulate. Wraps snowflake.ml.dataset.Dataset.
"""

from typing import Any, Dict, List, Optional

# ---------------------------------------------------------------------------
# Dataset CRUD
# ---------------------------------------------------------------------------

def create_dataset(
    session,
    name: str,
    exist_ok: bool = False,
) -> Dict[str, Any]:
    """Create a new Snowflake Dataset."""
    from snowflake.ml.dataset import Dataset

    ds = Dataset.create(session=session, name=name, exist_ok=exist_ok)
    return {
        "name": name,
        "fully_qualified_name": str(ds.fully_qualified_name),
    }


def load_dataset(
    session,
    name: str,
) -> Dict[str, Any]:
    """Load an existing Snowflake Dataset."""
    from snowflake.ml.dataset import Dataset

    ds = Dataset.load(session=session, name=name)
    return {
        "name": name,
        "fully_qualified_name": str(ds.fully_qualified_name),
    }


def list_datasets(session) -> Any:
    """List datasets in the current database/schema via SHOW DATASETS."""
    result = session.sql("SHOW DATASETS").to_pandas()
    return result


def delete_dataset(
    session,
    name: str,
) -> None:
    """Delete a dataset and all its versions."""
    from snowflake.ml.dataset import Dataset

    ds = Dataset.load(session=session, name=name)
    ds.delete()


# ---------------------------------------------------------------------------
# Dataset version operations
# ---------------------------------------------------------------------------

def create_dataset_version(
    session,
    name: str,
    version: str,
    input_sql: str,
    shuffle: bool = False,
    exclude_cols: Optional[List[str]] = None,
    label_cols: Optional[List[str]] = None,
    partition_by: Optional[str] = None,
    comment: Optional[str] = None,
) -> Dict[str, Any]:
    """Create a new version of a dataset from a SQL query."""
    from snowflake.ml.dataset import Dataset

    ds = Dataset.load(session=session, name=name)
    input_df = session.sql(input_sql)

    ds = ds.create_version(
        version=version,
        input_dataframe=input_df,
        shuffle=shuffle,
        exclude_cols=exclude_cols,
        label_cols=label_cols,
        partition_by=partition_by,
        comment=comment,
    )

    return {
        "name": name,
        "version": version,
        "fully_qualified_name": str(ds.fully_qualified_name),
    }


def list_dataset_versions(
    session,
    name: str,
    detailed: bool = False,
) -> Any:
    """List versions of a dataset."""
    from snowflake.ml.dataset import Dataset

    ds = Dataset.load(session=session, name=name)
    versions = ds.list_versions(detailed=detailed)

    if detailed:
        # Returns list of Row objects -> convert to pandas
        import pandas as pd
        return pd.DataFrame([row.as_dict() for row in versions])
    else:
        # Returns list of strings
        return versions


def delete_dataset_version(
    session,
    name: str,
    version: str,
) -> None:
    """Delete a specific version from a dataset."""
    from snowflake.ml.dataset import Dataset

    ds = Dataset.load(session=session, name=name)
    ds.delete_version(version)


def read_dataset(
    session,
    name: str,
    version: str,
) -> Any:
    """Read a dataset version into a pandas DataFrame."""
    from snowflake.ml.dataset import Dataset

    ds = Dataset.load(session=session, name=name)
    ds = ds.select_version(version)
    return ds.read.to_pandas()
