"""Owner-class lookup (public / quasi-public / conservation) and green-space key audit.
Usage: python3 -I scripts/02_owner_greenspace_audit.py data/audit_raw output/audit
Writes output/audit/owner_class_counts.csv, owner_class_rules.csv, greenspace_match.csv."""
import json, sys, re, csv, collections, pathlib

R, OUT = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]); OUT.mkdir(parents=True, exist_ok=True)
L = lambda s: json.loads((R / f"{s}.json").read_text())
key = lambda v: re.sub(r"\W", "", str(v or "")).upper()
def pad(block, lot):
    b, l = key(block), key(lot)
    mb, ml = re.match(r"^(\d+)([A-Z]?)$", b), re.match(r"^(\d+)([A-Z]?)$", l)
    return f"{int(mb[1]):04d}{mb[2]}{int(ml[1]):03d}{ml[2]}" if mb and ml else None

P = {}
for r in L("PARCEL"): P.setdefault(key(r["BLOCKLOT"]), r)
full = {key(a["BLOCKLOT"]): re.sub(r"\s+", " ", f"{a['OWNER_1']} {a['OWNER_2'] or ''} {a['OWNER_3'] or ''}").strip().upper()
        for a in (f["attributes"] for f in json.loads((R / "PUBLIC_OWNER_NAMES.json").read_text())["features"])}

# Official RESPAGCY domain (CityView/RealProperty_OB field domain, read 2026-11-23)
RESP = {"01": "Unassigned", "02": "BC Hospital", "03": "DGS", "04": "Docks and Wharves", "05": "Education",
        "06": "Libraries", "07": "Fire Department", "08": "Mayoralty", "10": "Health", "11": "Highways",
        "12": "Jail", "13": "M & CS", "14": "Mec / Elec", "15": "Museums", "18": "Rec & Parks", "19": "Sanitation",
        "20": "Sewers", "21": "Supervisor of Elections", "22": "Post Mortem Examiners", "23": "Water Supply",
        "24": "Police", "25": "Central Garage", "26": "BCC", "27": "Urban Services", "28": "War Memorial Commission",
        "29": "Aquarium", "30": "Office of the Comptroller", "31": "Excess Street Opening", "32": "Unallocated",
        "33": "Off Street Parking", "34": "NPA/HCD", "35": "Social Services", "36": "Civic and Convention Centers",
        "37": "Transit & Traffic", "38": "Finance", "39": "Commission for Aging", "43": "BDC"}
CITY_GROUP = {"11": "CITY_TRANSPORTATION", "31": "CITY_TRANSPORTATION", "37": "CITY_TRANSPORTATION",
              "18": "CITY_PARKS",
              "34": "CITY_LANDBANK", "30": "CITY_LANDBANK", "32": "CITY_LANDBANK", "01": "CITY_LANDBANK", "": "CITY_LANDBANK",
              "20": "CITY_UTILITY", "23": "CITY_UTILITY", "19": "CITY_UTILITY"}

# Curated owner-name rules, applied in order to OWNER_1+2+3 (anchored phrases, never bare keywords)
RULES = [
    ("CONSERVATION_TRUST",      r"BALTIMORE GREEN SPACE"),
    ("STATE_TRANSPORTATION",    r"MASS TRANSIT ADMIN|MARYLAND TRANSIT ADMIN|METROPOLITAN TRANSIT AUTH|STATE HIGHWAY ADMIN|\(S\.H\.A\.\)|MARYLAND TRANSPORTATION\s*AUTHORITY|MARYLAND PORT ADMIN|STATE OF MARYLAND,? MPA\b|AVIATION ADMIN|DEPT\.? OF TRANSPORTATION"),
    ("STATE_UNIVERSITY",        r"STATE OF M(ARYLAN)?D\b.*(UNIVERSITY|UNIV SYS|BOARD OF REGENTS|MORGAN STATE)"),
    ("STATE_OTHER_NAMED",       r"STATE OF MARYLAND.*(PUBLIC SAFETY|ENVIRONMENT)|MARYLAND STADIUM\s*AUTHORITY"),
    ("STATE_UNNAMED_AGENCY",    r"^STATE OF MARYLAND(,? THE| THE)?$"),
    ("FEDERAL",                 r"^UNITED STATES OF AMERICA|SECRETARY OF HOUSING AND|SECRETARY OF VETERANS|UNITED STATES POSTAL|^UNITED STATES SECRETARY"),
    ("RAILROAD",                r"^CSX TRANSPORTATION|^NATIONAL RAILROAD|^CANTON RAILROAD|^BALTIMORE & ANNAPOLIS RAILROAD"),
    ("UTILITY",                 r"^BALTO\.? GAS|^BALTIMORE GAS (AND|&) ELECTRIC"),
    ("COMMUNITY_LAND_TRUST",    r"CHARM CITY LAND TRUSTS|COMMUNITY LAND TRUST|SOUTH BALTIMORE COMMUNITY LAND"),
    ("HOUSING_AUTHORITY",       r"^HOUSING AUTHORITY"),
]
def owner_class(k, r):
    o1 = re.sub(r"\s+", " ", (r.get("OWNER_1") or "")).strip().upper()
    name = full.get(k, o1)
    if "MAYOR AND CITY COUNCIL" in o1:
        code = str(r.get("RESPAGCY") or "").strip()
        return CITY_GROUP.get(code, "CITY_OTHER_FACILITY"), f"OWNER_1=MCC; RESPAGCY={code or 'blank'} ({RESP.get(code, 'none')})"
    for cls, pat in RULES:
        if re.search(pat, name): return cls, f"owner name matches /{pat[:40]}/"
    if re.search(r"LAND TRUST", name): return "PRIVATE_TITLE_TRUST", "owner name contains LAND TRUST (address/family title-holding trust)"
    return "PRIVATE_OR_OTHER", ""

