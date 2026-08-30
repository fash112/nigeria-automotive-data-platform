"""
Complete synthetic source data generator — all entities.

Generates realistic, deliberately messy data for every entity in the data
catalog, so the staging layer's cleaning rules have real work to do.

Entities produced:
    CRM        : customers, vehicles
    DMS        : work_orders (CDC stream), work_order_lines, technicians
    ERP        : parts, stock_movements, suppliers
    POS        : invoices, payments
    Telematics : events

No real data of any kind is used.

Usage:
    python data_generator/generate_all.py --months 24 --customers 1200
"""

import argparse
import random
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd
from faker import Faker

fake = Faker()
Faker.seed(42)
random.seed(42)

# ─────────────────────────── reference data ───────────────────────────

MAKES = {
    "Toyota": ["Corolla", "Camry", "Hilux", "RAV4", "Highlander", "Sienna"],
    "Honda": ["Accord", "Civic", "CR-V", "Pilot"],
    "Mercedes-Benz": ["C-Class", "E-Class", "GLK", "ML350"],
    "Lexus": ["RX 350", "ES 350", "GX 460"],
    "Nissan": ["Almera", "X-Trail", "Pathfinder"],
    "Hyundai": ["Elantra", "Tucson", "Santa Fe"],
    "Kia": ["Rio", "Sportage", "Sorento"],
}

MAKE_VARIANTS = {
    "Toyota": ["Toyota", "TOYOTA", "toyota", "Toyota Motors"],
    "Honda": ["Honda", "HONDA", "honda"],
    "Mercedes-Benz": ["Mercedes-Benz", "MERCEDES", "MERC", "MERCEDES BENZ"],
    "Lexus": ["Lexus", "LEXUS", "lexus"],
    "Nissan": ["Nissan", "NISSAN", "nissan"],
    "Hyundai": ["Hyundai", "HYUNDAI"],
    "Kia": ["Kia", "KIA"],
}

SERVICE_CODES = {
    "SVC-MIN": ("Minor service", 1.5),
    "SVC-MAJ": ("Major service", 4.0),
    "BRK-PAD": ("Brake pad replacement", 1.5),
    "BRK-DSC": ("Brake disc replacement", 2.5),
    "ENG-DIA": ("Engine diagnostics", 1.0),
    "ENG-OVH": ("Engine overhaul", 24.0),
    "SUS-SHK": ("Shock absorber replacement", 3.0),
    "ELE-BAT": ("Battery replacement", 0.5),
    "ELE-ALT": ("Alternator replacement", 3.0),
    "AC-REG": ("AC regas", 1.0),
    "TYR-FIT": ("Tyre fitting", 0.75),
    "BDY-PNT": ("Body panel respray", 8.0),
}

PARTS_CATALOG = [
    ("BRK-PAD-TOY-001", "Brake pad set front - Toyota", "Brakes", "Pads", 18500),
    ("BRK-PAD-HON-001", "Brake pad set front - Honda", "Brakes", "Pads", 19200),
    ("BRK-DSC-TOY-001", "Brake disc front - Toyota", "Brakes", "Discs", 34000),
    ("FLT-OIL-001", "Engine oil filter - universal", "Filters", "Oil", 4200),
    ("FLT-AIR-001", "Air filter - Toyota Corolla", "Filters", "Air", 6800),
    ("FLT-CAB-001", "Cabin filter - universal", "Filters", "Cabin", 5400),
    ("OIL-5W30-4L", "Engine oil 5W-30 fully synthetic 4L", "Fluids", "Oil", 28500),
    ("OIL-10W40-4L", "Engine oil 10W-40 semi synthetic 4L", "Fluids", "Oil", 21000),
    ("BAT-70AH-001", "Battery 70Ah maintenance free", "Electrical", "Battery", 78000),
    ("BAT-100AH-001", "Battery 100Ah heavy duty", "Electrical", "Battery", 112000),
    ("ALT-TOY-001", "Alternator - Toyota Corolla", "Electrical", "Alternator", 145000),
    ("SPK-PLG-4PK", "Spark plug set of 4 iridium", "Engine", "Ignition", 24000),
    ("SHK-ABS-FRT", "Shock absorber front pair", "Suspension", "Shocks", 96000),
    ("SHK-ABS-RR", "Shock absorber rear pair", "Suspension", "Shocks", 88000),
    ("TYR-195-65-15", "Tyre 195/65 R15", "Tyres", "Tyre", 62000),
    ("TYR-225-60-17", "Tyre 225/60 R17", "Tyres", "Tyre", 94000),
    ("AC-GAS-R134A", "AC refrigerant R134a 1kg", "Climate", "Refrigerant", 15500),
    ("WPR-BLD-PR", "Wiper blade pair", "Body", "Wipers", 9800),
    ("CLT-KIT-001", "Clutch kit - Toyota", "Transmission", "Clutch", 178000),
    ("RAD-TOY-001", "Radiator - Toyota Corolla", "Cooling", "Radiator", 86000),
    ("BLT-TIM-001", "Timing belt kit", "Engine", "Belts", 54000),
    ("SNS-O2-001", "Oxygen sensor", "Engine", "Sensors", 42000),
]

