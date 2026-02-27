# Dependency Map: Python Connector to R Package

**Status**: Draft  
**Date**: 2026-02-27

---

## 1. Overview

This document maps every dependency of the Snowflake Connector for Python
to its R equivalent (or explains why no equivalent is needed). The goal is
to minimize hard dependencies in the R package while maintaining feature
parity with the Python connector's core functionality.

---

## 2. Python Connector Hard Dependencies -> R Equivalents

### 2.1 HTTP Stack

| Python Package | Role in Connector | R Equivalent | Dep Type | Notes |
|---------------|-------------------|-------------|----------|-------|
| `requests` | HTTP client for all REST API calls | `httr2` | **Import** | httr2 is the modern R HTTP client; pipe-based API, built-in retry, OAuth support. Wraps `curl`. |
| `urllib3` (vendored) | Connection pooling, low-level HTTP | `curl` (via httr2) | Transitive | httr2 depends on curl; connection pooling handled by curl's multi interface. |
| `certifi` | TLS certificate bundle | System CA bundle (via curl) | None needed | R's `curl` package uses the OS certificate store or a bundled Mozilla CA bundle. No separate package required. |
| `idna` | International domain name encoding | `curl` (built-in) | None needed | libcurl handles IDNA encoding internally. |
| `charset-normalizer` | Character encoding detection | Base R `Encoding()` / `iconv()` | None needed | R has built-in character encoding support. Snowflake returns UTF-8 exclusively. |

**Summary**: The entire Python HTTP stack (requests + urllib3 + certifi + idna +
charset-normalizer = 5 packages) maps to a single R Import: `httr2`.

### 2.2 Crypto / TLS

| Python Package | Role in Connector | R Equivalent | Dep Type | Notes |
|---------------|-------------------|-------------|----------|-------|
| `cryptography` | RSA key loading, JWT signing, TLS cert operations | `openssl` | **Suggests** | Only needed for key-pair JWT auth. PAT/session-token auth needs no crypto. |
| `pyOpenSSL` | OpenSSL bindings for TLS, OCSP checking | `curl` (via httr2) | None needed | libcurl handles TLS, certificate verification, and OCSP stapling natively. |
| `oscrypto` | OS-level crypto backend selection | None | None needed | R's `openssl` package links directly to system OpenSSL/LibreSSL. |
| `cffi` | C FFI for cryptography bindings | None | None needed | R packages use `.Call()` or `Rcpp` for C integration; `openssl` handles this internally. |
| `PyJWT` | JWT token encoding | `openssl` or `jose` | **Suggests** | JWT generation can be done with `openssl::jwt_encode_sig()` or the `jose` package. |

**Summary**: Python needs 5 crypto packages. R needs `openssl` as a Suggests
dependency (only for key-pair auth). For PAT/session-token auth, zero crypto
packages are needed.

### 2.3 Utility / OS Integration

| Python Package | Role in Connector | R Equivalent | Dep Type | Notes |
|---------------|-------------------|-------------|----------|-------|
| `platformdirs` | OS-appropriate config/cache directories | `rappdirs` or `tools::R_user_dir()` | None needed | R 4.0+ provides `tools::R_user_dir()` in base R. For Snowflake's `~/.snowflake/` convention, simple `path.expand()` suffices. |
| `filelock` | Cross-process file locking (credential cache) | `filelock` (CRAN) | Not needed initially | File locking only needed if we implement credential caching. Not in MVP. |
| `packaging` | Version parsing/comparison | `package_version()` (base R) | None needed | Base R has built-in version comparison. |
| `sortedcontainers` | Sorted data structures (query context cache) | Base R `list` / `environment` | None needed | R's built-in data structures suffice. |
| `tomlkit` / `tomli` | TOML parsing for connections.toml | `RcppTOML` | **Suggests** | Only needed if user has connections.toml. Can also parse with simple string ops for the subset of TOML we need. |

**Summary**: All Python utility packages map to base R functionality or are
not needed for the R package's use cases.

---

## 3. Python Connector Optional Dependencies -> R Equivalents

### 3.1 Arrow / DataFrame Extras

| Python Package | Install Extra | Role | R Equivalent | Dep Type | Notes |
|---------------|--------------|------|-------------|----------|-------|
| `pyarrow` | `[pandas]` | Arrow IPC result deserialization, fast DataFrame construction | `nanoarrow` or `arrow` | **Suggests** | `nanoarrow` is lightweight (no compiled Arrow libs). `arrow` is full-featured but heavier. |
| `pandas` | `[pandas]` | DataFrame construction, type coercion | Base R `data.frame` | None needed | R data.frames are the native tabular format. No extra package needed. |
| `numpy` | (via pandas) | Numeric array backing for DataFrames | Base R vectors | None needed | R vectors are the native numeric array type. |

**Recommendation**: Use `nanoarrow` as the Suggests dependency for Arrow
result fetching. It is small (~200 KB), has no system requirements, and
provides zero-copy Arrow-to-R conversion. Fall back to JSON results when
nanoarrow is not installed.

### 3.2 Secure Local Storage

