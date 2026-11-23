# 20_build_index.R — parcel-by-parcel vacancy index with receipts.
# Run from the project folder:  Rscript scripts/20_build_index.R
# Inputs : data/raw/<SID>_<date>.geojson + data/raw/manifest.json  (scripts/10_fetch_build_sources.py)
# Outputs: output/parcel_index.csv/.gpkg, evidence.csv, sources.csv, rules.csv, match_audit.csv,
#          unmatched/unmatched_<SID>.csv, geometry_checks.csv, bnia_tract_check.csv, run_log.txt
# Spec   : PROVENANCE.md ; design decisions: AUDIT_FINDINGS.md
suppressPackageStartupMessages({library(sf); library(data.table); library(jsonlite)})
sf_use_s2(FALSE)
RAW <- "data/raw"; OUT <- "output"; dir.create(file.path(OUT, "unmatched"), recursive = TRUE, showWarnings = FALSE)
LOG <- file.path(OUT, "run_log.txt"); cat("", file = LOG)
say <- function(...) { m <- paste0(...); cat(m, "\n"); cat(m, "\n", file = LOG, append = TRUE) }
say("build started ", format(Sys.time(), tz = "UTC"), " UTC")
man <- fromJSON(file.path(RAW, "manifest.json"))
CRS_M <- 26985  # NAD83 / Maryland (metres)
rd <- function(sid) { x <- st_read(man[[sid]]$raw_file, quiet = TRUE); st_transform(x, CRS_M) }

# ---------------- keys ----------------
KEY_RE <- "^([0-9]{4}[A-Z]?|PSC[0-9])([0-9]{3}[A-Z]?)$"
norm <- function(x) { x <- toupper(gsub("[^A-Za-z0-9]", "", ifelse(is.na(x), "", as.character(x))))
  x[x %in% c("", "NONE", "NULL")] <- NA; x }
pad <- function(b, l) { b <- norm(b); l <- norm(l); out <- rep(NA_character_, length(b))
  ok <- !is.na(b) & !is.na(l) & grepl("^[0-9]+[A-Z]?$", b) & grepl("^[0-9]+[A-Z]?$", l)
  out[ok] <- sprintf("%04d%s%03d%s", as.integer(sub("[A-Z]$", "", b[ok])), sub("^[0-9]+", "", b[ok]),
                     as.integer(sub("[A-Z]$", "", l[ok])), sub("^[0-9]+", "", l[ok])); out }
keyify <- function(bl, b = NULL, l = NULL) {
  n <- max(length(bl), length(b)); if (is.null(bl)) bl <- rep(NA_character_, n)
  k <- norm(bl); bad <- is.na(k) | !grepl(KEY_RE, k)
  parts <- strsplit(trimws(ifelse(is.na(bl), "", as.character(bl))), "\\s+"); two <- lengths(parts) == 2
  if (any(bad & two)) { i <- which(bad & two); sp <- pad(sapply(parts[i], `[`, 1), sapply(parts[i], `[`, 2))
    k[i[!is.na(sp)]] <- sp[!is.na(sp)] }
  bad <- is.na(k) | !grepl(KEY_RE, k)
  if (!is.null(b) && any(bad)) { p <- pad(b, l); k[bad & !is.na(p)] <- p[bad & !is.na(p)] }
  k }
todate <- function(x) { if (is.null(x)) return(as.Date(NA)); if (inherits(x, "POSIXt")) return(as.Date(x))
  if (inherits(x, "Date")) return(x); v <- suppressWarnings(as.numeric(x))
  as.Date(as.POSIXct(v / 1000, origin = "1970-01-01", tz = "UTC")) }
qurl <- function(sid, oid) paste0(man[[sid]]$service_url, "/query?where=", man[[sid]]$oid_field, "%3D", oid, "&outFields=*&f=html")

