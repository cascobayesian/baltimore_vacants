"""Fetch attribute-only (no geometry) snapshots of every candidate source for the key audit.
Writes data/audit_raw/<source_id>.json (list of attribute dicts) and a manifest."""
import json, sys, time, hashlib, urllib.parse, subprocess, datetime, pathlib

O = "https://services1.arcgis.com/UWYHeuuJISiGmgXx/arcgis/rest/services"
G = "https://services8.arcgis.com/ksfQpKmeklI0YH5h/arcgis/rest/services"
D = "https://baltegis.baltimorecity.gov/mapping/rest/services/Housing/DHCD_Open_Baltimore_Datasets/FeatureServer"
PARCEL_F = ("OBJECTID_1,OBJECTID,PIN,PINRELATE,BLOCKLOT,BLOCK,LOT,WARD,SECTION,NO_IMPRV,VACIND,RESPAGCY,"
            "OWNER_ABBR,OWNER_1,FULLADDR,BLDG_NO,UNIT_NUM,USEGROUP,ZONECODE,EXMPCODE,DHCDUSE1,CURRIMPR,EXMPIMPR,"
            "BFCVIMPR,YEAR_BUILD,STRUCTAREA,LDATE,SALEDATE,PROPDESC,SDATLINK,blocklot_c,Blocklot_1,BLOCK_1,LOT_1,"
            "VACANT_IND,LUC,In_Re_1_0,In_Rem_2_0,Blocklot_2,VACANT_I_1,LUC_1,Blocklot_3,Shape__Area")
CAMA_F = ("OBJECTID,PIN,BLOCKLOT,BLOCK,LOT,NO_IMPRV,VACIND,RESPAGCY,OWNER_ABBR,FULLADDR,UNIT_NUM,ACCTID,PTYPE,"
          "CAMADATE,MDPVDATE,CM_CIUSE,CM_DSCIUSE,CM_BLDTOTL,duplicate_blocklot,bldg_footprint,structure_area_missing,Shape__Area")
RP_F = "FID,PIN,BLOCKLOT,BLOCK,LOT,NO_IMPRV,RESPAGCY,OWNER_ABBR,FULLADDR,LDATE,Shape__Area"

SOURCES = {
    "PARCEL":        (f"{O}/Real_Property_Parcel_Map/FeatureServer/0", PARCEL_F),
    "CAMA":          (f"{O}/Real_property_CAMA/FeatureServer/0", CAMA_F),
    "REALPROP_2025": (f"{O}/realprop/FeatureServer/0", RP_F),
    "VBN_OPEN":      (f"{D}/1", "*"),
    "VBN_ALL":       (f"{O}/VBN/FeatureServer/0", "*"),
    "VBN_SEPT16":    (f"{O}/Vacant_Building_Notices_Sept16/FeatureServer/0", "*"),
    "VACANT_LOTS":   (f"{O}/Vacant_Lots/FeatureServer/0", "*"),
    "MCC_LOTS":      (f"{O}/MCC_Vacant_Lots_20251016/FeatureServer/0", "*"),
    "PRIV_LOTS":     (f"{O}/Private_Vacant_Lots_20251016/FeatureServer/0", "*"),
    "RECPARK":       (f"{O}/RecParkOwnedParcels/FeatureServer/0", "*"),
    "CITY_OWNED":    (f"{O}/All_City_Owned_Properties/FeatureServer/0", "*"),
    "DEMO":          (f"{D}/0", "*"),
    "REHAB":         (f"{D}/2", "*"),
    "RECEIV_OPEN":   (f"{D}/4", "*"),
    "RECEIV_SETTLED":(f"{D}/5", "*"),
    "ADOPT_LOT":     (f"{D}/6", "*"),
    "V2V_BID":       (f"{D}/7", "*"),
    "FORECLOSURE":   (f"{D}/11", "*"),
    "TAX_SALE":      (f"{O}/Tax_Sale/FeatureServer/0", "*"),
    # Baltimore Green Space (land trust) — protected / community-managed open space
    "BGS_PRESERVED": (f"{G}/Preserved_Sites/FeatureServer/0", "*"),
    "BGS_LOTS_2023": (f"{G}/bgs2023lots_poly2/FeatureServer/0", "*"),
    "BGS_FOREST":    (f"{G}/Preserved_Symbology/FeatureServer/7", "*"),
    "BGS_FOREST_PTS":(f"{G}/Forest_Site_Points_2026/FeatureServer/0", "*"),
    # UMBC urban agriculture master site list (lat/lon + land tenure)
    # BNIA tract-level benchmarks (external check on parcel-level counts)
    "BNIA_VBN_TRACT_2024": ("https://services1.arcgis.com/mVFRs7NF4iFitgbY/arcgis/rest/services/2024%20Percent%20of%20Residential%20Properties%20that%20are%20Vacant%20and%20Abandoned/FeatureServer/0", "*"),
    "BNIA_USPS_NOMAIL_2025": ("https://services1.arcgis.com/mVFRs7NF4iFitgbY/arcgis/rest/services/usps_vac_122025_tractsum_2kx/FeatureServer/0", "*"),
    "UA_SITES":      ("https://services1.arcgis.com/diQbEFavWah0WAHd/arcgis/rest/services/Baltimore_UA_Master-site-list/FeatureServer/0", "*"),
}

