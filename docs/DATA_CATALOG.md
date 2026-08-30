# Data Catalog — Nigeria Automotive Sales & Service Data Platform

Every data entity in the platform, what it contains, and exactly what is
cleaned, fixed or transformed at each pipeline stage.

**Legend**
🥉 Bronze — raw landing. No cleaning. Immutable.
🥈 Silver — cleaned, typed, deduplicated, conformed.
🥇 Gold — business-ready, aggregated, metric-defined.

---

## 1. SOURCE SYSTEMS INVENTORY

| # | Source system | Type | Entities | Volume/day | Ingestion | Freshness SLA |
|---|---------------|------|----------|-----------|-----------|---------------|
| 1 | Workshop DMS | PostgreSQL | Work orders, job lines, technicians, bays | ~450 rows | CDC | 1 hour |
| 2 | Parts ERP | SQL Server | Parts, stock, movements, suppliers, purchase orders | ~1,200 rows | Batch (hourly) | 2 hours |
| 3 | POS / Invoicing | REST API | Invoices, payments, credit notes | ~380 rows | API poll (15 min) | 30 min |
| 4 | CRM | REST API | Customers, vehicles, contacts, service reminders | ~90 rows | API poll (hourly) | 4 hours |
| 5 | Supplier price feeds | SFTP CSV | Price lists, lead times, availability | ~3,000 rows | Daily file drop | 24 hours |
| 6 | Telematics | JSON events | Odometer readings, fault codes, GPS | ~15,000 events | Event stream | 15 min |
| 7 | Manual spreadsheets | Excel upload | Warranty claims, insurance jobs | ~40 rows | Manual, validated | Weekly |

---

## 2. ENTITY-BY-ENTITY CATALOG

---

### 2.1 WORK ORDERS  (`work_orders`)

The central fact of the business. One row per repair job.

| Stage | Table | Grain | Notes |
|-------|-------|-------|-------|
| 🥉 | `bronze.dms_work_orders` | 1 row per CDC event | Includes inserts, updates, deletes |
| 🥈 | `stg_dms__work_orders` | 1 row per work order (current state) | |
| 🥇 | `fct_work_orders` | 1 row per work order | Enriched with costs, duration, profit |

**Fields and cleaning rules**

| Field | Raw type | Silver type | Cleaning / fix applied |
|-------|----------|-------------|------------------------|
| `wo_number` | VARCHAR | VARCHAR | Trim whitespace; uppercase; strip legacy `WO-` prefix inconsistency (some records use `WO`, `W/O`, `wo-`) → normalise to `WO-NNNNNN` |
| `customer_id` | VARCHAR | VARCHAR | Trim; uppercase; map legacy pre-2019 IDs via `seeds/customer_id_migration.csv` |
| `vehicle_vin` | VARCHAR | VARCHAR | Uppercase; strip spaces and hyphens; **validate 17 characters**; invalid VINs routed to quarantine table, not silently dropped |
| `date_opened` | VARCHAR | TIMESTAMP | Source sends 3 formats (`DD/MM/YYYY`, `YYYY-MM-DD`, epoch ms) — all parsed and **converted to UTC** |
| `date_closed` | VARCHAR | TIMESTAMP | Same as above; **null where job still open** (source uses `1900-01-01` as a placeholder — converted to NULL) |
| `status` | VARCHAR | VARCHAR | Source uses `1/2/3/4` AND `OPEN/CLOSED/...` inconsistently → mapped to single vocabulary: `open`, `in_progress`, `awaiting_parts`, `completed`, `cancelled` |
| `service_type_code` | VARCHAR | VARCHAR | Trim; uppercase; unknown codes flagged, not dropped |
| `technician_id` | VARCHAR | VARCHAR | Trim; NULL where `'UNASSIGNED'`, `''`, `'N/A'`, `'-'` |
| `bay_id` | VARCHAR | VARCHAR | Trim; uppercase |
| `odometer_reading` | VARCHAR | INTEGER | Strip `km`/`KM`/commas; **reject negatives and values > 2,000,000** → NULL + flagged |
| `labour_hours` | VARCHAR | DECIMAL(6,2) | Comma decimal separator (`3,5`) converted to point; **capped alert if > 24 per technician per day** |
| `customer_complaint` | TEXT | TEXT | Trim; collapse repeated whitespace; **no PII extraction** |
| `is_warranty` | VARCHAR | BOOLEAN | `Y/N/1/0/TRUE/FALSE/yes/no` all normalised |
| `is_deleted` | — | BOOLEAN | Derived from CDC delete events — **soft delete, never hard delete** |

