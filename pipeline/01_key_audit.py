"""Key / format / consistency audit across all candidate sources.
Usage: python3 -I scripts/01_key_audit.py data/audit_raw output/audit
Reads <source>.json attribute snapshots; writes audit tables and prints a summary."""
import json, sys, re, csv, collections, pathlib, datetime

raw, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
man = json.loads((raw / "manifest.json").read_text())
S = {p.stem: json.loads(p.read_text()) for p in raw.glob("*.json") if p.stem != "manifest"}

KEY_RE = re.compile(r"^(\d{4}[A-Z]?|PSC\d)(\d{3}[A-Z]?)$")  # PSC = railroad/utility blocks

def shape(v):
    if v is None: return "<null>"
    return re.sub(r"[A-Za-z]", "A", re.sub(r"\d", "9", str(v))).replace(" ", "_") or "<empty>"

def norm(v):
    """Canonical key BBBB[X]LLL[Y]: uppercase, strip spaces/punctuation."""
    if v is None: return None
    s = re.sub(r"[^0-9A-Za-z]", "", str(v)).upper()
    return s if KEY_RE.match(s) else (s or None)

def norm_pad(block, lot):
    """Build key from separate block/lot fields, restoring dropped leading zeros."""
    if block is None or lot is None: return None
    b = re.sub(r"[^0-9A-Za-z]", "", str(block)).upper(); l = re.sub(r"[^0-9A-Za-z]", "", str(lot)).upper()
    mb = re.match(r"^(\d+)([A-Z]?)$", b); ml = re.match(r"^(\d+)([A-Z]?)$", l)
    if not (mb and ml): return None
    return f"{int(mb.group(1)):04d}{mb.group(2)}{int(ml.group(1)):03d}{ml.group(2)}"

# key field(s) per source: (blocklot field, block field, lot field)
KEYS = {"PARCEL": ("BLOCKLOT", "BLOCK", "LOT"), "CAMA": ("BLOCKLOT", "BLOCK", "LOT"),
        "REALPROP_2025": ("BLOCKLOT", "BLOCK", "LOT"), "VBN_OPEN": ("BLOCKLOT", None, None),
        "VBN_ALL": ("BLOCKLOT", None, None), "VBN_SEPT16": ("BLOCKLOT", None, None),
        "VACANT_LOTS": ("BLOCKLOT", "BLOCK", "LOT"), "MCC_LOTS": ("BLOCKLOT", "BLOCK", "LOT"),
        "PRIV_LOTS": ("BLOCKLOT", "BLOCK", "LOT"), "RECPARK": ("BLOCKLOT", "BLOCK", "LOT"),
        "CITY_OWNED": ("BLOCKLOT", "BLOCK", "LOT"), "DEMO": ("BLOCKLOT", "Block", "Lot"),
        "REHAB": ("BLOCKLOT", "Block", "Lot"), "RECEIV_OPEN": ("BLOCKLOT", None, None),
        "RECEIV_SETTLED": ("BLOCKLOT", None, None), "ADOPT_LOT": ("BlockLot", None, None),
        "V2V_BID": ("BlockLot", "Block", "Lot"), "FORECLOSURE": ("BLOCKLOT", None, None),
        "TAX_SALE": (None, "block", "lot")}

def key_of(sid, r):
    bl, b, l = KEYS[sid]
    k = norm(r.get(bl)) if bl else None
    if (k is None or not KEY_RE.match(k or "")) and b: k = norm_pad(r.get(b), r.get(l)) or k
    return k

P = S["PARCEL"]; pkeys = collections.Counter(key_of("PARCEL", r) for r in P)
cama_keys = {key_of("CAMA", r) for r in S.get("CAMA", [])}
rp25_keys = {key_of("REALPROP_2025", r) for r in S.get("REALPROP_2025", [])}
raw_pkeys = {r.get("BLOCKLOT") for r in P}