# ---------------- parcels ----------------
P <- rd("PARCEL_OB")
say("PARCEL_OB rows: ", nrow(P), " (server count ", man$PARCEL_OB$server_count, ")")
P$blocklot <- keyify(P$BLOCKLOT, P$BLOCK, P$LOT)
geo <- list()
geo$no_key <- sum(is.na(P$blocklot)); geo$bad_key_shape <- sum(!is.na(P$blocklot) & !grepl(KEY_RE, P$blocklot))
geo$empty_geom <- sum(st_is_empty(P)); geo$invalid_geom <- sum(!st_is_valid(P), na.rm = TRUE)
P <- P[!st_is_empty(P) & !is.na(P$blocklot), ]
P <- st_make_valid(P)
# multipart parcels: several rows per key -> dissolve (check attributes agree first)
d <- as.data.table(st_drop_geometry(P))
dupk <- d[, .N, by = blocklot][N > 1, blocklot]
geo$multirow_keys <- length(dupk); geo$multirow_rows <- d[blocklot %in% dupk, .N]
geo$multirow_keys_attr_disagree <- d[blocklot %in% dupk, uniqueN(paste(OWNER_1, FULLADDR, NO_IMPRV, VACIND)), by = blocklot][V1 > 1, .N]
if (length(dupk)) {
  dd <- P[P$blocklot %in% dupk, ]
  ug <- lapply(split(st_geometry(dd), dd$blocklot), function(g) st_union(g))
  first <- dd[!duplicated(dd$blocklot), ]; st_geometry(first) <- st_sfc(do.call(c, ug[first$blocklot]), crs = CRS_M)
  P <- rbind(P[!P$blocklot %in% dupk, ], first)
}
P$area_m2 <- as.numeric(st_area(P))
geo$slivers_lt5m2 <- sum(P$area_m2 < 5)
# stacked polygons (condominium units drawn as the whole building): same centroid (0.5 m) and area (1 m2)
cc <- suppressWarnings(st_coordinates(st_point_on_surface(st_geometry(P))))
P$geo_id <- paste(round(cc[, 1] * 2), round(cc[, 2] * 2), round(P$area_m2))
pd <- as.data.table(st_drop_geometry(P))
pd[, stack_n := .N, by = geo_id]
geo$stacked_groups <- pd[stack_n > 1, uniqueN(geo_id)]; geo$stacked_rows <- pd[stack_n > 1, .N]
geo$stacked_groups_sharing_PINRELATE <- pd[stack_n > 1, uniqueN(PINRELATE) == 1, by = geo_id][, sum(V1)]
G <- P[!duplicated(P$geo_id), c("geo_id", "area_m2")]
say("parcels after dissolve: ", nrow(P), "; distinct footprints: ", nrow(G))

# city boundary check (Census place, Baltimore city)
bnd <- tryCatch(st_transform(tigris::places("24", cb = TRUE, year = 2023, progress_bar = FALSE), CRS_M), error = function(e) NULL)
if (!is.null(bnd)) { bnd <- bnd[bnd$NAME == "Baltimore", ]
  inside <- lengths(st_intersects(st_point_on_surface(st_geometry(G)), st_buffer(bnd, 50))) > 0
  geo$footprints_outside_city <- sum(!inside) }

# ---------------- owner class ----------------
RESP <- c("01"="Unassigned","02"="BC Hospital","03"="DGS","04"="Docks and Wharves","05"="Education","06"="Libraries",
  "07"="Fire Department","08"="Mayoralty","10"="Health","11"="Highways","12"="Jail","13"="M & CS","14"="Mec / Elec",
  "15"="Museums","18"="Rec & Parks","19"="Sanitation","20"="Sewers","21"="Supervisor of Elections","22"="Post Mortem Examiners",
  "23"="Water Supply","24"="Police","25"="Central Garage","26"="BCC","27"="Urban Services","28"="War Memorial Commission",
  "29"="Aquarium","30"="Office of the Comptroller","31"="Excess Street Opening","32"="Unallocated","33"="Off Street Parking",
  "34"="NPA/HCD","35"="Social Services","36"="Civic and Convention Centers","37"="Transit & Traffic","38"="Finance",
  "39"="Commission for Aging","43"="BDC")
CITY_GROUP <- c("11"="CITY_TRANSPORTATION","31"="CITY_TRANSPORTATION","37"="CITY_TRANSPORTATION","18"="CITY_PARKS",
  "34"="CITY_LANDBANK","30"="CITY_LANDBANK","32"="CITY_LANDBANK","01"="CITY_LANDBANK",
  "20"="CITY_UTILITY","23"="CITY_UTILITY","19"="CITY_UTILITY")
