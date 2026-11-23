# 41_export_web_extras.R — adds to web/: evidence-strength bitmask on each mapped parcel (parcels.json field m)
# and Maryland context shapes (context.json). Run after 40_export_web.R.
suppressPackageStartupMessages({library(sf); library(data.table); library(jsonlite)})
sf_use_s2(FALSE); W <- "web"
e <- fread("output/evidence.csv", select = c("blocklot", "source_id", "field", "value"))
# bureaucratic vacancy signals: one bit per independent record type (labels must match SIGNALS in web/index.html)
bits <- list(
  e[field == "vacant_building_notice", blocklot],                  # 0 open vacant building notice (DHCD)
  e[field == "VACIND", blocklot],                                  # 1 assessor vacancy flag
  e[field == "receivership_open", blocklot],                       # 2 open receivership case
  e[field == "vacants_to_value", blocklot],                        # 3 Vacants to Value listing
  e[field == "tax_sale_2023", blocklot],                           # 4 2023 tax sale list
  e[field == "NO_IMPRV" & startsWith(value, "NO_IMPRV=Y"), blocklot], # 5 assessor: no improvements
  e[field == "vacant_lot_list", blocklot],                         # 6 city vacant-lot list
  e[field %in% c("vacant_lot_list_city", "vacant_lot_list_private"), blocklot], # 7 Oct 2025 city/private vacant-lot lists
  e[field == "demolition", blocklot],                              # 8 completed demolition
  e[field == "adopt_a_lot", blocklot])                             # 9 Adopt-a-Lot
mask <- data.table(blocklot = unique(e$blocklot))[, m := 0L]
for (i in seq_along(bits)) mask[blocklot %in% bits[[i]], m := m + 2L^(i - 1L)]
mk <- setNames(mask$m, mask$blocklot)
feat <- fromJSON(file.path(W, "parcels.json"), simplifyVector = FALSE)
for (i in seq_along(feat)) feat[[i]]$m <- unname(mk[feat[[i]]$k])
writeLines(toJSON(feat, auto_unbox = TRUE, digits = NA), file.path(W, "parcels.json"))
# context: neighbouring states, Maryland counties, Baltimore City outline
simp <- function(x, tol) st_transform(st_simplify(st_transform(x, 26985), dTolerance = tol, preserveTopology = TRUE), 4326)
st <- tigris::states(cb = TRUE, resolution = "500k", year = 2023, progress_bar = FALSE)
st <- simp(st[st$STUSPS %in% c("MD", "DE", "PA", "VA", "WV", "DC", "NJ"), "STUSPS"], 150)
co <- simp(tigris::counties("24", cb = TRUE, resolution = "500k", year = 2023, progress_bar = FALSE)[, "NAME"], 60)
ci <- simp(tigris::places("24", cb = TRUE, year = 2023, progress_bar = FALSE), 10); ci <- ci[ci$NAME == "Baltimore", "NAME"]
gj <- function(x, nm) lapply(seq_len(nrow(x)), function(i) list(n = x[[nm]][i],
  g = lapply(st_cast(st_geometry(x)[i], "MULTIPOLYGON")[[1]], function(p) lapply(p, function(r) round(r, 5)))))
ctx <- list(states = gj(st, "STUSPS"), counties = gj(co, "NAME"), city = gj(ci, "NAME"),
            md_bounds = { b <- st_bbox(st[st$STUSPS == "MD", ]); list(c(b$ymin, b$xmin), c(b$ymax, b$xmax)) })
writeLines(toJSON(ctx, auto_unbox = TRUE, digits = NA), file.path(W, "context.json"))
cat("parcels.json", round(file.size(file.path(W, "parcels.json")) / 1e6, 1), "MB; context.json", round(file.size(file.path(W, "context.json")) / 1e6, 2), "MB\n")
x <- fread("output/parcel_index.csv", select = c("blocklot", "category"))
x[, m := mk[blocklot]]; x[is.na(m), m := 0L]
pc <- function(v, b) sapply(v, function(z) sum(bitwAnd(z, sum(2L^b)) > 0 & bitwAnd(rep(z, length(b)), 2L^b) > 0))
x[category == "VACANT_BUILDING", s := pc(m, 0:4)]; x[category == "VACANT_LOT", s := pc(m, 5:9)]
print(x[!is.na(s), .N, by = .(category, s)][order(category, s)])
