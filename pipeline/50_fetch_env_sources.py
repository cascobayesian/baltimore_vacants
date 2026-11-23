"""Fetch canopy / land-cover rasters and stormwater + tree layers for the parcel environment extension.
Usage: python3 -I scripts/50_fetch_env_sources.py data/raw_env [SID ...]
Kept separate from 10_fetch_build_sources.py (own folder, own manifest) so it can run alongside the vacancy build.
Feature layers are paged by OBJECTID chunks (MapServer layers here do not all support resultOffset); pages are cached in
data/raw_env/pages/<SID>/ so an interrupted run resumes. Each layer is merged into <SID>_<YYYYMMDD>.geojson (EPSG:4326)
and recorded (server count, downloaded count, sha256) in data/raw_env/manifest.json."""
import json, sys, time, hashlib, urllib.parse, subprocess, datetime, pathlib

DPW = "https://dpwgis.baltimorecity.gov/ags102/rest/services"
S3 = "https://prod-is-usgs-sb-prod-publish.s3.amazonaws.com"
SB = "https://www.sciencebase.gov/catalog/item"
LULC_ITEM, LULCC_ITEM = "68011bd8d4be0263cab0ff37", "68011c83d4be0263cab101c8"
RASTERS = {  # source_id: (url, portal page, role)
    "LULC_2013": (f"{S3}/{LULC_ITEM}/balt_24510_lulc_2013_2024-Edition.tif", f"{SB}/{LULC_ITEM}", "1 m land cover, 2013/14 imagery"),
    "LULC_2018": (f"{S3}/{LULC_ITEM}/balt_24510_lulc_2018_2024-Edition.tif", f"{SB}/{LULC_ITEM}", "1 m land cover, 2017/18 imagery"),
    "LULC_2021": (f"{S3}/{LULC_ITEM}/balt_24510_lulc_2021_2024-Edition.tif", f"{SB}/{LULC_ITEM}", "1 m land cover, 2021/22 imagery"),
    "LULCC_2013_2021": (f"{S3}/{LULCC_ITEM}/balt_24510_lulc-change_2013-2021_2024-Edition.tif", f"{SB}/{LULCC_ITEM}", "1 m land-cover change 2013-2021"),
    "LULC_META": (f"https://www.sciencebase.gov/catalog/file/get/{LULC_ITEM}?f=__disk__da%2F69%2F48%2Fda6948d0a7598f4892d516e40311bf1d646ae14d", f"{SB}/{LULC_ITEM}", "FGDC metadata incl. class table"),
}
LAYERS = {  # source_id: (layer url, outFields, portal page, role)
    "SW_INLET":   (f"{DPW}/Storm/storminlet/MapServer/0", "OBJECTID,FacilityID,INLET_ID,TYPE,AGENCY,FEAT_STATUS,INSTALL_DATE,SUMP_IND,EDIT_DATE",
                   "https://publicworks.baltimorecity.gov/stormwater", "storm-drain inlets (DPW)"),
    "SW_DRAIN":   (f"{DPW}/Storm/stormdrain/MapServer/0", "OBJECTID,FacilityID,SUBTYPE,COMBINED,PIP_MATERIAL,HEIGHT,WIDTH,PIP_INSTALL_DATE,AGENCY,FEAT_STATUS,last_edited_date",
                   "https://publicworks.baltimorecity.gov/stormwater", "storm-drain pipes (DPW)"),
    "SW_OUTFALL": (f"{DPW}/OAM/Outfall_Locations/MapServer/0", "OBJECTID,OUTFALL_ID,Outfall_Type,Feature_Status,Watershed,Major_Outfall,INSPECTION_DATE",
                   "https://publicworks.baltimorecity.gov/stormwater", "storm outfalls (DPW)"),
    "SW_FAC_OUTFALL": (f"{DPW}/OAM/MS4_Table_OEC_FS/MapServer/0", "*",
                   "https://publicworks.baltimorecity.gov/stormwater", "MS4 facility outfalls (DPW)"),
    "SW_PROJECTS": ("https://dpwdata.baltimorecity.gov/pubgis/rest/services/Hosted/Stormwater_Project_Planning/FeatureServer/0", "*",
                   "https://publicworks.baltimorecity.gov/interactive-maps", "MS4 restoration projects: BMP type and status"),
    "TREES":      ("https://baltegis.baltimorecity.gov/mapping/rest/services/Forestry/TreeInventory_Public/FeatureServer/0",
                   "OBJECTID,ID,COMMON,SPP,GENUS,DBH,TREE_HT,SPACE_TYPE,LOC_TYPE,Address,DATA_ORIGIN",
                   "https://baltimore-city-forestry.hub.arcgis.com", "public tree inventory (Forestry)"),
}

