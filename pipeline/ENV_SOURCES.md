# Canopy & stormwater sources — feasibility recon (2026-11-23)

Count-only/metadata queries; nothing downloaded yet. Companion to AUDIT_FINDINGS.md.

## Canopy / impervious (parcel-level: YES)
**Chesapeake Bay LULC Database 2024 Edition** (USGS/Chesapeake Conservancy, doi:10.5066/P14BEBRC), 1 m rasters,
Baltimore City item https://www.sciencebase.gov/catalog/item/68011bd8d4be0263cab0ff37
- `balt_24510_lulc_2013_2024-Edition.tif`, `_2018_`, `_2021_` — 36.9 MB each (imagery years 2013/14, 2017/18, 2021/22)
- change rasters 2013-2018 / 2013-2021 / 2018-2021 (7.5–12.1 MB) at item 68011c83d4be0263cab101c8
- Classes: 20 Roads, 21 Structures, 22 Other Impervious, 23/24/25 Tree Canopy over Roads/Structures/Other Impervious,
  26 Tree Canopy over Turf, 27 Turf, 28 Bare Developed, 40/41 Forest, wetlands, water…
- Download links (sciencebase.usgs.gov/manager/download/…) are a JavaScript app — curl gets HTML. Need a browser
  download (or Chrome automation), then save under data/raw/.
- Older/other: cicgis.org Baltimore/Tree_Canopy MapServer (2015 raster, view only); city TreeCanopyChange_2007_2015 tiles (view only).

## Street / park trees (point inventory: YES, public trees only)
- baltegis Forestry/TreeInventory_Public/FeatureServer/0 — 193,009 trees (species, DBH, height, address, space type)
- services1 MasterInventory2026_view — 31,856 (newer forestry inventory subset; not yet compared)
- Covers street and park trees only, not private yards. The raster is the canopy measure; these are supporting evidence.

## Stormwater infrastructure (public, current)
dpwgis.baltimorecity.gov/ags102/rest/services:
- Storm/storminlet/MapServer/0 — 55,166 inlets (AGENCY DPW/PRV/UNK, TYPE, INSTALL_DATE in 34,899)
- Storm/stormdrain/MapServer/0 — 105,690 pipe segments (material, size, install date, COMBINED flag; edited Aug 2026)
- OAM/Outfall_Locations/MapServer/0 — 2,412 outfalls (inspection attributes)
- OAM/MS4_Table_OEC_FS/MapServer/0 — 674 facility outfalls
- OAM/Age_Of_Pipes_Storm_Water — token required (not public)
dpwdata.baltimorecity.gov/pubgis/rest/services/Hosted/Stormwater_Project_Planning/FeatureServer/0 — 1,263 MS4 restoration
  project points (bmp_type, status: Completed 28, Planned 151, Potential 201, rest rejected/infeasible)

## Gaps
- **Existing BMPs / on-site stormwater management:** MDE StormwaterPrint (statewide BMP inventory) services on
  mdewin64.mde.state.md.us are stopped ("could not find service"). No public city BMP layer found. Would need an MDE/DPW
  data request (the MS4 geodatabase is a permit deliverable) or a Public Information Act request.
- **Per-parcel impervious area used for the stormwater fee:** only via the DPW Stormwater Fee Finder (one address at a
  time); no bulk layer. Recompute it from the LULC raster instead (ERU = 1,050 sq ft impervious).
- Inlets and pipes sit mostly in the right-of-way, so "drainage" per parcel can only be measured by proximity or frontage,
  not by service connection. There is no lot-to-inlet drainage-area layer.

## Build (done 2026-11-23)
- `scripts/50_fetch_env_sources.py data/raw_env` downloads the rasters from ScienceBase's public S3 links (no browser
  needed: the item JSON's `publishedS3Uri`) and pages the vector layers by OBJECTID chunks. Writes `data/raw_env/manifest.json`.
- `scripts/51_env_metrics.R` works from the parcel geometry frozen as `data/raw_env/PARCEL_GEOM_20261123.gpkg`, a
  copy of `output/parcel_index.gpkg`. It computes everything once per unique geometry (`geo_id`, so each stack of
  condo polygons is done once). Land-cover pixel shares are exact fractions from `exactextractr`. `terra` exact
  extraction took more than 9 minutes per 5k parcels, versus 8 s with `exactextractr`. The full run takes about 4 minutes.
  - Avoid `st_is_within_distance` here: it compares every pair with no spatial index. Use buffered features with `st_intersects`.
- Outputs, all under `output/env/` (none of the vacancy build's files are touched):
  - `parcel_env.csv`/`.gpkg`: one row per blocklot.
  - `env_evidence.csv`: 591k receipt rows (land-cover summary per parcel for 2013 and 2021, each inlet on a parcel, each
    stormwater project on or within 30 m).
  - `env_sources.csv` and `env_match_audit.csv`.
- Canopy classes are 23–26, 40, 41 and the forested wetlands. Impervious is 20–25 and 31, counting impervious surface
  under canopy, as the fee does. `eru_est_2021` = impervious sq ft / 1,050, which is an estimate and not DPW's billed figure.
- `lc_certainty`:
  - low: lot under 150 m², raster coverage under 90 %, or a stacked condo (the value describes the shared footprint);
  - medium: 150–400 m²;
  - high: everything else.
- Still to do: append `env_sources.csv` and `env_evidence.csv` to the shared receipts, and join `parcel_env.csv` into
  `parcel_index`. Do this only after the vacancy build stops writing those files.
