# 40_export_web.R — data files for the interactive map (web/).
# base.png: every parcel footprint (Web Mercator raster); parcels.json: flagged parcels as simplified polygons;
# detail.json: per-parcel receipts; search.json: every parcel (key, address, category, point) for lookup.
suppressPackageStartupMessages({library(sf); library(data.table); library(jsonlite)})
sf_use_s2(FALSE); W <- "web"; dir.create(W, showWarnings = FALSE)
g <- st_read("output/parcel_index.gpkg", quiet = TRUE)
x <- fread("output/parcel_index.csv"); e <- fread("output/evidence.csv"); r <- fread("output/rules.csv")
CATS <- c("VACANT_BUILDING", "VACANT_LOT", "COMMUNITY_OPEN_SPACE", "PARK", "PROTECTED_GREENSPACE", "TRANSPORTATION", "NOT_VACANT")
CERT <- c("high", "medium", "low")
# ---- base raster (all footprints) in EPSG:3857
m <- st_transform(g[!duplicated(g$geo_id), ], 3857); bb <- st_bbox(m)
# 2 x 2 tiles so each file stays under the 15 MB artifact limit
px <- 2800; xs4 <- seq(bb$xmin, bb$xmax, length.out = 3); ys4 <- seq(bb$ymin, bb$ymax, length.out = 3); tiles <- list()
for (i in 1:2) for (j in 1:2) {
  xl <- xs4[i:(i + 1)]; yl <- ys4[j:(j + 1)]; nm <- sprintf("base_%d%d.png", i, j)
  png(file.path(W, nm), width = px, height = round(px * diff(yl) / diff(xl)), bg = "transparent")
  par(mar = c(0, 0, 0, 0)); plot.new(); plot.window(xlim = xl, ylim = yl, xaxs = "i", yaxs = "i", asp = NA)
  plot(st_geometry(m), col = "#8f969c", border = NA, add = TRUE); dev.off()
  cb <- st_bbox(st_transform(st_as_sfc(st_bbox(c(xmin = xl[1], ymin = yl[1], xmax = xl[2], ymax = yl[2]), crs = 3857)), 4326))
  tiles[[length(tiles) + 1]] <- list(f = nm, b = list(c(cb$ymin, cb$xmin), c(cb$ymax, cb$xmax))) }
corn <- st_transform(st_as_sfc(st_bbox(bb, crs = 3857)), 4326) |> st_bbox()
# ---- flagged parcels (one footprint per stacked condo)
f <- g[g$category != "NOT_VACANT" | g$conflict_flag, ]
f <- f[!duplicated(f$geo_id), ]
f <- st_simplify(st_transform(f, 26985), dTolerance = 0.8, preserveTopology = TRUE)
f <- st_transform(f, 4326)
ring <- function(geom) { gg <- st_cast(st_sfc(geom, crs = 4326), "MULTIPOLYGON")[[1]]
  lapply(gg, function(poly) lapply(poly, function(rr) round(rr, 6))) }
feat <- lapply(seq_len(nrow(f)), function(i) list(k = f$blocklot[i], c = match(f$category[i], CATS) - 1,
  r = match(f$certainty[i], CERT) - 1, x = as.integer(f$conflict_flag[i]), g = ring(st_geometry(f)[[i]])))
writeLines(toJSON(feat, auto_unbox = TRUE, digits = NA), file.path(W, "parcels.json"))
# ---- receipts for flagged parcels and for every parcel that shares their footprint
keys <- x$blocklot   # receipts for every parcel
ev <- e[blocklot %in% keys, .(blocklot, s = source_id, i = source_record_id, f = field, v = value, d = fifelse(is.na(record_date), "", as.character(record_date)), m = match_method, o = overlap_pct)]
xs <- x[blocklot %in% keys]
# each receipt as [source, record id, field, value, date, match method, overlap %]; source/field/method coded by index
SRCS <- sort(unique(ev$s)); FLD <- sort(unique(ev$f)); MET <- sort(unique(ev$m))
ev[, `:=`(s = match(s, SRCS) - 1L, f = match(f, FLD) - 1L, m = match(m, MET) - 1L)]
ev[startsWith(v, "MAYOR AND CITY COUNCIL OF BALTIMORE"), v := sub("MAYOR AND CITY COUNCIL OF BALTIMORE", "MCC", v, fixed = TRUE)]
det <- lapply(split(ev, by = "blocklot", keep.by = FALSE), function(d) lapply(seq_len(nrow(d)), function(j) list(d$s[j], d$i[j], d$f[j], d$v[j], d$d[j], d$m[j], d$o[j])))
ws <- sub(".*Ward=([0-9]+)&SECTION=([0-9]+).*", "\\1/\\2", xs$sdat_url); ws[!grepl("^[0-9]+/[0-9]+$", ws)] <- NA
recs <- lapply(seq_len(nrow(xs)), function(i) { b <- xs$blocklot[i]   # SDAT and block-plat links are rebuilt in the page from ward/section + key
  z <- list(a = xs$address[i], oc = xs$owner_class[i], c = match(xs$category[i], CATS) - 1L, r = match(xs$certainty[i], CERT) - 1L,
            u = xs$rule_id[i], ws = ws[i], e = det[[b]])
  if (nzchar(xs$conflict_note[i])) z$n <- xs$conflict_note[i]; if (isTRUE(xs$stacked_condo[i])) z$cd <- 1L; z })
names(recs) <- xs$blocklot
dir.create(file.path(W, "detail"), showWarnings = FALSE); unlink(file.path(W, "detail.json"))
grp <- substr(xs$blocklot, 1, 2)   # chunk by first two characters of the block, loaded on demand
for (gname in unique(grp)) writeLines(toJSON(recs[grp == gname], auto_unbox = TRUE, na = "null", digits = NA), file.path(W, "detail", paste0(gname, ".json")))
# ---- search index for every parcel: [blocklot, address, cat, cert, lon, lat, geo_id-in-flagged?]
pt <- st_coordinates(st_point_on_surface(st_geometry(st_transform(g, 4326))))
si <- data.table(k = g$blocklot, lon = round(pt[, 1], 5), lat = round(pt[, 2], 5))[x[, .(k = blocklot, a = address, c = match(category, CATS) - 1, r = match(certainty, CERT) - 1)], on = "k"]
si[is.na(a), a := ""]
writeLines(toJSON(si[, .(k, a, c, r, lon, lat)], dataframe = "values", digits = NA), file.path(W, "search.json"))
# ---- meta: map bounds, rule table, sources, counts
src <- fread("output/sources.csv"); man <- fromJSON("data/raw/manifest.json")
src[, oid := sapply(source_id, function(s) man[[s]]$oid_field)]
meta <- list(bounds = list(c(corn$ymin, corn$xmin), c(corn$ymax, corn$xmax)), tiles = tiles, built = as.character(Sys.Date()), cats = CATS,
  rules = r, sources = src[, .(source_id, name, oid, service_url, portal_url, downloaded_at, layer_last_edit, n_records, role)],
  counts = x[, .N, by = .(category, certainty)], srcs = SRCS, fields = FLD, methods = MET, n_parcels = nrow(x), n_conflict = sum(x$conflict_flag))
writeLines(toJSON(meta, auto_unbox = TRUE, digits = NA), file.path(W, "meta.json"))
ff <- list.files(W, recursive = TRUE, full.names = TRUE); cat(length(ff), "files; largest:\n"); print(head(sort(setNames(round(file.size(ff) / 1e6, 1), ff), decreasing = TRUE), 8)); cat("total MB", sum(file.size(ff)) / 1e6, "\n")
