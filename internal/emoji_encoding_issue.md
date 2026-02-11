# Emoji Encoding Issue: Cursor vs Snowflake Workspace

## Problem

When editing Jupyter notebooks in both Cursor (local IDE) and Snowflake Workspace Notebooks, emoji characters get re-encoded differently by each environment. This causes:

1. **Phantom changes** - Files appear modified even when no code was changed
2. **Merge conflicts** - Git sees encoding differences as content changes
3. **Sync issues** - Every pull/push requires manual conflict resolution

## Root Cause

Different Unicode representations of the same emoji:
- Cursor may use: `✓` (U+2713)
- Workspace may use: `✓` with different encoding or HTML entities
- Same visual character, different byte representation

## Solution

Replace emojis with ASCII equivalents that are stable across all environments.

## Emoji -> ASCII Mapping

| Emoji | ASCII | Usage |
|-------|-------|-------|
| ✓ | `[OK]` | Success messages |
| ✗ | `[FAIL]` | Error messages |
| ⚠ / ⚠️ | `[WARN]` | Warning messages |
| ✅ | `[YES]` | Positive status in tables |
| ❌ | `[NO]` | Negative status in tables |
| → | `->` | Arrows in diagrams |
| ← | `<-` | Arrows in diagrams |
| ↕ | `<->` | Bidirectional arrows |
| ↑ | `^` | Up arrow |
| ↓ | `v` | Down arrow |

## Files Updated (2026-02-11)

- `r_notebook/r_setup_interop.ipynb`
- `r_notebook/r_snowflake_connectivity.ipynb`
- `r_notebook/r_forecasting_demo.ipynb`
- `r_notebook/_archived_r_workspace_notebook.ipynb`
- `r_notebook/r_helpers.py`
- `r_notebook/setup_r_environment.sh`

## Future: Restoring Emojis

If/when the Snowflake Notebooks team fixes the encoding issue:

1. File a bug with Snowflake Notebooks team referencing this document
2. Once fixed, use find/replace to restore emojis:
   - `[OK]` -> `✓`
   - `[FAIL]` -> `✗`
   - `[WARN]` -> `⚠`
   - `[YES]` -> `✅`
   - `[NO]` -> `❌`
   - `->` -> `→` (careful with code arrows)

## Prevention

When adding new output messages to notebooks or Python files:
- Use ASCII markers: `[OK]`, `[FAIL]`, `[WARN]`
- Avoid emojis until encoding issue is resolved