FAULT_CODES = ["P0300", "P0171", "P0420", "P0128", "P0442",
               "P0455", "P0301", "P0011", "C1201", "B1318"]

CITIES = ["Lagos", "LAGOS", "Lag", "Lagos State", "Ibadan", "Abeokuta", "Abuja"]
STATUS_RAW = ["1", "OPEN", "2", "IN PROGRESS", "3", "AWAITING PARTS",
              "4", "COMPLETED", "CLOSED", "5", "CANCELLED"]
WO_PREFIXES = ["WO-", "WO", "W/O ", "wo-"]
VAT_RATE = 0.075


# ─────────────────────────── messiness helpers ───────────────────────────

def messy_date(dt):
    style = random.choice(["iso", "eu", "epoch"])
    if style == "iso":
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    if style == "eu":
        return dt.strftime("%d/%m/%Y")
    return str(int(dt.timestamp() * 1000))


def messy_number(value, unit=""):
    style = random.choice(["plain", "unit", "sep", "comma"])
    if style == "plain":
        return str(value)
    if style == "unit":
        return f"{value}{unit}"
    if style == "sep":
        return f"{value:,.0f}{unit}"
    return str(value).replace(".", ",")


def messy_money(value):
    style = random.choice(["plain", "symbol", "sep", "code"])
    if style == "plain":
        return f"{value:.2f}"
    if style == "symbol":
        return f"NGN{value:,.2f}"
    if style == "sep":
        return f"{value:,.2f}"
    return f"NGN {value:.2f}"


def clean_money(s):
    try:
        return float(str(s).replace("NGN", "").replace(",", "").strip())
    except ValueError:
        return 0.0


def make_vin(valid=True):
    chars = "ABCDEFGHJKLMNPRSTUVWXYZ0123456789"
    n = 17 if valid else random.choice([15, 16, 18])
    return "".join(random.choice(chars) for _ in range(n))


# ─────────────────────────── generators ───────────────────────────

def gen_suppliers(n=25):
    return pd.DataFrame([{
        "supplier_id": f"SUP{i+1:04d}",
        "supplier_name": fake.company(),
        "contact_phone": f"0{random.choice([70,80,81,90])}{random.randint(10**7,10**8-1)}",
        "contact_email": fake.company_email(),
        "city": random.choice(CITIES),
        "lead_time_days": random.choice(["3", "5", "7", "14", "7 days"]),
        "payment_terms": random.choice(["NET30", "net 30", "NET60", "COD"]),
        "is_active": random.choice(["Y", "N", "1", "TRUE"]),
    } for i in range(n)])


def gen_technicians(n=18):
    return pd.DataFrame([{
        "technician_id": f"TECH{i+1:03d}",
        "technician_name": fake.name(),
        "skill_level": random.choice(["apprentice", "APPRENTICE", "junior",
                                      "Junior", "senior", "SENIOR", "master"]),
        "specialisation": random.choice(
            ["engine", "ENGINE", "brakes;suspension", "electrical",
             "bodywork", "engine;transmission", "general"]),
        "hire_date": messy_date(fake.date_time_between("-12y", "-6m")),
        "hourly_rate_ngn": messy_money(random.choice([2500, 3500, 5000, 7500, 9000])),
        "is_active": random.choice(["Y", "Y", "Y", "N", "1"]),
    } for i in range(n)])


