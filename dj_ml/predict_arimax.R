#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 3) {
  stop("Usage: Rscript predict_arimax.R <model_path> <input_csv> <output_csv>")
}

model_path <- args[1]
input_csv <- args[2]
output_csv <- args[3]

library(forecast)

model <- readRDS(model_path)

input_data <- read.csv(input_csv)

if (!all(c("exog_var1", "exog_var2") %in% colnames(input_data))) {
  stop("Input data must contain columns: exog_var1, exog_var2")
}

xreg_new <- as.matrix(input_data[, c("exog_var1", "exog_var2")])

n_ahead <- nrow(input_data)

predictions <- forecast(model, xreg = xreg_new, h = n_ahead)

output_data <- data.frame(
  forecast = as.numeric(predictions$mean),
  lower_80 = as.numeric(predictions$lower[, 1]),
  upper_80 = as.numeric(predictions$upper[, 1]),
  lower_95 = as.numeric(predictions$lower[, 2]),
  upper_95 = as.numeric(predictions$upper[, 2])
)

write.csv(output_data, output_csv, row.names = FALSE)

cat("Predictions saved to", output_csv, "\n")
