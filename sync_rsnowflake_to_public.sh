#!/usr/bin/env bash
# sync_rsnowflake_to_public.sh
# ============================================================================
# Syncs the RSnowflake R package from this private development repo to the
# public Snowflake-Labs/RSnowflake repository.
#
# What gets synced:
#   - RSnowflake/           (the R package -- root of the public repo)
#   - .github/              (CI workflows, if present)
#   - LICENSE               (Apache-2.0)
#
# What is excluded:
#   - internal/             (dev notes, plans, feasibility studies)
#   - snowflakeR/           (the companion ML package -- separate repo)
#   - tests/integration/    (live-connection tests with local paths)
#   - *.Rcheck/             (check artefacts)
#   - *.tar.gz              (build artefacts)
#   - sync_*.sh             (sync scripts)
#
# Safety:
#   A post-copy scan checks the staging directory for known personal
#   identifiers and secrets patterns before committing.
#
# Usage:
#   ./sync_rsnowflake_to_public.sh [--dry-run]
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - Public repo exists: Snowflake-Labs/RSnowflake
#   - rsync installed
# ============================================================================

set -euo pipefail

# --- Configuration ---
PRIVATE_REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLIC_REMOTE="https://github.com/Snowflake-Labs/RSnowflake.git"
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
echo "1/4  Copying RSnowflake/ package files..."
rsync -a --delete \
  --exclude='*.Rcheck' \
  --exclude='*.tar.gz' \
  --exclude='.Rhistory' \
  --exclude='.RData' \
  --exclude='.Ruserdata' \
  --exclude='__pycache__' \
  --exclude='tests/integration/' \
  "$PRIVATE_REPO_DIR/RSnowflake/" \
  "$STAGING_DIR/"

# --- Step 2: Copy CI workflows ---
echo "2/4  Copying .github/ workflows..."
if [[ -d "$PRIVATE_REPO_DIR/.github" ]]; then
  rsync -a \
    "$PRIVATE_REPO_DIR/.github/" \
    "$STAGING_DIR/.github/"
else
  echo "     (no .github/ directory found, skipping)"
fi

# --- Step 3: Copy LICENSE ---
echo "3/4  Copying LICENSE..."
if [[ -f "$PRIVATE_REPO_DIR/LICENSE" ]]; then
  cp "$PRIVATE_REPO_DIR/LICENSE" "$STAGING_DIR/LICENSE"
else
  echo "     (no LICENSE file found in private repo root, skipping)"
fi

# --- Step 4: Scan for leaked secrets / personal identifiers ---
echo "4/4  Scanning staging directory for secrets and personal identifiers..."

BLOCKED_PATTERNS=(
  '/Users/sfield'
  'simon_rsa_key'
  'ak32940'
  'SIMON_XS'
  'sfc-gh-sfield'
  'connection.json'
  'rsnowflake_dev'
  'simon.field@snowflake'
)

scan_failed=false
for pattern in "${BLOCKED_PATTERNS[@]}"; do
  matches=$(grep -r --include='*.R' --include='*.Rd' --include='*.py' \
    --include='*.Rmd' --include='*.md' --include='*.yml' --include='*.yaml' \
    --include='*.sh' --include='*.txt' --include='*.json' --include='*.toml' \
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

# --- Step 5: Commit and push to public repo ---
echo "5/5  Committing and pushing to public repo..."
cd "$STAGING_DIR"

if [[ ! -d .git ]]; then
  git init -b main
  git remote add origin "$PUBLIC_REMOTE"
fi

git fetch origin main 2>/dev/null && git reset --soft origin/main 2>/dev/null || true

git add -A

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