def curl(args, tries=8):
    for i in range(tries):
        try:
            return subprocess.run(["curl", "-s", "-f", "--http1.1", "-m", "600"] + args, capture_output=True, check=True).stdout
        except Exception:
            if i == tries - 1: raise
            time.sleep(10 * (i + 1))

def get(url, params, post=False):
    for i in range(6):
        b = curl(["--data", urllib.parse.urlencode(params), url] if post else [url + "?" + urllib.parse.urlencode(params)])
        d = json.loads(b)
        if "error" not in d: return d
        time.sleep(10 * (i + 1))
    raise RuntimeError(d["error"])

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
now = lambda: datetime.datetime.now(datetime.timezone.utc).isoformat()

out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
only = set(sys.argv[2:]); mpath = out / "manifest.json"
manifest = json.loads(mpath.read_text()) if mpath.exists() else {}
today = datetime.date.today().strftime("%Y%m%d")
def save(): mpath.write_text(json.dumps(manifest, indent=1))

for sid, (url, portal, role) in RASTERS.items():
    if only and sid not in only: continue
    try:
        ext = ".xml" if sid == "LULC_META" else ".tif"
        p = out / f"{sid}{ext}"
        if not p.exists():
            tmp = p.with_suffix(ext + ".part"); curl(["-L", "-o", str(tmp), url]); tmp.rename(p)
        if ext == ".tif" and p.read_bytes()[:2] not in (b"II", b"MM"): raise RuntimeError("not a TIFF")
        manifest[sid] = {"service_url": url, "portal_url": portal, "name": p.name, "role": role, "n_downloaded": 1,
                         "server_count": 1, "bytes": p.stat().st_size, "downloaded_at": now(), "raw_file": str(p), "sha256": sha(p)}
        print(f"{sid}: {p.stat().st_size/1e6:.1f} MB", flush=True)
    except Exception as e:
        print(f"{sid}: FAILED {e}", flush=True); manifest.setdefault(sid, {})["error"] = str(e)
    save()

for sid, (url, fields, portal, role) in LAYERS.items():
    if only and sid not in only: continue
    try:
        meta = get(url, {"f": "json"})
        oid = next(f["name"] for f in meta["fields"] if f["type"] == "esriFieldTypeOID")
        ids = sorted(get(url + "/query", {"where": "1=1", "returnIdsOnly": "true", "f": "json"}, post=True)["objectIds"])
        step = min(meta.get("maxRecordCount", 1000) or 1000, 1000)
        pdir = out / "pages" / sid; pdir.mkdir(parents=True, exist_ok=True)
        feats = []
        for k in range(0, len(ids), step):
            chunk = ids[k:k + step]; pf = pdir / f"{k:07d}.json"
            if pf.exists(): d = json.loads(pf.read_text())
            else:
                d = get(url + "/query", {"objectIds": ",".join(map(str, chunk)), "outFields": fields, "returnGeometry": "true",
                                         "outSR": 4326, "geometryPrecision": 7, "f": "geojson"}, post=True)
                if len(d.get("features", [])) != len(chunk): raise RuntimeError(f"chunk {k}: got {len(d.get('features', []))} of {len(chunk)}")
                pf.write_text(json.dumps(d))
            feats += d["features"]
        p = out / f"{sid}_{today}.geojson"; p.write_text(json.dumps({"type": "FeatureCollection", "features": feats}))
        t = (meta.get("editingInfo") or {}).get("lastEditDate")
        manifest[sid] = {"service_url": url, "portal_url": portal, "name": meta.get("name"), "role": role, "server_count": len(ids),
                         "n_downloaded": len(feats), "oid_field": oid,
                         "layer_last_edit": datetime.datetime.fromtimestamp(t / 1000, datetime.timezone.utc).isoformat() if t else None,
                         "downloaded_at": now(), "raw_file": str(p), "sha256": sha(p)}
        print(f"{sid}: {len(feats)}/{len(ids)}", flush=True)
    except Exception as e:
        print(f"{sid}: FAILED {e}", flush=True); manifest.setdefault(sid, {})["error"] = str(e)
    save()
