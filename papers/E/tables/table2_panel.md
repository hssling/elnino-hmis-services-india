# Working table B (not numbered in the paper; the manuscript's Table 1 is the published panel table). Panel description, primary window (April 2012 to February 2020)

Units: 34. Months: 95. State-months: 3,230. HMIS status dates (all values provisional): 19 September 2015 to 6 November 2020.

| Indicator | State-months with a valid value | District-months valid | Reported count per state-month, median (IQR)<sup>a</sup> | Coverage per 1,000 expected births |
|---|---|---|---|---|
| ANC registration | 3,175 | 99.2% | 41,082 (4,012–97,312) | not available (SRS not retrieved) |
| Third dose of a DPT-containing vaccine | 3,150 | 98.8% | 27,789 (1,742–90,268) | not available (SRS not retrieved) |
| Institutional deliveries | 3,168 | 99.1% | 24,445 (2,162–77,218) | not available (SRS not retrieved) |
| Outpatient attendance | 3,151 | 98.9% | 1,516,633 (208,338–5,606,538) | not applicable |
| Diarrhoea in children under 5 years | 3,109 | 97.7% | 3,460 (935–13,136) | not applicable |
| First dose of a measles-containing vaccine | 3,152 | 98.9% | 29,248 (1,731–87,634) | not available (SRS not retrieved) |
| Full immunisation | 3,151 | 98.9% | 28,729 (1,626–85,843) | not available (SRS not retrieved) |

A state-month enters the analysis only if at least 90% of the districts listed for the state and year reported the item (completeness = valid / listed districts); otherwise it is missing, never zero and never scaled up. Values failing a data-quality gate are masked. District-months valid: valid district-months as a share of listed district-months. Coverage ratios would divide by expected births from the Sample Registration System, which could not be retrieved, so they are not reported; the analysis does not depend on them.

<sup>a</sup> Descriptive: computed by `papers/E/tables/make_tables.py` from `data/derived/hmis/hmis_model.csv` over the valid primary-window state-months; the unrounded values are in `papers/E/tables/data/table2.csv`. Not a results.json key.
