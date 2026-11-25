# Compare replication runs A and B with each other and with the 2026-11-23 build ("Y").
suppressMessages(library(data.table))
setwd("/Users/jobrien/Library/CloudStorage/Dropbox/Teaching/Experiments/Baltimore.Parcels")
out <- "replication/comparison"; dir.create(out, showWarnings = FALSE)
sink(file.path(out, "compare_log.txt"), split = TRUE)

rd <- function(f) fread(f, colClasses = list(character = "blocklot"), showProgress = FALSE)
A <- rd("replication/run_A/output/parcel_list.csv")
B <- rd("replication/run_B/output/parcel_list.csv")
Y <- rd("output/parcel_index.csv")
YE <- rd("output/env/parcel_env.csv")

# harmonize category labels to a common coarse scheme
coarse <- function(x) {
  x <- tolower(gsub("_", " ", x))
  fcase(grepl("vacant build", x), "vacant_building",
        grepl("vacant lot", x), "vacant_lot",
        grepl("protected|green space prot|bgs", x) & !grepl("community", x), "protected_green",
        grepl("park", x), "park",
        grepl("transport", x), "transportation",
        grepl("community", x), "community_open_space",
        grepl("other public|public", x), "other_public",
        grepl("not vacant|no vacancy|in use|occupied", x), "not_vacant",
        default = paste0("?", x))
}
cat("Raw category labels:\n"); for (d in list(A = A, B = B, Y = Y)) print(table(d$category))
A[, cat := coarse(category)]; B[, cat := coarse(category)]; Y[, cat := coarse(category)]
for (n in c("A", "B", "Y")) { d <- get(n); d <- d[!duplicated(blocklot)]; assign(n, d) }

cat("\nParcel counts: A", nrow(A), " B", nrow(B), " Y", nrow(Y), "\n")
kappa <- function(x, y) { t <- table(x, y); lv <- union(rownames(t), colnames(t))
  t <- table(factor(x, lv), factor(y, lv)); n <- sum(t); po <- sum(diag(t)) / n
  pe <- sum(rowSums(t) * colSums(t)) / n^2; (po - pe) / (1 - pe) }
pair <- function(n1, n2) {
  d1 <- get(n1); d2 <- get(n2)
  m <- merge(d1[, .(blocklot, c1 = cat, k1 = certainty)], d2[, .(blocklot, c2 = cat, k2 = certainty)], by = "blocklot")
  cat(sprintf("\n==== %s vs %s: %d common keys (%d only in %s, %d only in %s)\n", n1, n2, nrow(m),
              nrow(d1) - nrow(m), n1, nrow(d2) - nrow(m), n2))
  cat(sprintf("Agreement %.2f%%, kappa %.3f\n", 100 * mean(m$c1 == m$c2), kappa(m$c1, m$c2)))
  ct <- dcast(m[, .N, by = .(c1, c2)], c1 ~ c2, value.var = "N", fill = 0)
  setnames(ct, "c1", paste0(n1, "\\", n2)); print(ct)
  for (v in c("vacant_building", "vacant_lot")) {
    a <- m$c1 == v; b <- m$c2 == v
    cat(sprintf("%s: %s=%d %s=%d both=%d Jaccard=%.3f\n", v, n1, sum(a), n2, sum(b), sum(a & b), sum(a & b) / sum(a | b)))
    hi <- m$c1 == v & m$k1 == "high"; hi2 <- m$c2 == v & m$k2 == "high"
    cat(sprintf("   high-certainty only: both=%d, Jaccard=%.3f\n", sum(hi & hi2), sum(hi & hi2) / sum(hi | hi2)))
  }
  fwrite(m[c1 != c2], file.path(out, sprintf("disagree_%s_%s.csv", n1, n2)))
  invisible(m)
}
mAB <- pair("A", "B"); mAY <- pair("A", "Y"); mBY <- pair("B", "Y")

# three-way consensus on vacancy
m3 <- Reduce(function(x, y) merge(x, y, by = "blocklot"),
  list(A[, .(blocklot, A = cat)], B[, .(blocklot, B = cat)], Y[, .(blocklot, Y = cat)]))
for (v in c("vacant_building", "vacant_lot")) {
  k <- (m3$A == v) + (m3$B == v) + (m3$Y == v)
  cat(sprintf("\n%s: called by 3 runs=%d, 2=%d, 1=%d\n", v, sum(k == 3), sum(k == 2), sum(k == 1)))
}

# canopy / impervious / inlets
cat("\n==== Environmental metrics\n")
cat("Column names B:\n"); print(names(B))
num <- function(d, pat) { j <- grep(pat, names(d), value = TRUE)[1]; if (is.na(j)) NULL else j }
env <- list(
  A = A[, .(blocklot, canopy = canopy_pct, imperv = get(num(A, "^impervious_pct")), inlet_d = get(num(A, "dist_inlet")))],
  B = B[, c(list(blocklot = blocklot, canopy = canopy_pct),
            if (!is.null(num(B, "imperv.*pct"))) list(imperv = B[[num(B, "imperv.*pct")]]),
            if (!is.null(num(B, "inlet.*(dist|_m)"))) list(inlet_d = B[[num(B, "inlet.*(dist|_m)")]]))],
  Y = YE[!duplicated(blocklot), .(blocklot, canopy = canopy_pct_2021, imperv = imperv_pct_2021, inlet_d = inlet_dist_m)])
for (pr in list(c("A", "B"), c("A", "Y"), c("B", "Y"))) {
  m <- merge(env[[pr[1]]], env[[pr[2]]], by = "blocklot", suffixes = c(".1", ".2"))
  for (v in intersect(c("canopy", "imperv", "inlet_d"), sub("\\.1$", "", grep("\\.1$", names(m), value = TRUE)))) {
    x <- m[[paste0(v, ".1")]]; y <- m[[paste0(v, ".2")]]; ok <- is.finite(x) & is.finite(y)
    cat(sprintf("%s vs %s  %-8s n=%d r=%.4f  median|diff|=%.2f  p95|diff|=%.2f  mean %.2f vs %.2f  |diff|>10: %d\n",
      pr[1], pr[2], v, sum(ok), cor(x[ok], y[ok]), median(abs(x - y)[ok]), quantile(abs(x - y)[ok], .95),
      mean(x[ok]), mean(y[ok]), sum(abs(x - y)[ok] > 10)))
  }
}
sink()
