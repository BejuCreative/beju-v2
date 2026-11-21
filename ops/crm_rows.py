"""Samples rows from the CRM (pipeline table) in the SAME shape as sheet.rows() — the sheet → CRM cut-over (11-21).

rows() returns dicts keyed by the Samples-tab column names, times as Vilnius "YYYY-MM-DD HH:MM" (like the sheet),
so alarms.py / autoshare / order_folders can switch their READS from the sheet to the CRM without other changes.
`_row` = the sheet row number for the same email (looked up from the sheet's column A), so WRITES keep going to the
sheet during the parallel run (the sheet is still the master until the cut-over; ops-sync copies it to the CRM).
Known gap: the CRM has no "Public at" yet (asked Simas's side for pipeline.public_at); until then it is read from the sheet.
Uses Benas's own CRM key (~/beju-jobs/crm/.env, benas_claude). Read-only on the CRM.
"""
import datetime as dt, json, os, sys, urllib.parse, urllib.request
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sheet  # noqa: E402

TZ = ZoneInfo("Europe/Vilnius")
MAP = {  # sheet column -> pipeline column
    "Lead email": "email", "Name": "name", "Show / channel": "show", "Owner": "owner", "Inbox": "inbox",
    "Yes at": "yes_at", "Due at": "due_at", "Status": "status", "Builder": "builder", "Drive link": "drive_link",
    "Public at": None, "Delivered at": "delivered_at", "Last reply at": "last_reply_at", "Next action": "next_action",
    "Next action at": "next_action_at", "Paid at": "paid", "Notes": "notes",
}
TIME_COLS = {"Yes at", "Due at", "Delivered at", "Last reply at", "Next action at"}


def _env():
    env = {}
    for line in open(os.path.expanduser("~/beju-jobs/crm/.env")):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            env[k] = v
    return env


def _local(v):
    """CRM ISO timestamp -> Vilnius 'YYYY-MM-DD HH:MM' (sheet style). Non-ISO text passes through."""
    if not v:
        return ""
    try:
        return dt.datetime.fromisoformat(str(v).replace("Z", "+00:00")).astimezone(TZ).strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return str(v)


def crm_pipeline():
    env = _env()
    k = env["SUPABASE_SERVICE_KEY"]
    h = {"apikey": k}
    if k.startswith("eyJ"):
        h["Authorization"] = "Bearer " + k
    req = urllib.request.Request(env["SUPABASE_URL"].rstrip("/") + "/rest/v1/pipeline?select=*", headers=h)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def rows(tok=None, public_from_sheet=True):
    """CRM pipeline rows shaped like sheet.rows(). tok = a Sheets token (for _row numbers + the Public at gap)."""
    tok = tok or sheet.token()
    srows = sheet.rows(tok)                       # only for _row + Public at (the known gap); nothing else is taken from it
    by_email = {r["Lead email"].strip().lower(): r for r in srows}
    out = []
    for p in crm_pipeline():
        e = (p.get("email") or "").strip().lower()
        d = {}
        for col, pc in MAP.items():
            v = p.get(pc) if pc else None
            d[col] = _local(v) if col in TIME_COLS else ("" if v is None else str(v))
        s = by_email.get(e)
        d["Lead email"] = p.get("email") or ""
        if public_from_sheet and s:
            d["Public at"] = s["Public at"]
        d["_row"] = s["_row"] if s else None
        out.append(d)
    return out
