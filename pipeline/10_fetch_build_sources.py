"""Fetch build snapshots WITH geometry (GeoJSON, EPSG:4326) for every source used in the index.
Usage: python3 -I scripts/10_fetch_build_sources.py data/raw [SID ...]
Pages are cached in data/raw/pages/<SID>/ so an interrupted run resumes; when all pages are present they are merged
into data/raw/<SID>_<YYYYMMDD>.geojson and recorded (count, layer edit date, sha256) in data/raw/manifest.json."""
import json, sys, time, hashlib, urllib.parse, subprocess, datetime, pathlib

O = "https://services1.arcgis.com/UWYHeuuJISiGmgXx/arcgis/rest/services"
G = "https://services8.arcgis.com/ksfQpKmeklI0YH5h/arcgis/rest/services"
D = "https://baltegis.baltimorecity.gov/mapping/rest/services/Housing/DHCD_Open_Baltimore_Datasets/FeatureServer"
B = "https://services1.arcgis.com/mVFRs7NF4iFitgbY/arcgis/rest/services"
PF = ("OBJECTID,PIN,PINRELATE,BLOCKLOT,BLOCK,LOT,NO_IMPRV,VACIND,RESPAGCY,OWNER_ABBR,OWNER_1,OWNER_2,OWNER_3,FULLADDR,"
      "UNIT_NUM,USEGROUP,ZONECODE,EXMPCODE,DHCDUSE1,CURRIMPR,YEAR_BUILD,STRUCTAREA,DWELUNIT,LDATE,SDATLINK,BLOCKPLAT,"
      "PROPDESC,NEIGHBOR,Shape__Area")
SOURCES = {  # source_id: (url, outFields, portal page)
    "PARCEL_OB":    ("https://baltegis.baltimorecity.gov/mapping/rest/services/CityView/RealProperty_OB/FeatureServer/0", PF, "https://data.baltimorecity.gov/datasets/baltimore::real-property-information"),
    "VBN_OPEN":     (f"{D}/1", "*", "https://data.baltimorecity.gov/datasets/baltimore::vacant-building-notices"),
    "VACANT_LOTS":  (f"{O}/Vacant_Lots/FeatureServer/0", "*", "https://data.baltimorecity.gov (Vacant_Lots)"),
    "MCC_LOTS":     (f"{O}/MCC_Vacant_Lots_20251016/FeatureServer/0", "*", "https://data.baltimorecity.gov (MCC_Vacant_Lots_20251016)"),
    "PRIV_LOTS":    (f"{O}/Private_Vacant_Lots_20251016/FeatureServer/0", "*", "https://data.baltimorecity.gov (Private_Vacant_Lots_20251016)"),
    "RECPARK":      (f"{O}/RecParkOwnedParcels/FeatureServer/0", "*", "https://data.baltimorecity.gov (RecParkOwnedParcels)"),
    "DEMO":         (f"{D}/0", "*", "https://data.baltimorecity.gov (DHCD demolitions)"),
    "REHAB":        (f"{D}/2", "*", "https://data.baltimorecity.gov (DHCD rehabs)"),
    "RECEIV_OPEN":  (f"{D}/4", "*", "https://data.baltimorecity.gov (receivership open)"),
    "RECEIV_SETTLED":(f"{D}/5", "*", "https://data.baltimorecity.gov (receivership settled)"),
    "ADOPT_LOT":    (f"{D}/6", "*", "https://data.baltimorecity.gov (Adopt-a-Lot)"),
    "V2V_BID":      (f"{D}/7", "*", "https://data.baltimorecity.gov (Vacants to Value bid)"),
    "FORECLOSURE":  (f"{D}/11", "*", "https://data.baltimorecity.gov (foreclosure filings)"),
    "TAX_SALE":     (f"{O}/Tax_Sale/FeatureServer/0", "*", "https://data.baltimorecity.gov (Tax_Sale)"),
    "BGS_PRESERVED":(f"{G}/Preserved_Sites/FeatureServer/0", "*", "https://baltimoregreenspace.org"),
    "BGS_LOTS_2023":(f"{G}/bgs2023lots_poly2/FeatureServer/0", "*", "https://baltimoregreenspace.org"),
    "BGS_FOREST":   (f"{G}/Preserved_Symbology/FeatureServer/7", "*", "https://baltimoregreenspace.org"),
    "BGS_FOREST_PTS":(f"{G}/Forest_Site_Points_2026/FeatureServer/0", "*", "https://baltimoregreenspace.org"),
    "UA_SITES":     ("https://services1.arcgis.com/diQbEFavWah0WAHd/arcgis/rest/services/Baltimore_UA_Master-site-list/FeatureServer/0", "*", "UMBC urban agriculture site list"),
    "BNIA_VBN_TRACT_2024": (f"{B}/2024%20Percent%20of%20Residential%20Properties%20that%20are%20Vacant%20and%20Abandoned/FeatureServer/0", "*", "https://bniajfi.org"),
    "BNIA_USPS_NOMAIL_2025": (f"{B}/usps_vac_122025_tractsum_2kx/FeatureServer/0", "*", "https://bniajfi.org"),
}

