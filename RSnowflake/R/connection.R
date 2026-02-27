# SnowflakeConnection S4 Class & DBI Methods
# =============================================================================

#' SnowflakeConnection
#'
#' An S4 class representing a connection to Snowflake via the SQL API v2.
#' Created by [dbConnect()] with a [Snowflake()] driver.
#'
#' @param object A [SnowflakeConnection-class] object (for `show`).
#' @param ... Additional arguments (currently ignored).
#' @slot account Account identifier.
#' @slot user Username.
#' @slot database Default database.
#' @slot schema Default schema.
#' @slot warehouse Default warehouse.
#' @slot role Default role.
#' @slot .auth Auth list (type, token, token_type, plus params for refresh).
#' @slot .state Environment holding mutable state (valid, in_transaction, session_info).
#' @export
setClass("SnowflakeConnection",
  contains = "DBIConnection",
  slots = list(
    account   = "character",
    user      = "character",
    database  = "character",
    schema    = "character",
    warehouse = "character",
    role      = "character",
    .auth     = "list",
    .state    = "environment"
  )
)

.new_conn_state <- function() {
  env <- new.env(parent = emptyenv())
  env$valid          <- TRUE
  env$in_transaction <- FALSE
  env$session_info   <- NULL
  env
}

#' @rdname SnowflakeConnection-class
#' @export
setMethod("show", "SnowflakeConnection", function(object) {
  if (object@.state$valid) {
    cat(sprintf(
      "<SnowflakeConnection> %s@%s [%s.%s]\n",
      object@user, object@account, object@database, object@schema
    ))
  } else {
    cat("<SnowflakeConnection> DISCONNECTED\n")
  }
})

#' @rdname SnowflakeConnection-class
#' @param dbObj A [SnowflakeConnection-class] object.
#' @export
setMethod("dbIsValid", "SnowflakeConnection", function(dbObj, ...) {
  dbObj@.state$valid
})

#' @rdname SnowflakeConnection-class
#' @param conn A [SnowflakeConnection-class] object.
#' @export
setMethod("dbDisconnect", "SnowflakeConnection", function(conn, ...) {
  .on_connection_closed(conn)
  conn@.state$valid <- FALSE
  invisible(TRUE)
})

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbGetInfo", "SnowflakeConnection", function(dbObj, ...) {
  list(
    dbname    = dbObj@database,
    username  = dbObj@user,
    host      = paste0(dbObj@account, ".snowflakecomputing.com"),
    port      = 443L,
    schema    = dbObj@schema,
    warehouse = dbObj@warehouse,
    role      = dbObj@role
  )
})

# ---------------------------------------------------------------------------
# Query execution
# ---------------------------------------------------------------------------