summary, unmatched_rows = [], []
for sid, rows in S.items():
    bl, b, l = KEYS.get(sid, (None, None, None))
    shapes = collections.Counter(shape(r.get(bl)) for r in rows) if bl else collections.Counter()
    keys = [key_of(sid, r) for r in rows]
    valid = [k for k in keys if k and KEY_RE.match(k)]
    dup = sum(c - 1 for c in collections.Counter(valid).values() if c > 1)
    raw_hit = sum(1 for r in rows if bl and r.get(bl) in raw_pkeys)
    hit = sum(1 for k in keys if k in pkeys)
    # internal consistency: BLOCKLOT field vs separate block/lot fields
    incons = 0
    if bl and b:
        incons = sum(1 for r in rows if norm(r.get(bl)) and norm_pad(r.get(b), r.get(l))
                     and norm(r.get(bl)) != norm_pad(r.get(b), r.get(l)))
    um = [(k, r) for k, r in zip(keys, rows) if k not in pkeys]
    um_in_cama = sum(1 for k, _ in um if k in cama_keys); um_in_25 = sum(1 for k, _ in um if k in rp25_keys)
    for k, r in um:
        unmatched_rows.append({"source_id": sid, "key_norm": k, "raw_key": r.get(bl) if bl else f"{r.get(b)}|{r.get(l)}",
                               "in_CAMA": k in cama_keys, "in_REALPROP_2025": k in rp25_keys,
                               "address": r.get("Address") or r.get("FULLADDR") or r.get("address") or r.get("PROPERTY_ADDRESS")})
    summary.append({"source_id": sid, "n": len(rows), "server_count": man.get(sid, {}).get("server_count"),
                    "key_shapes": "; ".join(f"{s}:{c}" for s, c in shapes.most_common(6)),
                    "null_or_bad_key": len(rows) - len(valid), "dup_keys_within": dup,
                    "blocklot_vs_block_lot_mismatch": incons,
                    "match_raw_exact": raw_hit, "match_normalized": hit, "unmatched": len(um),
                    "unmatched_found_in_CAMA": um_in_cama, "unmatched_found_in_REALPROP_2025": um_in_25,
                    "wkid": man.get(sid, {}).get("wkid"), "layer_last_edit": man.get(sid, {}).get("layer_last_edit")})

