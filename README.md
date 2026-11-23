# Baltimore parcel vacancy map

Live map: https://cascobayesian.github.io/baltimore_vacants/

Each of Baltimore City's 237,088 parcels gets a label: vacant building, vacant lot, community-managed open space, Rec & Parks land, Baltimore Green Space protected land, transportation land, or no vacancy evidence. Every label has a certainty (high, medium or low) and receipts. Each receipt is a record from a public dataset, with a link back to it on the publishing agency's server.

## Map views
- **All land**: parcels by category. Shading shows certainty. You can choose to outline parcels where sources disagree.
- **Vacant buildings** and **Vacant lots**: parcels shaded by how many separate government records point to vacancy.
- **Tree canopy**: canopy share in 2021/22, and its change since 2013/14, from 1-metre land cover (Chesapeake Bay Program LULC, 2024 edition).
- **Stormwater**: paved and roofed share of each parcel, with DPW storm pipes, inlets, outfalls and stormwater restoration project sites.

## Data
- City of Baltimore: Open Baltimore, DHCD and DPW services.
- Baltimore Green Space.
- UMBC urban agriculture site list.
- BNIA tract benchmarks.

All were downloaded on 2026-11-23. `pipeline/output/sources.csv` and `pipeline/output/env_sources.csv` list every service URL, download time, record count and SHA-256 checksum.

## Methods
- `pipeline/rules.csv` gives the labelling rules.
- `pipeline/PROVENANCE.md` and `pipeline/AUDIT_FINDINGS.md` describe the receipts design and the source audit.
- `pipeline/ENV_SOURCES.md` covers the canopy and stormwater sources.
- The scripts in `pipeline/` rebuild everything. Run them in numeric order: `10`, `20`, `30`, `40`, `41`, `51`, `42`.

This is an independent research index built from public records. It is not an official determination of vacancy, ownership or stormwater billing.
