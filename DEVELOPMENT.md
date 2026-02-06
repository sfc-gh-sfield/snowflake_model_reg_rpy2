# Development Guide

This is the internal development repository. The public-facing code is released to:
**https://github.com/Snowflake-Labs/sf_workspace_notebook_r_integration**

## Repository Structure

```
snowflake_model_reg_rpy2/           # This repo (internal development)
├── r_notebook/                     # → Synced to public repo
│   ├── archive/                    # NOT synced (internal only)
│   └── ...                         # All other files synced
├── internal/                       # Internal docs (gitignored)
├── dj_ml/                          # Original R subprocess approach
├── dj_ml_rpy2/                     # rpy2 approach reference
└── sync_to_public_repo.sh          # Sync script
```

## Syncing to Public Repository

When ready to release changes:

```bash
# 1. Clone public repo (if not already done)
git clone https://github.com/Snowflake-Labs/sf_workspace_notebook_r_integration.git /tmp/sf_workspace_notebook_r_integration

# 2. Run sync from this repo
./sync_to_public_repo.sh /tmp/sf_workspace_notebook_r_integration

# 3. Review, commit, and push
cd /tmp/sf_workspace_notebook_r_integration
git status && git diff
git add -A && git commit -m "Description of changes"
git push origin main
```

## What the Sync Does

1. **Copies** `r_notebook/` contents to public repo root
2. **Excludes** `archive/` folder (internal only)
3. **Replaces** dev values with placeholders:
   - `"SIMON"` → `"<YOUR_DATABASE>"`
   - `"SIMON_XS"` → `"<YOUR_WAREHOUSE>"`
4. **Clears** notebook outputs (security)
5. **Preserves** `.git/` and `LICENSE` in target

## Development Values

This repo uses real values for testing:
- Database: `SIMON`
- Warehouse: `SIMON_XS`

These are automatically replaced with `<YOUR_DATABASE>` and `<YOUR_WAREHOUSE>` during sync.

## Internal Documentation

See `internal/` folder for additional docs (not committed to git):
- `Public_Repo_Sync_Guide.md` - Detailed sync documentation
- `R_Integration_Summary_and_Recommendations.md` - Technical recommendations
