"""
Dirty PBM data generator (synthetic, no real PHI).

Writes one daily "load" of raw files the way a PBM receives them:
  data/raw/eligibility/load_date=YYYY-MM-DD/eligibility.csv        (834-style roster, flattened)
  data/raw/pharmacy_claims/load_date=YYYY-MM-DD/claims.csv         (NCPDP-style transactions: B1 / B2 / B3)
  data/raw/drug_reference/load_date=YYYY-MM-DD/ndc_master.csv      (Medi-Span-style drug file)
  data/raw/providers/load_date=YYYY-MM-DD/npi_registry.csv         (NPPES-style pharmacies + prescribers)
  data/raw/rebates/load_date=YYYY-MM-DD/rebate_invoices.csv        (manufacturer rebates by NDC and quarter)
  data/raw/_manifest/load_date=YYYY-MM-DD/defects.json             (every defect injected, with counts and example keys)

Defects are injected on purpose so the dbt tests you write can prove they catch each one.
Standard library only, deterministic for a given --seed and --load-date.

Usage:
  python generator/generate_pbm_data.py --load-date 2026-09-30
  python generator/generate_pbm_data.py --load-date 2026-10-01 --late-reversals --claims 3000 --window-days 3   (Class 3)

Later loads (when an earlier eligibility load exists) behave like a full-file 834 feed that evolves:
  - the roster starts from the previous load's current state (unchanged members are re-sent as 030 audit records)
  - retro plan changes (001), retro terminations (024), new adds (021),
    and late eligibility for cardholders that were orphans in the previous claims file
"""
import argparse
import csv
import json
import random
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"

CLIENTS = [("CL001", "Acme Logistics"), ("CL002", "Blue Ridge Foods"), ("CL003", "Northstar Tech")]
PLANS = ["PPO_RX_A", "PPO_RX_B", "HDHP_RX"]
FIRST = ["James", "Mary", "Robert", "Patricia", "John", "Jennifer", "Michael", "Linda", "David", "Elizabeth",
         "Arjun", "Priya", "Wei", "Mei", "Carlos", "Sofia", "Ahmed", "Fatima", "Olu", "Grace"]
LAST = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Patel", "Kumar",
        "Nguyen", "Chen", "Lopez", "Wilson", "Anderson", "Thomas", "Moore", "Okafor", "Khan", "Rossi"]
STATES = ["VA", "MD", "NC", "TX", "GA", "NY"]

# (drug_name, gpi14, multi_source_code, is_specialty, awp_unit_price, labeler)
DRUGS = [
    ("Atorvastatin 20 MG Tablet", "39400010100320", "Y", False, 0.45, "Greenfield Generics"),
    ("Lisinopril 10 MG Tablet", "36100030000310", "Y", False, 0.30, "Greenfield Generics"),
    ("Metformin 500 MG Tablet", "27250050000320", "Y", False, 0.25, "Riverbend Pharma"),
    ("Amlodipine 5 MG Tablet", "34000003000310", "Y", False, 0.28, "Riverbend Pharma"),
    ("Levothyroxine 50 MCG Tablet", "28100010100315", "Y", False, 0.55, "Greenfield Generics"),
    ("Sertraline 50 MG Tablet", "58160070100320", "Y", False, 0.40, "Coastal Labs"),
    ("Omeprazole 20 MG Capsule", "49270060006520", "Y", False, 0.60, "Coastal Labs"),
    ("Brandastatin 20 MG Tablet", "39400010100322", "O", False, 9.80, "Summit Brands"),
    ("Eliquis-like 5 MG Tablet", "83370010000330", "N", False, 9.50, "Summit Brands"),
    ("Jardiance-like 10 MG Tablet", "27700050000310", "N", False, 21.00, "Summit Brands"),
    ("Semaglutide-like 1 MG Pen", "27170070002020", "N", True, 1100.00, "Northline Bio"),
    ("Tirzepatide-like 5 MG Pen", "27175080002020", "N", True, 1150.00, "Northline Bio"),
    ("Adalimumab-like 40 MG Pen", "66270015002020", "N", True, 3400.00, "Northline Bio"),
    ("Adalimumab-biosim 40 MG Pen", "66270015002025", "M", True, 1300.00, "Coastal Labs"),
]