RULES <- list(
  CONSERVATION_TRUST   = "BALTIMORE GREEN SPACE",
  STATE_TRANSPORTATION = "MASS TRANSIT ADMIN|MARYLAND TRANSIT ADMIN|METROPOLITAN TRANSIT AUTH|STATE HIGHWAY ADMIN|\\(S\\.H\\.A\\.\\)|MARYLAND TRANSPORTATION\\s*AUTHORITY|MARYLAND PORT ADMIN|STATE OF MARYLAND,? MPA\\b|AVIATION ADMIN|DEPT\\.? OF TRANSPORTATION",
  STATE_UNIVERSITY     = "STATE OF M(ARYLAN)?D\\b.*(UNIVERSITY|UNIV SYS|BOARD OF REGENTS|MORGAN STATE)",
  STATE_OTHER_NAMED    = "STATE OF MARYLAND.*(PUBLIC SAFETY|ENVIRONMENT)|MARYLAND STADIUM\\s*AUTHORITY",
  STATE_UNNAMED_AGENCY = "^STATE OF MARYLAND(,? THE| THE)?$",
  FEDERAL              = "^UNITED STATES OF AMERICA|SECRETARY OF HOUSING AND|SECRETARY OF VETERANS|UNITED STATES POSTAL|^UNITED STATES SECRETARY",
  RAILROAD             = "^CSX TRANSPORTATION|^NATIONAL RAILROAD|^CANTON RAILROAD|^BALTIMORE & ANNAPOLIS RAILROAD",
  UTILITY              = "^BALTO\\.? GAS|^BALTIMORE GAS (AND|&) ELECTRIC",
  COMMUNITY_LAND_TRUST = "CHARM CITY LAND TRUSTS|COMMUNITY LAND TRUST|SOUTH BALTIMORE COMMUNITY LAND",
  HOUSING_AUTHORITY    = "^HOUSING AUTHORITY")
sq <- function(x) toupper(trimws(gsub("\\s+", " ", ifelse(is.na(x), "", x))))
pd[, owner := trimws(gsub("\\s+", " ", paste(sq(OWNER_1), sq(OWNER_2), sq(OWNER_3))))]
pd[, resp := trimws(ifelse(is.na(RESPAGCY), "", as.character(RESPAGCY)))]
pd[, `:=`(owner_class = NA_character_, owner_rule = NA_character_)]
pd[grepl("MAYOR AND CITY COUNCIL", sq(OWNER_1)), `:=`(
  owner_class = fifelse(resp %in% names(CITY_GROUP), CITY_GROUP[resp], fifelse(resp == "", "CITY_LANDBANK", "CITY_OTHER_FACILITY")),
  owner_rule = paste0("OWNER_1=Mayor and City Council; RESPAGCY=", fifelse(resp == "", "blank", resp), " (", fifelse(resp %in% names(RESP), RESP[resp], "no domain value"), ")"))]
for (cl in names(RULES)) pd[is.na(owner_class) & grepl(RULES[[cl]], owner, perl = TRUE),
                            `:=`(owner_class = cl, owner_rule = paste0("owner name matches /", substr(RULES[[cl]], 1, 50), "/"))]
pd[is.na(owner_class) & grepl("LAND TRUST", owner), `:=`(owner_class = "PRIVATE_TITLE_TRUST", owner_rule = "LAND TRUST in name (title-holding trust)")]
pd[is.na(owner_class), `:=`(owner_class = "PRIVATE_OR_OTHER", owner_rule = "no public/trust pattern matched")]
pd[, exmp := trimws(as.character(EXMPCODE))]
pd[, owner_class_inferred := owner_class]
pd[owner_class == "STATE_UNNAMED_AGENCY" & exmp %in% c("36", "38", "30"), owner_class_inferred := "STATE_TRANSPORTATION_INFERRED"]
pd[owner_class == "STATE_UNNAMED_AGENCY" & exmp %in% c("25", "21"), owner_class_inferred := "STATE_UNIVERSITY_INFERRED"]
say("owner classes: ", paste(capture.output(print(pd[, .N, by = owner_class_inferred][order(-N)])), collapse = "\n"))

# ---------------- evidence ----------------
EV <- list(); AUD <- list()
add_ev <- function(dt) EV[[length(EV) + 1]] <<- dt
# parcel layer's own fields
pk <- pd[, .(blocklot, oid = OBJECTID, ldate = as.Date(sprintf("%08d", suppressWarnings(as.integer(LDATE))), "%m%d%Y"))]
mk <- function(field, value, keep = rep(TRUE, nrow(pd))) pk[keep, .(blocklot, source_id = "PARCEL_OB", source_record_id = as.character(oid),
  field = field, value = value[keep], record_date = ldate, match_method = "self", overlap_pct = NA_real_, record_url = qurl("PARCEL_OB", oid))]
add_ev(mk("owner", paste0(pd$owner, " | RESPAGCY=", pd$resp, " | EXMPCODE=", pd$exmp, " -> ", pd$owner_class_inferred)))
add_ev(mk("NO_IMPRV", paste0("NO_IMPRV=", pd$NO_IMPRV, "; CURRIMPR=", pd$CURRIMPR, "; USEGROUP=", trimws(pd$USEGROUP))))
add_ev(mk("VACIND", rep("VACIND=Y", nrow(pd)), pd$VACIND %in% "Y"))

