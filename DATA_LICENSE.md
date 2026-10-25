# Data licence

The results, aggregate data, derived tables and figure data in this repository, and any figures drawn from them, are licensed under the Creative Commons Attribution 4.0 International licence (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/, subject to the third-party terms below.

Copyright (c) 2026 Siddalingaiah H S.

This covers:

- `papers/E/results.json`, `papers/E/traceability.csv`, `papers/E/output/`, `papers/E/figures/data/` and `papers/E/tables/` (results, aggregate tables, figure and table data);
- `data/derived/hmis/` (the HMIS state-month panel and model table, the unit-month climate table, and the gate, break and acquisition reports);
- `pipeline/reference/hmis_*.csv` and `pipeline/reference/state_frame.csv` (the indicator crosswalk, programme-event months, reviewed dispositions, portal file list and the state frame);
- `data/derived/enso_monthly.csv`, `data/derived/climate_state_month.csv` and `data/derived/model/population_2001_2027.csv` (ENSO, climate and population inputs).

Attribution: cite the paper (see README.md) or this repository (CITATION.cff), and the original sources below.

## HMIS (Government Open Data License – India)

The HMIS-derived values (`data/derived/hmis/hmis_state_month.csv`, `hmis_model.csv`, the gate and break reports, the figure data and every HMIS-based result) are derived from data published under the Government Open Data License – India (GODL-India, https://data.gov.in/government-open-data-license-india), which requires this attribution, reproduced verbatim:

Health Management Information System (HMIS), Ministry of Health and Family Welfare, Government of India; via data.gov.in / hmis.mohfw.gov.in; Government Open Data License – India

The raw HMIS workbooks are not redistributed; `pipeline/reference/hmis_sources.csv` and `data/derived/hmis/acquisition_report.md` list the portal files with their URLs and SHA-256 hashes. The FY2020-21 state-month files were downloaded from the HMIS portal only, which states no explicit licence (see README.md for how this release treats the FY2020-21 rows). HMIS values are provisional as of the status dates recorded in the panel.

## Third-party sources

CC BY 4.0 applies to the aggregation and processing in this repository. The original data remain subject to their producers' terms, and users must also attribute them.

| Source | Producer | Terms |
|---|---|---|
| Oceanic Niño Index (traditional), Relative ONI, Niño-3.4 anomaly (`data/derived/enso_monthly.csv`) | NOAA Climate Prediction Center (https://www.cpc.ncep.noaa.gov/data/indices/) | US Government public data; attribute NOAA CPC |
| Dipole Mode Index (HadISST) | NOAA Physical Sciences Laboratory (https://psl.noaa.gov/gcos_wgsp/Timeseries/DMI/) | US Government public data; attribute NOAA PSL; HadISST is Met Office Hadley Centre data |
| Gridded daily rainfall (0.25°) and maximum temperature (1°), as state and unit aggregates (`data/derived/climate_state_month.csv`, `data/derived/hmis/climate_unit_month.csv`) | India Meteorological Department (IMD), Pune | IMD gridded-data terms; raw grids are not redistributed. Cite Pai DS et al. 2014, MAUSAM 65(1):1–18 and Srivastava AK et al. 2009, Atmos Sci Lett 10:249–254 |
| Population projections 2011–2036 by state (`data/derived/model/population_2001_2027.csv`, interpolated) and Census 2011 populations | National Commission on Population, Ministry of Health and Family Welfare (Technical Group on Population Projections, 2019); Office of the Registrar General and Census Commissioner, India | Government of India publications; attribute the source |
| State monsoon sensitivity to ENSO (`papers/D/output/risk_index.csv`, column `hazard_rain`) | The author's companion synthesis (https://doi.org/10.5281/zenodo.23632647) | CC BY 4.0 |
| Unit identifiers (`gid1_members` in `pipeline/reference/state_frame.csv`) | GADM 4.1 (https://gadm.org) | GADM licence (free for academic and other non-commercial use; redistribution or commercial use needs GADM's permission, https://gadm.org/license.html); no boundaries are included |
