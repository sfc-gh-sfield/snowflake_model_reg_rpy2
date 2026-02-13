# Release Workflow: Internal Dev → Public Repo

**Last Updated:** 2026-02-13

This document describes the steps to commit changes in the internal development
repo and sync the snowflakeR package to the public Snowflake-Labs repository.

---

## Repository Layout

| Repository | Purpose | URL |
|---|---|---|
| **Internal (dev)** | Development, testing, blog drafts, internal docs | `sfc-gh-sfield/snowflake_model_reg_rpy2` |
| **Public** | Customer-facing snowflakeR package | `Snowflake-Labs/snowflakeR` |

### What lives where

```
snowflake_model_reg_rpy2/               # Internal dev repo
├── snowflakeR/                         # R package (synced to public)
│   ├── R/                              # Package source
│   ├── man/                            # Roxygen-generated docs
│   ├── vignettes/                      # Package vignettes
│   ├── inst/notebooks/                 # Demo notebooks (synced)
│   └── ...
├── blog_series/                        # Blog drafts (PRIVATE -- never synced)
├── internal/                           # Internal docs, devops, previews (PRIVATE)
│   ├── devops/                         # This folder -- workflows, guidelines
│   ├── vignette_previews/              # Rendered HTML previews of vignettes
│   └── ...
├── .github/                            # CI workflows (synced to public)
├── sync_snowflakeR_to_public.sh        # Sync script
└── DEVELOPMENT.md                      # Dev guide (needs updating)
```

---

## Step-by-Step Release Workflow

### 1. Make and test your changes

Work in the `snowflakeR/` directory. Follow the development standards in
`internal/snowflakeR_package_dev_standards.md`.

### 2. Regenerate roxygen docs (if you changed any roxygen comments)

```bash
cd snowflakeR
Rscript -e 'roxygen2::roxygenise()'
```

This updates `man/*.Rd` files and `NAMESPACE`. Always commit these generated
files alongside your source changes.

### 3. Re-render vignette previews (if you changed any vignettes)

```bash
cd snowflakeR
Rscript -e '
for (v in c("workspace-notebooks", "setup", "getting-started",
            "feature-store", "model-registry")) {
  rmd <- file.path("vignettes", paste0(v, ".Rmd"))
  if (file.exists(rmd)) {
    message("Rendering: ", v)
    rmarkdown::render(rmd, output_dir = "../internal/vignette_previews",
                      quiet = TRUE)
  }
}
'
```

Previews live in `internal/vignette_previews/` (private, not synced).

### 4. Commit to the internal dev repo

```bash
cd /path/to/snowflake_model_reg_rpy2
git add -A   # or selectively add files
git commit -m "Description of changes"
```

**What NOT to commit:**
- Credentials, tokens, `.env` files
- `notebook_config.yaml` (dev-specific, gitignored)
- Large data files or model artefacts

### 5. Dry-run the public sync

```bash
./sync_snowflakeR_to_public.sh --dry-run
```

Review the output. Check:
- No unexpected files in the diff
- No credential leaks (database names, account IDs, etc.)
- File counts look reasonable

### 6. Sync to public

```bash
./sync_snowflakeR_to_public.sh
```

The script:
1. Copies `snowflakeR/` to a staging directory (becomes the root of the public repo)
2. Copies `.github/` workflows
3. Copies `LICENSE` (if present)
4. Fetches the public repo's existing history
5. Commits and pushes to `Snowflake-Labs/snowflakeR`

### 7. Verify

- Check the [public repo](https://github.com/Snowflake-Labs/snowflakeR) on GitHub
- Confirm no sensitive data was included
- Verify the README renders correctly

---

## What Gets Synced (and What Doesn't)

### Synced to public repo

- `snowflakeR/` → becomes the repo root (R/, man/, vignettes/, inst/, etc.)
- `.github/` → CI workflows
- `LICENSE` → Apache-2.0

### Never synced (stays private)

- `blog_series/` — blog drafts, outlines, images
- `internal/` — dev docs, vignette previews, devops guides
- `r_notebook/` — legacy notebooks (superseded by `snowflakeR/inst/notebooks/`)
- `dj_ml/`, `dj_ml_rpy2/` — early prototypes
- `sync_*.sh` — sync scripts themselves
- `DEVELOPMENT.md` — internal dev guide
- `notebook_config.yaml` — dev-specific config (template is synced)

---

## Quick Reference

```bash
# Full workflow (common case)
cd snowflakeR && Rscript -e 'roxygen2::roxygenise()'
cd ..
git add -A && git commit -m "your message"
./sync_snowflakeR_to_public.sh --dry-run   # review
./sync_snowflakeR_to_public.sh             # push
```

```bash
# If you also changed vignettes
cd snowflakeR
Rscript -e 'roxygen2::roxygenise()'
Rscript -e 'for (v in Sys.glob("vignettes/*.Rmd")) rmarkdown::render(v, output_dir="../internal/vignette_previews", quiet=TRUE)'
cd ..
git add -A && git commit -m "your message"
./sync_snowflakeR_to_public.sh
```

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `sync_snowflakeR_to_public.sh` fails to push | Check `gh auth status` and ensure you have push access to `Snowflake-Labs/snowflakeR` |
| roxygen warnings about undocumented params | Add `@param` entries to the roxygen block in the `.R` file |
| Vignette render fails | Check that `rmarkdown` and `knitr` are installed; vignettes don't eval code so Snowflake access isn't needed |
| Public repo has diverged | The sync script does `git fetch origin main && git reset --soft origin/main` -- it always works from the public repo's HEAD |
| Stale `.Rd` files | Delete the stale `.Rd` and re-run `roxygen2::roxygenise()` |

---

## Related Documents

- `internal/snowflakeR_package_dev_standards.md` — coding standards, style guide
- `internal/devops/CONTRIBUTING.md` — contributor onboarding guide
- `internal/Public_Repo_Sync_Guide.md` — **OUTDATED**, superseded by this document
- `DEVELOPMENT.md` — **OUTDATED**, superseded by this document