SPEC <- list(  # bl/b/l = key fields; f = (field label, value fn, date fn); sp = spatial fallback
  VBN_OPEN       = list(bl = "BLOCKLOT", field = "vacant_building_notice", val = function(x) paste0("notice ", x$NoticeNum, " (", x$NT, ")"), dt = function(x) todate(x$DateNotice), sp = "point"),
  VACANT_LOTS    = list(bl = "BLOCKLOT", b = "BLOCK", l = "LOT", field = "vacant_lot_list", val = function(x) "listed", dt = function(x) NA, sp = "best"),
  MCC_LOTS       = list(bl = "BLOCKLOT", b = "BLOCK", l = "LOT", field = "vacant_lot_list_city", val = function(x) paste0("HOUSE_LOT=", x$HOUSE_LOT), dt = function(x) NA, sp = "best"),
  PRIV_LOTS      = list(bl = "BLOCKLOT", b = "BLOCK", l = "LOT", field = "vacant_lot_list_private", val = function(x) paste0("VACANT_IND=", x$VACANT_IND), dt = function(x) NA, sp = "best"),
  RECPARK        = list(bl = "BLOCKLOT", b = "BLOCK", l = "LOT", field = "rec_parks_inventory", val = function(x) paste0(x$agency, ": ", trimws(x$PROPDESC)), dt = function(x) NA, sp = "best"),
  DEMO           = list(bl = "BLOCKLOT", b = "Block", l = "Lot", field = "demolition", val = function(x) x$SimplifiedStatus, dt = function(x) todate(x$DateDemoFinished), sp = "point"),
  REHAB          = list(bl = "BLOCKLOT", b = "Block", l = "Lot", field = "rehab_permit", val = function(x) paste0(x$PermitNum, " ", x$ProposedUse), dt = function(x) todate(x$DateIssue), sp = "point"),
  RECEIV_OPEN    = list(bl = "BLOCKLOT", field = "receivership_open", val = function(x) paste0("case ", x$ID_RS_Web), dt = function(x) todate(x$DateFiled), sp = "point"),
  RECEIV_SETTLED = list(bl = "BLOCKLOT", field = "receivership_settled", val = function(x) paste0("case ", x$ID_RS_Web), dt = function(x) todate(x$Settlement_DateSaleRatified), sp = "point"),
  ADOPT_LOT      = list(bl = "BlockLot", field = "adopt_a_lot", val = function(x) paste0("agency ", x$ResponsibleAgency), dt = function(x) NA, sp = "point"),
  V2V_BID        = list(bl = "BlockLot", b = "Block", l = "Lot", field = "vacants_to_value", val = function(x) x$Status, dt = function(x) NA, sp = "point"),
  FORECLOSURE    = list(bl = "BLOCKLOT", field = "foreclosure_filing", val = function(x) x$Case__, dt = function(x) todate(x$Date), sp = "point"),
  TAX_SALE       = list(b = "block", l = "lot", field = "tax_sale_2023", val = function(x) paste0(x$being_remo, "; ", x$when_sold), dt = function(x) NA, sp = "point"),
  BGS_LOTS_2023  = list(bl = "Block_Lot_", b = "BLOCK", l = "LOT", field = "bgs_community_site_2023", val = function(x) paste0(x$Site_Name, " (", x$Management, ")"), dt = function(x) NA, sp = "best"),
  BGS_PRESERVED  = list(field = "bgs_preserved_site", val = function(x) x$Site__Site, dt = function(x) NA, sp = "cover"),
  BGS_FOREST     = list(field = "bgs_forest_site", val = function(x) x$Name, dt = function(x) NA, sp = "cover"),
  BGS_FOREST_PTS = list(field = "bgs_forest_site_point", val = function(x) x$Name, dt = function(x) NA, sp = "point"),
  UA_SITES       = list(field = "urban_ag_site", val = function(x) paste0(x$Name, " (", x$Category, "; ", x$Status, ")"), dt = function(x) NA, sp = "point"))