**Deduplication rule**
CDC produces multiple rows per work order. Silver keeps the latest by
`ROW_NUMBER() OVER (PARTITION BY wo_number ORDER BY cdc_timestamp DESC) = 1`.

**Tests applied**
`unique(wo_number)` · `not_null(wo_number, customer_id, date_opened, status)` ·
`accepted_values(status)` · `relationships(customer_id → stg_crm__customers)` ·
custom: `date_closed >= date_opened` · custom: `labour_hours between 0 and 24`

---

### 2.2 WORK ORDER LINES  (`work_order_lines`)

One row per part or labour item on a job.

| Field | Cleaning / fix applied |
|-------|------------------------|
| `line_id` | Composite key built as `wo_number \|\| '-' \|\| line_no` (source has no unique line ID) |
| `line_type` | Normalised to `part` / `labour` / `sublet` / `fee` |
| `part_number` | Uppercase; strip spaces, dots and hyphens; map supplier-specific variants via `seeds/part_number_aliases.csv` |
| `quantity` | Cast to DECIMAL; **negatives allowed only where `line_type = 'return'`**, otherwise quarantined |
| `unit_price_ngn` | Strip `₦`, `NGN`, commas; cast DECIMAL(14,2); **reject negatives** |
| `discount_pct` | Values arrive as both `0.15` and `15` → normalised to fraction, validated 0–1 |
| `vat_rate` | Joined from `seeds/vat_rates.csv` by effective date — **not taken from source** (source was wrong for 2023 records) |
| `line_total_ngn` | **Recalculated, not trusted** — source totals disagreed with quantity × price in ~3% of rows |

**Tests:** `unique(line_id)` · `not_null(wo_number, line_type)` ·
custom: `line_total = round(quantity * unit_price * (1 - discount_pct) * (1 + vat_rate), 2)`

---

### 2.3 CUSTOMERS  (`customers`)

| Field | Cleaning / fix applied |
|-------|------------------------|
| `customer_id` | Trim; uppercase; legacy ID mapping applied |
| `customer_name` | Trim; collapse whitespace; title case; **entity resolution applied** (see below) |
| `customer_type` | Normalised to `individual` / `fleet` / `corporate` / `insurance` |
| `phone_primary` | Strip spaces, hyphens, parentheses; **normalise Nigerian numbers to E.164** (`0803...` → `+234803...`) |
| `email` | Lowercase; trim; validate format; invalid → NULL + flagged |
| `address_city` | Trim; title case; map spelling variants (`Lag`, `LAGOS`, `Lagos State` → `Lagos`) |
| `registration_date` | Multi-format parse → DATE |
| `is_active` | Derived: any work order in last 24 months |

**Entity resolution (the big one)**
The source contains duplicate customers entered at different times.
Resolution runs in three passes:

1. **Exact match** — normalised phone OR normalised email
2. **Fuzzy match** — Levenshtein distance ≤ 2 on normalised name AND same city
3. **Review queue** — probable matches below threshold written to
   `quarantine.customer_match_review` for human decision

A `golden_customer_id` is assigned per cluster; original IDs are preserved
in `int_customer_id_mapping` — **duplicates are linked, never deleted.**

---

### 2.4 VEHICLES  (`vehicles`)

| Field | Cleaning / fix applied |
|-------|------------------------|
| `vin` | Uppercase; strip separators; validate 17 chars; check digit validation |
| `plate_number` | Uppercase; strip spaces and hyphens; Nigerian plate format validation |
| `make` | Normalised via `seeds/vehicle_make_aliases.csv` (`TOYOTA`, `Toyota Motors`, `toyota` → `Toyota`) |
| `model` | Trim; title case; alias mapping |
| `year_manufactured` | Cast INTEGER; **reject < 1950 or > current year + 1** |
| `engine_type` | Normalised to `petrol` / `diesel` / `hybrid` / `electric` |
| `transmission` | Normalised to `manual` / `automatic` / `cvt` |
| `first_service_date` | Derived from earliest work order, not source |

