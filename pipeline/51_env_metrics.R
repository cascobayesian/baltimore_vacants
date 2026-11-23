# Parcel-level canopy, impervious-surface and stormwater-infrastructure metrics (environment extension).
# Inputs : data/raw_env/manifest.json (from 50_fetch_env_sources.py); parcel geometry from output/parcel_index.gpkg,
#          frozen to data/raw_env/PARCEL_GEOM_<date>.gpkg on first run so the vacancy build can keep rewriting its output.
# Outputs: output/env/parcel_env.csv (+ .gpkg), env_evidence.csv, env_sources.csv, env_match_audit.csv, env_run_log.txt
# Kept separate from 20_build_index.R; a later step joins parcel_env.csv to the index by blocklot.
# Usage  : Rscript scripts/51_env_metrics.R [n_test_geometries]
suppressMessages({ library(sf); library(terra); library(data.table); library(jsonlite) })
sf_use_s2(FALSE)
args <- commandArgs(TRUE); NTEST <- if (length(args)) as.integer(args[1]) else NA
RAW <- "data/raw_env"; OUT <- "output/env"; dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
CRS_M <- 26985
LOG <- file.path(OUT, if (is.na(NTEST)) "env_run_log.txt" else "env_run_log_test.txt"); cat("", file = LOG)
say <- function(...) { m <- paste0(format(Sys.time(), "%H:%M:%S "), ...); cat(m, "\n"); cat(m, "\n", file = LOG, append = TRUE) }
man <- fromJSON(file.path(RAW, "manifest.json"))
sha <- function(p) sub(" .*", "", system2("shasum", c("-a", "256", shQuote(p)), stdout = TRUE))

# ---- parcel geometry snapshot ----------------------------------------------------------------------------------------
snap <- Sys.glob(file.path(RAW, "PARCEL_GEOM_*.gpkg"))
if (!length(snap)) {
  snap <- file.path(RAW, paste0("PARCEL_GEOM_", format(Sys.Date(), "%Y%m%d"), ".gpkg"))
  file.copy("output/parcel_index.gpkg", snap)
}
snap <- tail(sort(snap), 1)
man$PARCEL_GEOM <- list(service_url = "output/parcel_index.gpkg (20_build_index.R; from PARCEL_OB)", portal_url = "",
  name = "parcel geometry, one row per blocklot", role = "parcel polygons (multi-row keys unioned by the vacancy build)",
  raw_file = snap, sha256 = sha(snap), downloaded_at = format(file.mtime(snap), "%Y-%m-%dT%H:%M:%S"))
for (s in names(man)) say("input ", s, " sha256=", substr(man[[s]]$sha256, 1, 16), " ", man[[s]]$raw_file)

P <- st_read(snap, quiet = TRUE)[, c("blocklot", "geo_id", "stacked_condo")]
P <- st_transform(P, CRS_M); P$area_m2 <- as.numeric(st_area(P))
say("parcels: ", nrow(P), "; unique geometries (geo_id): ", uniqueN(P$geo_id))
G <- P[!duplicated(P$geo_id), c("geo_id", "area_m2")]
if (!is.na(NTEST)) { set.seed(1); G <- G[sort(sample(nrow(G), NTEST)), ]; P <- P[P$geo_id %in% G$geo_id, ]; say("TEST MODE: ", nrow(G), " geometries") }
G$gid <- seq_len(nrow(G))

# ---- land cover: exact pixel fractions, three years at once ----------------------------------------------------------
R <- rast(c(man$LULC_2013$raw_file, man$LULC_2018$raw_file, man$LULC_2021$raw_file)); names(R) <- c("y2013", "y2018", "y2021")
GR <- st_transform(G, crs(R))
CANOPY <- c(23, 24, 25, 26, 40, 41, 53, 54, 63, 64, 73, 74)
IMPERV <- c(20, 21, 22, 23, 24, 25, 31)            # includes impervious under tree canopy (fee basis counts it)
grp <- function(v) fcase(v %in% CANOPY, "canopy", default = "other")
chunks <- split(seq_len(nrow(GR)), ceiling(seq_len(nrow(GR)) / 3000))
acc <- vector("list", length(chunks)); t0 <- Sys.time()
for (i in seq_along(chunks)) {   # exactextractr: exact cell-coverage fractions (terra exact=TRUE was ~100x slower)
  ix <- chunks[[i]]
  e <- rbindlist(exactextractr::exact_extract(R, GR[ix, ], progress = FALSE), idcol = "ID")
  e[, gid := ix[ID]]
  acc[[i]] <- rbindlist(lapply(c("y2013", "y2018", "y2021"), function(y)
    e[, .(m2 = sum(coverage_fraction)), by = .(gid, cls = get(y))][, year := y]))
  rm(e)
  if (i %% 10 == 0 || i == length(chunks))
    say(sprintf("land cover chunk %d/%d (%.1f min)", i, length(chunks), as.numeric(difftime(Sys.time(), t0, units = "mins"))))
}
LC <- rbindlist(acc); rm(acc)
LC[is.na(cls), cls := 0L]
W <- LC[, .(
  covered_m2  = sum(m2[cls != 0]),
  canopy_m2   = sum(m2[cls %in% CANOPY]),
  imperv_m2   = sum(m2[cls %in% IMPERV]),
  struct_m2   = sum(m2[cls %in% c(21, 24)]),
  road_m2     = sum(m2[cls %in% c(20, 23)]),
  othimp_m2   = sum(m2[cls %in% c(22, 25, 31)]),
  tc_imp_m2   = sum(m2[cls %in% c(23, 24, 25)]),
  turf_m2     = sum(m2[cls %in% c(26, 27)]),
  bare_m2     = sum(m2[cls %in% c(15, 28, 30, 36, 42)]),
  suspsucc_m2 = sum(m2[cls %in% c(36, 37, 38)]),
  natsucc_m2  = sum(m2[cls %in% c(42, 43, 44)]),
  water_m2    = sum(m2[cls %in% 10:14])), by = .(gid, year)]
