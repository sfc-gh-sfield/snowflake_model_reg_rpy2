#!/bin/bash
# =============================================================================
# Sync r_notebook to Public Repository
# =============================================================================
#
# This script syncs the r_notebook folder from the internal development repo
# to the public-facing Snowflake-Labs repository.
#
# What it does:
#   1. Copies files from r_notebook/ to the public repo (excluding archive/)
#   2. Replaces development-specific values with user-configurable placeholders
#   3. Clears notebook outputs (if any)
#
# Usage:
#   ./sync_to_public_repo.sh /path/to/public/repo
#
# Example:
#   ./sync_to_public_repo.sh ~/repos/sf_workspace_notebook_r_integration
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration - values to replace
DEV_DATABASE="SIMON"
DEV_WAREHOUSE="SIMON_XS"
PUBLIC_DATABASE="<YOUR_DATABASE>"
PUBLIC_WAREHOUSE="<YOUR_WAREHOUSE>"

# Get script directory (source repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/r_notebook"

# Check arguments
if [ -z "$1" ]; then
    echo -e "${RED}Error: Please provide the path to the public repository${NC}"
    echo "Usage: $0 /path/to/public/repo"
    echo "Example: $0 ~/repos/sf_workspace_notebook_r_integration"
    exit 1
fi

TARGET_DIR="$1"

# Validate directories
if [ ! -d "$SOURCE_DIR" ]; then
    echo -e "${RED}Error: Source directory not found: $SOURCE_DIR${NC}"
    exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
    echo -e "${RED}Error: Target directory not found: $TARGET_DIR${NC}"
    echo "Please clone the public repo first:"
    echo "  git clone https://github.com/Snowflake-Labs/sf_workspace_notebook_r_integration.git"
    exit 1
fi

if [ ! -d "$TARGET_DIR/.git" ]; then
    echo -e "${RED}Error: Target directory is not a git repository: $TARGET_DIR${NC}"
    exit 1
fi

echo -e "${GREEN}=== Syncing r_notebook to Public Repository ===${NC}"
echo "Source: $SOURCE_DIR"
echo "Target: $TARGET_DIR"
echo ""

# Files/folders to exclude from source
EXCLUDES=(
    "archive"
    "__pycache__"
    ".ipynb_checkpoints"
    "*.pyc"
    ".DS_Store"
    "notebook_env"
    ".folder"
)

# Files/folders to preserve in target (not delete)
PRESERVE=(
    ".git"
    "LICENSE"
)

# Build rsync exclude arguments
EXCLUDE_ARGS=""
for exclude in "${EXCLUDES[@]}"; do
    EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$exclude"
done

# Build rsync filter arguments to preserve certain files in target
FILTER_ARGS=""
for preserve in "${PRESERVE[@]}"; do
    FILTER_ARGS="$FILTER_ARGS --filter=P_$preserve"
done

# Step 1: Sync files (excluding archive and other unwanted files)
echo -e "${YELLOW}Step 1: Copying files...${NC}"
rsync -av --delete $EXCLUDE_ARGS $FILTER_ARGS "$SOURCE_DIR/" "$TARGET_DIR/"
echo ""

# Step 2: Replace development values with placeholders
echo -e "${YELLOW}Step 2: Replacing development values with placeholders...${NC}"

# Find and replace in all relevant files
# Note: In JSON files (*.ipynb), quotes are escaped as \"
find "$TARGET_DIR" -type f \( -name "*.ipynb" -o -name "*.py" -o -name "*.md" -o -name "*.yaml" -o -name "*.yml" \) | while read file; do
    if grep -q "$DEV_DATABASE\|$DEV_WAREHOUSE" "$file" 2>/dev/null; then
        echo "  Processing: $(basename "$file")"
        # Use sed to replace (works on macOS and Linux)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS - handle both regular quotes and JSON-escaped quotes
            # JSON escaped quotes: \"SIMON\" -> \"<YOUR_DATABASE>\"
            sed -i '' "s/\\\\\"$DEV_DATABASE\\\\\"/\\\\\"$PUBLIC_DATABASE\\\\\"/g" "$file"
            sed -i '' "s/\\\\\"$DEV_WAREHOUSE\\\\\"/\\\\\"$PUBLIC_WAREHOUSE\\\\\"/g" "$file"
            # Regular quotes: "SIMON" -> "<YOUR_DATABASE>"
            sed -i '' "s/\"$DEV_DATABASE\"/\"$PUBLIC_DATABASE\"/g" "$file"
            sed -i '' "s/\"$DEV_WAREHOUSE\"/\"$PUBLIC_WAREHOUSE\"/g" "$file"
        else
            # Linux - handle both regular quotes and JSON-escaped quotes
            sed -i "s/\\\\\"$DEV_DATABASE\\\\\"/\\\\\"$PUBLIC_DATABASE\\\\\"/g" "$file"
            sed -i "s/\\\\\"$DEV_WAREHOUSE\\\\\"/\\\\\"$PUBLIC_WAREHOUSE\\\\\"/g" "$file"
            sed -i "s/\"$DEV_DATABASE\"/\"$PUBLIC_DATABASE\"/g" "$file"
            sed -i "s/\"$DEV_WAREHOUSE\"/\"$PUBLIC_WAREHOUSE\"/g" "$file"
        fi
    fi
done
echo ""

# Step 3: Clear notebook outputs (security measure)
echo -e "${YELLOW}Step 3: Clearing notebook outputs...${NC}"
python3 - "$TARGET_DIR" << 'PYEOF'
import json
import os
import sys

target_dir = sys.argv[1] if len(sys.argv) > 1 else "."

for root, dirs, files in os.walk(target_dir):
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
            except Exception as e:
                print(f"  Warning: Could not process {f}: {e}")
PYEOF
echo ""

# Step 4: Summary
echo -e "${GREEN}=== Sync Complete ===${NC}"
echo ""
echo "Files synced to: $TARGET_DIR"
echo ""
echo "Next steps:"
echo "  1. cd $TARGET_DIR"
echo "  2. Review changes: git status && git diff"
echo "  3. Commit: git add -A && git commit -m 'Sync from development repo'"
echo "  4. Push: git push origin main"
echo ""
