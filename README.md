# Nigeria Automotive Sales & Service Data Platform

> An end-to-end data platform for an automotive dealership and repair business —
> ingestion, transformation, testing, orchestration and BI delivery.
> Built on the medallion architecture with Azure and dbt.

**Author:** Dayo Fasokun — Data & Infrastructure Engineer
**Stack:** Azure Data Factory · Azure Data Lake Storage · dbt · Python · PySpark · SQL · Power BI
**Data:** 100% synthetic. No real customer, vehicle or financial data is used anywhere in this repository.

---

## Why this project exists

Early in my career I worked as an administrator at an automotive company in Lagos.
Work orders lived in paper files and spreadsheets. Parts inventory was counted by hand.
Nobody could answer basic questions: which mechanics were most productive, which repairs
were actually profitable, which customers were about to stop coming back.

This platform is the data infrastructure that business needed — rebuilt properly,
seventeen years later, with the tools I use today.

---

## The business questions it answers

| # | Question | Served by | Status |
|---|----------|-----------|--------|
| 1 | Which service types generate the most gross profit after parts and labour? | `mart_service_profitability` | ✅ built |
| 2 | Which mechanics complete work fastest without triggering rework? | `mart_technician_performance` | 🔜 planned |
| 3 | Which parts will stock out in the next 14 days? | `mart_inventory_health` | 🔜 planned |
| 4 | Which customers are overdue for service and likely to churn? | `mart_customer_retention` | 🔜 planned |
| 5 | What is the true cost of a repair job, end to end? | `mart_job_costing` | 🔜 planned (`fct_work_orders` already computes per-job cost and profit) |
| 6 | Which vehicle models generate the most repeat repairs? | `mart_vehicle_reliability` | 🔜 planned |

---

## Architecture

```
   SOURCES                 BRONZE              SILVER               GOLD
   ─────────               ──────              ──────               ────
   Workshop DMS   ──┐
   Parts ERP      ──┤                      ┌─ stg_* models ─┐
   POS / Invoicing──┼── ADF ──► ADLS Gen2 ─┤                ├─► marts ──► Power BI
   CRM            ──┤   (raw, immutable)   └─ int_* models ─┘
   Supplier feeds ──┤                             dbt
   Telematics CSV ──┘                        (tested, documented)
```

**Bronze** — raw landing zone. Nothing is cleaned. Nothing is judged. Partitioned by ingest date.
**Silver** — cleaned, typed, deduplicated, conformed. One staging model per source table.
**Gold** — business-ready marts. Pre-calculated metrics with agreed definitions.

Full detail: [`docs/DATA_CATALOG.md`](docs/DATA_CATALOG.md)

---

## Repository structure

```
.
├── data_generator/        Synthetic source data generation (Python + Faker)
├── ingestion/             Python ingestion scripts (source → bronze, all 11 raw tables)
├── dbt_project/
│   ├── models/
│   │   ├── staging/       Bronze → Silver: work_orders, work_order_lines,
│   │   │                  technicians, parts (4 of ~10 source tables so far)
│   │   └── marts/         Gold: fct_work_orders, mart_service_profitability
│   ├── macros/            Reusable SQL logic (DuckDB-specific: RE2 regex, strptime)
│   ├── tests/             Custom data quality test (line-total reconciliation)
│   ├── seeds/             Reference data (service codes, VAT rates, make aliases)
│   └── profiles.yml       Local/CI DuckDB target — run with DBT_PROFILES_DIR=.
├── docs/
│   └── DATA_CATALOG.md    Every entity, every field, the cleaning rule that
│                          applies to it, and which stage each has reached
└── .github/workflows/     CI: dbt build + test on every pull request
```

`intermediate/` models, ADF `orchestration/`, and `docs/ARCHITECTURE.md` /
`RUNBOOK.md` are referenced in the data catalog as the target design but are
not built yet — see Status below.

---

## Data quality approach

Every implemented model is tested. The pipeline fails loudly rather than delivering wrong numbers quietly.

- **Source freshness** — declared per source in `_staging__models.yml` (not yet enforced by a schedule, since there's no orchestration yet)
- **Staging tests** — `not_null` and `unique` on every primary key, `accepted_values` on every status/vocabulary field
- **Anomaly flags, not silent drops** — invalid VINs, out-of-range odometer readings, and labour hours over 24 are nulled/flagged with a boolean column rather than dropped or rejected
- **Reconciliation test** — `fct_work_orders` recalculates every line total from quantity, price, discount and the date-effective VAT rate, and flags where it disagrees with the source by more than ₦1. A custom test (`tests/assert_line_total_mismatch_rate_within_expected_bounds.sql`) checks that mismatch rate stays near the ~3% the generator deliberately injects — proving the recalculation catches real errors without over- or under-firing

See [`docs/DATA_CATALOG.md`](docs/DATA_CATALOG.md) for the cleaning rule applied to every single field, and which ones are implemented.

---

## Running it locally

```bash
# 0. Install dependencies
pip install -r requirements.txt

# 1. Generate synthetic source data
python data_generator/generate_all.py --months 24

# 2. Land it in the bronze layer
python ingestion/land_to_bronze.py

# 3. Build and test the dbt project
cd dbt_project
DBT_PROFILES_DIR=. dbt deps
DBT_PROFILES_DIR=. dbt build   # runs models + tests together
DBT_PROFILES_DIR=. dbt docs generate && dbt docs serve
```

If `dbt deps` fails with an SSL certificate error on Windows (common behind
corporate antivirus/proxy setups), install `pip-system-certs` — it makes
Python trust the Windows certificate store.

---

## Status

| Component | Status |
|-----------|--------|
| Synthetic data generator (all 11 source tables) | ✅ |
| Bronze ingestion (all 11 source tables) | ✅ |
| Silver staging models | 🔶 4 of ~10 source tables (work orders, lines, technicians, parts) |
| Gold marts | 🔶 2 of 8 (`fct_work_orders`, `mart_service_profitability`) |
| dbt tests | ✅ 35/35 passing — schema tests, custom reconciliation test, dbt_utils checks |
| CI (GitHub Actions, dbt build on every PR) | ✅ |
| ADF orchestration | 🔜 not started |
| Power BI dashboard | 🔜 not started |
| Entity resolution (duplicate customers) | 🔜 not started |
| Streaming telematics ingestion | 🔜 not started |

The remaining marts, ADF pipeline definitions, and Power BI dashboard are
tracked as "still to build" — see `docs/DATA_CATALOG.md` section 3 for the
full target design.

---

## Contact

[LinkedIn](https://www.linkedin.com/in/dayofasokun) · Open to Data Engineer roles and consulting engagements.