pct <- function(a, b) fifelse(b > 0, round(100 * a / b, 1), NA_real_)
wide <- dcast(W, gid ~ year, value.var = setdiff(names(W), c("gid", "year")))
E <- data.table(gid = G$gid, geo_id = G$geo_id, area_m2 = G$area_m2)[wide, on = "gid"]
E[, `:=`(
  lc_coverage_pct      = pct(covered_m2_y2021, area_m2),
  canopy_pct_2013      = pct(canopy_m2_y2013, covered_m2_y2013),
  canopy_pct_2018      = pct(canopy_m2_y2018, covered_m2_y2018),
  canopy_pct_2021      = pct(canopy_m2_y2021, covered_m2_y2021),
  canopy_m2_2021       = round(canopy_m2_y2021, 1),
  canopy_over_imperv_pct_2021 = pct(tc_imp_m2_y2021, covered_m2_y2021),
  imperv_pct_2013      = pct(imperv_m2_y2013, covered_m2_y2013),
  imperv_pct_2021      = pct(imperv_m2_y2021, covered_m2_y2021),
  imperv_m2_2021       = round(imperv_m2_y2021, 1),
  structures_pct_2021  = pct(struct_m2_y2021, covered_m2_y2021),
  roads_pct_2021       = pct(road_m2_y2021, covered_m2_y2021),
  other_imperv_pct_2021 = pct(othimp_m2_y2021, covered_m2_y2021),
  turf_pct_2021        = pct(turf_m2_y2021, covered_m2_y2021),
  bare_pct_2021        = pct(bare_m2_y2021, covered_m2_y2021),
  susp_succession_pct_2021 = pct(suspsucc_m2_y2021, covered_m2_y2021),
  nat_succession_pct_2021  = pct(natsucc_m2_y2021, covered_m2_y2021),
  water_pct_2021       = pct(water_m2_y2021, covered_m2_y2021))]
E[, canopy_change_pp_2013_2021 := round(canopy_pct_2021 - canopy_pct_2013, 1)]
E[, imperv_change_pp_2013_2021 := round(imperv_pct_2021 - imperv_pct_2013, 1)]
E[, imperv_sqft_2021 := round(imperv_m2_2021 * 10.7639)]
E[, eru_est_2021 := round(imperv_sqft_2021 / 1050)]   # 1 ERU = 1,050 sq ft (City Code Art. 27); estimate, not DPW billing
E[, lc_certainty := fcase(is.na(lc_coverage_pct) | lc_coverage_pct < 90, "low",
                          area_m2 < 150, "low", area_m2 < 400, "medium", default = "high")]
E <- E[, !grepl("_y20", names(E)), with = FALSE]
say("land cover done: ", nrow(E), " geometries; median canopy 2021 = ", median(E$canopy_pct_2021, na.rm = TRUE), "%")

# ---- vector layers ---------------------------------------------------------------------------------------------------
rdv <- function(s) st_transform(st_read(man[[s]]$raw_file, quiet = TRUE), CRS_M)
Gm <- G[, "gid"]
# planar st_is_within_distance is unindexed (all pairs); buffering the features and using indexed st_intersects is equivalent
wdist <- function(g, pts, d) lengths(st_intersects(g, st_buffer(st_geometry(pts), d, nQuadSegs = 8)))
near <- function(pts, maxd) {  # distance from each geometry to nearest feature; count within maxd
  nf <- st_nearest_feature(Gm, pts)
  list(d = round(as.numeric(st_distance(Gm, pts[nf, ], by_element = TRUE)), 1),
       n = if (maxd > 0) wdist(Gm, pts, maxd) else NA_integer_)
}
EV <- list()  # evidence rows for point/line records on a parcel
qurl <- function(s, oid) paste0(man[[s]]$service_url, "/query?where=", man[[s]]$oid_field, "%3D", oid, "&outFields=*&f=html")

