# snowflakeR Package: Development Standards & Style Guide

**Date:** February 2026
**Status:** Living document -- update as decisions evolve
**Package name:** `snowflakeR`

---

## 1. Package Name: `snowflakeR`

The package name is **`snowflakeR`** (capital R).

**Rationale:**

- The capital R visually separates "snowflake" from "R", making it immediately clear this is an R interface to Snowflake (compare: `bigrquery`, `duckplyr`, `DBI`).
- CRAN permits mixed case in package names. Several popular packages use a trailing capital R: `quantmodR`, `httr`, etc. The embedded-capital pattern is also well established: `ggplot2`, `Rcpp`, `RcppTOML`.
- Not taken on CRAN. No conflict with `snowquery` (SQL-only), `snowflakeauth` (auth-only), or `snow` (parallel computing).
- Reads naturally in prose: "install snowflakeR" / "the snowflakeR package".

**Internal references:** Use `snowflakeR` consistently in docs, function messages, and error text. The repository name should be `snowflakeR` (matching the package name exactly).

---

## 2. Programming Paradigm: S3 + Functional

### Decision: S3 classes with functional-style programming

We use **S3 classes** for key objects (connections, model references) and **functions** for everything else. No S4 or R6.

**Why S3:**

- S3 is the most widely used OO system in R. Virtually every tidyverse and base R package uses S3. It is the system recommended by Hadley Wickham in [Advanced R](https://adv-r.hadley.nz/s3.html): *"S3 is R's first and simplest OO system. S3 is informal and ad hoc, but there is a certain elegance in its minimalism."*
- Posit's own `snowflakeauth` uses S3 (`structure(params, class = c("snowflake_connection", "list"))`). Using the same pattern ensures interoperability.
- S3 is the only OO system with zero additional dependencies.
- CRAN reviewers are most familiar with S3; exotic OO systems invite scrutiny.

**Why not S4, R5, R6:**

| System | Used by | Why not for us |
| ------ | ------- | -------------- |
| S4 | Bioconductor, `Matrix`, `methods` | Heavyweight, verbose, unfamiliar to most R users. Designed for complex type hierarchies we don't need. |
| R5 (Reference Classes) | Rarely used directly | Effectively superseded by R6. |
| R6 | `plumber`, `shiny` (internal) | Adds a dependency (`R6`). Mutable reference semantics feel un-R-like for a data-science-facing API. Best suited for stateful services, not our use case. |

### S3 Classes We Define

| Class | Purpose | Print method | Other methods |
| ----- | ------- | ------------ | ------------- |
| `sfr_connection` | Wraps Snowpark session + metadata | `print.sfr_connection` | `is_sfr_connection()` |
| `sfr_model` | Reference to a registered model | `print.sfr_model` | |
| `sfr_model_version` | Reference to a model version | `print.sfr_model_version` | |
| `sfr_feature_view` | Reference to a Feature View | `print.sfr_feature_view` | |
| `sfr_entity` | Reference to a Feature Store entity | `print.sfr_entity` | |

Each class is implemented as a named list with a class attribute, following `snowflakeauth`'s pattern:

```r
structure(
  list(
    session = py_session,
    account = account,
    user = user,
    database = database,
    schema = schema,
    warehouse = warehouse,
    auth_method = auth_method
  ),
  class = c("sfr_connection", "list")
)
```

### Connection Object Attributes

The `sfr_connection` object stores descriptive attributes about the connection:

| Attribute | Type | Description |
| --------- | ---- | ----------- |
| `session` | Python object | The underlying Snowpark session (via reticulate) |
| `account` | character | Snowflake account identifier |
| `user` | character | Snowflake username |
| `database` | character | Current database (if set) |
| `schema` | character | Current schema (if set) |
| `warehouse` | character | Current warehouse (if set) |
| `role` | character | Current role (if set) |
| `auth_method` | character | Authentication method used (e.g., "pat", "keypair", "externalbrowser", "session_token") |
| `environment` | character | "workspace" or "local" |
| `created_at` | POSIXct | When the connection was established |

The `print.sfr_connection` method displays a clean summary (redacting sensitive fields), modelled on `snowflakeauth`'s print method.

---

## 3. Naming Conventions

We follow the **[Tidyverse Style Guide](https://style.tidyverse.org/)** with one package-specific convention: all exported functions use the `sfr_` prefix.

### 3.1 Functions: `snake_case` with `sfr_` prefix

```r
# GOOD
sfr_connect()
sfr_log_model()
sfr_predict_local()
sfr_create_feature_view()
sfr_show_models()

# BAD
sfrConnect()          # camelCase
sfr.connect()         # dot.case (looks like S3 method)
sf_connect()          # wrong prefix
snowflaker_connect()  # too long
```

**Why `sfr_` prefix (not `sf_`):**

- `sfr_` is an unambiguous abbreviation of `snowflakeR`. Avoids collision with the `sf` package (Simple Features for spatial data), which is enormously popular and uses the `st_` prefix for its functions.
- Three characters is still short enough for comfortable typing.
- Consistent with R package conventions: `dplyr` uses `dplyr::` not `dp_`, but packages that do prefix (like `sf`, `fs`, `cli`) use 2-3 chars.

**Mapping from Python snowflake.ml names:**

Where our functions wrap an equivalent in `snowflake.ml`, use the same conceptual name adapted to R snake_case:

| Python (`snowflake.ml`) | R (`snowflakeR`) | Notes |
| ----------------------- | ---------------- | ----- |
| `Registry.log_model()` | `sfr_log_model()` | Verb stays the same |
| `Registry.show_models()` | `sfr_show_models()` | |
| `Registry.get_model()` | `sfr_get_model()` | |
| `Registry.delete_model()` | `sfr_delete_model()` | |
| `Model.version()` | `sfr_get_model_version()` | Disambiguated: `_model_` |
| `ModelVersion.run()` | `sfr_predict()` | R convention: "predict" |
| `ModelVersion.set_metric()` | `sfr_set_model_metric()` | Disambiguated: `_model_` |
| `ModelVersion.show_metrics()` | `sfr_show_model_metrics()` | Disambiguated: `_model_` |
| `ModelVersion.create_service()` | `sfr_deploy_model()` | R-friendly name |
| `FeatureStore()` | (internal) | Instantiated inside `sfr_connect()` |
| `FeatureView()` | `sfr_create_feature_view()` | |
| `Entity()` | `sfr_create_entity()` | |
| `FeatureStore.generate_training_data()` | `sfr_generate_training_data()` | |

### 3.2 Variables and arguments: `snake_case`

```r
# GOOD
model_name <- "MY_MODEL"
version_name <- "v1"
input_cols <- list(x = "double")
compute_pool <- "ML_POOL"

# BAD
modelName <- "MY_MODEL"    # camelCase
model.name <- "MY_MODEL"   # dot.case
```

### 3.3 File names: `snake_case.R`

```
R/
  connect.R
  registry.R
  features.R
  query.R
  helpers.R
  workspace.R
  python_deps.R
  zzz.R
  snowflakeR-package.R
```

### 3.4 S3 methods: `generic.class`

```r
print.sfr_connection <- function(x, ...) { ... }
print.sfr_model <- function(x, ...) { ... }
is_sfr_connection <- function(x) inherits(x, "sfr_connection")
```

### 3.5 Internal (non-exported) functions: no prefix needed

```r
# Internal helpers don't need sfr_ prefix
ensure_python_deps <- function() { ... }
get_bridge_module <- function(module_name) { ... }
build_model_signature <- function(input_cols, output_cols) { ... }
```

### 3.6 Constants: `SCREAMING_SNAKE_CASE` (R convention for options)

```r
SNOWFLAKER_PYTHON_ENV <- "r-snowflakeR"
DTYPE_MAP <- list(integer = "INT64", double = "DOUBLE", ...)
```

---

## 4. Code Style

Follow the [Tidyverse Style Guide](https://style.tidyverse.org/) in full. Key points:

### 4.1 Spacing

```r
# GOOD
average <- mean(x / 12 + y, na.rm = TRUE)
result <- sfr_query(conn, sql = "SELECT 1")

# BAD
average<-mean(x/12+y,na.rm=TRUE)
```

### 4.2 Assignment: use `<-`, never `=`

```r
# GOOD
x <- 5

# BAD
x = 5
```

### 4.3 Line length: 80 characters

Strive for 80 characters; hard limit at 100. For long function signatures, indent continuation lines to align with the opening `(`:

```r
sfr_log_model <- function(conn,
                          model,
                          model_name,
                          version_name = NULL,
                          predict_fn = "predict",
                          predict_pkgs = character(0),
                          ...) {
  # body
}
```

### 4.4 Indentation: 2 spaces (never tabs)

```r
if (condition) {
  do_something()
} else {
  do_something_else()
}
```

### 4.5 Curly braces

Opening brace on same line; closing brace on its own line:

```r
# GOOD
if (x > 0) {
  log(x)
}

# BAD
if (x > 0)
{
  log(x)
}
```

### 4.6 Pipes

Use the base R pipe `|>` (not magrittr `%>%`) in package code. The base pipe requires R >= 4.1 (which we depend on anyway).

```r
# GOOD (base pipe)
result <- data |>
  transform_step_1() |>
  transform_step_2()

# AVOID in package code (adds dependency)
result <- data %>%
  transform_step_1() %>%
  transform_step_2()
```

### 4.7 Return values

Use explicit `return()` only for early returns. The last expression in a function is returned implicitly (Tidyverse convention):

```r
# GOOD
sfr_query <- function(conn, sql) {
  validate_connection(conn)
  result <- conn$session$sql(sql)$to_pandas()
  as.data.frame(result)
}

# GOOD - early return
sfr_query <- function(conn, sql) {
  if (!is_sfr_connection(conn)) {
    cli::cli_abort("{.arg conn} must be an {.cls sfr_connection} object.")
    return(invisible(NULL))
  }
  # ... continue
}
```

---

## 5. Documentation: roxygen2

All documentation uses **roxygen2** with markdown syntax. This is the universal standard for R packages (as described in [R Packages, Ch. 16](https://r-pkgs.org/man.html)).

### 5.1 Every exported function gets roxygen2 docs

```r
#' Log an R model to the Snowflake Model Registry
#'
#' Saves the R model to an `.rds` file, auto-generates a Python `CustomModel`
#' wrapper (using rpy2), and registers it to the Snowflake Model Registry.
#'
#' @param conn An `sfr_connection` object from [sfr_connect()].
#' @param model An R model object (anything that can be `saveRDS()`'d).
#' @param model_name Character. Name for the model in the registry.
#' @param version_name Character. Optional version name (auto-generated if
#'   `NULL`).
#' @param predict_fn Character. R function name for inference. Default:
#'   `"predict"`.
#' @param predict_pkgs Character vector. R packages needed at inference time.
#' @param input_cols Named list mapping input column names to types.
#'   Valid types: `"integer"`, `"double"`, `"string"`, `"boolean"`.
#' @param output_cols Named list mapping output column names to types.
#' @param conda_deps Character vector. Conda packages for the model
#'   environment. Defaults include `r-base` and `rpy2`.
#' @param target_platforms Character. One of `"SNOWPARK_CONTAINER_SERVICES"`,
#'   `"WAREHOUSE"`, or both. Default: `"SNOWPARK_CONTAINER_SERVICES"`.
#' @param comment Character. Description of the model.
#' @param metrics Named list. Metrics to attach to the model version.
#' @param ... Additional arguments passed to the underlying Python
#'   `Registry.log_model()`.
#'
#' @returns An `sfr_model_version` object.
#'
#' @seealso [sfr_predict_local()], [sfr_predict()], [sfr_show_models()]
#'
#' @examples
#' \dontrun{
#' conn <- sfr_connect()
#' model <- lm(mpg ~ wt, data = mtcars)
#' mv <- sfr_log_model(conn, model, model_name = "MTCARS_MPG",
#'                     input_cols = list(wt = "double"),
#'                     output_cols = list(prediction = "double"))
#' }
#'
#' @export
sfr_log_model <- function(conn,
                          model,
                          model_name,
                          version_name = NULL,
                          predict_fn = "predict",
                          predict_pkgs = character(0),
                          input_cols = NULL,
                          output_cols = NULL,
                          conda_deps = NULL,
                          target_platforms = "SNOWPARK_CONTAINER_SERVICES",
                          comment = NULL,
                          metrics = NULL,
                          ...) {
  # implementation
}
```

### 5.2 Documentation conventions

- **Title:** Sentence case, no period at end. One line.
- **Description:** One paragraph. Use `@description` tag if multiple paragraphs needed.
- **`@param`:** Document every parameter. Include type, default, valid values.
- **`@returns`:** Always document the return value.
- **`@examples`:** Wrap Snowflake-dependent examples in `\dontrun{}` for CRAN. Use `@examplesIf` for conditional examples (following `snowflakeauth` pattern).
- **`@seealso`:** Link to related functions.
- **`@export`:** On every public function.
- **`@noRd`:** On internal helper functions that don't need `.Rd` files.
- **Cross-references:** Use `[function_name()]` for auto-linking (roxygen2 markdown).

### 5.3 Package-level documentation

File: `R/snowflakeR-package.R`

```r
#' @keywords internal
"_PACKAGE"
```

Generated by `usethis::use_package_doc()`.

---

## 6. Error Handling & User Messages

Use the **`cli`** package for all user-facing messages and errors (following Posit/tidyverse convention). Never use `cat()`, `message()`, or `warning()` directly.

```r
# GOOD
cli::cli_inform("Model registered: {.val {model_name}}")
cli::cli_abort("{.arg model} must be an R model object, not {.cls {class(model)}}.")
cli::cli_warn("Version {.val {version}} is not the default.")

# BAD
message(paste("Model registered:", model_name))
stop(paste("model must be an R model object"))
cat("Model registered\n")
```

### Error message style

- Use `cli::cli_abort()` for errors (not `stop()`).
- Use `cli::cli_warn()` for warnings (not `warning()`).
- Use `cli::cli_inform()` for informational messages (not `message()`).
- Refer to arguments with `{.arg name}`.
- Refer to classes with `{.cls class_name}`.
- Refer to values with `{.val value}`.
- Refer to functions with `{.fn function_name}`.
- Refer to file paths with `{.path path}`.

---

## 7. Dependency Management

### 7.1 R Dependencies

| Type | Packages | Reason |
| ---- | -------- | ------ |
| **Imports** | `reticulate`, `jsonlite`, `cli`, `rlang` | Core functionality; always needed |
| **Suggests** | `dplyr`, `dbplyr`, `DBI`, `testthat`, `knitr`, `rmarkdown`, `withr`, `snowflakeauth` | Optional; Feature Store (dbplyr), testing, vignettes |

### 7.2 `snowflakeauth` Integration

We should **depend on `snowflakeauth`** (in `Suggests`) and use it for authentication when available. This avoids reinventing their connection-parameter resolution (which handles `connections.toml`, `config.toml`, environment variables, and multiple auth methods).

```r
sfr_connect <- function(..., .use_snowflakeauth = TRUE) {
  if (.use_snowflakeauth && requireNamespace("snowflakeauth", quietly = TRUE)) {
    # Use snowflakeauth for parameter resolution
    sf_conn <- snowflakeauth::snowflake_connection(...)
    # Then create Snowpark session from those parameters
    session <- create_session_from_params(sf_conn)
  } else {
    # Fall back to direct parameter handling
    session <- create_session_direct(...)
  }
  # ...
}
```

### 7.3 Python Dependencies

Checked/installed lazily. Never auto-install without user consent (CRAN requirement).

```r
ensure_python_deps <- function() {
  if (!reticulate::py_module_available("snowflake.ml")) {
    cli::cli_abort(c(
      "Python package {.pkg snowflake-ml-python} is not installed.",
      "i" = "Install it with: {.code sfr_install_python_deps()}"
    ))
  }
}
```

---

## 8. Lessons from `snowflakeauth` and `snowquery`

### From `snowflakeauth` (Posit)

| Lesson | How we apply it |
| ------ | --------------- |
| **`connections.toml` / `config.toml` support** | Use `snowflakeauth` as optional dependency for auth; if unavailable, read these files ourselves |
| **S3 class for connection** (`snowflake_connection`) | Our `sfr_connection` follows the same `structure(list(...), class = ...)` pattern |
| **Redaction of secrets** in print methods | `print.sfr_connection` redacts PAT tokens, passwords, private keys |
| **`cli` package for messages** | Adopt throughout |
| **`@examplesIf` for conditional examples** | Use for Snowflake-dependent examples |
| **Environment variable parsing** | Support `SNOWFLAKE_*` env vars as fallback (already handle in our helpers) |
| **`has_a_default_connection()`** | Provide similar `sfr_has_connection()` for examples/tests |
| **Clean separation:** auth is auth, not query execution | Our `sfr_connect()` does auth + session creation; query/ML operations are separate functions |

### From `snowquery` (Dani Mermelstein)

| Lesson | How we apply it |
| ------ | --------------- |
| **Uses `reticulate` for snowflake-connector-python** | Validates the reticulate approach for CRAN |
| **Local DuckDB caching** | Not in scope for us, but interesting pattern for future |
| **Imports `dbplyr`/`dplyr`/`DBI`** | Confirms these are safe CRAN dependencies for Snowflake packages |

### Not yet incorporated from our learnings

Both `snowflakeauth` and `snowquery` are **connection/query** packages. Neither covers ML operations (Model Registry, Feature Store). Our unique value is the ML layer. Specific things we bring that they don't:

- Auto-generation of Python `CustomModel` wrappers for R models
- rpy2-based inference bridge (R model running inside Python container)
- `saveRDS()` / `readRDS()` serialization for model artifacts
- Feature View creation from dbplyr pipelines
- Workspace Notebook R environment management

---

## 9. Testing

### Framework: `testthat` edition 3

```r
# tests/testthat.R
library(testthat)
library(snowflakeR)
test_check("snowflakeR")
```

### Test organization

```
tests/testthat/
  test-connect.R       # Connection creation, validation
  test-registry.R      # Model registry operations
  test-features.R      # Feature store operations
  test-query.R         # SQL execution
  test-helpers.R       # Output formatting, diagnostics
  test-python-deps.R   # Python dependency checking
  helper-mocks.R       # Shared test helpers and mocks
```

### Test categories

```r
# Unit tests (run everywhere, no Snowflake needed)
test_that("sfr_log_model validates model argument", {
  expect_error(sfr_log_model(mock_conn, "not_a_model", "name"))
})

# Integration tests (skip on CRAN)
test_that("sfr_log_model registers model to Snowflake", {
  skip_on_cran()
  skip_if_not(sfr_has_connection())
  conn <- sfr_connect()
  # ...
})
```

### Mocking Python for unit tests

Use `testthat::local_mocked_bindings()` or `withr::local_*` to mock reticulate calls:

```r
test_that("sfr_show_models returns data.frame", {
  local_mocked_bindings(
    get_bridge_module = function(...) mock_bridge
  )
  result <- sfr_show_models(mock_conn)
  expect_s3_class(result, "data.frame")
})
```

---

## 10. Tooling

| Tool | Purpose | Config |
| ---- | ------- | ------ |
| **roxygen2** | Documentation generation | `Roxygen: list(markdown = TRUE)` in DESCRIPTION |
| **testthat** (ed. 3) | Testing | `Config/testthat/edition: 3` |
| **devtools** | Build/check/document cycle | Standard workflow |
| **usethis** | Package scaffolding | One-time setup |
| **pkgdown** | Documentation website | `_pkgdown.yml` |
| **styler** | Code formatting | Tidyverse style |
| **lintr** | Linting | `.lintr` config |
| **covr** | Code coverage | GitHub Actions integration |
| **rhub** | Pre-CRAN checking | Run before submission |

### Development workflow

```r
# Daily cycle
devtools::load_all()      # Ctrl+Shift+L
devtools::document()      # Ctrl+Shift+D
devtools::test()          # Ctrl+Shift+T
devtools::check()         # Ctrl+Shift+E
```

---

## 11. Git & Version Control

- **Branch strategy:** `main` (stable) + feature branches
- **Commit messages:** Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`)
- **PR required** for merges to main
- **CI:** GitHub Actions for `R CMD check` on Linux/macOS/Windows

---

## 12. CRAN Submission Checklist

Before submitting to CRAN:

- [ ] `R CMD check` returns 0 errors, 0 warnings, 0 notes
- [ ] All exported functions have `@returns` documentation
- [ ] All exported functions have `@examples` (use `\dontrun{}` for Snowflake-dependent)
- [ ] No writes to user filesystem without consent
- [ ] No internet access during `R CMD check` (skip Snowflake tests on CRAN)
- [ ] `DESCRIPTION` has proper `SystemRequirements` for Python
- [ ] `LICENSE` file is correct
- [ ] `NEWS.md` documents changes
- [ ] Tested with `rhub::check_for_cran()`
- [ ] Spell-check with `devtools::spell_check()`

---

## 13. Summary of Key Decisions

| Decision | Choice | Reference |
| -------- | ------ | --------- |
| Package name | `snowflakeR` | Section 1 |
| OO system | S3 | Section 2 |
| Naming convention | `snake_case` | [Tidyverse Style Guide](https://style.tidyverse.org/) |
| Function prefix | `sfr_` | Section 3.1 |
| Code style | Tidyverse | [style.tidyverse.org](https://style.tidyverse.org/) |
| Assignment | `<-` (not `=`) | [Tidyverse Style Guide](https://style.tidyverse.org/) |
| Pipe | `\|>` (base R) | Section 4.6 |
| Documentation | roxygen2 + markdown | [R Packages Ch. 16](https://r-pkgs.org/man.html) |
| Error handling | `cli` package | Section 6 |
| Testing | testthat edition 3 | Section 9 |
| Auth integration | `snowflakeauth` (optional) | Section 7.2 |
| Config files | `connections.toml` / `config.toml` | Section 8 |
| Connection object | S3 class with descriptive attributes | Section 2 |
| Python R code template vars | `{{MODEL}}`, `{{INPUT}}`, `{{UID}}`, `{{N}}` | Carried from existing impl |
