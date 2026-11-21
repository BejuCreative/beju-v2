"""Sheet → CRM cut-over, step 2 (11-21): ONE write path for the Samples data, CRM first, sheet as a copy.

    pipeline_set(email, {"Status": "PUBLIC", "Drive link": url, "Public at": "2026-11-21 18:40"}, actor="autoshare")
        1. PATCH public.pipeline (by email) with the same column MAP the readers use (crm_rows.MAP), Vilnius
           "YYYY-MM-DD HH:MM" times -> timestamptz, x-actor/x-source headers so audit_log records who wrote it;
           raises LookupError if no pipeline row matched (never "succeeds" on nothing, the Tara bug).
        2. mirrors the same cells into the Samples sheet (best effort: a sheet error is logged, never raised),
           so the sheet stays a readable copy until ops-sync's direction is flipped.
    pipeline_insert({...sheet columns...}, actor)   new YES row: CRM insert first, then the sheet append.
    --dry on the command line (or dry=True) prints what would be written and writes nothing.

Same file is meant for both Macs (Simas's side copies it), so both sides write the CRM the same way.
"""
import datetime as dt, json, os, re, sys, urllib.parse, urllib.request
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sheet, crm_rows  # noqa: E402

TZ = ZoneInfo("Europe/Vilnius")
MAP = dict(crm_rows.MAP, **{"Public at": "public_at"})          # public_at exists since 11-21 18:4x (Simas's side)
TIME_COLS = set(crm_rows.TIME_COLS) | {"Public at"}
DRY = "--dry" in sys.argv
LOG = os.path.join(HERE, "pipeline_write.log")


def _env():
    return dict(l.strip().split("=", 1) for l in open(os.path.expanduser("~/beju-jobs/crm/.env")) if "=" in l)


def _iso(v):
    """Vilnius 'YYYY-MM-DD HH:MM' (rough 'HH:5x' allowed) -> UTC ISO; '' -> None; ISO passes; other text raises."""
    v = (v or "").strip()
    if not v:
        return None
    if re.match(r"^\d{4}-\d{2}-\d{2}T", v):
        return v
    m = re.match(r"^(\d{4}-\d{2}-\d{2})(?:[ T](\d{1,2}):(\d)([0-9x]))?$", v)
    if not m:
        raise ValueError(f"not a sheet time: {v!r}")
    d, hh, m1, m2 = m.groups()
    local = dt.datetime.fromisoformat(f"{d} {int(hh or 0):02d}:{m1 or 0}{(m2 or '0').replace('x', '0')}").replace(tzinfo=TZ)
    return local.astimezone(dt.timezone.utc).isoformat()


def _body(updates):
    body = {}
    for col, v in updates.items():
        if col not in MAP or MAP[col] is None:
            raise KeyError(f"unknown / unmapped Samples column: {col!r}")
        body[MAP[col]] = _iso(v) if col in TIME_COLS else v
    return body


def _req(method, path, body, actor):
    env = _env(); k = env["SUPABASE_SERVICE_KEY"]
    h = {"apikey": k, "Content-Type": "application/json", "Prefer": "return=representation",
         "x-actor": actor, "x-source": "script"}
    if k.startswith("eyJ"):
        h["Authorization"] = "Bearer " + k
    req = urllib.request.Request(env["SUPABASE_URL"].rstrip("/") + "/rest/v1/" + path, method=method,
                                 data=json.dumps(body).encode(), headers=h)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"[]")


def _log(line):
    with open(LOG, "a") as f:
        f.write(dt.datetime.now(TZ).strftime("%Y-%m-%d %H:%M:%S ") + line + "\n")


def _sheet_row(tok, email):
    for r in sheet.rows(tok):
        if r["Lead email"].strip().lower() == email:
            return r["_row"]
    return None


def pipeline_set(email, updates, actor, tok=None, row=None, dry=None):
    """CRM first, then the sheet copy. Returns the updated pipeline row (or the would-be body when dry)."""
    dry = DRY if dry is None else dry
    email = email.strip().lower()
    body = _body(updates)
    if dry:
        print(f"DRY pipeline_set {email} by {actor}: CRM {body} | sheet row {row or '(lookup)'} {updates}")
        return body
    rows = _req("PATCH", "pipeline?email=eq." + urllib.parse.quote(email), body, actor)
    if not rows:
        raise LookupError(f"pipeline_set: no pipeline row for {email}; nothing was changed")
    _log(f"CRM ok {email} {actor} {json.dumps(body)}")
    try:                                                         # the copy: never blocks the CRM write
        tok = tok or sheet.token()
        row = row or _sheet_row(tok, email)
        if row:
            sheet.set_cells(tok, row, updates)
        else:
            _log(f"SHEET skip {email}: no sheet row")
    except Exception as ex:                                      # noqa: BLE001
        _log(f"SHEET error {email}: {type(ex).__name__}: {ex}")
    return rows[0]


def pipeline_insert(values, actor, tok=None, dry=None):
    """New Samples row (e.g. a YES): CRM insert first, then append to the sheet in COLS order."""
    dry = DRY if dry is None else dry
    if not values.get("Lead email"):
        raise ValueError("Lead email is required")
    body = _body(values); body["email"] = body["email"].strip().lower()
    if dry:
        print(f"DRY pipeline_insert by {actor}: CRM {body} | sheet append {values}")
        return body
    rows = _req("POST", "pipeline", body, actor)
    _log(f"CRM insert {body['email']} {actor}")
    try:
        tok = tok or sheet.token()
        sheet.call("POST", "values/" + urllib.parse.quote(f"'{sheet.TAB}'!A:Q", safe="") + ":append?valueInputOption=RAW",
                   tok, {"values": [[values.get(c, "") for c in sheet.COLS]]})
    except Exception as ex:                                      # noqa: BLE001
        _log(f"SHEET append error {body['email']}: {type(ex).__name__}: {ex}")
    return rows[0] if rows else body


if __name__ == "__main__":   # self-check: times + a dry write for a real row (writes nothing)
    for t in ["2026-11-21 18:40", "2026-11-21 21:5x", "2026-11-21", "", "2026-10-25 02:27"]:
        print(repr(t), "->", _iso(t))
    pipeline_set("kirsten@kirstenjonesinc.com", {"Status": "PUBLIC", "Public at": "2026-11-21 19:50"}, "selftest", dry=True)
    try:
        _body({"Nope": 1})
    except KeyError as e:
        print("unknown column refused:", e)
