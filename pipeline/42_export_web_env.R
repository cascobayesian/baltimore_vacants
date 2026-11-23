# 42_export_web_env.R — canopy / impervious / stormwater layers for the interactive map (web/).
# Inputs : output/env/parcel_env.csv + env_evidence.csv + env_sources.csv (51_env_metrics.R), data/raw_env/*.geojson,
#          output/parcel_index.gpkg, web/meta.json (tile extents from 40_export_web.R)
# Outputs: web/env_<layer>_<ij>.png parcel choropleth tiles, web/pipes_<ij>.png, web/stormwater.json (projects,
#          outfalls, inlets), web/env/<NN>.json per-parcel metrics + receipts, web/env_meta.json
suppressPackageStartupMessages({library(sf); library(data.table); library(jsonlite)})
sf_use_s2(FALSE); W <- "web"; dir.create(file.path(W, "env"), showWarnings = FALSE)
man <- fromJSON("data/raw_env/manifest.json"); meta <- fromJSON(file.path(W, "meta.json"), simplifyVector = FALSE)
X <- fread("output/env/parcel_env.csv")
g <- st_read("output/parcel_index.gpkg", quiet = TRUE)[, c("blocklot", "geo_id")]
g <- g[!duplicated(g$geo_id), ]
g <- merge(g, X[!duplicated(geo_id), .(geo_id, canopy_pct_2021, canopy_change_pp_2013_2021, imperv_pct_2021)], by = "geo_id", all.x = TRUE)
m <- st_transform(g, 3857)

# ---- choropleth layers: bins and colours (colours also listed in env_meta.json for the legend)
LAYERS <- list(
  canopy = list(v = "canopy_pct_2021", br = c(-Inf, 5, 15, 30, 50, Inf),
    lab = c("under 5%", "5–15%", "15–30%", "30–50%", "50% or more"), col = c("#efeadb", "#c9dca0", "#86b86a", "#3f8a4a", "#14532d")),
  canopy_change = list(v = "canopy_change_pp_2013_2021", br = c(-Inf, -10, -3, 3, 10, Inf),
    lab = c("lost 10+ points", "lost 3–10", "within ±3", "gained 3–10", "gained 10+ points"), col = c("#b2432f", "#e9a17e", "#e8e6df", "#8fc39a", "#1f7a4d")),
  imperv = list(v = "imperv_pct_2021", br = c(-Inf, 25, 50, 75, 90, Inf),
    lab = c("under 25%", "25–50%", "50–75%", "75–90%", "90% or more"), col = c("#e3eef5", "#a9c8dc", "#6d9cbc", "#3d6a8f", "#1b3550")))
tiles <- meta$tiles; px <- 2400
tile_ext <- function(t) { b <- st_bbox(st_transform(st_as_sfc(st_bbox(c(xmin = t$b[[1]][[2]], ymin = t$b[[1]][[1]], xmax = t$b[[2]][[2]], ymax = t$b[[2]][[1]]), crs = 4326)), 3857)); b }
render <- function(fn, draw) for (t in tiles) {
  b <- tile_ext(t); nm <- sub("base_", paste0(fn, "_"), t$f)
  if (file.exists(file.path(W, nm)) && Sys.getenv("REDRAW") == "") next
  png(file.path(W, nm), width = px, height = round(px * (b$ymax - b$ymin) / (b$xmax - b$xmin)), bg = "transparent")
  par(mar = c(0, 0, 0, 0)); plot.new(); plot.window(xlim = c(b$xmin, b$xmax), ylim = c(b$ymin, b$ymax), xaxs = "i", yaxs = "i", asp = NA)
  draw(); dev.off() }
counts <- list()
for (ln in names(LAYERS)) { L <- LAYERS[[ln]]
  k <- cut(m[[L$v]], L$br, labels = FALSE, right = FALSE); cl <- ifelse(is.na(k), NA, L$col[k])
  counts[[ln]] <- as.list(tabulate(k, length(L$lab)))
  render(paste0("env_", ln), function() plot(st_geometry(m)[!is.na(cl)], col = cl[!is.na(cl)], border = NA, add = TRUE)) }