**SCD Type 2** applied — a vehicle changing owner creates a new row with
`valid_from` / `valid_to` / `is_current`, so historical jobs stay attributed
to the correct owner at the time of service.

---

### 2.5 PARTS & INVENTORY  (`parts`, `stock_movements`)

| Field | Cleaning / fix applied |
|-------|------------------------|
| `part_number` | Uppercase; strip separators; supplier alias mapping |
| `part_description` | Trim; collapse whitespace; sentence case |
| `category` | Mapped to controlled hierarchy: `category` → `subcategory` |
| `unit_cost_ngn` | Currency symbols stripped; **FX-converted where supplier prices in USD/EUR** using rate effective on transaction date, not today's rate |
| `qty_on_hand` | Cast INTEGER; negatives permitted (backorder) but **flagged for review** |
| `reorder_point` | NULL → defaulted to 30-day average consumption |
| `movement_type` | Normalised to `receipt` / `issue` / `return` / `adjustment` / `writeoff` |
| `movement_qty` | **Sign convention enforced**: receipts positive, issues negative (source was inconsistent per warehouse) |
| `supplier_id` | Trim; uppercase; deduplicated via supplier entity resolution |

**Reconciliation test:** `sum(movement_qty)` per part must equal
`qty_on_hand` in the ERP snapshot. Divergence > 2 units triggers an alert.

---

### 2.6 INVOICES & PAYMENTS  (`invoices`, `payments`)

| Field | Cleaning / fix applied |
|-------|------------------------|
| `invoice_number` | Trim; uppercase; normalise prefix variants |
| `invoice_date` | Multi-format parse → DATE (UTC) |
| `subtotal_ngn` / `vat_ngn` / `total_ngn` | Currency stripped; **totals recalculated and reconciled against work order lines** |
| `currency` | Defaulted to `NGN`; USD/EUR invoices converted using date-effective FX |
| `payment_method` | Normalised to `cash` / `card` / `transfer` / `insurance` / `credit` |
| `payment_status` | Normalised to `unpaid` / `partial` / `paid` / `written_off` |
| `amount_paid_ngn` | Summed from payments; **not trusted from invoice header** |
| `days_outstanding` | Derived: `current_date - invoice_date` where unpaid |

**Test:** every invoice must reconcile to its work order lines within ₦1.00.

---

### 2.7 TECHNICIANS  (`technicians`)

| Field | Cleaning / fix applied |
|-------|------------------------|
| `technician_id` | Trim; uppercase |
| `technician_name` | Trim; title case |
| `skill_level` | Normalised to `apprentice` / `junior` / `senior` / `master` |
| `specialisation` | Mapped to controlled list; multi-value split into bridge table |
| `hire_date` | Multi-format parse → DATE |
| `hourly_rate_ngn` | Currency stripped; **rate effective-dated** — historical jobs costed at the rate in force at the time |
| `is_active` | Derived from work order activity in last 90 days |

> **Note:** no personal, medical or disciplinary data is ingested. The platform
> stores only what is needed for scheduling and job costing.

---

### 2.8 TELEMATICS EVENTS  (`telematics_events`)

| Field | Cleaning / fix applied |
|-------|------------------------|
| `event_id` | UUID from source; deduplicated (at-least-once delivery produces repeats) |
| `vin` | Uppercase; validated; unmatched VINs quarantined |
| `event_timestamp` | Epoch ms → TIMESTAMP UTC; **late-arriving events tolerated via 3-day reprocessing window** |
| `odometer_km` | Cast INTEGER; **monotonic check** — a reading lower than the previous one for the same VIN is flagged, not loaded |
| `fault_code` | Uppercase; trim; mapped to description via `seeds/obd_fault_codes.csv` |
| `latitude` / `longitude` | Cast DECIMAL; **out-of-Nigeria coordinates flagged**; GPS not exposed in any mart |
| `ingested_at` | Added at ingestion — used for SLA monitoring, distinct from `event_timestamp` |