Pg <- P[, c("blocklot", "geo_id")]; keyset <- P$blocklot; rawset <- setNames(P$BLOCKLOT, P$blocklot)
geo2keys <- pd[, .(blocklot), by = geo_id]
spatial <- function(x, mode) {   # x: sf with rid; returns rid, geo_id, overlap_pct (of source), parcel_pct
  x <- x[!st_is_empty(x), ]; if (!nrow(x)) return(data.table())
  gt <- unique(as.character(st_geometry_type(x)))
  if (all(gt %in% c("POINT", "MULTIPOINT")) || mode == "point") {
    if (!all(gt %in% c("POINT", "MULTIPOINT"))) x <- suppressWarnings(st_point_on_surface(x))
    j <- st_join(x[, "rid"], G[, "geo_id"], join = st_within)
    j <- as.data.table(st_drop_geometry(j))[!is.na(geo_id)]
    return(j[, .(rid, geo_id, overlap_pct = NA_real_, parcel_pct = NA_real_)]) }
  x <- st_make_valid(x); x$src_area <- as.numeric(st_area(x))
  i <- suppressWarnings(st_intersection(x[, c("rid", "src_area")], G))
  if (!nrow(i)) return(data.table())
  i <- as.data.table(st_drop_geometry(cbind(i, ia = as.numeric(st_area(i)))))
  i[, `:=`(overlap_pct = round(100 * ia / src_area, 1), parcel_pct = round(100 * ia / area_m2, 1))]
  if (mode == "best") i <- i[order(-ia)][, .SD[1], by = rid][overlap_pct >= 50]
  else i <- i[parcel_pct >= 50]
  i[, .(rid, geo_id, overlap_pct, parcel_pct)] }

for (sid in names(SPEC)) {
  s <- SPEC[[sid]]; x <- rd(sid); n <- nrow(x)
  x$rid <- as.character(x[[man[[sid]]$oid_field]])
  bl <- if (!is.null(s$bl)) x[[s$bl]] else NULL
  k <- if (!is.null(s$bl) || !is.null(s$b)) keyify(bl, if (!is.null(s$b)) x[[s$b]], if (!is.null(s$l)) x[[s$l]]) else rep(NA_character_, n)
  hit <- !is.na(k) & k %in% keyset
  exact <- if (is.null(bl)) rep(FALSE, n) else (hit & !is.na(bl) & bl %in% "" == FALSE & bl == rawset[k]) %in% TRUE
  val <- rep_len(as.character(s$val(x)), n); dts <- s$dt(x); if (length(dts) == 1) dts <- rep(as.Date(dts), n)
  # geo-check: keyed match whose own geometry lies > 15 m from that parcel
  far <- rep(NA, n)
  if (any(hit)) { hx <- which(hit & !st_is_empty(x))
    if (length(hx)) { pp <- P[match(k[hx], P$blocklot), ]
      far[hx] <- as.numeric(st_distance(st_geometry(x)[hx], st_geometry(pp), by_element = TRUE)) > 15 } }
  ek <- data.table(blocklot = k[hit], source_id = sid, source_record_id = x$rid[hit], field = s$field,
                   value = paste0(val[hit], fifelse(far[hit] %in% TRUE, " [record geometry >15 m from this parcel]", "")),
                   record_date = as.Date(dts[hit]), match_method = fifelse(exact[hit], "key_exact", "key_normalized"),
                   overlap_pct = NA_real_, record_url = qurl(sid, x$rid[hit]))
  add_ev(ek)
  # spatial fallback for records without a usable key
  um <- which(!hit); sj <- data.table()
  if (length(um) && !is.null(s$sp)) {
    sj <- spatial(x[um, ], s$sp)
    if (nrow(sj)) {
      sj <- merge(sj, geo2keys, by = "geo_id", allow.cartesian = TRUE)
      ii <- match(sj$rid, x$rid)
      add_ev(sj[, .(blocklot, source_id = sid, source_record_id = rid, field = s$field,
        value = paste0(val[ii], fifelse(is.na(parcel_pct), "", paste0(" [covers ", parcel_pct, "% of parcel]"))),
        record_date = as.Date(dts[ii]), match_method = paste0("spatial_", s$sp), overlap_pct, record_url = qurl(sid, rid))])
    } }
  still <- setdiff(x$rid[um], sj$rid)
  if (length(still)) { ui <- match(still, x$rid)
    fwrite(data.table(source_id = sid, source_record_id = still, raw_key = if (!is.null(bl)) as.character(bl[ui]) else NA,
      normalized_key = k[ui], value = val[ui], has_geometry = !st_is_empty(x[ui, ]),
      reason = fifelse(is.na(k[ui]), "no usable key", "key not in current parcel layer"), record_url = qurl(sid, still)),
      file.path(OUT, "unmatched", paste0("unmatched_", sid, ".csv"))) }
  AUD[[sid]] <- data.table(source_id = sid, n_records = n, n_server = man[[sid]]$server_count, key_exact = sum(exact),
    key_normalized = sum(hit & !exact), keyed_geometry_gt15m = sum(far %in% TRUE),
    spatial = uniqueN(sj$rid), unmatched = length(still), match_rate = round(100 * (n - length(still)) / n, 1))
  say(sprintf("%-15s n=%6d exact=%6d norm=%6d spatial=%5d unmatched=%5d far=%4d", sid, n, sum(exact), sum(hit & !exact),
              uniqueN(sj$rid), length(still), sum(far %in% TRUE)))
}
E <- rbindlist(EV, use.names = TRUE)
fwrite(rbindlist(AUD), file.path(OUT, "match_audit.csv"))