# ---- storm pipes (active, not abandoned) as a line raster
D <- st_read(man$SW_DRAIN$raw_file, quiet = TRUE); D <- D[!st_is_empty(D) & !(D$FEAT_STATUS %in% "ABD"), ]
D <- st_transform(D, 3857)
render("pipes", function() plot(st_geometry(D), col = "#2f7fbf", lwd = 1.1, add = TRUE))
# ---- point layers
pts <- function(s) { x <- st_read(man[[s]]$raw_file, quiet = TRUE); x <- x[!st_is_empty(x), ]; cc <- st_coordinates(x); list(x = x, ll = round(cc[, 2:1], 6)) }
pr <- pts("SW_PROJECTS"); of <- pts("SW_OUTFALL"); il <- pts("SW_INLET")
sw <- list(
  projects = lapply(seq_len(nrow(pr$x)), function(i) list(pr$ll[i, ], pr$x$bmp_type[i], pr$x$status[i], trimws(pr$x$plan_id_ms42021_1[i]), pr$x$objectid[i])),
  outfalls = lapply(seq_len(nrow(of$x)), function(i) list(of$ll[i, ], of$x$OUTFALL_ID[i], of$x$Outfall_Type[i], of$x$Watershed[i], of$x$OBJECTID[i])),
  inlets = lapply(seq_len(nrow(il$x)), function(i) c(il$ll[i, ], match(il$x$AGENCY[i], c("DPW", "PRV"), nomatch = 0L))))
writeLines(toJSON(sw, auto_unbox = TRUE, digits = NA), file.path(W, "stormwater.json"))
# ---- per-parcel metrics + receipts, chunked like detail/
ev <- fread("output/env/env_evidence.csv")[!startsWith(source_id, "LULC_")]
ev <- ev[, .(r = list(list(source_id, source_record_id, field, value, record_date))), by = blocklot]
evl <- setNames(ev$r, ev$blocklot)
X[, grp := substr(blocklot, 1, 2)]
# compact: each parcel is an array in the order of `cols` (listed in env_meta.json), receipts last
cols <- c("canopy_pct_2021", "canopy_pct_2013", "canopy_change_pp_2013_2021", "imperv_pct_2021", "structures_pct_2021",
          "imperv_sqft_2021", "eru_est_2021", "inlet_dist_m", "inlets_on_parcel", "private_inlets_on_parcel", "pipe_m_on_parcel",
          "sw_projects_within_30m", "public_trees_on_parcel", "lc_certainty", "sw_project_detail")
unlink(file.path(W, "env"), recursive = TRUE); dir.create(file.path(W, "env"))
X[sw_project_detail == "", sw_project_detail := NA]
for (gname in unique(X$grp)) { xs <- X[grp == gname]
  vals <- lapply(cols, function(cn) xs[[cn]])
  recs <- lapply(seq_len(nrow(xs)), function(i) { z <- lapply(vals, `[`, i); if (!is.null(evl[[xs$blocklot[i]]])) z[[length(z) + 1]] <- evl[[xs$blocklot[i]]]; z })
  names(recs) <- xs$blocklot
  writeLines(toJSON(recs, auto_unbox = TRUE, na = "null", digits = NA), file.path(W, "env", paste0(gname, ".json"))) }
src <- fread("output/env/env_sources.csv")
em <- list(layers = lapply(LAYERS, function(L) list(lab = L$lab, col = L$col)), counts = counts, cols = cols,
  sources = src[, .(source_id, name, service_url, portal_url, downloaded_at, n_records, role)],
  oid = lapply(man, function(s) s$oid_field), urls = lapply(man, function(s) s$service_url),
  status_counts = as.list(table(pr$x$status)))
writeLines(toJSON(em, auto_unbox = TRUE, digits = NA), file.path(W, "env_meta.json"))
ff <- list.files(W, pattern = "^(env|pipes|stormwater)", full.names = TRUE)
cat(sprintf("%-28s %6.1f MB\n", basename(ff), file.size(ff) / 1e6), sep = ""); cat("env chunks MB", sum(file.size(list.files(file.path(W, "env"), full.names = TRUE))) / 1e6, "\n")