cls_rows = collections.Counter(); exm = collections.defaultdict(collections.Counter); examples = {}
assign = {}
for k, r in P.items():
    c, why = owner_class(k, r); assign[k] = c; cls_rows[c] += 1
    exm[c][str(r.get("EXMPCODE")).strip()] += 1
    examples.setdefault(c, (k, full.get(k, r.get("OWNER_1", "")).strip(), why))
with open(OUT / "owner_class_counts.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["owner_class", "parcels", "top_EXMPCODEs", "example_blocklot", "example_owner", "rule"])
    for c, n in cls_rows.most_common(): w.writerow([c, n, exm[c].most_common(5), *examples[c]])
with open(OUT / "owner_class_rules.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["owner_class", "pattern_or_rule"])
    w.writerow(["CITY_*", "OWNER_1 contains MAYOR AND CITY COUNCIL; class from RESPAGCY: " + json.dumps(CITY_GROUP)])
    for c, p in RULES: w.writerow([c, p])
    w.writerow(["PRIVATE_TITLE_TRUST", "LAND TRUST in name, not matched above"])
print("OWNER CLASSES")
for c, n in cls_rows.most_common():
    if c != "PRIVATE_OR_OTHER" or True: print(f"  {c:<24}{n:>7}  EXMPCODE {exm[c].most_common(4)}")
# what do unnamed-state parcels look like vs named state agencies' exemption codes?
named = collections.Counter()
for k, c in assign.items():
    if c.startswith("STATE_") and c != "STATE_UNNAMED_AGENCY": named[(str(P[k].get('EXMPCODE')).strip(), c)] += 1
print("  EXMPCODE -> named state class:", sorted(named.items()))

# ---------- green space key audit ----------
print("\nGREEN SPACE")
gl = L("BGS_LOTS_2023")
rows = []
for r in gl:
    raw = r.get("Block_Lot_"); k1 = key(raw); k2 = pad(r.get("BLOCK"), r.get("LOT"))
    hit = k2 in P; c = assign.get(k2)
    rows.append({"site": r.get("Site_Name"), "raw_key": raw, "naive_key": k1, "padded_key": k2, "naive_match": k1 in P,
                 "padded_match": hit, "owner_layer": (r.get("OWNNAME1") or "").strip(), "owner_class_now": c,
                 "management": r.get("Management"), "record_type": r.get("Record_Typ")})
with open(OUT / "greenspace_match.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
print(f"  BGS 2023 sites: {len(rows)}; naive key match {sum(r['naive_match'] for r in rows)}; padded match {sum(r['padded_match'] for r in rows)}")
print("  record type:", collections.Counter(r["record_type"] for r in rows).most_common(5))
print("  management:", collections.Counter(r["management"] for r in rows).most_common(5))
print("  current owner class of matched sites:", collections.Counter(r["owner_class_now"] for r in rows if r["padded_match"]).most_common(8))
bgs_owned_now = {k for k, c in assign.items() if c == "CONSERVATION_TRUST"}
print(f"  parcels BGS owns now: {len(bgs_owned_now)}; of these in 2023 site list: {len(bgs_owned_now & {r['padded_key'] for r in rows})}")
pres = L("BGS_PRESERVED"); print(f"  preserved sites 2026: {len(pres)} (no parcel key; address only: {sum(1 for r in pres if r.get('Street_Add'))}) -> spatial match in build")
print(f"  forest sites: {len(L('BGS_FOREST'))} polygons, {len(L('BGS_FOREST_PTS'))} points (address strings) -> spatial match in build")
ua = L("UA_SITES"); print("  UMBC urban-ag sites:", len(ua), " Land_Tenure:", collections.Counter(r.get("Land_Tenure") for r in ua).most_common(6),
                          " Status:", collections.Counter(r.get("Status") for r in ua).most_common(4))