# ---------------- flags -> category ----------------
f <- function(fl, pat = NULL) { e <- E[field == fl]; if (!is.null(pat)) e <- e[grepl(pat, value)]; unique(e$blocklot) }
X <- pd[, .(blocklot, geo_id, stack_n, owner_class = owner_class_inferred, owner_rule, resp, NO_IMPRV, VACIND,
            address = trimws(FULLADDR), owner, sdat_url = SDATLINK, blockplat_url = BLOCKPLAT, usegroup = trimws(USEGROUP), area_m2,
            has_impr_value = suppressWarnings(as.numeric(CURRIMPR)) > 0 | suppressWarnings(as.numeric(STRUCTAREA)) > 0)]
vbn <- E[field == "vacant_building_notice", .(vbn_date = max(record_date, na.rm = TRUE)), by = blocklot]
demo <- E[field == "demolition" & value %like% "Complete", .(demo_date = max(record_date, na.rm = TRUE)), by = blocklot]
rehab <- E[field == "rehab_permit", .(rehab_date = max(record_date, na.rm = TRUE)), by = blocklot]
X <- Reduce(function(a, b) merge(a, b, by = "blocklot", all.x = TRUE), list(X, vbn, demo, rehab))
X[, `:=`(
  has_vbn = !is.na(vbn_date) | blocklot %in% f("vacant_building_notice"),
  vac_y = VACIND %in% "Y", unimp = NO_IMPRV %in% "Y",
  lot_list = blocklot %in% c(f("vacant_lot_list"), f("vacant_lot_list_city"), f("vacant_lot_list_private")),
  recpark = blocklot %in% f("rec_parks_inventory"), park_resp = resp == "18",
  bgs_own = owner_class == "CONSERVATION_TRUST", bgs_site = blocklot %in% c(f("bgs_preserved_site"), f("bgs_forest_site"), f("bgs_forest_site_point")),
  community = blocklot %in% c(f("bgs_community_site_2023"), f("urban_ag_site")),
  transport_named = owner_class %in% c("CITY_TRANSPORTATION", "STATE_TRANSPORTATION", "RAILROAD"),
  transport_inf = owner_class == "STATE_TRANSPORTATION_INFERRED")]