| Python Package | Install Extra | Role | R Equivalent | Dep Type | Notes |
|---------------|--------------|------|-------------|----------|-------|
| `keyring` | `[secure-local-storage]` | Encrypted credential caching | `keyring` (CRAN) | **Suggests** | The R `keyring` package provides the same functionality. Optional, not needed for MVP. |

### 3.3 Other Extras

| Python Package | Install Extra | Role | R Equivalent | Notes |
|---------------|--------------|------|-------------|-------|
| `snowflake-ml-python` | N/A | Model Registry, Feature Store | `snowflakeR` (separate package) | ML features stay in the higher-level snowflakeR package. |
| `snowflake-snowpark-python` | N/A | DataFrame API, session management | N/A | Snowpark's DataFrame API has no R equivalent; not needed for DBI. |

---

## 4. Proposed R Package Dependency List

### 4.1 DESCRIPTION Imports (Hard Dependencies)

```
Imports:
    DBI (>= 1.2.0),
    methods,
    httr2 (>= 1.0.0),
    jsonlite,
    rlang (>= 1.0.0),
    cli
```

**Count: 6 packages** (all on CRAN, all actively maintained).

Rationale for each:
- `DBI`: Required for DBI generics. Must be in Imports for a DBI backend.
- `methods`: Required for S4 classes. Part of base R.
- `httr2`: HTTP client. Core functionality.
- `jsonlite`: JSON parsing for API requests/responses. Core functionality.
- `rlang`: Tidy evaluation and condition handling. Used throughout.
- `cli`: User-facing messages and progress bars. Used throughout.

### 4.2 DESCRIPTION Suggests (Optional Dependencies)

```
Suggests:
    nanoarrow (>= 0.3.0),
    openssl,
    jose,
    RcppTOML,
    dbplyr (>= 2.3.0),
    dplyr,
    blob (>= 1.2.0),
    hms (>= 1.0.0),
    bit64,
    keyring,
    DBItest (>= 1.8.0),
    testthat (>= 3.0.0),
    withr,
    knitr,
    rmarkdown
```

Feature enablement by Suggests dependency:

| Suggests Package | Feature Enabled When Installed |
|-----------------|-------------------------------|
| `nanoarrow` | Arrow IPC result fetching (fast path) |
| `openssl` | Key-pair JWT authentication |
| `jose` | Alternative JWT library |
| `RcppTOML` | connections.toml profile reading |
| `dbplyr` | dplyr integration / lazy SQL |
| `blob` | BINARY column support |
| `hms` | TIME column support |
| `bit64` | Large integer support (> 2^31) |
| `keyring` | Secure credential caching |
| `DBItest` | DBI compliance test suite |

### 4.3 SystemRequirements

```
SystemRequirements: libcurl, OpenSSL
```

Both are universally available on all platforms where R runs. They are
system requirements of `curl` and `openssl` respectively, which are already
widely used CRAN packages.

**No Python requirement.** This is the key differentiator from the current
snowflakeR package.

---

## 5. Dependency Comparison Summary

### Python Connector for Python

```
Hard dependencies (always installed):
  requests, certifi, idna, urllib3 (vendored),
  cryptography, pyOpenSSL, oscrypto, cffi,
  platformdirs, filelock, packaging, charset-normalizer,
  sortedcontainers, tomlkit
  Total: ~14 packages

Optional (extras):
  pyarrow, pandas, numpy          ([pandas] extra)
  keyring, keyrings.alt           ([secure-local-storage] extra)
  Total: ~5 additional packages
```

### Proposed R Package (RSnowflake)

```
Hard dependencies (Imports):
  DBI, methods, httr2, jsonlite, rlang, cli
  Total: 6 packages (all on CRAN, all lightweight)

Optional (Suggests):
  nanoarrow, openssl, jose, RcppTOML, dbplyr, dplyr,
  blob, hms, bit64, keyring
  Total: ~10 additional packages (all on CRAN)
```

### Net Reduction

- Hard dependencies: 14 -> 6 (57% fewer)
- No Python runtime requirement
- No conda/pip environment management
- All dependencies available as CRAN binary packages (instant install)

---

## 6. Dependency Risk Assessment

| Dependency | CRAN Status | Maintainer | Risk Level | Notes |
|-----------|------------|------------|------------|-------|
| `DBI` | Active | R Consortium / r-dbi | Very Low | Foundation of R database ecosystem |
| `httr2` | Active | Posit (Hadley Wickham) | Very Low | Modern HTTP client, actively developed |
| `jsonlite` | Active | Jeroen Ooms (rOpenSci) | Very Low | Most downloaded R package for JSON |
| `rlang` | Active | Posit (Lionel Henry) | Very Low | Core tidyverse infrastructure |
| `cli` | Active | Posit (Gabor Csardi) | Very Low | Widely used across R ecosystem |
| `nanoarrow` | Active | Apache Arrow project | Low | Growing adoption; backed by Apache |
| `openssl` | Active | Jeroen Ooms (rOpenSci) | Very Low | Mature, widely used |

All proposed dependencies are actively maintained, widely used, and backed
by major organizations (Posit, R Consortium, Apache, rOpenSci). There is
minimal supply-chain risk.
