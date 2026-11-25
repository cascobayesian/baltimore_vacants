# 70_consensus.R: merge the three independent builds into one parcel list. The three builds are
# Y (2026-11-23, output/), A and B (2026-11-24, replication/run_A and run_B; see replication/compare.R).
# How strong the vacancy evidence is depends on how many builds call the parcel vacant, and at what certainty.
# Writes replication/consensus/ (parcel_consensus.csv, summary, map) and web/consensus*.json for the map.
suppressPackageStartupMessages({library(data.table); library(sf); library(jsonlite)})
sf_use_s2(FALSE)
setwd("/Users/jobrien/Library/CloudStorage/Dropbox/Teaching/Experiments/Baltimore.Parcels")
OUT <- "replication/consensus"; dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
rd <- function(f) fread(f, colClasses = list(character = "blocklot"), showProgress = FALSE)
A <- rd("replication/run_A/output/parcel_list.csv")[!duplicated(blocklot)]
B <- rd("replication/run_B/output/parcel_list.csv")[!duplicated(blocklot)]
Y <- rd("output/parcel_index.csv")[!duplicated(blocklot)]
YE <- rd("output/env/parcel_env.csv")[!duplicated(blocklot)]

# common category scheme (the same mapping as compare.R)
coarse <- function(x) { x <- tolower(gsub("_", " ", x))
  fcase(grepl("vacant build", x), "vacant_building", grepl("vacant lot", x), "vacant_lot",
        grepl("protected", x), "protected_green", grepl("park", x), "park", grepl("transport", x), "transportation",
        grepl("community", x), "community_open_space", grepl("public", x), "other_public", default = "not_vacant") }
W <- c(high = 1, medium = 0.6, low = 0.3)   # certainty weights for the evidence score

d <- Y[, .(blocklot, address, owner, Y_cat = coarse(category), Y_cert = certainty, Y_rule = rule_id, Y_evidence = evidence_summary, Y_conflict = conflict_note)]
d <- merge(d, A[, .(blocklot, A_cat = coarse(category), A_cert = certainty, A_rule = rule, A_evidence = evidence_sources,
                    A_noimpr = city_no_imprv, A_structure_pct = structure_pct, A_canopy = canopy_pct, A_imperv = impervious_pct, A_inlet = dist_inlet_m)], by = "blocklot", all = TRUE)
d <- merge(d, B[, .(blocklot, B_cat = coarse(category), B_cert = certainty, B_rule = rule, B_evidence = evidence_sources,
                    B_signals = other_vacancy_signals, B_canopy = canopy_pct, B_imperv = impervious_pct)], by = "blocklot", all = TRUE)
d <- merge(d, YE[, .(blocklot, Y_canopy = canopy_pct_2021, Y_imperv = imperv_pct_2021, Y_inlet = inlet_dist_m)], by = "blocklot", all.x = TRUE)
stopifnot(nrow(d) == nrow(Y), !anyNA(d$A_cat), !anyNA(d$B_cat))

isvac <- function(x) x %in% c("vacant_building", "vacant_lot")
d[, votes := isvac(A_cat) + isvac(B_cat) + isvac(Y_cat)]
wt <- function(c) { w <- unname(W[c]); fifelse(is.na(w), 0, w) }
d[, score := round(isvac(A_cat) * wt(A_cert) + isvac(B_cat) * wt(B_cert) + isvac(Y_cat) * wt(Y_cert), 2)]
d[is.na(score), score := 0]
d[, n_high := (isvac(A_cat) & A_cert == "high") + (isvac(B_cat) & B_cert == "high") + (isvac(Y_cat) & Y_cert == "high")]
d[, tier := fcase(votes == 3 & n_high == 3, 4L, votes == 3, 3L, votes == 2, 2L, votes == 1, 1L, default = 0L)]
TIER_LAB <- c("0" = "not vacant (all three builds)", "1" = "weak: 1 of 3 builds", "2" = "contested: 2 of 3 builds",
              "3" = "strong: 3 of 3 builds", "4" = "confirmed: 3 of 3 builds, all high certainty")