def get(url, params, tries=8):
    q = url + "?" + urllib.parse.urlencode(params)
    for i in range(tries):
        try:
            # curl uses the macOS keychain; this Python build has no CA bundle
            r = subprocess.run(["curl", "-s", "-f", "--http1.1", "-m", "180", q], capture_output=True, check=True)
            d = json.loads(r.stdout)
            if "error" in d: raise RuntimeError(d["error"])
            return d
        except Exception as e:
            if i == tries - 1: raise
            time.sleep(10 * (i + 1))

def fetch(url, fields):
    meta = get(url, {"f": "json"})
    oid = next(f["name"] for f in meta["fields"] if f["type"] == "esriFieldTypeOID")
    n = get(url + "/query", {"where": "1=1", "returnCountOnly": "true", "f": "json"})["count"]
    page = min(meta.get("maxRecordCount", 1000) or 1000, 2000)
    rows, off = [], 0
    while off < n:
        d = get(url + "/query", {"where": "1=1", "outFields": fields, "returnGeometry": "false",
                                 "orderByFields": oid, "resultOffset": off, "resultRecordCount": page, "f": "json"})
        feats = d.get("features", [])
        if not feats: break
        rows += [f["attributes"] for f in feats]; off += len(feats)
    t = (meta.get("editingInfo") or {}).get("lastEditDate")
    return rows, {"service_url": url, "server_count": n, "n_downloaded": len(rows), "oid_field": oid,
                  "wkid": (meta.get("extent") or {}).get("spatialReference", {}).get("wkid"),
                  "layer_last_edit": datetime.datetime.utcfromtimestamp(t/1000).isoformat() if t else None,
                  "fields": [(f["name"], f["type"]) for f in meta["fields"]]}

out = pathlib.Path(sys.argv[1])
only = set(sys.argv[2:])            # optional: re-fetch just these source IDs
mpath = out / "manifest.json"
manifest = json.loads(mpath.read_text()) if (only and mpath.exists()) else {}
for sid, (url, fields) in SOURCES.items():
    if only and sid not in only: continue
    try:
        rows, m = fetch(url, fields)
    except Exception as e:
        print(f"{sid}: FAILED {e}", flush=True); manifest[sid] = {"service_url": url, "error": str(e)}; continue
    p = out / f"{sid}.json"
    p.write_text(json.dumps(rows))
    m["downloaded_at"] = datetime.datetime.utcnow().isoformat() + "Z"
    m["sha256"] = hashlib.sha256(p.read_bytes()).hexdigest()
    manifest[sid] = m
    print(f"{sid}: {m['n_downloaded']}/{m['server_count']}", flush=True)
    mpath.write_text(json.dumps(manifest, indent=1))  # save after each source
