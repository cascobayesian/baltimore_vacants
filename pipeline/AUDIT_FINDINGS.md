# Source audit — keys, formats, vintages, cross-source consistency (2026-11-23)

Scripts: `scripts/00_fetch_audit_attrs.py` (attribute-only snapshots → `data/audit_raw/`, with
`manifest.json` holding URL, server count, download time, sha256), `scripts/01_key_audit.py`
(→ `output/audit/key_audit_summary.csv`, `output/audit/unmatched_keys.csv`).
All 19 sources downloaded completely (downloaded = server count).

## A. Parcel key (BLOCKLOT) formats
| issue | where | handling |
|---|---|---|
| Space vs no space (`0702 050` / `0702050`), both **inside the parcel layer itself** | all sources | strip spaces/punctuation, uppercase |
| Letter suffix on block and/or lot (`4163B023`, `0702 050A`) | all | canonical pattern `BBBB[X]LLL[Y]` |
| Railroad/utility blocks `PSC0`–`PSC9` (137 rows, CSX etc.) | parcel layer | allowed as block form |
| Trailing spaces in key | Adopt-a-Lot | stripped |
| Separate block/lot fields only, no BLOCKLOT | Tax Sale | key built from `block`+`lot`; 0 conflicts with `pin` |
| No key at all (7,921 of 14,142) | Foreclosures (2017–20 rows) | address-geocoded only; see D |
| Literal string `"None"` as a value | Adopt-a-Lot agency | treated as missing |

After normalization every source checks clean: BLOCKLOT never disagrees with its own BLOCK/LOT/PIN fields.

## B. Parcel layer structure
- **Multipart parcels**: 1,013 keys appear on 2,411 rows, all with identical attributes → one parcel split into several polygons. Dissolve by key; never count twice.
- **Condominiums**: 12,987 unit records (`PINRELATE` ≠ `PIN`) in 387 buildings, each unit carrying a full-building polygon (median ~9,400 m²) → stacked, overlapping polygons. Map and classify condos at the **building** level (group by `PINRELATE`) and keep unit-level evidence in the receipts.
- 49 sliver polygons < 5 m².
- **Vintage**: every assessor record has `LDATE = 2025-10-12`. Although the layer was edited Jun 2026, its assessment attributes are an **Oct 2025 extract**.
- Three parcel versions disagree: current (236,971 keys), CAMA (236,699), older `realprop` (234,763, LDATEs ~2018). 4,188 current keys are new since the old version and 1,980 old keys are retired (lot consolidations/renumbering). The old version serves as a **crosswalk for retired keys** in other sources.
- `VACIND` (assessor vacancy flag) disagrees between the parcel layer and CAMA on ~3,500 parcels (mostly N↔blank, but 100 Y↔N). Blank is the norm (208k), so only **Y** is treated as evidence; blank ≠ N.

## C. Agency code `RESPAGCY` (see section G1 for the official table, which supersedes this)
First decoded by cross-tabulating with Adopt-a-Lot agency names. Every inference was later confirmed by the
official field domain, except 30, which is officially "Office of the Comptroller" (the office that runs the tax sale).
104 city-owned (`MCC`) parcels have no agency code.
Note: DOT holds very few parcels (426), because streets and right-of-way are **not parcels** and sit
in the gaps between them. "DOT land" in the map therefore means DOT-held parcels, not the street network.

## D. Source vintages and scope (several differ from their names)
| source | actual content |
|---|---|
| Vacant Building Notices – Open (DHCD) | 11,308 open notices, issued 2004-11 → 2026-11-21; current |
| `VBN` (city org) | **historical snapshot**: notice dates 1993 → Jul 2018 only, 16,518 rows; 9,512 no longer open. Dates are 2-digit-year `MMDDYY` |
| `Vacant_Building_Notices_Sept16` | 60 rows; not useful |
| `All_City_Owned_Properties` | **only the Downtown Management District** (176), not all city property → dropped; use parcel `OWNER_ABBR`/`RESPAGCY` instead |
| Foreclosure filings | 2015–2020 only; stale. 2017–20 rows have no BLOCKLOT (geocoded, many score < 100) |
| Tax Sale | 2023 list; stale, weak signal only |
| Vacant_Lots (Apr 2026) | 19,188 rows, but 1,825 keys **not in the current parcel layer** (926 found in the old version; 1,786 in blocks that still exist → renumbered/consolidated lots). Some keys repeat up to 64× (multipart). Needs **spatial** matching, not just keys |
| MCC / Private vacant lots (Oct 2025) | the "Private" list includes 93 publicly owned parcels (HABC 54, MCC 24, HUD 9, USA 4, DHCD 2) |