X[, demo_after := !is.na(demo_date) & (is.na(vbn_date) | demo_date >= vbn_date)]
X[, rehab_after := !is.na(rehab_date) & !is.na(vbn_date) & rehab_date > vbn_date]
X[, `:=`(category = NA_character_, certainty = NA_character_, rule_id = NA_character_)]
setr <- function(cond, cat, cer, id) X[is.na(category) & eval(cond), `:=`(category = cat, certainty = cer, rule_id = id)]
setr(quote(park_resp & recpark),                       "PARK",                 "high",   "R01")
setr(quote(park_resp | recpark),                       "PARK",                 "medium", "R02")
setr(quote(bgs_own & bgs_site),                        "PROTECTED_GREENSPACE", "high",   "R03")
setr(quote(bgs_own | bgs_site),                        "PROTECTED_GREENSPACE", "medium", "R04")
setr(quote(has_vbn & demo_after),                      "VACANT_LOT",           "medium", "R05")
setr(quote(has_vbn & vac_y & !unimp & !rehab_after),   "VACANT_BUILDING",      "high",   "R06")
setr(quote(has_vbn),                                   "VACANT_BUILDING",      "medium", "R07")
setr(quote(transport_named),                           "TRANSPORTATION",       "high",   "R08")
setr(quote(transport_inf),                             "TRANSPORTATION",       "low",    "R09")
setr(quote(vac_y & !unimp),                            "VACANT_BUILDING",      "low",    "R10")
setr(quote(community),                                 "COMMUNITY_OPEN_SPACE", "medium", "R11")
setr(quote(unimp & lot_list),                          "VACANT_LOT",           "high",   "R12")
setr(quote(lot_list | (unimp & demo_after)),           "VACANT_LOT",           "medium", "R13")
setr(quote(unimp),                                     "VACANT_LOT",           "low",    "R14")
setr(quote(!unimp & has_impr_value %in% TRUE),        "NOT_VACANT",           "medium", "R15")
setr(quote(TRUE),                                      "NOT_VACANT",           "low",    "R16")
RULES_T <- data.table(rule_id = sprintf("R%02d", 1:16),
  category = c("PARK","PARK","PROTECTED_GREENSPACE","PROTECTED_GREENSPACE","VACANT_LOT","VACANT_BUILDING","VACANT_BUILDING",
               "TRANSPORTATION","TRANSPORTATION","VACANT_BUILDING","COMMUNITY_OPEN_SPACE","VACANT_LOT","VACANT_LOT","VACANT_LOT","NOT_VACANT","NOT_VACANT"),
  certainty = c("high","medium","high","medium","medium","high","medium","high","low","low","medium","high","medium","low","medium","low"),
  condition = c("RESPAGCY=18 (Rec & Parks) AND on Rec & Parks parcel inventory",
    "RESPAGCY=18 OR on Rec & Parks inventory (not both)",
    "Owned by Baltimore Green Space AND inside a BGS preserved/forest site",
    "Owned by Baltimore Green Space OR >=50% inside a BGS preserved/forest site polygon (or forest site point)",
    "Open vacant building notice, but a demolition was completed on/after the notice date",
    "Open VBN AND assessor VACIND=Y AND assessor shows improvements AND no rehab permit after the notice",
    "Open VBN, other combinations (see conflict_note)",
    "Owner is city transportation (RESPAGCY 11 Highways, 31 Excess Street Opening, 37 Transit & Traffic), a named state transportation agency, or a railroad",
    "Owner 'State of Maryland' with no agency named; EXMPCODE 30/36/38 matches the codes used by named transportation agencies (inferred)",
    "Assessor VACIND=Y with improvements, but no open VBN",
    "Baltimore Green Space community-managed site (2023 list) or UMBC urban-agriculture site; NOT legally protected",
    "Assessor NO_IMPRV=Y AND on a city vacant-lot list (Vacant_Lots, MCC or Private vacant lots)",
    "On a vacant-lot list but assessor shows improvements, OR unimproved with a completed demolition",
    "Assessor NO_IMPRV=Y only (may be a yard, parking or side lot)",
    "NO_IMPRV not Y AND (CURRIMPR>0 or STRUCTAREA>0), and no vacancy evidence from any source",
    "NO_IMPRV not Y but no improvement value or structure area recorded; no vacancy evidence"),
  precedence = 1:16)
fwrite(RULES_T, file.path(OUT, "rules.csv"))

# conflicts
X[, conflict_note := ""]
addc <- function(cond, msg) X[eval(cond), conflict_note := paste0(conflict_note, fifelse(conflict_note == "", "", "; "), msg)]
addc(quote(category %in% c("PARK", "PROTECTED_GREENSPACE") & lot_list), "on a vacant-lot list")
addc(quote(category %in% c("PARK", "PROTECTED_GREENSPACE", "TRANSPORTATION") & has_vbn), "has an open vacant building notice")
addc(quote(has_vbn & unimp), "open VBN but assessor says no improvements")
addc(quote(has_vbn & demo_after), "demolition completed on/after VBN date")
addc(quote(has_vbn & rehab_after), "rehab permit issued after VBN date")
addc(quote(vac_y & !has_vbn), "assessor VACIND=Y but no open VBN")
addc(quote(has_vbn & lot_list), "open VBN and also on a vacant-lot list")
addc(quote(lot_list & !unimp), "on vacant-lot list but assessor shows improvements")
addc(quote(recpark & !park_resp), "on Rec & Parks inventory but RESPAGCY is not 18")
addc(quote(park_resp & !recpark), "RESPAGCY=18 but not on Rec & Parks inventory")
farb <- unique(E[value %like% "\\[record geometry >15 m", blocklot])
addc(quote(blocklot %in% farb), "a keyed record's own location is >15 m from this parcel")
X[, conflict_flag := conflict_note != ""]
say("conflicts by type:\n", paste(capture.output(print(sort(table(unlist(strsplit(X[conflict_flag == TRUE, conflict_note], "; "))), decreasing = TRUE))), collapse = "\n"))

# evidence summary
setkey(E, blocklot)
ES <- E[, .(n_evidence = .N, evidence_summary = paste(unique(paste0(source_id, ":", field,
  fifelse(field %in% c("owner", "NO_IMPRV"), "", paste0("=", substr(value, 1, 40))),
  fifelse(is.na(record_date), "", paste0("@", record_date)))), collapse = " | ")), by = blocklot]
X <- merge(X, ES, by = "blocklot", all.x = TRUE)
X[, stacked_condo := stack_n > 1]
IDX <- X[, .(blocklot, address, owner, owner_class, category, certainty, rule_id, evidence_summary, n_evidence,
             conflict_flag, conflict_note, stacked_condo, geo_id, area_m2 = round(area_m2, 1), sdat_url, blockplat_url)]