---

### 2.9 REFERENCE / SEED DATA

Small, version-controlled CSVs that live in Git, not in a source system.

| Seed file | Purpose |
|-----------|---------|
| `service_type_codes.csv` | Service code → description, standard hours, category |
| `vat_rates.csv` | Date-effective VAT rates |
| `fx_rates.csv` | Date-effective NGN/USD/EUR rates |
| `part_number_aliases.csv` | Supplier part number → canonical part number |
| `vehicle_make_aliases.csv` | Make/model spelling normalisation |
| `customer_id_migration.csv` | Legacy pre-2019 customer ID mapping |
| `obd_fault_codes.csv` | Fault code → human-readable description |
| `bay_capacity.csv` | Workshop bay → capacity and equipment |

---

## 3. GOLD LAYER — BUSINESS MARTS

| Mart | Grain | Key metrics | Status |
|------|-------|-------------|--------|
| `fct_work_orders` | 1 per work order | parts_cost, labour_cost, revenue, gross_profit, cycle_time_hours | ✅ built |
| `mart_service_profitability` | service_type × month | revenue, cost, margin_pct, job_count, avg_cycle_time | ✅ built |
| `mart_technician_performance` | technician × month | jobs_completed, avg_cycle_time, rework_rate, billable_utilisation | 🔜 planned |
| `mart_inventory_health` | part × day | qty_on_hand, days_cover, stockout_risk_flag, reorder_due | 🔜 planned |
| `mart_customer_retention` | customer | last_service_date, days_since_service, lifetime_revenue, churn_risk_band | 🔜 planned |
| `mart_vehicle_reliability` | make × model × year | repeat_repair_rate, avg_repairs_per_vehicle, top_fault_codes | 🔜 planned |
| `mart_job_costing` | 1 per work order | fully-loaded cost incl. bay time, technician rate, parts, sublet | 🔜 planned (`fct_work_orders` already covers parts + labour cost) |
| `mart_daily_operations` | day | jobs_opened, jobs_closed, bay_utilisation, revenue, wip_value | 🔜 planned |

`fct_work_orders` and `mart_service_profitability` are real, tested dbt
models in `dbt_project/models/marts/`. Everything else in this section is
target design, not yet built.

**Metric definitions are declared once** in dbt so every dashboard, export
and ad-hoc query returns the same number.

---

## 4. QUARANTINE & EXCEPTION HANDLING

Bad records are never silently dropped. Each lands in a quarantine table
with the reason, awaiting review.

| Quarantine table | Catches |
|------------------|---------|
| `quarantine.invalid_vin` | VINs failing length or check-digit validation |
| `quarantine.orphan_work_orders` | Work orders with no matching customer or vehicle |
| `quarantine.line_total_mismatch` | Invoice lines where recalculated total ≠ source total |
| `quarantine.odometer_regression` | Readings lower than the prior reading for the same VIN |
| `quarantine.customer_match_review` | Probable duplicate customers below auto-merge threshold |
| `quarantine.unknown_service_code` | Service codes not present in the seed reference |
| `quarantine.negative_stock` | Stock movements producing impossible balances |

A daily summary of quarantine volumes is delivered with the morning refresh.
Rising quarantine counts are an early warning that something upstream changed.

---

## 5. PIPELINE STAGE SUMMARY

| Stage | What happens | What never happens |
|-------|--------------|--------------------|
| 🥉 **Bronze** | Land raw data exactly as received, partitioned by ingest date | No cleaning, no joins, no filtering, no type casting |
| 🥈 **Silver** | Rename, cast types, normalise values, deduplicate, quarantine invalid rows | No joins across sources, no aggregation, no business logic |
| 🔗 **Intermediate** | Join sources, apply business rules, entity resolution, enrichment | No presentation formatting |
| 🥇 **Gold** | Aggregate, calculate metrics, apply agreed definitions, optimise for query | No source-system naming, no unresolved duplicates |

---

*All data in this repository is synthetically generated. No real customer,
vehicle, employee or financial records are present.*