## E. Cross-source contradictions to handle explicitly
- **553 of 571 Rec & Parks parcels appear on the Vacant_Lots list** (79 on the city-owned vacant-lot list). These lists mean "no building", not "abandoned". Rule: protected/park status takes precedence over vacant-lot status, and the overlap is recorded in the receipt.
- Of all vacant-lot listings, 91 parcels also hold an open vacant *building* notice → conflict flag (stale notice after demolition, or a lot list that is out of date).
- 77 open building notices sit on parcels the assessor says have **no improvements**, 13 on parcels with a completed city demolition → probably demolished; downgrade and flag.
- 1,959 parcels flagged vacant by the assessor have no open notice; 989 open notices sit on parcels the assessor does not flag (681 blank, 308 N).
- 1,291 no-improvement parcels are on no vacant-lot list (candidates: parking lots, rail, utility land; check `USEGROUP`/owner).

## F. Formats that must be parsed explicitly
- **Dates, 7 formats**: epoch ms; `MMDDYYYY` string; `MMDDYY` string (VBN historical, pivot year needed); `YYYYMON` (CAMA);
  integer `MDDYYYY` with **leading zero lost** (`6171936` = 06/17/1936); text `"Dec 22 2025 12…"` (Rehab); 8-digit integer.
- **Coordinate systems, 3**: Web Mercator (102100), MD State Plane NAD83 ft (102685), MD State Plane NAD83(HARN) ft (2893). Reproject everything to one CRS before any spatial match.
- Text fields are fixed-width padded (`'MAYOR AND CITY COUNCIL OF     '`) → trim.

---
# Follow-up audit (items 1, 2, 4), 2026-11-23
New scripts: `scripts/02_owner_greenspace_audit.py` (→ `output/audit/owner_class_counts.csv`,
`owner_class_rules.csv`, `greenspace_match.csv`) and `output/audit/unmatched_keys_reviewed.csv`.
Official data dictionary saved at `data/docs/realprop_data_dictionary.xlsx`
(Open Baltimore item `17e4f1054a874677934885b1420621a5`).

## G1. Official parcel source and field definitions
- **Use `baltegis.baltimorecity.gov/mapping/rest/services/CityView/RealProperty_OB/FeatureServer/0` as the parcel base.**
  It is the city's weekly-updated layer (all records `LDATE = 11/22/2026`, 237,515 records). The copy used so far
  (`Real_Property_Parcel_Map`) is an Oct 2025 extract, and its vacancy flags are stale (`VACIND=Y` 12,288 then vs 11,199 now).
- `RESPAGCY` official domain: 01 Unassigned · 02 BC Hospital · 03 DGS · 04 Docks & Wharves · 05 Education · 06 Libraries ·
  07 Fire · 08 Mayoralty · 10 Health · **11 Highways** · 12 Jail · 13 M & CS · 14 Mec/Elec · 15 Museums · **18 Rec & Parks** ·
  19 Sanitation · 20 Sewers · 21 Elections · 22 Post Mortem · 23 Water Supply · 24 Police · 25 Central Garage · 26 BCC ·
  27 Urban Services · 28 War Memorial · 29 Aquarium · **30 Office of the Comptroller** (runs the tax sale) · **31 Excess Street Opening** ·
  32 Unallocated · 33 Off Street Parking · **34 NPA/HCD** (housing land bank) · 35 Social Services · 36 Civic & Convention Ctrs ·
  **37 Transit & Traffic** · 38 Finance · 39 Commission for Aging · 43 BDC.
  City transportation therefore = **11 + 31 + 37** (427 parcels), not 11 alone.
- `NO_IMPRV` (dictionary): "Vacant lot proxy. 'Y' if assessed improvements total $0. All Y's are vacant lots and have no building."
- `VACIND` (dictionary): "Indicates if structure on property is designated as vacant", values Y / N / NULL; N vs NULL undocumented.
  **Empirically**, N parcels are 53% no-building, 16% demolished, 34% city-owned, and only 1.7% carry an open notice.
  So N ≈ "reviewed, no vacant structure (often because it was demolished)", and NULL = never flagged.
  Neither N nor NULL is evidence of occupancy; only Y is used as evidence.
- `EXMPCODE` = "State exempt code" (00–99); the dictionary has **no code table**, and the SDAT definitions page refused automated access.
  Codes are used only as inferred evidence (G2).
- `OWNER_2`/`OWNER_3` carry the agency name for state parcels → the build must fetch them (the audit snapshot had only `OWNER_1`).