def luhn_npi_check_digit(first9: str) -> str:
    """NPI check digit: Luhn over '80840' + first 9 digits."""
    digits = [int(d) for d in "80840" + first9]
    total = 0
    for i, d in enumerate(reversed(digits)):
        if i % 2 == 0:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return str((10 - total % 10) % 10)


def make_npi(rng, prefix: str) -> str:
    first9 = prefix + "".join(str(rng.randint(0, 9)) for _ in range(9 - len(prefix)))
    return first9 + luhn_npi_check_digit(first9)


def bad_npi(rng, prefix: str) -> str:
    good = make_npi(rng, prefix)
    return good[:-1] + str((int(good[-1]) + rng.randint(1, 9)) % 10)


def ndc11(rng) -> str:
    return f"{rng.randint(10000, 99999)}{rng.randint(0, 9999):04d}{rng.randint(0, 99):02d}"


def ndc_as_10_digit(ndc: str, rng) -> str:
    """Render an 11-digit 5-4-2 NDC the way it appears on packages (10 digits, hyphenated)."""
    labeler, product, package = ndc[:5], ndc[5:9], ndc[9:]
    style = rng.choice(["4-4-2", "5-3-2", "5-4-1"])
    if style == "4-4-2" and labeler.startswith("0"):
        return f"{labeler[1:]}-{product}-{package}"
    if style == "5-3-2" and product.startswith("0"):
        return f"{labeler}-{product[1:]}-{package}"
    if style == "5-4-1" and package.startswith("0"):
        return f"{labeler}-{product}-{package[1:]}"
    return f"{labeler}-{product}-{package}"  # 5-4-2 with hyphens


def money(x: float) -> str:
    return f"{x:.2f}"


def write_csv(path: Path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)