with open(out / "key_audit_summary.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(summary[0])); w.writeheader(); w.writerows(summary)
with open(out / "unmatched_keys.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(unmatched_rows[0]) if unmatched_rows else ["source_id"]); w.writeheader(); w.writerows(unmatched_rows)

print("SOURCE            n      srv    nullbad dup  bl!=b/l rawhit  normhit unmatch inCAMA in2025 wkid    shapes")
for s in summary:
    print(f"{s['source_id']:<16}{s['n']:>7}{s['server_count'] or 0:>8}{s['null_or_bad_key']:>7}{s['dup_keys_within']:>6}"
          f"{s['blocklot_vs_block_lot_mismatch']:>7}{s['match_raw_exact']:>8}{s['match_normalized']:>8}{s['unmatched']:>8}"
          f"{s['unmatched_found_in_CAMA']:>7}{s['unmatched_found_in_REALPROP_2025']:>7} {s['wkid']}  {s['key_shapes'][:70]}")

# ---------- date-format audit ----------
print("\nDATE FIELDS (type / shapes of sample values)")
for sid, m in man.items():
    for name, typ in m.get("fields", []):
        if re.search(r"date|DATE|Date|LDATE|_DATE", name) and sid in S:
            vals = [r.get(name) for r in S[sid] if r.get(name) not in (None, "", " ")]
            if not vals: continue
            sh = collections.Counter(shape(v) if typ != "esriFieldTypeDate" else "epoch_ms" for v in vals)
            ex = vals[0]
            if typ == "esriFieldTypeDate":
                ex = f"{ex} -> {datetime.datetime.utcfromtimestamp(ex/1000).date()}"
            print(f"  {sid:<15}{name:<28}{typ.replace('esriFieldType',''):<8} n={len(vals):<7} {dict(sh.most_common(4))}  e.g. {ex}")

# ---------- parcel-layer internal checks ----------
print("\nPARCEL LAYER INTERNAL")
print("  duplicate normalized keys:", sum(1 for c in pkeys.values() if c > 1), "keys,", sum(c for c in pkeys.values() if c > 1), "rows")
print("  PIN != key:", sum(1 for r in P if r.get("PIN") and norm(r["PIN"]) != key_of("PARCEL", r)))
print("  PINRELATE != PIN (condo/child units):", sum(1 for r in P if r.get("PINRELATE") and r.get("PINRELATE") != r.get("PIN")))
def ct(f, rows=P): return dict(collections.Counter(str(r.get(f)).strip() or "<blank>" for r in rows).most_common(12))
for f in ["VACIND", "VACANT_IND", "VACANT_I_1", "NO_IMPRV", "LUC", "LUC_1", "OWNER_ABBR", "USEGROUP", "RESPAGCY"]:
    print(f"  {f}: {ct(f)}")
print("  NO_IMPRV=Y but improvement value>0:", sum(1 for r in P if (r.get('NO_IMPRV') or '').strip() == 'Y'
      and ((r.get('CURRIMPR') or 0) + (r.get('EXMPIMPR') or 0)) > 0))
print("  NO_IMPRV blank but improvement value==0:", sum(1 for r in P if (r.get('NO_IMPRV') or '').strip() == ''
      and ((r.get('CURRIMPR') or 0) + (r.get('EXMPIMPR') or 0)) == 0))
print("  VACIND=Y and NO_IMPRV=Y (both building-vacant and no building):",
      sum(1 for r in P if (r.get('VACIND') or '').strip() == 'Y' and (r.get('NO_IMPRV') or '').strip() == 'Y'))
print("  joined cols Blocklot_1/2/3 populated:", {f: sum(1 for r in P if (r.get(f) or '').strip()) for f in ['Blocklot_1', 'Blocklot_2', 'Blocklot_3', 'blocklot_c']})
print("  Blocklot_1 != BLOCKLOT (when set):", sum(1 for r in P if (r.get('Blocklot_1') or '').strip() and norm(r['Blocklot_1']) != key_of('PARCEL', r)))
print("  RESPAGCY x OWNER_ABBR (top):", dict(collections.Counter((str(r.get('RESPAGCY')).strip(), str(r.get('OWNER_ABBR')).strip())
      for r in P if str(r.get('RESPAGCY')).strip()).most_common(20)))
print("  OWNER_ABBR=MCC with blank RESPAGCY:", sum(1 for r in P if str(r.get('OWNER_ABBR')).strip() == 'MCC' and not str(r.get('RESPAGCY')).strip()))
print("  LDATE shapes:", dict(collections.Counter(shape(r.get('LDATE')) for r in P).most_common(5)))

# ---------- parcel versions ----------
print("\nPARCEL VERSIONS (normalized key sets)")
pk = set(pkeys)
print(f"  PARCEL {len(pk)}  CAMA {len(cama_keys)}  REALPROP_2025 {len(rp25_keys)}")
print("  in PARCEL not CAMA:", len(pk - cama_keys), " in CAMA not PARCEL:", len(cama_keys - pk))
print("  in PARCEL not 2025:", len(pk - rp25_keys), " in 2025 not PARCEL (retired?):", len(rp25_keys - pk))
C = S.get("CAMA", [])
print("  CAMA duplicate_blocklot:", ct("duplicate_blocklot", C), " CAMA VACIND:", ct("VACIND", C))
cv = {key_of("CAMA", r): (r.get("VACIND") or "").strip() for r in C}
pv = {key_of("PARCEL", r): (r.get("VACIND") or "").strip() for r in P}
both = [k for k in pv if k in cv]
print("  VACIND disagreement PARCEL vs CAMA:", collections.Counter((pv[k], cv[k]) for k in both if pv[k] != cv[k]).most_common(6))

# ---------- cross-source consistency ----------
def kset(sid): return {key_of(sid, r) for r in S.get(sid, [])} - {None}
pidx = {key_of("PARCEL", r): r for r in P}
vo, va, vl, mcc, prv, rec, cty = (kset(s) for s in ["VBN_OPEN", "VBN_ALL", "VACANT_LOTS", "MCC_LOTS", "PRIV_LOTS", "RECPARK", "CITY_OWNED"])
print("\nCROSS-SOURCE")
print("  VBN_OPEN vs VBN_ALL: both", len(vo & va), " open-only", len(vo - va), " all-only", len(va - vo))
print("  VBN_ALL STATUS_1:", ct("STATUS_1", S.get("VBN_ALL", [])), " VAC_IND:", ct("VAC_IND", S.get("VBN_ALL", [])))
print("  VBN_OPEN NT:", ct("NT", S.get("VBN_OPEN", [])), " DateCancel set:", sum(1 for r in S.get('VBN_OPEN', []) if r.get('DateCancel')),
      " DateAbate set:", sum(1 for r in S.get('VBN_OPEN', []) if r.get('DateAbate')))
print("  VBN_OPEN parcels: parcel VACIND", collections.Counter(pv.get(k, "<nomatch>") for k in vo).most_common(4))
print("  parcel VACIND=Y without open VBN:", sum(1 for k, v in pv.items() if v == "Y" and k not in vo))
print("  VBN_OPEN on parcel with NO_IMPRV=Y (demolished?):", sum(1 for k in vo if (pidx.get(k, {}).get("NO_IMPRV") or "").strip() == "Y"))
demo = kset("DEMO"); print("  VBN_OPEN on parcel with completed demo record:", len(vo & demo))
lots_union = vl | mcc | prv
print("  VACANT_LOTS vs MCC+PRIV(2025): both", len(vl & (mcc | prv)), " VL-only", len(vl - mcc - prv), " 2025-only", len((mcc | prv) - vl), " MCC&PRIV overlap", len(mcc & prv))
print("  vacant-lot listings with an open VBN (contradiction):", len(lots_union & vo))
print("  vacant-lot listings: parcel NO_IMPRV", collections.Counter((pidx.get(k, {}).get("NO_IMPRV") or "<nomatch>").strip() or "<blank>" for k in lots_union).most_common(4))
print("  parcel NO_IMPRV=Y not on any vacant-lot list:", sum(1 for k, r in pidx.items() if (r.get("NO_IMPRV") or "").strip() == "Y" and k not in lots_union))
print("  MCC_LOTS owner on parcel layer:", collections.Counter(str(pidx.get(k, {}).get("OWNER_ABBR")).strip() for k in mcc).most_common(5))
print("  PRIV_LOTS owner on parcel layer:", collections.Counter(str(pidx.get(k, {}).get("OWNER_ABBR")).strip() for k in prv).most_common(5))
print("  RECPARK agency field:", ct("agency", S.get("RECPARK", [])), " method:", ct("method", S.get("RECPARK", [])))
print("  RECPARK parcels' RESPAGCY on parcel layer:", collections.Counter(str(pidx.get(k, {}).get("RESPAGCY")).strip() for k in rec).most_common(6))
print("  RESPAGCY=18 parcels not in RECPARK:", sum(1 for k, r in pidx.items() if str(r.get("RESPAGCY")).strip() == "18" and k not in rec))
print("  RECPARK parcels on a vacant-lot list:", len(rec & lots_union), " with open VBN:", len(rec & vo))
print("  ADOPT_LOT ResponsibleAgency:", ct("ResponsibleAgency", S.get("ADOPT_LOT", [])))
print("  TAX_SALE pin vs block/lot mismatch:", sum(1 for r in S.get("TAX_SALE", []) if r.get("pin") and norm(r["pin"]) != norm_pad(r.get("block"), r.get("lot"))))
fc = S.get("FORECLOSURE", [])
print("  FORECLOSURE geocode Status:", ct("Status", fc), " Score<100:", sum(1 for r in fc if (r.get("Score") or 0) < 100), " Addr_type:", ct("Addr_type", fc))
