# my_app/api/import_leads_text.py

import csv
import io
from typing import List, Dict

import frappe
from frappe.utils.data import cint

# Map CSV headers (your file) to Lead fields
CSV_TO_LEAD = {
    "Salutation": "salutation",
    "First Name": "first_name",
    "Last Name": "last_name",
    "Email": "email",
    "Mobile No": "mobile_no",
    "Gender": "gender",
    "Status": "status",
    "Organization": "organization",
    "Website": "website",
    "Industry": "industry",
    "Annual Revenue": "annual_revenue",
    "No. of Employees": "no_of_employees",
}

# Require at least one of these columns to exist in the HEADER
# (we still validate that each ROW has either first_name or organization)
REQUIRED_MIN = {"Salutation","First Name", "Last Name","Email","Mobile No","Gender","Status", "Organization"}

@frappe.whitelist()
def import_leads_from_csv_file():
    try:
        # Get the file from the form data  
        file = frappe.request.files.get('file')
        
        if not file:
            return {"exc": "File not found in request"}
        
        file_content = file.read()

        # If file content is bytes, decode to string
        if isinstance(file_content, bytes):
            text = _decode_bytes(file_content)
        else:
            # If it's already a string, no need to decode
            text = file_content

        return _import_from_text(text, 0)  # Pass the text to the existing import logic
    except Exception as e:
        return {"exc": str(e)}

# ---------------- internal helpers ----------------

def _import_from_text(text: str, dry_run: int) -> str:
    # Sniff dialect; be tolerant of Excel oddities
    try:
        first_line = (text.splitlines() or [""])[0] + "\n"
        dialect = csv.Sniffer().sniff(first_line)
    except Exception:
        dialect = csv.excel

    # Use StringIO to read the content, no need to pass `newline=''` to csv.reader
    reader = csv.reader(io.StringIO(text), dialect)

    rows = list(reader)
    if not rows or len(rows) < 2:
        return "No rows found (need header + at least one data row)."

    header = [h.strip() for h in rows[0]]
    _validate_headers(header)

    idx = {col: i for i, col in enumerate(header)}

    created, errors = 0, []
    _, select_options = _get_select_fields_and_options("CRM Lead")

    for line_no, row in enumerate(rows[1:], start=2):
        # Debugging log to check row length
        if len(row) != len(header):
            errors.append(f"Line {line_no}: Row has {len(row)} columns, but header expects {len(header)} columns.")
            continue  # Skip rows with incorrect column count

        if not any((cell or "").strip() for cell in row):
            continue

        payload = _row_to_payload(row, idx)

        # Require first name or organization per-row
        if not payload.get("first_name") and not payload.get("company_name"):
            errors.append(f"Line {line_no}: missing first_name/organization")
            continue

        # Validate select fields present in your mapping (status commonly Select)
        for f in ("status",):
            if payload.get(f):
                opts = select_options.get(f)
                if opts and payload[f] not in opts:
                    errors.append(
                        f"Line {line_no}: invalid value '{payload[f]}' for {f}. "
                        f"Allowed: {', '.join(sorted(opts))} "
                    )
                    continue

        try:
            # Build lead_name: salutation + first + last
            lead_name_parts = [
                payload.get("salutation") or "",
                payload.get("first_name") or "",
                payload.get("last_name") or "",
            ]
            payload["lead_name"] = " ".join(p for p in lead_name_parts if p).strip()

            if dry_run:
                doc = frappe.get_doc({"doctype": "CRM Lead", **payload})
                doc.run_method("validate")
                continue

            doc = frappe.get_doc({"doctype": "CRM Lead", **payload})
            doc.insert(ignore_permissions=True)
            created += 1

        except Exception as e:
            errors.append(f"Line {line_no}: {frappe.utils.cstr(e)}")

    if dry_run:
        non_empty_rows = sum(1 for r in rows[1:] if any((c or "").strip() for c in r))
        would_insert = max(non_empty_rows - len(errors), 0)
    else:
        would_insert = created

    summary = [
        f"Dry run: {bool(dry_run)}",
        f"Inserted (new records): {would_insert}",
        f"Errors: {len(errors)}",
        f"Rows: {rows}",
    ]
    if errors:
        summary.append("\nDetails (first 100):")
        summary.extend(errors[:100])

    return "\n".join(summary)

def _decode_bytes(b: bytes) -> str:
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        try:
            return b.decode("latin-1")  # Try latin-1 if UTF-8 fails
        except UnicodeDecodeError:
            return b.decode("windows-1252", errors="ignore")  # Fallback to windows-1252 or ignore errors



def _validate_headers(header: List[str]) -> None:
    missing = [f for f in REQUIRED_MIN if f not in header]
    if missing:
        frappe.throw(f"Missing required column(s): {', '.join(missing)}")

    unknown = [h for h in header if h not in CSV_TO_LEAD]
    if unknown:
        frappe.log_error("\n".join(unknown), "Import Leads: Unknown headers")


def _row_to_payload(row: List[str], idx: Dict[str, int]) -> Dict[str, str]:
    out = {}
    for csv_key, lead_field in CSV_TO_LEAD.items():
        i = idx.get(csv_key)
        if i is not None and i < len(row):
            out[lead_field] = (row[i] or "").strip()
        else:
            out[lead_field] = ""  # Fill with empty value if column is missing
    return out



def _get_select_fields_and_options(doctype: str):
    meta = frappe.get_meta(doctype)
    select_fields = [df.fieldname for df in meta.fields if df.fieldtype == "Select"]
    options_map = {}
    for df in meta.fields:
        if df.fieldtype == "Select":
            opts = [o for o in (df.options or "").split("\n") if o]
            options_map[df.fieldname] = set(opts)
    return select_fields, options_map