def get(url, params, tries=8, raw=False):
    q = url + "?" + urllib.parse.urlencode(params)
    for i in range(tries):
        try:
            r = subprocess.run(["curl", "-s", "-f", "--http1.1", "-m", "300", q], capture_output=True, check=True)
            d = json.loads(r.stdout)
            if "error" in d: raise RuntimeError(d["error"])
            return d
        except Exception as e:
            if i == tries - 1: raise
            time.sleep(10 * (i + 1))

out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
only = set(sys.argv[2:]); mpath = out / "manifest.json"
manifest = json.loads(mpath.read_text()) if mpath.exists() else {}
today = datetime.date.today().strftime("%Y%m%d")
for sid, (url, fields, portal) in SOURCES.items():
    if only and sid not in only: continue
    try:
        meta = get(url, {"f": "json"})
        oid = next(f["name"] for f in meta["fields"] if f["type"] == "esriFieldTypeOID")
        n = get(url + "/query", {"where": "1=1", "returnCountOnly": "true", "f": "json"})["count"]
        page = min(meta.get("maxRecordCount", 1000) or 1000, 2000)
        pdir = out / "pages" / sid; pdir.mkdir(parents=True, exist_ok=True)
        feats, off = [], 0
        while off < n:
            pf = pdir / f"{off:07d}.json"
            if pf.exists(): d = json.loads(pf.read_text())
            else:
                d = get(url + "/query", {"where": "1=1", "outFields": fields, "returnGeometry": "true", "outSR": 4326,
                                         "geometryPrecision": 7, "orderByFields": oid, "resultOffset": off,
                                         "resultRecordCount": page, "f": "geojson"})
                if not d.get("features"): break
                pf.write_text(json.dumps(d))
            feats += d["features"]; off += len(d["features"])
        t = (meta.get("editingInfo") or {}).get("lastEditDate")
        fc = {"type": "FeatureCollection", "features": feats}
        p = out / f"{sid}_{today}.geojson"; p.write_text(json.dumps(fc))
        manifest[sid] = {"service_url": url, "portal_url": portal, "name": meta.get("name"), "server_count": n,
                         "n_downloaded": len(feats), "oid_field": oid, "native_wkid": (meta.get("extent") or {}).get("spatialReference", {}).get("latestWkid"),
                         "layer_last_edit": datetime.datetime.utcfromtimestamp(t/1000).isoformat() if t else None,
                         "downloaded_at": datetime.datetime.utcnow().isoformat() + "Z", "raw_file": str(p),
                         "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
        print(f"{sid}: {len(feats)}/{n}", flush=True)
    except Exception as e:
        print(f"{sid}: FAILED {e}", flush=True); manifest.setdefault(sid, {})["error"] = str(e)
    mpath.write_text(json.dumps(manifest, indent=1))
