#!/usr/bin/env Rscript

library(forecast)

set.seed(42)

n <- 100
time_index <- 1:n
trend <- 0.5 * time_index
seasonal <- 10 * sin(2 * pi * time_index / 12)
noise <- rnorm(n, mean = 0, sd = 2)

exog_var1 <- rnorm(n, mean = 5, sd = 1)
exog_var2 <- rnorm(n, mean = 10, sd = 2)

y <- 50 + trend + seasonal + 2 * exog_var1 + 1.5 * exog_var2 + noise

xreg <- cbind(exog_var1, exog_var2)

arimax_model <- auto.arima(y, xreg = xreg, seasonal = TRUE)

saveRDS(arimax_model, file = "arimax_model_artifact.rds")

cat("ARIMAX model trained and saved to arimax_model_artifact.rds\n")
cat("Model summary:\n")
print(summary(arimax_model))