def evolve_eligibility(prev_dir: Path, load_date: date, loaded_at: datetime, rng, n_base_members: int, flag):
    """Next full-file 834 roster: the previous load's current state plus this load's business changes."""
    with (prev_dir / "eligibility.csv").open() as f:
        prev_rows = list(csv.DictReader(f))
    state = {}
    for r in sorted(prev_rows, key=lambda r: r["file_loaded_at"]):  # latest record per member wins
        state[(r["cardholder_id"], r["person_code"])] = dict(r, maintenance_type_code="030", file_loaded_at=loaded_at.isoformat())

    active = sorted(k for k, r in state.items() if r["coverage_end_date"] == "" and r["coverage_start_date"] <= load_date.isoformat())
    changed = rng.sample(active, 40)
    for k in changed[:25]:  # retro plan change, effective 16 days before the file arrives
        r = state[k]
        eff = (load_date - timedelta(days=16)).isoformat()
        r.update(plan_id=rng.choice([p for p in PLANS if p != r["plan_id"]]), maintenance_type_code="001", maintenance_effective_date=eff)
        flag("retro_plan_change", "-".join(k), "eligibility", f"Plan change (001) effective {eff}, received {load_date}")
    for k in changed[25:]:  # retro termination, effective 11 days before the file arrives
        r = state[k]
        end = (load_date - timedelta(days=11)).isoformat()
        r.update(coverage_end_date=end, maintenance_type_code="024", maintenance_effective_date=end)
        flag("retro_termination", "-".join(k), "eligibility", f"Termination (024) effective {end}, received {load_date}")

    def new_member(cardholder, person_code, start):
        client_id, _ = CLIENTS[rng.randrange(len(CLIENTS))]
        return {"cardholder_id": cardholder, "person_code": person_code, "relationship_code": "18",
                "first_name": rng.choice(FIRST), "last_name": rng.choice(LAST),
                "date_of_birth": date(rng.randint(1950, 2005), rng.randint(1, 12), rng.randint(1, 28)).isoformat(),
                "gender": rng.choice(["M", "F"]), "zip_code": f"{rng.randint(20000, 29999)}", "client_id": client_id,
                "group_id": f"{client_id}-G1", "plan_id": rng.choice(PLANS), "coverage_start_date": start,
                "coverage_end_date": "", "maintenance_type_code": "021", "maintenance_effective_date": start,
                "file_loaded_at": loaded_at.isoformat()}

    next_id = 100000 + n_base_members + sum(1 for ch, _ in state if ch.startswith("RW1") and int(ch[2:]) >= 100000 + n_base_members)
    for i in range(30):  # brand-new members starting on the load date
        r = new_member(f"RW{next_id + i}", "01", load_date.isoformat())
        state[(r["cardholder_id"], "01")] = r
        flag("new_member_add", f"{r['cardholder_id']}-01", "eligibility", "New member (021) starting on the load date")

    prev_claims = prev_dir.parent.parent / "pharmacy_claims" / prev_dir.name / "claims.csv"
    if prev_claims.exists():  # eligibility finally arrives for members whose claims were orphans last load
        with prev_claims.open() as f:
            orphans = sorted({(r["cardholder_id"], r["person_code"]) for r in csv.DictReader(f)} - set(state))
        start = (load_date - timedelta(days=30)).replace(day=1).isoformat()
        for ch, pc in rng.sample(orphans, min(10, len(orphans))):
            state[(ch, pc)] = new_member(ch, pc, start)
            flag("late_eligibility_prior_orphan", f"{ch}-{pc}", "eligibility",
                 "Member whose claims were orphans in the previous load now appears in eligibility (retro add)")

    rows = list(state.values())
    for r in rng.sample(rows, 25):
        rows.append(dict(r))
        flag("duplicate_eligibility_record", f"{r['cardholder_id']}-{r['person_code']}", "eligibility", "Exact duplicate row in the 834 file")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--load-date", required=True, help="YYYY-MM-DD; claims cover the 30 days before it")
    ap.add_argument("--members", type=int, default=2000)
    ap.add_argument("--claims", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--window-days", type=int, default=30, help="claims have dates of service in the N days before the load")
    ap.add_argument("--late-reversals", action="store_true",
                    help="also emit B2 reversals for claims filled in earlier loads (late-arriving data)")
    args = ap.parse_args()

    load_date = date.fromisoformat(args.load_date)
    rng = random.Random(f"{args.seed}-{args.load_date}")
    base_rng = random.Random(args.seed)  # stable members, drugs, providers across loads
    loaded_at = datetime.combine(load_date, datetime.min.time()) + timedelta(hours=6)
    defects = defaultdict(lambda: {"count": 0, "examples": []})

    def flag(name, key, feed, note):
        d = defects[name]
        d["feed"], d["note"] = feed, note
        d["count"] += 1
        if len(d["examples"]) < 5:
            d["examples"].append(key)

    # ---------- drug reference (mostly clean) ----------
    drugs = []
    for name, gpi, msc, spec, awp, labeler in DRUGS:
        drugs.append({"ndc11": ndc11(base_rng), "drug_name": name, "gpi14": gpi, "multi_source_code": msc,
                      "is_specialty": str(spec).lower(), "awp_unit_price": money(awp), "labeler_name": labeler})
    drug_rows = list(drugs)

    # ---------- providers: pharmacies (type 2) + prescribers (type 1) ----------
    pharmacies = [{"npi": make_npi(base_rng, "1"), "entity_type": "2",
                   "name": f"{base_rng.choice(['Main Street', 'Riverside', 'Parkway', 'Oak Hill', 'Lakeside'])} Pharmacy #{i:03d}",
                   "taxonomy_code": "3336C0003X", "state": base_rng.choice(STATES)} for i in range(60)]
    prescribers = [{"npi": make_npi(base_rng, "1"), "entity_type": "1",
                    "name": f"Dr. {base_rng.choice(FIRST)} {base_rng.choice(LAST)}",
                    "taxonomy_code": base_rng.choice(["207Q00000X", "207R00000X", "208D00000X", "207RE0101X"]),
                    "state": base_rng.choice(STATES)} for _ in range(300)]
    provider_rows = [dict(p) for p in pharmacies + prescribers]
    for p in rng.sample(prescribers, 6):  # same NPI, different spelling of the name
        dup = dict(p, name=p["name"].upper().replace("DR. ", ""))
        provider_rows.append(dup)
        flag("duplicate_npi_different_name", p["npi"], "providers", "Same NPI appears twice with different name spellings")
    for _ in range(4):
        n = bad_npi(rng, "1")
        provider_rows.append({"npi": n, "entity_type": "1", "name": f"Dr. {rng.choice(FIRST)} {rng.choice(LAST)}",
                              "taxonomy_code": "207Q00000X", "state": rng.choice(STATES)})
        flag("invalid_npi_check_digit", n, "providers", "NPI fails the Luhn check digit")

    # ---------- eligibility (834-style) ----------
    members, elig_rows = [], []
    for i in range(args.members):
        cardholder = f"RW{100000 + i}"
        client_id, _ = CLIENTS[i % len(CLIENTS)]
        start = date(2026, 1, 1) if base_rng.random() < 0.8 else date(2026, base_rng.randint(2, 9), 1)
        end = "" if base_rng.random() < 0.92 else (date(2026, base_rng.randint(9, 12), 1) - timedelta(days=1)).isoformat()
        dob = date(base_rng.randint(1950, 2005), base_rng.randint(1, 12), base_rng.randint(1, 28))
        m = {"cardholder_id": cardholder, "person_code": "01", "relationship_code": "18",
             "first_name": base_rng.choice(FIRST), "last_name": base_rng.choice(LAST), "date_of_birth": dob.isoformat(),
             "gender": base_rng.choice(["M", "F"]), "zip_code": f"{base_rng.randint(20000, 29999)}",
             "client_id": client_id, "group_id": f"{client_id}-G1", "plan_id": base_rng.choice(PLANS),
             "coverage_start_date": start.isoformat(), "coverage_end_date": end,
             "maintenance_type_code": "021", "maintenance_effective_date": start.isoformat(),
             "file_loaded_at": loaded_at.isoformat()}
        members.append(m)
        elig_rows.append(dict(m))
        if base_rng.random() < 0.35:  # spouse / child, same cardholder, different person code
            dep = dict(m, person_code="02", relationship_code=base_rng.choice(["01", "19"]),
                       first_name=base_rng.choice(FIRST),
                       date_of_birth=date(base_rng.randint(1955, 2020), base_rng.randint(1, 12), base_rng.randint(1, 28)).isoformat())
            members.append(dep)
            elig_rows.append(dict(dep))

    prev_elig = sorted(p for p in (RAW / "eligibility").glob("load_date=*") if p.name < f"load_date={load_date.isoformat()}")
    if not prev_elig:  # first load: the dirty roster from Class 1
        for r in rng.sample(elig_rows, 40):  # dirty formatting
            r["date_of_birth"] = datetime.fromisoformat(r["date_of_birth"]).strftime("%m/%d/%Y")
            flag("dob_in_mmddyyyy_format", f"{r['cardholder_id']}-{r['person_code']}", "eligibility", "DOB sent as MM/DD/YYYY instead of ISO")
        for r in rng.sample(elig_rows, 30):
            r["first_name"] = f"  {r['first_name'].upper()} "
            r["last_name"] = r["last_name"].lower()
            flag("name_case_and_whitespace", f"{r['cardholder_id']}-{r['person_code']}", "eligibility", "Names with stray spaces and mixed case")
        for r in rng.sample(elig_rows, 15):
            r["zip_code"] = ""
            flag("missing_zip", f"{r['cardholder_id']}-{r['person_code']}", "eligibility", "Blank ZIP code")
        for r in rng.sample(elig_rows, 8):
            r["coverage_end_date"] = (date.fromisoformat(r["coverage_start_date"]) - timedelta(days=15)).isoformat()
            flag("coverage_end_before_start", f"{r['cardholder_id']}-{r['person_code']}", "eligibility", "Coverage end date earlier than start date")
        for r in rng.sample(elig_rows, 25):  # same record sent twice in the file
            elig_rows.append(dict(r))
            flag("duplicate_eligibility_record", f"{r['cardholder_id']}-{r['person_code']}", "eligibility", "Exact duplicate row in the 834 file")
        for r in rng.sample(elig_rows, 20):  # a later change record for the same member (plan change)
            chg = dict(r, plan_id=rng.choice([p for p in PLANS if p != r["plan_id"]]), maintenance_type_code="001",
                       maintenance_effective_date=load_date.replace(day=1).isoformat(),
                       file_loaded_at=(loaded_at + timedelta(minutes=30)).isoformat())
            elig_rows.append(chg)
            flag("member_plan_change_same_file", f"{r['cardholder_id']}-{r['person_code']}", "eligibility",
                 "Change record (001) for a member already in the file; latest record should win")

    else:  # later load: evolve the previous roster (full-file 834 feed)
        elig_rows = evolve_eligibility(prev_elig[-1], load_date, loaded_at, rng, args.members, flag)

    elig_fields = list(members[0].keys())

    # ---------- pharmacy claims (NCPDP-style transactions) ----------
    claim_rows, txn = [], 0
    window_start = load_date - timedelta(days=args.window_days)

    def new_txn_id():
        nonlocal txn
        txn += 1
        return f"T{load_date.strftime('%Y%m%d')}{txn:07d}"

    def price(drug, qty):
        awp = float(drug["awp_unit_price"])
        ingredient = round(awp * qty * (0.80 if drug["multi_source_code"] == "Y" else 0.83), 2)
        fee = 1.50 if drug["multi_source_code"] == "Y" else 1.00
        copay = 10.00 if drug["multi_source_code"] == "Y" else (75.00 if drug["is_specialty"] == "true" else 40.00)
        copay = min(copay, ingredient + fee)
        return ingredient, fee, copay, round(ingredient + fee - copay, 2)

    elig_keys = [(m["cardholder_id"], m["person_code"]) for m in members]
    for _ in range(args.claims):
        ch, pc = rng.choice(elig_keys)
        drug = rng.choices(drugs, weights=[14, 12, 12, 10, 8, 8, 8, 3, 6, 5, 3, 2, 1, 1])[0]
        days_supply = rng.choice([30, 30, 30, 90]) if drug["is_specialty"] == "false" else 28
        qty = days_supply if "Pen" not in drug["drug_name"] else rng.choice([1, 2, 4])
        ing, fee, copay, plan_paid = price(drug, qty)
        dos = window_start + timedelta(days=rng.randint(0, args.window_days - 1))
        row = {"transaction_id": new_txn_id(), "transaction_code": "B1", "response_status": "P",
               "pharmacy_npi": rng.choice(pharmacies)["npi"], "rx_number": f"{rng.randint(1000000, 9999999)}",
               "fill_number": str(rng.choice([0, 0, 1, 2, 3])), "date_of_service": dos.isoformat(),
               "cardholder_id": ch, "person_code": pc, "ndc": drug["ndc11"],
               "quantity_dispensed": str(qty), "days_supply": str(days_supply), "daw_code": rng.choice(["0", "0", "0", "1", "2"]),
               "ingredient_cost_paid": money(ing), "dispensing_fee_paid": money(fee), "patient_pay_amount": money(copay),
               "plan_paid_amount": money(plan_paid), "prescriber_npi": rng.choice(prescribers)["npi"],
               "submitted_at": (datetime.combine(dos, datetime.min.time()) + timedelta(hours=rng.randint(8, 20), minutes=rng.randint(0, 59))).isoformat(),
               "file_loaded_at": loaded_at.isoformat()}
        claim_rows.append(row)

    paid = list(claim_rows)
    rng.shuffle(paid)
    # Disjoint slices so each defect is clean and countable (no row carries two defects).
    n_rev = int(len(paid) * 0.05)
    bounds = [0, n_rev, n_rev + 300, n_rev + 700, n_rev + 760, n_rev + 800, n_rev + 825, n_rev + 835, n_rev + 870, n_rev + 920]
    s_rev, s_rej, s_ndc10, s_badndc, s_orphan, s_days, s_future, s_npi, s_dollar = (
        paid[a:b] for a, b in zip(bounds[:-1], bounds[1:]))

    # reversals (B2): same fill key, later timestamp, amounts repeated as positives (a classic netting trap)
    for c in s_rev:
        rev = dict(c, transaction_id=new_txn_id(), transaction_code="B2",
                   submitted_at=(datetime.fromisoformat(c["submitted_at"]) + timedelta(days=rng.randint(1, 5))).isoformat())
        claim_rows.append(rev)
        flag("reversal_b2", f"{c['pharmacy_npi']}|{c['rx_number']}|{c['fill_number']}|{c['date_of_service']}", "pharmacy_claims",
             "B2 reversal of a paid claim; the fill should net to zero")
        if rng.random() < 0.4:  # rebill (B3) after the reversal, with corrected quantity
            q = max(1, int(c["quantity_dispensed"]) - rng.choice([0, 1, 5]))
            drug = next(d for d in drugs if d["ndc11"] == c["ndc"])
            ing, fee, copay, plan_paid = price(drug, q)
            rb = dict(c, transaction_id=new_txn_id(), transaction_code="B3", quantity_dispensed=str(q),
                      ingredient_cost_paid=money(ing), dispensing_fee_paid=money(fee), patient_pay_amount=money(copay),
                      plan_paid_amount=money(plan_paid),
                      submitted_at=(datetime.fromisoformat(rev["submitted_at"]) + timedelta(hours=2)).isoformat())
            claim_rows.append(rb)
            flag("rebill_b3", f"{c['pharmacy_npi']}|{c['rx_number']}|{c['fill_number']}|{c['date_of_service']}", "pharmacy_claims",
                 "B3 rebill after a reversal; the rebill is the final version of the fill")

    for c in s_rej:  # rejected claims are in the file but were never paid
        c["response_status"] = "R"
        c["plan_paid_amount"] = "0.00"
        flag("rejected_claim", c["transaction_id"], "pharmacy_claims", "Rejected transaction (response_status R); not a paid fill")
    for c in s_ndc10:  # NDC printed as 10-digit hyphenated
        c["ndc"] = ndc_as_10_digit(c["ndc"], rng)
        flag("ndc_10_digit_hyphenated", c["transaction_id"], "pharmacy_claims", "NDC in 10-digit hyphenated package format, not 11-digit")
    for c in s_badndc:
        c["ndc"] = ndc11(rng)
        flag("ndc_not_in_drug_reference", c["transaction_id"], "pharmacy_claims", "NDC not found in the drug reference file")
    for c in s_orphan:
        c["cardholder_id"] = f"RW9{rng.randint(10000, 99999)}"
        flag("orphan_member", c["transaction_id"], "pharmacy_claims", "Cardholder not present in eligibility")
    for c in s_days:
        c["days_supply"] = rng.choice(["0", "999"])
        flag("days_supply_out_of_range", c["transaction_id"], "pharmacy_claims", "Days supply 0 or 999")
    for c in s_future:
        c["date_of_service"] = (load_date + timedelta(days=rng.randint(5, 60))).isoformat()
        flag("future_date_of_service", c["transaction_id"], "pharmacy_claims", "Date of service after the file date")
    for c in s_npi:
        c["prescriber_npi"] = bad_npi(rng, "1")
        flag("invalid_prescriber_npi", c["transaction_id"], "pharmacy_claims", "Prescriber NPI fails the Luhn check digit")
    for c in s_dollar:
        c["ingredient_cost_paid"] = f"${c['ingredient_cost_paid']}"
        flag("amount_with_dollar_sign", c["transaction_id"], "pharmacy_claims", "Amount sent as text with a $ sign")

    if args.late_reversals:  # reversals for real fills from the previous load: late-arriving data
        prev = sorted(p for p in (RAW / "pharmacy_claims").glob("load_date=*") if p.name < f"load_date={load_date.isoformat()}")
        if not prev:
            raise SystemExit("--late-reversals needs an earlier load; generate that load first")
        with (prev[-1] / "claims.csv").open() as f:
            prev_rows = list(csv.DictReader(f))
        prev_load = prev[-1].name.split("=")[1]
        fk = lambda r: (r["pharmacy_npi"], r["rx_number"], r["fill_number"], r["date_of_service"])
        touched = {fk(r) for r in prev_rows if r["transaction_code"] != "B1"}
        known_ndcs = {d["ndc11"] for d in drugs}  # skip fills already reversed or rebilled
        earlier = list({r["transaction_id"]: r for r in prev_rows
                        if r["transaction_code"] == "B1" and r["response_status"] == "P" and fk(r) not in touched
                        and r["days_supply"] in ("28", "30", "90") and r["date_of_service"] <= prev_load
                        # keep "one defect per row": skip fills that already carry another injected defect
                        and r["ndc"] in known_ndcs and not r["ingredient_cost_paid"].startswith("$")
                        and r["cardholder_id"].startswith("RW1")
                        and luhn_npi_check_digit(r["prescriber_npi"][:9]) == r["prescriber_npi"][9]}.values())
        earlier.sort(key=lambda r: r["transaction_id"])
        for c in rng.sample(earlier, min(80, len(earlier))):
            r = dict(c, transaction_id=new_txn_id(), transaction_code="B2",
                     submitted_at=loaded_at.isoformat(), file_loaded_at=loaded_at.isoformat())
            claim_rows.append(r)
            flag("late_reversal_prior_load", r["transaction_id"], "pharmacy_claims",
                 f"Reversal arrives in this file for a fill loaded in {prev[-1].name}")

    # Duplicates last, so the copy is byte-identical to the final row.
    for c in rng.sample([r for r in paid if r["response_status"] == "P"], 150):
        claim_rows.append(dict(c))
        flag("exact_duplicate_claim_row", c["transaction_id"], "pharmacy_claims", "Same transaction delivered twice")

    rng.shuffle(claim_rows)
    claim_fields = list(claim_rows[0].keys())

    # ---------- rebates (by NDC and quarter, brand drugs only) ----------
    q = (load_date.month - 1) // 3 + 1
    rebate_rows = []
    for d in drugs:
        if d["multi_source_code"] in ("N", "O"):
            units = rng.randint(500, 5000)
            per_unit = round(float(d["awp_unit_price"]) * rng.uniform(0.15, 0.35), 4)
            rebate_rows.append({"rebate_quarter": f"{load_date.year}Q{q}", "ndc11": d["ndc11"], "manufacturer": d["labeler_name"],
                                "invoiced_units": str(units), "rebate_per_unit": f"{per_unit:.4f}",
                                "invoiced_amount": money(units * per_unit), "status": rng.choice(["INVOICED", "INVOICED", "COLLECTED", "DISPUTED"])})

    # ---------- write ----------
    part = f"load_date={load_date.isoformat()}"
    write_csv(RAW / "eligibility" / part / "eligibility.csv", elig_rows, elig_fields)
    write_csv(RAW / "pharmacy_claims" / part / "claims.csv", claim_rows, claim_fields)
    write_csv(RAW / "drug_reference" / part / "ndc_master.csv", drug_rows, list(drug_rows[0].keys()))
    write_csv(RAW / "providers" / part / "npi_registry.csv", provider_rows, list(provider_rows[0].keys()))
    write_csv(RAW / "rebates" / part / "rebate_invoices.csv", rebate_rows, list(rebate_rows[0].keys()))
    manifest_path = RAW / "_manifest" / part / "defects.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest = {"load_date": load_date.isoformat(), "seed": args.seed,
                "row_counts": {"eligibility": len(elig_rows), "pharmacy_claims": len(claim_rows), "drug_reference": len(drug_rows),
                               "providers": len(provider_rows), "rebates": len(rebate_rows)},
                "defects": dict(sorted(defects.items()))}
    manifest_path.write_text(json.dumps(manifest, indent=2))

    print(f"Load {load_date}: wrote raw files under {RAW.relative_to(ROOT)}/<feed>/{part}/")
    for k, v in manifest["row_counts"].items():
        print(f"  {k:<16} {v:>7,} rows")
    print(f"  defects injected: {sum(d['count'] for d in defects.values()):,} across {len(defects)} types "
          f"(see {manifest_path.relative_to(ROOT)})")


if __name__ == "__main__":
    main()
