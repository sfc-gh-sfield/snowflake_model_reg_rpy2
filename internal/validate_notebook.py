#!/usr/bin/env python3
"""Validate and optionally fix Snowflake Workspace Notebook (.ipynb) files.

Checks every cell against the metadata requirements that Workspace enforces.
Missing fields cause Workspace to reject the file as "corrupted or invalid".

Usage:
    # Validate only (exit code 1 if issues found)
    python internal/validate_notebook.py path/to/notebook.ipynb

    # Validate and auto-fix
    python internal/validate_notebook.py path/to/notebook.ipynb --fix

    # Validate all .ipynb files under a directory
    python internal/validate_notebook.py internal/ --fix
"""

import argparse
import json
import re
import sys
import uuid
from pathlib import Path

VALID_CELL_TYPES = {"code", "markdown", "raw"}

UUID4_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)

HTML_ANCHOR_RE = re.compile(r'<a\s+id\s*=\s*["\'].*?["\']\s*/?\s*>')


def _issues_for_cell(idx: int, cell: dict) -> list[str]:
    """Return a list of human-readable issue descriptions for one cell."""
    issues: list[str] = []
    ct = cell.get("cell_type")

    if ct not in VALID_CELL_TYPES:
        issues.append(f"Cell {idx}: invalid cell_type '{ct}'")
        return issues

    # id
    cid = cell.get("id")
    if not cid:
        issues.append(f"Cell {idx} ({ct}): missing 'id'")
    elif not UUID4_RE.match(str(cid)):
        issues.append(f"Cell {idx} ({ct}): 'id' is not a valid UUID4 ({cid!r})")

    # source
    src = cell.get("source")
    if not isinstance(src, list):
        issues.append(f"Cell {idx} ({ct}): 'source' should be a list, got {type(src).__name__}")

    # metadata
    meta = cell.get("metadata")
    if not isinstance(meta, dict):
        issues.append(f"Cell {idx} ({ct}): missing or invalid 'metadata'")
        meta = {}

    if ct == "code":
        if "language" not in meta:
            issues.append(f"Cell {idx} (code): missing metadata.language")
        if "execution_count" not in cell:
            issues.append(f"Cell {idx} (code): missing 'execution_count'")
        if "outputs" not in cell:
            issues.append(f"Cell {idx} (code): missing 'outputs'")
    elif ct in ("markdown", "raw"):
        if "codeCollapsed" not in meta:
            issues.append(f"Cell {idx} (markdown): missing metadata.codeCollapsed")

    # Markdown content checks
    if ct in ("markdown", "raw") and isinstance(src, list):
        text = "".join(src)
        if HTML_ANCHOR_RE.search(text):
            issues.append(f"Cell {idx} (markdown): contains HTML anchor tag (<a id=...>)")
        if text.lstrip().startswith("---"):
            issues.append(f"Cell {idx} (markdown): starts with '---' horizontal rule")

    return issues


def _fix_cell(cell: dict) -> int:
    """Apply fixes to a single cell in-place. Returns count of fixes applied."""
    fixes = 0
    ct = cell.get("cell_type", "code")

    if "id" not in cell or not cell["id"]:
        cell["id"] = str(uuid.uuid4())
        fixes += 1

    if "metadata" not in cell or not isinstance(cell["metadata"], dict):
        cell["metadata"] = {}
        fixes += 1

    if ct == "code":
        if "language" not in cell["metadata"]:
            cell["metadata"]["language"] = "python"
            fixes += 1
        if "execution_count" not in cell:
            cell["execution_count"] = None
            fixes += 1
        if "outputs" not in cell:
            cell["outputs"] = []
            fixes += 1
    elif ct in ("markdown", "raw"):
        if "codeCollapsed" not in cell["metadata"]:
            cell["metadata"]["codeCollapsed"] = True
            fixes += 1

    return fixes


def validate_notebook(path: Path, fix: bool = False) -> list[str]:
    """Validate a single notebook file. Returns list of issues found."""
    try:
        with open(path) as f:
            nb = json.load(f)
    except json.JSONDecodeError as e:
        return [f"{path}: Invalid JSON — {e}"]

    if "cells" not in nb:
        return [f"{path}: No 'cells' key found — not a valid notebook"]

    all_issues: list[str] = []
    total_fixes = 0

    for idx, cell in enumerate(nb["cells"]):
        issues = _issues_for_cell(idx, cell)
        all_issues.extend(issues)
        if fix and issues:
            total_fixes += _fix_cell(cell)

    if fix and total_fixes > 0:
        with open(path, "w") as f:
            json.dump(nb, f, indent=1, ensure_ascii=False)
            f.write("\n")
        print(f"  FIXED {path}: {total_fixes} fix(es) applied across {len(nb['cells'])} cells")
    elif all_issues:
        print(f"  FAIL  {path}: {len(all_issues)} issue(s)")
    else:
        print(f"  OK    {path}")

    return all_issues


def main():
    parser = argparse.ArgumentParser(
        description="Validate Snowflake Workspace Notebook files"
    )
    parser.add_argument(
        "paths",
        nargs="+",
        help="Notebook file(s) or directories to check",
    )
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Auto-fix missing metadata fields (adds ids, execution_count, etc.)",
    )
    args = parser.parse_args()

    notebooks: list[Path] = []
    for p in args.paths:
        path = Path(p)
        if path.is_file() and path.suffix == ".ipynb":
            notebooks.append(path)
        elif path.is_dir():
            notebooks.extend(sorted(path.rglob("*.ipynb")))
        else:
            print(f"Skipping {p} (not a .ipynb file or directory)")

    if not notebooks:
        print("No .ipynb files found.")
        sys.exit(0)

    all_issues: list[str] = []
    for nb_path in notebooks:
        issues = validate_notebook(nb_path, fix=args.fix)
        all_issues.extend(issues)

    print()
    if all_issues and not args.fix:
        print(f"Found {len(all_issues)} issue(s). Run with --fix to auto-repair.")
        for issue in all_issues:
            print(f"  - {issue}")
        sys.exit(1)
    elif all_issues and args.fix:
        print(f"Fixed {len(all_issues)} issue(s).")
        sys.exit(0)
    else:
        print("All notebooks valid.")
        sys.exit(0)


if __name__ == "__main__":
    main()
