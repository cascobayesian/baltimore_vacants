# Provenance ("receipts") spec — Baltimore parcel vacancy index

Every classification must be traceable to specific source records. No parcel gets a
label without at least one evidence row behind it, including "in use" (which cites the
assessor record and the absence of vacancy evidence).

## Output files

### 1. `output/sources.csv` — source registry (one row per source layer)
| field | meaning |
|---|---|
| `source_id` | short ID used everywhere else (e.g. `VBN_OPEN`, `ASSESSOR`) |
| `name`, `publisher` | e.g. "Vacant Building Notice – Open", Baltimore DHCD |
| `service_url` | exact ArcGIS REST layer URL |
| `portal_url` | human-readable Open Baltimore / ArcGIS item page |
| `downloaded_at` | UTC timestamp of our download |
| `layer_last_edit` | layer's own `editingInfo.lastEditDate` |
| `n_records` | records downloaded (must equal server count at download time) |
| `raw_file`, `sha256` | snapshot in `data/raw/` and its checksum |
| `role` | what this source is evidence *for* (vacant building, vacant lot, protected land, …) |

### 2. `output/evidence.csv` — one row per (parcel × source record)
| field | meaning |
|---|---|
| `blocklot` | normalized parcel key (`BBBBSLLL`, spaces removed, uppercase) |
| `source_id` | links to `sources.csv` |
| `source_record_id` | that source's own ID (NoticeNum, OBJECTID/GlobalID, case number, PIN) |
| `field`, `value` | the attribute used, as published (e.g. `VACIND = Y`, `NoticeNum = 2655955A`) |
| `record_date` | the record's own date (notice date, assessor `LDATE`, filing date), if any |
| `match_method` | `key_exact`, `key_normalized`, or `spatial` (with `overlap_pct`) |
| `record_url` | REST query returning that one record by its ID |

### 3. `output/parcel_index.csv` (+ `.gpkg` with geometry) — one row per parcel
`blocklot, address, owner, category, certainty, rule_id, evidence_summary, n_evidence,
conflict_flag, conflict_note, sdat_url, blockplat_url`

- `rule_id` names the exact rule that assigned the label (see `rules.csv`).
- `evidence_summary` is a plain-English receipt, e.g.
  *"Open vacant building notice 2655955A (DHCD, 2026-05-28); assessor vacancy flag Y (record updated 2025-10-12)."*
- `sdat_url`: the Maryland SDAT state assessment page for the parcel (an independent check).
- `blockplat_url`: city block plat PDF.

### 4. `output/rules.csv` — decision rules
`rule_id, category, certainty, plain-language definition, required evidence, precedence`.
Rules are applied in a fixed, documented order; the README reproduces this table.

### 5. `output/match_audit.csv` — nothing dropped silently
For each source: records downloaded, matched by key, matched only spatially, unmatched,
and duplicates. Unmatched records are listed in `output/unmatched_<source_id>.csv`.

### 6. Conflicts are reported, not hidden
When sources disagree (e.g. a Rec & Parks parcel carrying an open vacant notice, or a
"vacant lot" listing on a parcel with improvement value), the label follows the rule
precedence, `conflict_flag = 1`, and `conflict_note` names the disagreeing sources.

## Reproducibility
- Raw downloads are kept unmodified in `data/raw/<source_id>_<YYYYMMDD>.geojson`;
  live layers change (notices close), so the snapshot, not the live URL, is canonical.
- `record_url` is a convenience link to the live record and may drift after the snapshot date.
- Every script logs its inputs (by `source_id` + sha256) to `output/run_log.txt`.

## Known key issue (found 2026-11-23)
Parcel layer stores `BLOCKLOT` as `0702050`; DHCD notices store `0702 050`; some
blocks have letter suffixes (`4163B023`). All keys are normalized before joining, and
match rates are reported in `match_audit.csv`.