def gen_parts():
    rows = []
    for pn, desc, cat, subcat, cost in PARTS_CATALOG:
        variant = random.choice([pn, pn.replace("-", ""), pn.lower(), f" {pn} "])
        rows.append({
            "part_number": variant,
            "part_description": desc,
            "category": cat,
            "subcategory": subcat,
            "unit_cost_ngn": messy_money(cost),
            "unit_price_ngn": messy_money(round(cost * random.uniform(1.25, 1.65), 2)),
            "supplier_id": f"SUP{random.randint(1,25):04d}",
            "qty_on_hand": str(random.randint(-2, 180)),
            "reorder_point": random.choice([str(random.randint(5, 40)), "", "N/A"]),
            "currency": random.choice(["NGN", "NGN", "NGN", "USD"]),
        })
    return pd.DataFrame(rows)


def gen_customers(n):
    rows = []
    for i in range(n):
        name = fake.name()
        digits = f"0{random.choice([70,80,81,90,91])}{random.randint(10**7,10**8-1)}"
        phone = random.choice([digits, f"+234{digits[1:]}",
                               f"{digits[:4]} {digits[4:7]} {digits[7:]}"])
        email = fake.email() if random.random() > 0.15 else random.choice(["", "n/a", "notanemail"])
        rows.append({
            "customer_id": f"CUST{i+1:05d}",
            "customer_name": name,
            "customer_type": random.choice(["individual", "INDIVIDUAL", "fleet",
                                            "corporate", "insurance"]),
            "phone_primary": phone,
            "email": email,
            "address_city": random.choice(CITIES),
            "registration_date": messy_date(fake.date_time_between("-6y", "-1y")),
        })
        # ~8% duplicated with slight differences — for entity resolution
        if random.random() < 0.08:
            rows.append({
                "customer_id": f"CUST{n+i+1:05d}",
                "customer_name": name.upper() if random.random() > 0.5 else name.replace(" ", "  "),
                "customer_type": "individual",
                "phone_primary": phone,
                "email": email,
                "address_city": random.choice(CITIES),
                "registration_date": messy_date(fake.date_time_between("-6y", "-1y")),
            })
    return pd.DataFrame(rows)


def gen_vehicles(customers):
    rows = []
    for _, c in customers.iterrows():
        for _ in range(random.choice([1, 1, 1, 2])):
            make = random.choice(list(MAKES))
            rows.append({
                "vin": make_vin(valid=random.random() > 0.03),
                "plate_number": f"{fake.lexify('???').upper()}-{random.randint(100,999)}{fake.lexify('??').upper()}",
                "customer_id": c["customer_id"],
                "make": random.choice(MAKE_VARIANTS[make]),
                "model": random.choice(MAKES[make]),
                "year_manufactured": random.choice([str(random.randint(2005, 2024))] * 9 + ["1899"]),
                "engine_type": random.choice(["petrol", "PETROL", "diesel", "Diesel", "hybrid"]),
                "transmission": random.choice(["automatic", "AUTOMATIC", "manual", "Manual", "cvt"]),
                "colour": fake.color_name(),
            })
    return pd.DataFrame(rows)