# inlets
I <- rdv("SW_INLET"); I <- I[!st_is_empty(I), ]
on <- st_intersects(Gm, I)
nn <- near(I, 15)
E[, `:=`(inlet_dist_m = nn$d, inlets_within_15m = nn$n, inlets_on_parcel = lengths(on),
         private_inlets_on_parcel = sapply(on, function(k) sum(I$AGENCY[k] %in% "PRV")))]
h <- data.table(gid = rep(seq_along(on), lengths(on)), k = unlist(on))
if (nrow(h)) EV$SW_INLET <- h[, .(gid, source_id = "SW_INLET", source_record_id = as.character(I$OBJECTID[k]),
  field = "inlet_on_parcel", value = paste0("FacilityID ", I$FacilityID[k], "; type ", I$TYPE[k], "; agency ", I$AGENCY[k]),
  record_date = as.character(as.Date(as.POSIXct(as.numeric(I$INSTALL_DATE[k]) / 1000, origin = "1970-01-01"))),
  match_method = "spatial", record_url = qurl("SW_INLET", I$OBJECTID[k]))]
say("inlets: ", nrow(I), "; parcels with an inlet on them: ", sum(E$inlets_on_parcel > 0))

# storm pipes
D <- rdv("SW_DRAIN"); D <- D[!st_is_empty(D), ]
hit <- st_intersects(Gm, D); h <- data.table(gid = rep(seq_along(hit), lengths(hit)), k = unlist(hit))
E[, pipe_m_on_parcel := 0]
if (nrow(h)) {
  ix <- suppressWarnings(st_intersection(Gm[unique(h$gid), ], st_geometry(D)[unique(h$k)]))  # only intersecting pairs
  pm <- data.table(gid = ix$gid, m = as.numeric(st_length(ix)))[, .(m = sum(m)), by = gid]
  E[pm, pipe_m_on_parcel := round(i.m, 1), on = "gid"]
}
nn <- near(D, 0); E[, pipe_dist_m := nn$d]
say("storm pipes: ", nrow(D), "; parcels crossed by a pipe: ", sum(E$pipe_m_on_parcel > 0))

# stormwater restoration projects (DPW MS4 planning layer)
S <- rdv("SW_PROJECTS"); S <- S[!st_is_empty(S), ]
w <- st_intersects(Gm, st_buffer(S, 30)); h <- data.table(gid = rep(seq_along(w), lengths(w)), k = unlist(w))
h[, `:=`(status = S$status[k], type = S$bmp_type[k],
         on = mapply(function(g, k) lengths(st_intersects(st_geometry(Gm)[g], st_geometry(S)[k])) > 0, gid, k))]
sumtxt <- function(st, ty) paste(sort(paste0(ty, " (", st, ")")), collapse = "; ")
E[, `:=`(sw_projects_on_parcel = 0L, sw_projects_within_30m = 0L, sw_project_detail = "")]
if (nrow(h)) {
  E[h[, .(n = .N, non = sum(on), d = sumtxt(status, type)), by = gid],
    `:=`(sw_projects_within_30m = i.n, sw_projects_on_parcel = i.non, sw_project_detail = i.d), on = "gid"]
  EV$SW_PROJECTS <- h[, .(gid, source_id = "SW_PROJECTS", source_record_id = as.character(S$objectid[k]),
    field = fifelse(on, "sw_project_on_parcel", "sw_project_within_30m"),
    value = paste0(S$plan_id_ms42021_1[k], ": ", type, " (", status, ")"), record_date = NA_character_,
    match_method = "spatial", record_url = qurl("SW_PROJECTS", S$objectid[k]))]
}
say("stormwater projects: ", nrow(S), "; parcels with one within 30 m: ", sum(E$sw_projects_within_30m > 0))

# public trees
Tr <- rdv("TREES"); Tr <- Tr[!st_is_empty(Tr), ]
on <- st_intersects(Gm, Tr)
E[, `:=`(public_trees_on_parcel = lengths(on), public_trees_within_10m = wdist(Gm, Tr, 10))]
say("public trees: ", nrow(Tr), "; parcels with an inventoried tree on them: ", sum(E$public_trees_on_parcel > 0))