#' @rdname SnowflakeConnection-class
#' @param statement SQL statement string.
#' @param params Optional parameter list for parameterized queries.
#' @export
setMethod("dbSendQuery", signature("SnowflakeConnection", "character"),
  function(conn, statement, params = NULL, ...) {
    .check_valid(conn)
    bindings <- if (!is.null(params)) .params_to_bindings(params) else NULL
    resp <- sf_api_submit(conn, statement, bindings = bindings)
    meta <- sf_parse_metadata(resp)

    new("SnowflakeResult",
      connection = conn,
      statement  = statement,
      .resp_body = resp,
      .meta      = meta,
      .state     = .new_result_state(rows_affected = -1L)
    )
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbSendStatement", signature("SnowflakeConnection", "character"),
  function(conn, statement, params = NULL, ...) {
    .check_valid(conn)
    bindings <- if (!is.null(params)) .params_to_bindings(params) else NULL
    resp <- sf_api_submit(conn, statement, bindings = bindings)
    meta <- sf_parse_metadata(resp)
    rows <- .extract_rows_affected(resp)

    new("SnowflakeResult",
      connection = conn,
      statement  = statement,
      .resp_body = resp,
      .meta      = meta,
      .state     = .new_result_state(rows_affected = rows)
    )
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbGetQuery", signature("SnowflakeConnection", "character"),
  function(conn, statement, params = NULL, ...) {
    .check_valid(conn)
    bindings <- if (!is.null(params)) .params_to_bindings(params) else NULL
    resp <- sf_api_submit(conn, statement, bindings = bindings)
    parsed <- sf_parse_response(resp)
    meta <- parsed$meta

    if (meta$num_partitions > 1L) {
      parts <- vector("list", meta$num_partitions)
      parts[[1L]] <- parsed$data

      for (i in 2L:meta$num_partitions) {
        part_resp <- sf_api_fetch_partition(conn, meta$statement_handle, i - 1L)
        part_parsed <- sf_parse_response(part_resp)
        parts[[i]] <- part_parsed$data
      }

      return(do.call(rbind, parts))
    }

    parsed$data
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbExecute", signature("SnowflakeConnection", "character"),
  function(conn, statement, params = NULL, ...) {
    .check_valid(conn)
    bindings <- if (!is.null(params)) .params_to_bindings(params) else NULL
    resp <- sf_api_submit(conn, statement, bindings = bindings)
    .extract_rows_affected(resp)
  }
)

# ---------------------------------------------------------------------------
# DBI Arrow methods
# ---------------------------------------------------------------------------

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbGetQueryArrow", signature("SnowflakeConnection", "character"),
  function(conn, statement, params = NULL, ...) {
    rlang::check_installed("nanoarrow", reason = "for Arrow result format")
    .check_valid(conn)
    bindings <- if (!is.null(params)) .params_to_bindings(params) else NULL
    resp <- sf_api_submit_arrow(conn, statement, bindings = bindings)
    meta <- sf_parse_metadata(resp)
    sf_fetch_all_arrow_stream(conn, meta)
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbSendQueryArrow", signature("SnowflakeConnection", "character"),
  function(conn, statement, params = NULL, ...) {
    rlang::check_installed("nanoarrow", reason = "for Arrow result format")
    .check_valid(conn)
    bindings <- if (!is.null(params)) .params_to_bindings(params) else NULL
    resp <- sf_api_submit_arrow(conn, statement, bindings = bindings)
    meta <- sf_parse_metadata(resp)

    state <- .new_result_state(rows_affected = -1L)
    state$use_arrow <- TRUE

    new("SnowflakeResult",
      connection = conn,
      statement  = statement,
      .resp_body = resp,
      .meta      = meta,
      .state     = state
    )
  }
)

# ---------------------------------------------------------------------------
# Table operations
# ---------------------------------------------------------------------------

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbListTables", "SnowflakeConnection", function(conn, ...) {
  .check_valid(conn)
  resp <- sf_api_submit(conn, "SHOW TABLES IN SCHEMA")
  parsed <- sf_parse_response(resp)
  if (nrow(parsed$data) == 0L) return(character(0))

  name_col <- which(tolower(parsed$meta$columns$name) == "name")
  if (length(name_col) == 0L) return(character(0))

  parsed$data[[name_col]]
})

#' @rdname SnowflakeConnection-class
#' @param name Table name (character).
#' @export
setMethod("dbExistsTable", signature("SnowflakeConnection", "character"),
  function(conn, name, ...) {
    .check_valid(conn)
    tolower(name) %in% tolower(dbListTables(conn))
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbListFields", signature("SnowflakeConnection", "character"),
  function(conn, name, ...) {
    .check_valid(conn)
    id <- dbQuoteIdentifier(conn, name)
    resp <- sf_api_submit(conn, paste0("SHOW COLUMNS IN TABLE ", id))
    parsed <- sf_parse_response(resp)
    if (nrow(parsed$data) == 0L) return(character(0))

    col_col <- which(tolower(parsed$meta$columns$name) == "column_name")
    if (length(col_col) == 0L) return(character(0))

    parsed$data[[col_col]]
  }
)

#' @rdname SnowflakeConnection-class
#' @param prefix An `Id` object indicating the hierarchy level to list
#'   (NULL for databases, 1-component for schemas, 2-component for tables).
#' @export
setMethod("dbListObjects", signature("SnowflakeConnection"),
  function(conn, prefix = NULL, ...) {
    .check_valid(conn)

    if (is.null(prefix)) {
      return(.list_databases(conn))
    }

    parts <- prefix@name
    if (length(parts) == 1L) {
      return(.list_schemas(conn, parts[[1L]]))
    }
    if (length(parts) == 2L) {
      return(.list_tables_in_schema(conn, parts[[1L]], parts[[2L]]))
    }

    data.frame(table = I(list()), is_prefix = logical(0))
  }
)

.list_databases <- function(conn) {
  resp <- sf_api_submit(conn, "SHOW DATABASES")
  parsed <- sf_parse_response(resp)
  if (nrow(parsed$data) == 0L) {
    return(data.frame(table = I(list()), is_prefix = logical(0)))
  }
  name_col <- which(tolower(parsed$meta$columns$name) == "name")
  if (length(name_col) == 0L) {
    return(data.frame(table = I(list()), is_prefix = logical(0)))
  }
  dbs <- parsed$data[[name_col]]
  data.frame(
    table = I(lapply(dbs, function(d) Id(catalog = d))),
    is_prefix = rep(TRUE, length(dbs))
  )
}

.list_schemas <- function(conn, database) {
  qdb <- dbQuoteIdentifier(conn, database)
  resp <- sf_api_submit(conn, paste0("SHOW SCHEMAS IN DATABASE ", qdb))
  parsed <- sf_parse_response(resp)
  if (nrow(parsed$data) == 0L) {
    return(data.frame(table = I(list()), is_prefix = logical(0)))
  }
  name_col <- which(tolower(parsed$meta$columns$name) == "name")
  if (length(name_col) == 0L) {
    return(data.frame(table = I(list()), is_prefix = logical(0)))
  }
  schemas <- parsed$data[[name_col]]
  data.frame(
    table = I(lapply(schemas, function(s) Id(catalog = database, schema = s))),
    is_prefix = rep(TRUE, length(schemas))
  )
}

.list_tables_in_schema <- function(conn, database, schema) {
  qdb <- dbQuoteIdentifier(conn, database)
  qsch <- dbQuoteIdentifier(conn, schema)
  sql <- paste0("SHOW TABLES IN SCHEMA ", qdb, ".", qsch)
  resp <- sf_api_submit(conn, sql)
  parsed <- sf_parse_response(resp)
  if (nrow(parsed$data) == 0L) {
    return(data.frame(table = I(list()), is_prefix = logical(0)))
  }
  name_col <- which(tolower(parsed$meta$columns$name) == "name")
  if (length(name_col) == 0L) {
    return(data.frame(table = I(list()), is_prefix = logical(0)))
  }
  tables <- parsed$data[[name_col]]
  data.frame(
    table = I(lapply(tables, function(t) {
      Id(catalog = database, schema = schema, table = t)
    })),
    is_prefix = rep(FALSE, length(tables))
  )
}

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbReadTable", signature("SnowflakeConnection", "character"),
  function(conn, name, ...) {
    .check_valid(conn)
    id <- dbQuoteIdentifier(conn, name)
    dbGetQuery(conn, paste0("SELECT * FROM ", id))
  }
)

#' @rdname SnowflakeConnection-class
#' @param value A data.frame.
#' @param overwrite Logical. Drop existing table first?
#' @param append Logical. Append to existing table?
#' @param row.names Ignored (always FALSE for Snowflake).
#' @export
setMethod("dbWriteTable",
  signature("SnowflakeConnection", "character", "data.frame"),
  function(conn, name, value, overwrite = FALSE, append = FALSE,
           row.names = FALSE, ...) {
    .check_valid(conn)

    id <- dbQuoteIdentifier(conn, name)
    exists <- dbExistsTable(conn, name)

    if (exists && !overwrite && !append) {
      cli_abort("Table {.val {name}} already exists. Use {.arg overwrite} or {.arg append}.")
    }

    if (overwrite && exists) {
      dbExecute(conn, paste0("DROP TABLE IF EXISTS ", id))
      exists <- FALSE
    }

    if (!exists) {
      dbCreateTable(conn, name, value)
    }

    if (nrow(value) > 0L) {
      .insert_data(conn, id, value)
    }

    invisible(TRUE)
  }
)

#' @rdname SnowflakeConnection-class
#' @param fields A data.frame or named character vector of column types.
#' @param temporary Logical. Create a temporary table?
#' @export
setMethod("dbCreateTable",
  signature("SnowflakeConnection", "character"),
  function(conn, name, fields, ..., row.names = NULL, temporary = FALSE) {
    .check_valid(conn)
    id <- dbQuoteIdentifier(conn, name)

    if (is.data.frame(fields)) {
      col_types <- vapply(fields, r_to_sf_type, character(1))
      col_names <- names(fields)
    } else if (is.character(fields)) {
      col_names <- names(fields)
      col_types <- unname(fields)
    } else {
      cli_abort("{.arg fields} must be a data.frame or a named character vector.")
    }

    col_defs <- paste0(dbQuoteIdentifier(conn, col_names), " ", col_types)
    tmp <- if (temporary) "TEMPORARY " else ""
    ddl <- paste0("CREATE ", tmp, "TABLE ", id, " (\n  ",
                   paste(col_defs, collapse = ",\n  "), "\n)")
    dbExecute(conn, ddl)
    invisible(TRUE)
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbAppendTable",
  signature("SnowflakeConnection", "character"),
  function(conn, name, value, ..., row.names = NULL) {
    .check_valid(conn)
    id <- dbQuoteIdentifier(conn, name)
    if (nrow(value) == 0L) return(invisible(0L))
    .insert_data(conn, id, value)
    invisible(nrow(value))
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbRemoveTable", signature("SnowflakeConnection", "character"),
  function(conn, name, ...) {
    .check_valid(conn)
    id <- dbQuoteIdentifier(conn, name)
    dbExecute(conn, paste0("DROP TABLE IF EXISTS ", id))
    invisible(TRUE)
  }
)

# ---------------------------------------------------------------------------
# Quoting
# ---------------------------------------------------------------------------

#' @rdname SnowflakeConnection-class
#' @param x Character to quote.
#' @export
setMethod("dbQuoteIdentifier", signature("SnowflakeConnection", "character"),
  function(conn, x, ...) {
    needs_quote <- !grepl('^".*"$', x)
    x[needs_quote] <- paste0('"', gsub('"', '""', x[needs_quote]), '"')
    SQL(x)
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbQuoteString", signature("SnowflakeConnection", "character"),
  function(conn, x, ...) {
    is_na <- is.na(x)
    x <- gsub("'", "''", x)
    x <- paste0("'", x, "'")
    x[is_na] <- "NULL"
    SQL(x)
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbQuoteString", signature("SnowflakeConnection", "SQL"),
  function(conn, x, ...) { x }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbQuoteIdentifier", signature("SnowflakeConnection", "SQL"),
  function(conn, x, ...) { x }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbUnquoteIdentifier", signature("SnowflakeConnection", "SQL"),
  function(conn, x, ...) {
    lapply(x, function(id_str) {
      id_str <- as.character(id_str)
      parts <- character(0)
      remaining <- id_str

      while (nzchar(remaining)) {
        remaining <- trimws(remaining)
        if (startsWith(remaining, '"')) {
          close_pos <- regexpr('"([^"]|"")*"', remaining)
          if (close_pos == -1L) {
            parts <- c(parts, remaining)
            break
          }
          len <- attr(close_pos, "match.length")
          quoted <- substr(remaining, 2L, len - 1L)
          quoted <- gsub('""', '"', quoted)
          parts <- c(parts, quoted)
          remaining <- substr(remaining, len + 1L, nchar(remaining))
          remaining <- sub("^\\.", "", remaining)
        } else {
          dot_pos <- regexpr("\\.", remaining)
          if (dot_pos == -1L) {
            parts <- c(parts, remaining)
            break
          }
          parts <- c(parts, substr(remaining, 1L, dot_pos - 1L))
          remaining <- substr(remaining, dot_pos + 1L, nchar(remaining))
        }
      }

      switch(as.character(length(parts)),
        "1" = Id(table = parts[1L]),
        "2" = Id(schema = parts[1L], table = parts[2L]),
        "3" = Id(catalog = parts[1L], schema = parts[2L], table = parts[3L]),
        Id(table = id_str)
      )
    })
  }
)

#' @rdname SnowflakeConnection-class
#' @export
setMethod("dbQuoteLiteral", signature("SnowflakeConnection"),
  function(conn, x, ...) {
    if (is.factor(x)) return(dbQuoteString(conn, as.character(x)))
    if (is.character(x)) return(dbQuoteString(conn, x))
    if (is.logical(x)) {
      x <- ifelse(x, "TRUE", "FALSE")
      x[is.na(x)] <- "NULL"
      return(SQL(x))
    }
    if (inherits(x, "Date")) {
      is_na <- is.na(x)
      out <- paste0("'", format(x, "%Y-%m-%d"), "'::DATE")
      out[is_na] <- "NULL"
      return(SQL(out))
    }
    if (inherits(x, "POSIXct")) {
      is_na <- is.na(x)
      out <- paste0("'", format(x, "%Y-%m-%d %H:%M:%OS3", tz = "UTC"), "'::TIMESTAMP_NTZ")
      out[is_na] <- "NULL"
      return(SQL(out))
    }
    if (is.integer(x)) {
      is_na <- is.na(x)
      out <- as.character(x)
      out[is_na] <- "NULL"
      return(SQL(out))
    }
    if (is.numeric(x)) {
      is_na <- is.na(x)
      out <- format(x, scientific = FALSE)
      out[is_na] <- "NULL"
      return(SQL(out))
    }
    if (is.raw(x)) {
      return(SQL(paste0("X'", paste(format(x, width = 2), collapse = ""), "'")))
    }
    dbQuoteString(conn, as.character(x))
  }
)

# ---------------------------------------------------------------------------
# Data type
# ---------------------------------------------------------------------------

#' @rdname SnowflakeConnection-class
#' @param obj An R object to map to a Snowflake SQL type.
#' @export
setMethod("dbDataType", "SnowflakeConnection", function(dbObj, obj, ...) {
  r_to_sf_type(obj)
})

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

.check_valid <- function(conn) {
  if (!conn@.state$valid) {
    cli_abort("Connection is no longer valid. Use {.fn dbConnect} to reconnect.")
  }
}

.extract_rows_affected <- function(resp) {
  stats <- resp$stats
  if (!is.null(stats)) {
    counts <- c(
      stats$numRowsInserted,
      stats$numRowsUpdated,
      stats$numRowsDeleted,
      stats$numRowsUnloaded
    )
    counts <- counts[!is.na(counts)]
    if (length(counts) > 0L) return(as.integer(sum(counts)))
  }
  0L
}

#' Convert R params to SQL API v2 bindings format
#' @noRd
.params_to_bindings <- function(params) {
  if (is.null(params) || length(params) == 0L) return(NULL)

  if (is.data.frame(params)) {
    params <- as.list(params)
  }

  bindings <- list()
  for (i in seq_along(params)) {
    nm <- as.character(i)
    val <- params[[i]]

    if (is.logical(val)) {
      bindings[[nm]] <- list(type = "BOOLEAN", value = as.character(val))
    } else if (is.integer(val)) {
      bindings[[nm]] <- list(type = "FIXED", value = as.character(val))
    } else if (is.numeric(val)) {
      bindings[[nm]] <- list(type = "REAL", value = as.character(val))
    } else {
      bindings[[nm]] <- list(type = "TEXT", value = as.character(val))
    }
  }
  bindings
}

#' Insert data.frame rows via batched INSERT VALUES
#'
#' Uses named columns in the INSERT statement for robustness when column
#' order may differ between the data.frame and the table.  Batch size is
#' controlled by `getOption("RSnowflake.insert_batch_size")` (default 5000).
#' @noRd
.insert_data <- function(conn, table_id, df) {
  batch_size <- getOption("RSnowflake.insert_batch_size", 5000L)
  batch_size <- as.integer(batch_size)
  n <- nrow(df)
  ncols <- ncol(df)

  col_clause <- paste0(
    " (",
    paste(vapply(names(df), function(nm) {
      dbQuoteIdentifier(conn, nm)
    }, character(1)), collapse = ", "),
    ")"
  )

  use_progress <- n > batch_size && requireNamespace("cli", quietly = TRUE)
  if (use_progress) {
    pb <- cli::cli_progress_bar(
      total   = n,
      format  = "Inserting rows {cli::pb_current}/{cli::pb_total} {cli::pb_bar} {cli::pb_percent}"
    )
  }

  for (start in seq(1L, n, by = batch_size)) {
    end <- min(start + batch_size - 1L, n)
    rows <- vapply(start:end, function(i) {
      vals <- vapply(seq_len(ncols), function(j) {
        .format_value(df[[j]][i])
      }, character(1))
      paste0("(", paste(vals, collapse = ", "), ")")
    }, character(1))

    sql <- paste0(
      "INSERT INTO ", table_id, col_clause, " VALUES\n",
      paste(rows, collapse = ",\n")
    )
    sf_api_submit(conn, sql)

    if (use_progress) cli::cli_progress_update(set = end, id = pb)
  }

  if (use_progress) cli::cli_progress_done(id = pb)
}

.format_value <- function(x) {
  if (is.na(x)) return("NULL")
  if (is.logical(x)) return(if (x) "TRUE" else "FALSE")
  if (is.numeric(x)) return(as.character(x))
  if (inherits(x, "Date")) return(paste0("'", format(x, "%Y-%m-%d"), "'"))
  if (inherits(x, "POSIXct")) return(paste0("'", format(x, "%Y-%m-%d %H:%M:%S"), "'"))
  paste0("'", gsub("'", "''", as.character(x)), "'")
}

#' @rdname SnowflakeConnection-class
#' @export
setMethod("sqlData", "SnowflakeConnection",
  function(con, value, row.names = FALSE, ...) {
    as.data.frame(
      lapply(value, function(col) {
        if (is.logical(col)) {
          ifelse(col, "TRUE", "FALSE")
        } else if (inherits(col, "Date")) {
          format(col, "%Y-%m-%d")
        } else if (inherits(col, "POSIXct")) {
          format(col, "%Y-%m-%d %H:%M:%OS3", tz = "UTC")
        } else {
          as.character(col)
        }
      }),
      stringsAsFactors = FALSE
    )
  }
)