d[, tier_label := TIER_LAB[as.character(tier)]]
# vacancy type: majority of the vacant calls (ties go to building, the narrower claim backed by a notice)
d[, n_bld := (A_cat == "vacant_building") + (B_cat == "vacant_building") + (Y_cat == "vacant_building")]
d[, vacancy_type := fifelse(votes == 0, "", fifelse(n_bld * 2 >= votes, "vacant_building", "vacant_lot"))]
# consensus land category: majority of the three, or "disputed"
maj <- function(a, b, y) fifelse(a == b | a == y, a, fifelse(b == y, b, "disputed"))
d[, consensus_category := maj(A_cat, B_cat, Y_cat)]
d[, agree := fcase(A_cat == B_cat & B_cat == Y_cat, "3/3", consensus_category != "disputed", "2/3", default = "none")]

# why do the builds disagree? (a rough classification from the fields the builds share)
landuse <- c("park", "protected_green", "community_open_space", "transportation", "other_public")
d[, on_list := grepl("dhcd_vacant_lot|agol_vacant_lots|VACANT_LOTS|LOTS:|city_demo|DEMO:", paste(B_signals, B_evidence, Y_evidence))]
d[, dispute_reason := ""]
d[agree != "3/3", dispute_reason := {
  cats <- Map(c, A_cat, B_cat, Y_cat)
  lu <- vapply(cats, function(z) paste(intersect(landuse, z), collapse = "+"), "")
  fcase(nzchar(lu) & votes %in% 1:2, paste0("vacant vs ", lu, " (land-use definitions)"),
        nzchar(lu), paste0("land-use definitions: ", lu),
        on_list & A_noimpr %in% FALSE, "vacant-lot list or demolition record vs assessed improvements",
        A_noimpr %in% TRUE & A_structure_pct >= 20, "assessor shows no improvements but imagery shows a structure",
        default = "other rule differences") }]

# environmental: canopy and impervious averaged over the three builds; inlet distance from A and Y only (both use DPW inlets; B used 311 requests)
d[, canopy_pct := round(rowMeans(cbind(A_canopy, B_canopy, Y_canopy), na.rm = TRUE), 1)]
d[, canopy_spread := round(pmax(A_canopy, B_canopy, Y_canopy, na.rm = TRUE) - pmin(A_canopy, B_canopy, Y_canopy, na.rm = TRUE), 1)]
d[, impervious_pct := round(rowMeans(cbind(A_imperv, B_imperv, Y_imperv), na.rm = TRUE), 1)]
d[, dist_inlet_m := round(rowMeans(cbind(A_inlet, Y_inlet), na.rm = TRUE), 1)]
for (v in c("canopy_pct", "canopy_spread", "impervious_pct", "dist_inlet_m")) set(d, which(is.nan(d[[v]]) | is.infinite(d[[v]])), v, NA)

setcolorder(d, c("blocklot", "address", "owner", "tier", "tier_label", "votes", "score", "vacancy_type", "consensus_category", "agree", "dispute_reason",
                 "Y_cat", "Y_cert", "A_cat", "A_cert", "B_cat", "B_cert", "canopy_pct", "canopy_spread", "impervious_pct", "dist_inlet_m"))
d[, c("n_bld", "n_high") := NULL]
fwrite(d, file.path(OUT, "parcel_consensus.csv"))

# ---- summary
sink(file.path(OUT, "summary.txt"), split = TRUE)
cat("Parcels:", nrow(d), "\n\nVacancy evidence tier x type\n"); print(dcast(d[, .N, by = .(tier_label, vacancy_type)], tier_label ~ vacancy_type, value.var = "N", fill = 0))
cat("\nAgreement on the land category:\n"); print(d[, .N, by = agree])
cat("\nConsensus category (majority of 3):\n"); print(d[, .N, by = consensus_category][order(-N)])
cat("\nDispute reasons:\n"); print(d[dispute_reason != "", .N, by = dispute_reason][order(-N)])
cat("\nDispute reasons, parcels with 1 or 2 vacancy votes:\n"); print(d[votes %in% 1:2, .N, by = .(votes, dispute_reason)][order(votes, -N)])
sink()