# ---- expand to blocklot, write ---------------------------------------------------------------------------------------
X <- merge(as.data.table(st_drop_geometry(P))[, .(blocklot, geo_id, stacked_condo)], E[, !c("gid"), with = FALSE], by = "geo_id")
X[stacked_condo == TRUE, lc_certainty := "low"]   # metric describes the whole shared building footprint
X[, env_summary := sprintf("Canopy %s%% (2021), %s%% (2013); impervious %s%% ~%s ERU; nearest inlet %s m%s%s",
  canopy_pct_2021, canopy_pct_2013, imperv_pct_2021, eru_est_2021, inlet_dist_m,
  fifelse(private_inlets_on_parcel > 0, sprintf("; %d private inlet(s) on parcel", private_inlets_on_parcel), ""),
  fifelse(sw_project_detail != "", paste0("; SW project nearby: ", sw_project_detail), ""))]
setcolorder(X, c("blocklot", "geo_id", "stacked_condo", "area_m2", "lc_certainty"))
fwrite(X[order(blocklot)], file.path(OUT, if (is.na(NTEST)) "parcel_env.csv" else "parcel_env_test.csv"))
if (is.na(NTEST)) {
  gp <- merge(P[, "blocklot"], X[, .(blocklot, canopy_pct_2021, canopy_change_pp_2013_2021, imperv_pct_2021, eru_est_2021,
                                     susp_succession_pct_2021, inlet_dist_m, private_inlets_on_parcel, sw_projects_within_30m, lc_certainty)], by = "blocklot")
  f <- file.path(OUT, "parcel_env.gpkg"); if (file.exists(f)) file.remove(f); st_write(gp, f, quiet = TRUE)
}

# evidence: one land-cover row per parcel per year used, plus every point/line record matched to a parcel
lcev <- rbindlist(lapply(c("2013", "2021"), function(y) X[, .(blocklot, source_id = paste0("LULC_", y),
  source_record_id = paste0(basename(man[[paste0("LULC_", y)]]$raw_file), " pixels in parcel"),
  field = "land_cover_summary",
  value = if (y == "2021") sprintf("canopy %s%%; impervious %s%% (structures %s, roads %s, other %s); turf %s%%; suspended succession %s%%; coverage %s%%",
            canopy_pct_2021, imperv_pct_2021, structures_pct_2021, roads_pct_2021, other_imperv_pct_2021, turf_pct_2021, susp_succession_pct_2021, lc_coverage_pct)
          else sprintf("canopy %s%%; impervious %s%%", canopy_pct_2013, imperv_pct_2013),
  record_date = if (y == "2021") "2021/22 imagery" else "2013/14 imagery",
  match_method = "spatial_exact_pixel_fraction", record_url = man[[paste0("LULC_", y)]]$portal_url)]))
g2b <- X[, .(blocklot, geo_id)]; gid2geo <- data.table(gid = G$gid, geo_id = G$geo_id)
pev <- rbindlist(EV)[gid2geo, on = "gid", nomatch = 0][g2b, on = "geo_id", allow.cartesian = TRUE, nomatch = 0][, !c("gid", "geo_id")]
ev <- rbind(lcev, pev, fill = TRUE)
if (is.na(NTEST)) fwrite(ev[order(blocklot, source_id)], file.path(OUT, "env_evidence.csv"))

src <- rbindlist(lapply(names(man), function(s) data.table(source_id = s, name = man[[s]]$name %||% "", service_url = man[[s]]$service_url,
  portal_url = man[[s]]$portal_url, downloaded_at = man[[s]]$downloaded_at, layer_last_edit = man[[s]]$layer_last_edit %||% NA,
  n_records = man[[s]]$n_downloaded %||% NA, server_count = man[[s]]$server_count %||% NA, raw_file = man[[s]]$raw_file,
  sha256 = man[[s]]$sha256, role = man[[s]]$role %||% "")), fill = TRUE)
if (is.na(NTEST)) fwrite(src, file.path(OUT, "env_sources.csv"))
aud <- rbindlist(lapply(c("SW_INLET", "SW_PROJECTS"), function(s) { e <- rbindlist(EV)[source_id == s]
  data.table(source_id = s, records_downloaded = man[[s]]$n_downloaded, records_on_or_near_a_parcel = uniqueN(e$source_record_id),
             parcel_record_pairs = nrow(e)) }))
aud <- rbind(aud, data.table(source_id = c("TREES", "SW_DRAIN"), records_downloaded = c(nrow(Tr), nrow(D)),
  records_on_or_near_a_parcel = c(length(unique(unlist(st_intersects(Gm, Tr)))), length(unique(unlist(hit)))), parcel_record_pairs = NA))
if (is.na(NTEST)) fwrite(aud, file.path(OUT, "env_match_audit.csv"))
say("wrote ", nrow(X), " parcel rows, ", nrow(ev), " evidence rows")