fwrite(IDX, file.path(OUT, "parcel_index.csv"))
fwrite(E[order(blocklot, source_id)], file.path(OUT, "evidence.csv"))
gp <- merge(P[, c("blocklot")], IDX[, .(blocklot, category, certainty, rule_id, conflict_flag, owner_class, stacked_condo, geo_id, address)], by = "blocklot")
if (file.exists(file.path(OUT, "parcel_index.gpkg"))) file.remove(file.path(OUT, "parcel_index.gpkg"))
st_write(gp, file.path(OUT, "parcel_index.gpkg"), quiet = TRUE)

# sources.csv
ROLE <- c(PARCEL_OB = "parcel base; owner, RESPAGCY, NO_IMPRV, VACIND", VBN_OPEN = "open vacant building notices",
  VACANT_LOTS = "city vacant-lot list", MCC_LOTS = "city-owned vacant lots (Oct 2025)", PRIV_LOTS = "privately owned vacant lots (Oct 2025)",
  RECPARK = "Rec & Parks parcel inventory", DEMO = "completed demolitions", REHAB = "rehab permits on VBN properties",
  RECEIV_OPEN = "receivership filings (context)", RECEIV_SETTLED = "receivership settled (context)", ADOPT_LOT = "Adopt-a-Lot (context)",
  V2V_BID = "Vacants to Value bid properties (context)", FORECLOSURE = "foreclosure filings 2015-2020 (context)",
  TAX_SALE = "2023 tax sale list (context)", BGS_LOTS_2023 = "BGS community-managed sites 2023", BGS_PRESERVED = "BGS preserved sites",
  BGS_FOREST = "BGS forest site polygons", BGS_FOREST_PTS = "BGS forest site points", UA_SITES = "UMBC urban agriculture sites",
  BNIA_VBN_TRACT_2024 = "tract benchmark (2010 tracts)", BNIA_USPS_NOMAIL_2025 = "tract benchmark (2020 tracts)")
S <- rbindlist(lapply(names(man), function(s) { m <- man[[s]]; if (is.null(m$raw_file)) return(NULL)
  data.table(source_id = s, name = m$name, service_url = m$service_url, portal_url = m$portal_url, downloaded_at = m$downloaded_at,
             layer_last_edit = if (is.null(m$layer_last_edit)) NA else m$layer_last_edit, n_records = m$n_downloaded,
             server_count = m$server_count, raw_file = m$raw_file, sha256 = m$sha256, role = ROLE[s]) }))
fwrite(S, file.path(OUT, "sources.csv"))

# ---------------- BNIA tract benchmark ----------------
bn <- tryCatch({
  tr <- rd("BNIA_VBN_TRACT_2024"); pts <- st_point_on_surface(merge(P[, "blocklot"], X[has_vbn == TRUE, .(blocklot)], by = "blocklot"))
  j <- as.data.table(st_drop_geometry(st_join(pts, tr[, "GEOID10"])))[, .(parcels_open_vbn = .N), by = GEOID10]
  b <- as.data.table(st_drop_geometry(tr))[, .(GEOID10, allres = as.numeric(allres), bnia_pct = as.numeric(F24percentvbn))]
  b <- merge(b, j, by = "GEOID10", all = TRUE); b[is.na(parcels_open_vbn), parcels_open_vbn := 0]
  b[, `:=`(bnia_implied = round(allres * bnia_pct / 100), index_pct = round(100 * parcels_open_vbn / allres, 2))]
  fwrite(b, file.path(OUT, "bnia_tract_check.csv"))
  say("BNIA 2024 tract check: implied ", sum(b$bnia_implied, na.rm = TRUE), " vs index open-VBN parcels ", sum(b$parcels_open_vbn),
      "; tract correlation ", round(cor(b$bnia_pct, b$index_pct, use = "complete.obs"), 3)); b }, error = function(e) say("BNIA check failed: ", conditionMessage(e)))

fwrite(data.table(check = names(geo), value = unlist(geo)), file.path(OUT, "geometry_checks.csv"))
say("geometry checks:\n", paste(names(geo), unlist(geo), sep = " = ", collapse = "\n"))
say("categories:\n", paste(capture.output(print(X[, .N, by = .(category, certainty)][order(category, certainty)])), collapse = "\n"))
say("conflict-flagged parcels: ", sum(X$conflict_flag))
say("evidence rows: ", nrow(E), "; build finished ", format(Sys.time(), tz = "UTC"))
