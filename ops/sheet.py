"""Minimal stdlib Google Sheets client for the Samples tab, as pipeline_write.py / crm_rows.py use it.
No IDs or secrets in this file (the repo is public): set them in the environment or an env file.
    SAMPLES_SHEET_ID     the lead sheet's id (Samples tab lives there)
    GOOGLE_TOKEN_FILE    an OAuth token JSON with client_id, client_secret, refresh_token (Sheets scope)
Names used by pipeline_write / crm_rows: token(), call(), rows(), set_cells(), TAB, COLS, SID."""
import json, os, urllib.parse, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
SID = os.environ.get("SAMPLES_SHEET_ID", "")
TAB = "Samples"
COLS = ["Lead email", "Name", "Show / channel", "Owner", "Inbox", "Yes at", "Due at", "Status", "Builder", "Drive link",
        "Public at", "Delivered at", "Last reply at", "Next action", "Next action at", "Paid at", "Notes"]


def token():
    t = json.load(open(os.environ.get("GOOGLE_TOKEN_FILE", os.path.join(HERE, "google_token.json"))))
    body = urllib.parse.urlencode({"client_id": t["client_id"], "client_secret": t["client_secret"],
                                   "refresh_token": t["refresh_token"], "grant_type": "refresh_token"}).encode()
    with urllib.request.urlopen(urllib.request.Request(t.get("token_uri") or "https://oauth2.googleapis.com/token", data=body), timeout=30) as r:
        return json.loads(r.read())["access_token"]


def call(method, path, tok, body=None):
    if not SID:
        raise RuntimeError("SAMPLES_SHEET_ID is not set")
    req = urllib.request.Request(f"https://sheets.googleapis.com/v4/spreadsheets/{SID}/{path}",
                                 data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b"{}")


def rows(tok):
    vals = call("GET", "values/" + urllib.parse.quote(f"'{TAB}'!A:Q", safe=""), tok).get("values", [])
    hdr = vals[0]
    assert hdr == COLS, hdr
    return [dict(zip(hdr, r + [""] * (len(hdr) - len(r)))) | {"_row": i} for i, r in enumerate(vals[1:], start=2)]


def set_cells(tok, row, updates):
    data = [{"range": f"'{TAB}'!{chr(65 + COLS.index(k))}{row}", "values": [[v]]} for k, v in updates.items()]
    call("POST", "values:batchUpdate", tok, {"valueInputOption": "RAW", "data": data})
