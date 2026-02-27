sf_user_agent <- function() {
  paste0(
    "RSnowflake/", utils::packageVersion("RSnowflake"),
    " R/", getRversion(),
    " (", Sys.info()[["sysname"]], ")"
  )
}

sf_host <- function(account) {
  paste0("https://", account, ".snowflakecomputing.com")
}
