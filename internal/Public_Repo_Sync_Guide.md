# Public Repository Sync Guide

This document describes how to sync changes from the internal development repo to the public-facing Snowflake-Labs repository.

## Repository Structure

| Repository | Purpose | URL |
|------------|---------|-----|
| **Development (Internal)** | Internal development and testing | This repo |
| **Public (Snowflake-Labs)** | Customer-facing release | https://github.com/Snowflake-Labs/sf_workspace_notebook_r_integration |

## What Gets Synced

The sync process copies the contents of `r_notebook/` to become the root of the public repository.

### Included Files

- `r_workspace_notebook.ipynb` - Main R integration notebook
- `r_forecasting_demo.ipynb` - Model Registry demo notebook
- `r_helpers.py` - Python helper functions
- `r_packages.yaml` - R package configuration
- `setup_r_environment.sh` - R environment setup script
- `README.md` - Documentation
- `PROJECT_OVERVIEW.md` - Project summary
- `.gitignore` - Git ignore rules

### Excluded Files

- `archive/` - Archived/non-working code (internal only)
- `notebook_env` - Environment marker file
- `.folder` - Folder marker
- `__pycache__/` - Python cache
- `.ipynb_checkpoints/` - Jupyter checkpoints

## Value Replacements

The sync script automatically replaces development-specific values with user-configurable placeholders:

| Development Value | Public Value |
|-------------------|--------------|
| `"SIMON"` | `"<YOUR_DATABASE>"` |
| `"SIMON_XS"` | `"<YOUR_WAREHOUSE>"` |

## Using the Sync Script

### Prerequisites

1. Clone the public repository:
   ```bash
   git clone https://github.com/Snowflake-Labs/sf_workspace_notebook_r_integration.git
   ```

2. Ensure you're on the correct branch in both repos

### Running the Sync

```bash
# From the development repo root
./sync_to_public_repo.sh /path/to/sf_workspace_notebook_r_integration
```

Example:
```bash
./sync_to_public_repo.sh ~/repos/sf_workspace_notebook_r_integration
```

### What the Script Does

1. **Copies files** from `r_notebook/` to the public repo (excluding `archive/`)
2. **Replaces values** - Substitutes dev database/warehouse with placeholders
3. **Clears outputs** - Removes all notebook outputs (security measure)

### After Syncing

1. Navigate to the public repo:
   ```bash
   cd /path/to/sf_workspace_notebook_r_integration
   ```

2. Review changes:
   ```bash
   git status
   git diff
   ```

3. Commit and push:
   ```bash
   git add -A
   git commit -m "Sync from development repo - <brief description of changes>"
   git push origin main
   ```

## Release Workflow

### When to Sync

- After completing and testing new features
- After fixing bugs that affect public users
- After updating documentation

### Pre-Sync Checklist

Before running the sync, ensure:

- [ ] All changes are committed in the dev repo
- [ ] Features have been tested in Snowflake Workspace Notebooks
- [ ] No credentials or sensitive data in code or outputs
- [ ] Documentation is updated
- [ ] README reflects current functionality

### Post-Sync Verification

After pushing to the public repo:

1. Verify the GitHub page renders correctly
2. Confirm no sensitive data was accidentally included
3. Test download/clone of the public repo works

## Troubleshooting

### Sync fails with "Target directory not found"

Clone the public repo first:
```bash
git clone https://github.com/Snowflake-Labs/sf_workspace_notebook_r_integration.git
```

### Sync overwrites uncommitted changes

The sync uses `rsync --delete`, which will remove files not in the source. Commit or stash any changes in the public repo before syncing.

### Values not being replaced

Check that the values in the script match exactly (case-sensitive, including quotes):
```bash
DEV_DATABASE="SIMON"
DEV_WAREHOUSE="SIMON_XS"
```

## Adding New Replacements

If you need to add more values to replace during sync, edit `sync_to_public_repo.sh`:

1. Add variables at the top:
   ```bash
   DEV_NEWVALUE="internal_value"
   PUBLIC_NEWVALUE="<YOUR_NEWVALUE>"
   ```

2. Add sed replacements in the Step 2 section:
   ```bash
   sed -i '' "s/\"$DEV_NEWVALUE\"/\"$PUBLIC_NEWVALUE\"/g" "$file"
   ```

## File Structure After Sync

```
sf_workspace_notebook_r_integration/
├── .gitignore
├── PROJECT_OVERVIEW.md
├── README.md
├── r_forecasting_demo.ipynb
├── r_helpers.py
├── r_packages.yaml
├── r_workspace_notebook.ipynb
└── setup_r_environment.sh
```
