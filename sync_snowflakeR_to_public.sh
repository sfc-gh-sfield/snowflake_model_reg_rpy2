#!/usr/bin/env bash
# sync_snowflakeR_to_public.sh
# ============================================================================
# Syncs the snowflakeR R package from this private development repo to the
# public Snowflake-Labs/snowflakeR repository.
#
# What gets synced:
#   - snowflakeR/          (the R package -- root of the public repo)
#   - .github/             (CI workflows)
#   - LICENSE              (Apache-2.0)
#   - r_notebook/snowflakeR/  -> notebooks/ (demo notebooks)
#
# What is excluded:
#   - internal/            (dev notes, plans)
#   - tests/integration/   (live-connection tests with local paths)
#   - r_notebook/*.ipynb   (legacy pre-package notebooks)
#   - *.Rcheck/            (check artefacts)
#   - *.tar.gz             (build artefacts)
#   - notebook_config.yaml (personal Snowflake config)
#   - sync_snowflakeR_to_public.sh  (this script)
#
# Safety:
#   A post-copy scan checks the staging directory for known personal
#   identifiers and secrets patterns before committing.
#
# Usage:
#   ./sync_snowflakeR_to_public.sh [--dry-run]
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - Public repo exists: Snowflake-Labs/snowflakeR
#   - rsync installed
# ============================================================================

set -euo pipefail

# --- Configuration ---
PRIVATE_REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLIC_REMOTE="https://github.com/Snowflake-Labs/snowflakeR.git"
STAGING_DIR="$(mktemp -d)"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "=== DRY RUN MODE ==="
fi

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "Private repo : $PRIVATE_REPO_DIR"
echo "Staging dir  : $STAGING_DIR"
echo ""

# --- Step 1: Copy R package to staging (becomes root of public repo) ---
echo "1/6  Copying snowflakeR/ package files..."
rsync -a --delete \
  --exclude='*.Rcheck' \
  --exclude='*.tar.gz' \
  --exclude='.Rhistory' \
  --exclude='.RData' \
  --exclude='__pycache__' \
  --exclude='inst/notebooks/notebook_config.yaml' \
  --exclude='tests/integration/' \
  "$PRIVATE_REPO_DIR/snowflakeR/" \
  "$STAGING_DIR/"

# --- Step 2: Copy CI workflows ---
echo "2/6  Copying .github/ workflows..."
rsync -a \
  "$PRIVATE_REPO_DIR/.github/" \
  "$STAGING_DIR/.github/"

# --- Step 3: Copy LICENSE ---
echo "3/6  Copying LICENSE..."
if [[ -f "$PRIVATE_REPO_DIR/LICENSE" ]]; then
  cp "$PRIVATE_REPO_DIR/LICENSE" "$STAGING_DIR/LICENSE"
else
  echo "     (no LICENSE file found in private repo root, skipping)"
fi

# --- Step 4: Copy snowflakeR notebooks ---
echo "4/6  Copying demo notebooks..."
if [[ -d "$PRIVATE_REPO_DIR/r_notebook/snowflakeR" ]]; then
  mkdir -p "$STAGING_DIR/notebooks"
  rsync -a \
    "$PRIVATE_REPO_DIR/r_notebook/snowflakeR/" \
    "$STAGING_DIR/notebooks/"
fi

# --- Step 5: Scan for leaked secrets / personal identifiers ---
echo "5/6  Scanning staging directory for secrets and personal identifiers..."

BLOCKED_PATTERNS=(
  '/Users/sfield'
  'simon_rsa_key'
  'ak32940'
  'SIMON_XS'
  'sfc-gh-sfield'
  'connection.json'
)

scan_failed=false
for pattern in "${BLOCKED_PATTERNS[@]}"; do
  # Search text files only (skip .git and binary files)
  matches=$(grep -r --include='*.R' --include='*.Rd' --include='*.py' \
    --include='*.Rmd' --include='*.md' --include='*.yml' --include='*.yaml' \
    --include='*.sh' --include='*.txt' --include='*.json' \
    -l "$pattern" "$STAGING_DIR" 2>/dev/null || true)
  if [[ -n "$matches" ]]; then
    echo "  BLOCKED: Pattern '$pattern' found in:"
    echo "$matches" | sed 's/^/    /'
    scan_failed=true
  fi
done

if $scan_failed; then
  echo ""
  echo "ERROR: Blocked patterns found in staging directory."
  echo "Fix the source files in the private repo and re-run."
  exit 1
fi
echo "  OK: No blocked patterns found."

# --- Step 6: Commit and push to public repo ---
echo "6/6  Committing and pushing to public repo..."
cd "$STAGING_DIR"

# Initialise git if not already
if [[ ! -d .git ]]; then
  git init -b main
  git remote add origin "$PUBLIC_REMOTE"
fi

# Try to pull existing history (will fail on first run -- that's OK)
git fetch origin main 2>/dev/null && git reset --soft origin/main 2>/dev/null || true

git add -A

# Check if there are changes to commit
if git diff --cached --quiet; then
  echo ""
  echo "No changes to sync. Public repo is up to date."
  exit 0
fi

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT_MSG="Sync from private repo @ $TIMESTAMP"

if $DRY_RUN; then
  echo ""
  echo "=== Changes that would be pushed ==="
  git diff --cached --stat
  echo ""
  echo "Commit message: $COMMIT_MSG"
  echo ""
  echo "Dry run complete. No changes pushed."
else
  git commit -m "$COMMIT_MSG"
  git push -u origin main
  echo ""
  echo "Sync complete."
fi