# ---- web export: polygons of every parcel with >= 1 vacancy vote, plus a lookup of the three verdicts for every parcel where the builds differ
g <- st_read("output/parcel_index.gpkg", quiet = TRUE)[, c("blocklot", "geo_id")]
CC <- c("vacant_building", "vacant_lot", "community_open_space", "park", "protected_green", "transportation", "other_public", "not_vacant")
CR <- c("high", "medium", "low")
code <- function(cat, cert) list(match(cat, CC) - 1L, match(cert, CR) - 1L)
f <- merge(g, d[votes > 0, .(blocklot, tier, votes, score, vacancy_type)], by = "blocklot")
f <- f[!duplicated(f$geo_id), ]
f <- st_transform(st_simplify(st_transform(f, 26985), dTolerance = 0.8, preserveTopology = TRUE), 4326)
ring <- function(geom) lapply(st_cast(st_sfc(geom, crs = 4326), "MULTIPOLYGON")[[1]], function(p) lapply(p, function(rr) round(rr, 6)))
feat <- lapply(seq_len(nrow(f)), function(i) list(k = f$blocklot[i], t = f$tier[i], y = as.integer(f$vacancy_type[i] == "vacant_lot"), g = ring(st_geometry(f)[[i]])))
writeLines(toJSON(feat, auto_unbox = TRUE, digits = NA), "web/consensus_parcels.json")
lk <- d[votes > 0 | agree != "3/3"]
look <- setNames(lapply(seq_len(nrow(lk)), function(i) with(lk[i], list(t = tier, s = score,
  v = list(c(code(Y_cat, Y_cert), Y_rule), c(code(A_cat, A_cert), A_rule), c(code(B_cat, B_cert), B_rule)),
  w = dispute_reason, cs = canopy_spread))), lk$blocklot)
writeLines(toJSON(look, auto_unbox = TRUE, na = "null", digits = NA), "web/consensus.json")
cm <- list(cats = CC, certs = CR, tiers = TIER_LAB, counts = d[, .N, by = .(tier, vacancy_type)],
  n_parcels = nrow(d), n_agree3 = sum(d$agree == "3/3"), built = as.character(Sys.Date()),
  runs = list(list(id = "Y", label = "Build 1 (2026-11-23)"), list(id = "A", label = "Build 2 (2026-11-24, independent)"), list(id = "B", label = "Build 3 (2026-11-24, independent)")))
writeLines(toJSON(cm, auto_unbox = TRUE, digits = NA), "web/consensus_meta.json")
cat("web files (MB):", round(file.size(c("web/consensus_parcels.json", "web/consensus.json", "web/consensus_meta.json")) / 1e6, 2), "\n")

# ---- static map
suppressPackageStartupMessages(library(ggplot2))
gm <- merge(st_read("output/parcel_index.gpkg", quiet = TRUE)[, "blocklot"], d[, .(blocklot, tier)], by = "blocklot")
gm$tier_f <- factor(gm$tier, 0:4, TIER_LAB)
p <- ggplot(gm) + geom_sf(aes(fill = tier_f), colour = NA) +
  scale_fill_manual(values = c("#e4e6e3", "#f3c9a8", "#e58f5c", "#c2512a", "#6e1e12"), name = "Vacancy evidence") +
  theme_void(base_size = 11) + labs(title = "Baltimore parcels: agreement of three independent vacancy builds")
ggsave(file.path(OUT, "map_consensus_tiers.png"), p, width = 9, height = 9.5, dpi = 200, bg = "white")