def gen_work_orders(vehicles, months):
    rows, index = [], []
    start = datetime.now() - timedelta(days=months * 30)
    seq = 1
    for _ in range(months * 380):
        v = vehicles.sample(1).iloc[0]
        opened = fake.date_time_between(start_date=start, end_date="now")
        is_closed = random.random() > 0.12
        closed = opened + timedelta(hours=random.randint(2, 120)) if is_closed else None
        code = random.choice(list(SERVICE_CODES))
        tech = random.choice([f"TECH{random.randint(1,18):03d}"] * 8 + ["UNASSIGNED", "", "N/A"])
        clean_wo = f"WO-{seq:06d}"

        index.append({"wo_number": clean_wo, "customer_id": v["customer_id"],
                      "vin": v["vin"], "opened": opened, "closed": closed,
                      "code": code, "tech": tech, "is_closed": is_closed})

        base = {
            "wo_number": f"{random.choice(WO_PREFIXES)}{seq:06d}",
            "customer_id": v["customer_id"],
            "vehicle_vin": v["vin"],
            "date_opened": messy_date(opened),
            "date_closed": messy_date(closed) if closed else "1900-01-01",
            "status": random.choice(STATUS_RAW[6:]) if is_closed else random.choice(STATUS_RAW[:6]),
            "service_type_code": random.choice([code, code.lower(), f" {code} "]),
            "technician_id": tech,
            "bay_id": f"BAY{random.randint(1,12):02d}",
            "odometer_reading": messy_number(random.randint(15000, 320000), " km")
                if random.random() > 0.02 else str(random.choice([-500, 9999999])),
            "labour_hours": messy_number(round(random.uniform(0.5, 12), 1), " hrs")
                if random.random() > 0.01 else "31.5",
            "customer_complaint": fake.sentence(nb_words=random.randint(5, 14)),
            "is_warranty": random.choice(["Y", "N", "1", "0", "TRUE", "false", "yes"]),
        }
        for i in range(random.choice([1, 1, 2, 3])):
            r = base.copy()
            r["cdc_operation"] = "I" if i == 0 else "U"
            r["cdc_timestamp"] = (opened + timedelta(hours=i * 6)).strftime("%Y-%m-%d %H:%M:%S")
            r["_ingested_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            rows.append(r)
        seq += 1
    return pd.DataFrame(rows), index


def gen_work_order_lines(index, parts):
    rows = []
    pns = parts["part_number"].str.strip().tolist()
    prices = dict(zip(parts["part_number"].str.strip(),
                      [clean_money(p) for p in parts["unit_price_ngn"]]))
    for wo in index:
        n = 1
        std = SERVICE_CODES[wo["code"]][1]
        rate = random.choice([2500, 3500, 5000, 7500, 9000])
        hours = round(std * random.uniform(0.7, 1.4), 2)
        rows.append({
            "wo_number": wo["wo_number"], "line_no": str(n),
            "line_type": random.choice(["labour", "LABOUR", "Labour"]),
            "part_number": "", "description": SERVICE_CODES[wo["code"]][0],
            "quantity": messy_number(hours), "unit_price_ngn": messy_money(rate),
            "discount_pct": random.choice(["0", "0.05", "5", "0.1", "10"]),
            "vat_rate": random.choice([str(VAT_RATE), "0.05", ""]),
            "line_total_ngn": messy_money(round(hours * rate * (1 + VAT_RATE), 2)),
        })
        n += 1
        for _ in range(random.randint(0, 4)):
            pn = random.choice(pns)
            qty = random.randint(1, 4)
            price = prices.get(pn, 20000)
            disc = random.choice([0, 0, 0.05, 0.1])
            total = round(qty * price * (1 - disc) * (1 + VAT_RATE), 2)
            if random.random() < 0.03:          # ~3% of source totals are wrong
                total = round(total * random.uniform(0.8, 1.2), 2)
            rows.append({
                "wo_number": wo["wo_number"], "line_no": str(n),
                "line_type": random.choice(["part", "PART", "Part"]),
                "part_number": pn, "description": "",
                "quantity": str(qty), "unit_price_ngn": messy_money(price),
                "discount_pct": str(disc if random.random() > 0.5 else disc * 100),
                "vat_rate": str(VAT_RATE), "line_total_ngn": messy_money(total),
            })
            n += 1
    return pd.DataFrame(rows)


def gen_invoices_payments(index, lines):
    totals = {}
    for wo, grp in lines.groupby("wo_number"):
        totals[wo] = sum(clean_money(x) for x in grp["line_total_ngn"])

    inv, pay, seq = [], [], 1
    for wo in index:
        if not wo["is_closed"]:
            continue
        total = totals.get(wo["wo_number"], 0)
        if total <= 0:
            continue
        subtotal = round(total / (1 + VAT_RATE), 2)
        inv_no = f"INV-{seq:06d}"
        status = random.choices(
            ["paid", "PAID", "partial", "unpaid", "UNPAID", "written_off"],
            weights=[45, 20, 12, 12, 8, 3])[0]
        inv.append({
            "invoice_number": inv_no, "wo_number": wo["wo_number"],
            "customer_id": wo["customer_id"], "invoice_date": messy_date(wo["closed"]),
            "subtotal_ngn": messy_money(subtotal),
            "vat_ngn": messy_money(round(total - subtotal, 2)),
            "total_ngn": messy_money(total),
            "currency": random.choice(["NGN"] * 9 + ["ngn"]),
            "payment_status": status,
        })
        if status.lower() in ("paid", "partial"):
            paid = total if status.lower() == "paid" else round(total * random.uniform(0.3, 0.8), 2)
            pay.append({
                "payment_id": f"PAY-{seq:06d}", "invoice_number": inv_no,
                "payment_date": messy_date(wo["closed"] + timedelta(days=random.randint(0, 45))),
                "amount_ngn": messy_money(paid),
                "payment_method": random.choice(["cash", "CASH", "transfer",
                                                 "TRANSFER", "card", "insurance", "credit"]),
            })
        seq += 1
    return pd.DataFrame(inv), pd.DataFrame(pay)


def gen_stock_movements(index, lines, parts):
    rows, seq = [], 1
    dates = {w["wo_number"]: w["opened"] for w in index}
    part_lines = lines[lines["line_type"].str.lower() == "part"]
    for _, l in part_lines.iterrows():
        rows.append({
            "movement_id": f"MOV{seq:07d}", "part_number": l["part_number"],
            "movement_type": random.choice(["issue", "ISSUE", "Issue"]),
            "movement_qty": random.choice([f"-{l['quantity']}", str(l["quantity"])]),
            "movement_date": messy_date(dates.get(l["wo_number"], datetime.now())),
            "reference": l["wo_number"],
            "warehouse": random.choice(["MAIN", "main", "WH-01"]),
        })
        seq += 1
    for pn in parts["part_number"].str.strip():
        for _ in range(random.randint(3, 12)):
            rows.append({
                "movement_id": f"MOV{seq:07d}", "part_number": pn,
                "movement_type": random.choice(["receipt", "RECEIPT", "Receipt"]),
                "movement_qty": str(random.randint(5, 60)),
                "movement_date": messy_date(fake.date_time_between("-2y", "now")),
                "reference": f"PO-{random.randint(1000,9999)}",
                "warehouse": random.choice(["MAIN", "WH-01"]),
            })
            seq += 1
    return pd.DataFrame(rows)


def gen_telematics(vehicles, n_events):
    fleet = vehicles.sample(min(len(vehicles), 200))
    rows = []
    for _ in range(n_events):
        v = fleet.sample(1).iloc[0]
        dt = fake.date_time_between("-6m", "now")
        rows.append({
            "event_id": fake.uuid4(), "vin": v["vin"],
            "event_timestamp": str(int(dt.timestamp() * 1000)),
            "odometer_km": str(random.randint(15000, 320000)),
            "fault_code": random.choice(FAULT_CODES + ["", "", ""]),
            "latitude": str(round(random.uniform(6.3, 6.7), 6)),
            "longitude": str(round(random.uniform(3.2, 3.6), 6)),
            "_ingested_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        })
    return pd.DataFrame(rows)


# ─────────────────────────── main ───────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--months", type=int, default=24)
    ap.add_argument("--customers", type=int, default=1200)
    ap.add_argument("--out", type=str, default="data/raw")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    written = {}

    def write(name, df):
        df.to_csv(out / f"{name}.csv", index=False)
        written[name] = len(df)
        print(f"  {name:<28} {len(df):>9,} rows")

    print("\nGenerating source data...\n")

    write("erp_suppliers", gen_suppliers())
    write("dms_technicians", gen_technicians())
    parts = gen_parts()
    write("erp_parts", parts)
    customers = gen_customers(args.customers)
    write("crm_customers", customers)
    vehicles = gen_vehicles(customers)
    write("crm_vehicles", vehicles)

    work_orders, index = gen_work_orders(vehicles, args.months)
    write("dms_work_orders", work_orders)

    lines = gen_work_order_lines(index, parts)
    write("dms_work_order_lines", lines)

    invoices, payments = gen_invoices_payments(index, lines)
    write("pos_invoices", invoices)
    write("pos_payments", payments)

    write("erp_stock_movements", gen_stock_movements(index, lines, parts))
    write("telematics_events", gen_telematics(vehicles, args.months * 600))

    print(f"\n  {'TOTAL':<28} {sum(written.values()):>9,} rows")
    print(f"\nWritten to: {out.resolve()}\n")


if __name__ == "__main__":
    main()