## G2. Owner classes (curated, anchored patterns; never bare keywords)
A loose pattern matched "MPA" inside "COMPANY" (1,043 false "Port Administration" parcels) and "GREEN"/"PARK" in
personal names. The rules in `owner_class_rules.csv` are anchored phrases checked against OWNER_1+2+3.
| class | parcels | notes |
|---|---|---|
| CITY_LANDBANK (RESPAGCY 34/30/32/01/blank) | 8,621 | housing dept, Comptroller/tax-sale, unallocated |
| HOUSING_AUTHORITY (HABC) | 1,404 | |
| CITY_PARKS (RESPAGCY 18) | 737 | 571 also on the Rec & Parks reviewed list |
| STATE_UNNAMED_AGENCY | 515 | owner is just "STATE OF MARYLAND"; see below |
| CITY_TRANSPORTATION (11/31/37) | 427 | |
| CITY_OTHER_FACILITY | 398 | schools, fire, libraries, … |
| RAILROAD (CSX, Amtrak, Canton RR, B&A RR) | 264 | rail museums/historic district corp excluded |
| STATE_TRANSPORTATION (MTA, SHA, MDTA, Port Admin, Aviation) | 227 | named in owner fields |
| CITY_UTILITY (sewers, water, sanitation) | 136 | |
| FEDERAL (USA, HUD, VA, USPS) | 92 | |
| STATE_UNIVERSITY | 68 | |
| UTILITY (BGE) | 57 | |
| PRIVATE_TITLE_TRUST ("1316 N Fulton Ave Land Trust", family trusts) | 39 | **private**, not conservation |
| CONSERVATION_TRUST (Baltimore Green Space) | 36 | |
| COMMUNITY_LAND_TRUST (housing CLTs) | 35 | affordable-housing land trusts, not open space |
| STATE_OTHER_NAMED (Stadium Auth., DPSCS, MDE) | 17 | |

**Unnamed state parcels (515)**, inferred from exemption codes that are 100% consistent among *named* state owners:
code 25 or 21 → university (268); 36/38/30 → transportation (67); 183 remain **unresolved**.
These are labeled "inferred from exemption code" (lower certainty) and should be checked by location in the build,
for example whether they sit along I-83, I-95 or light-rail corridors.

## G3. Green space / protected land
- Baltimore Green Space (land trust) publishes on its own ArcGIS org (`services8.arcgis.com/ksfQpKmeklI0YH5h`):
  - **Preserved sites 2026** (21 polygons): no parcel key → spatial match in the build.
  - **Community-managed sites 2023** (327; BLOCK/LOT fields): **lot not zero-padded** (`1748 53`). A naive key matches 10 of 327;
    padded, 317. These sit mostly on **city land-bank (154) or private (133) parcels**: they are community gardens and green
    lots in use, not legally protected. Proposed category: "community-managed open space (not protected)".
  - Forest sites 2025–26 (17 polygons + points).
  - Only 13 of the 36 parcels Baltimore Green Space owns today are on its 2023 site list (acquisitions since).
- UMBC urban-agriculture list (79 sites, 2026): lat/lon only; its `Land_Tenure` field is empty → use as a supporting "in use" signal.
- The Rec & Parks reviewed list carries `agency`/`method=SDAT` plus staff review columns → strong evidence.

## G4. Unmatched records, reviewed (`unmatched_keys_reviewed.csv`)
Each unmatched record was checked for whether its address exists in the current parcels under another key:
- Vacant_Lots 1,905 unmatched: 993 retired keys (lot consolidations; e.g. E Biddle St block 1531 redeveloped), 821 with no
  findable address (lots often have descriptive addresses like "ES DUNDALK AV NEC…"), 91 recovered by address.
  → **spatial match required** (build step 3).
- Historical VBN 282: 264 retired keys, 7 recovered by address. Tax Sale 35, Demo 5, Adopt-a-Lot 8: all retired keys.
- Private lots 2: renumbered with a lot suffix (`0314 003` → `0314003A`): recovered by address.
- Foreclosures 7,921: no key at all (2017–20 geocodes) → address/spatial only; low value given the 2020 end date.

## G5. External benchmarks (BNIA)
- BNIA tract-level "% residential properties vacant & abandoned", 2018–2024 (200 tracts, **2010 tract boundaries**,
  with residential denominators). Its implied 2024 citywide count is about 12,900, against 11,308 open notices today: consistent.
- BNIA USPS "no mail delivered" by tract, Dec 2025 (199 tracts, **2020 boundaries**). This is an independent vacancy measure.
- Both need a parcel→tract spatial join (build step 3); the two tract vintages must not be mixed.

## Still open after this audit
- `EXMPCODE` official table (183 unnamed-state parcels unresolved; inference unconfirmed). SDAT's definitions page
  (`sdat.dat.maryland.gov/RealProperty/Pages_HTML/rp_def.aspx`) blocks automated fetches. A person can open it in a
  browser, or SDAT can be asked.
- All geometry-based checks (step 3).
