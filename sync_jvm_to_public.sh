#!/usr/bin/env bash
# sync_jvm_to_public.sh
# ============================================================================
# Syncs the Scala & Java toolkit from this private development repo to the
# public Snowflake-Labs/snowflake-notebook-jvm repository.
#
# What gets synced:
#   - internal/Scala_Snowpark/prototype/*  (flattened to repo root)
#
# What is excluded:
#   - internal/              (dev notes, feasibility docs, spike notebooks)
#   - blog_scala_workspace.md (blog draft, published separately)
#   - __pycache__/           (Python bytecode)
#   - .ipynb_checkpoints/    (Jupyter checkpoints)
#   - .metadata_scala/       (runtime metadata)
#   - *.log                  (log files)
#   - sync_jvm_to_public.sh  (this script)
#
# What is preserved in target:
#   - .git/                  (target repo's git history)
#   - LICENSE                (Apache 2.0, pre-created in remote)
#
# Usage:
#   ./sync_jvm_to_public.sh /path/to/local/clone/of/snowflake-notebook-jvm
#   ./sync_jvm_to_public.sh /path/to/clone --dry-run
#
# Prerequisites:
#   - Public repo cloned locally: Snowflake-Labs/snowflake-notebook-jvm
#   - rsync installed
#   - python3 available (for notebook output clearing)
# ============================================================================

set -euo pipefail

# --- Configuration ---
PRIVATE_REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${PRIVATE_REPO_DIR}/internal/Scala_Snowpark/prototype"
PUBLIC_REMOTE="https://github.com/Snowflake-Labs/snowflake-notebook-jvm.git"
DRY_RUN=false

# --- Parse arguments ---
TARGET_DIR=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -*) echo "Unknown flag: $arg"; exit 1 ;;
    *) TARGET_DIR="$arg" ;;
  esac
done

if [[ -z "$TARGET_DIR" ]]; then
  echo "Error: Please provide the path to the local clone of snowflake-notebook-jvm"
  echo ""
  echo "Usage: $0 /path/to/snowflake-notebook-jvm [--dry-run]"
  echo ""
  echo "If you haven't cloned yet:"
  echo "  git clone ${PUBLIC_REMOTE}"
  exit 1
fi

# --- Validate ---
if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Error: Source directory not found: $SOURCE_DIR"
  exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: Target directory not found: $TARGET_DIR"
  echo "Clone the public repo first:"
  echo "  git clone ${PUBLIC_REMOTE}"
  exit 1
fi

if [[ ! -d "$TARGET_DIR/.git" ]]; then
  echo "Error: Target directory is not a git repository: $TARGET_DIR"
  exit 1
fi

if $DRY_RUN; then
  echo "=== DRY RUN MODE ==="
  echo ""
fi

echo "Source  : $SOURCE_DIR"
echo "Target  : $TARGET_DIR"
echo "Remote  : $PUBLIC_REMOTE"
echo ""

# --- Step 1: Sync files ---
echo "1/4  Syncing toolkit files to public repo root..."
rsync -av --delete \
  --exclude='__pycache__' \
  --exclude='.ipynb_checkpoints' \
  --exclude='.metadata_scala' \
  --exclude='*.log' \
  --exclude='.DS_Store' \
  --filter='P .git' \
  --filter='P LICENSE' \
  --filter='P .gitignore' \
  "$SOURCE_DIR/" "$TARGET_DIR/"
echo ""

# --- Step 2: Generate .gitignore ---
echo "2/4  Writing .gitignore..."
cat > "$TARGET_DIR/.gitignore" << 'GITIGNORE_EOF'
# =============================================================================
# snowflake-notebook-jvm .gitignore
# =============================================================================

# Python
__pycache__/
*.py[cod]
*.so

# Jupyter
.ipynb_checkpoints/

# JVM / Scala build artifacts
.metadata_scala/
*.class
*.jar

# Logs
*.log
setup_scala.log

# OS files
.DS_Store
Thumbs.db

# IDE
.idea/
.vscode/
*.swp
*~
GITIGNORE_EOF
echo "  Created .gitignore"
echo ""

# --- Step 3: Clear notebook outputs ---
echo "3/4  Clearing notebook outputs..."
python3 - "$TARGET_DIR" << 'PYEOF'
import json
import os
import sys

target_dir = sys.argv[1] if len(sys.argv) > 1 else "."

for root, dirs, files in os.walk(target_dir):
    # Skip .git directory
    dirs[:] = [d for d in dirs if d != '.git']
    for f in files:
        if f.endswith('.ipynb'):
            fpath = os.path.join(root, f)
            try:
                with open(fpath, 'r') as fp:
                    nb = json.load(fp)

                modified = False
                for cell in nb.get('cells', []):
                    if cell.get('outputs'):
                        cell['outputs'] = []
                        modified = True
                    if 'execution_count' in cell:
                        cell['execution_count'] = None
                        modified = True

                if modified:
                    with open(fpath, 'w') as fp:
                        json.dump(nb, fp, indent=2)
                    print(f"  Cleared outputs: {os.path.basename(fpath)}")
                else:
                    print(f"  No outputs to clear: {os.path.basename(fpath)}")
            except Exception as e:
                print(f"  Warning: Could not process {f}: {e}")
PYEOF
echo ""

# --- Step 4: Summary ---
echo "4/4  Summary"
echo ""
echo "Files synced to: $TARGET_DIR"
echo ""

if $DRY_RUN; then
  echo "=== DRY RUN — Changes staged but NOT committed ==="
  echo ""
  cd "$TARGET_DIR"
  git add -A
  if git diff --cached --quiet; then
    echo "No changes detected. Public repo is up to date."
  else
    echo "Changes that would be committed:"
    git diff --cached --stat
  fi
  git reset HEAD -- . > /dev/null 2>&1
  echo ""
  echo "Dry run complete. No changes committed."
else
  echo "Next steps:"
  echo "  1. cd $TARGET_DIR"
  echo "  2. Review changes: git status && git diff"
  echo "  3. Commit: git add -A && git commit -m 'Sync from development repo'"
  echo "  4. Push: git push origin main"
fi
