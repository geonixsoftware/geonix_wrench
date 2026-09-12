"""A stats dashboard you run yourself, on your own laptop. Not part of the app.

Reads directly out of the same SQLite database the main backend uses
(DB_PATH in config.py) — there is no HTTP call to the main API and no
Firebase-authenticated "admin account" involved at all. That is deliberate:
this tool only ever needs to answer to whoever can already reach the
database file, so there is nothing here for a login screen to protect that
the filesystem permissions do not already protect.

Optionally password-protected: set ADMIN_PORTAL_PASSWORD and every route
asks for it over HTTP Basic auth (any username). Unset, it serves openly.
Worth knowing before choosing: loopback is not a boundary a browser
respects, so any web page open on the same machine can read a local port
while the portal is running. Whichever way that goes, the Hide/Unhide posts
refuse any request whose Origin or Sec-Fetch-Site says it came from another
site, so a page elsewhere cannot drive them.

Still leave the bind address at 127.0.0.1 (the default). Basic auth over
plain HTTP on the open network would hand the password to anyone listening.

"Hide" does not touch the shop or subscriber's real data or their real
subscription — see admin.py's admin_portal_hidden table. It only removes
that row from this dashboard's view and totals, and "Unhide" brings it back
at any time.

Run from geonix_wrench_backend/, alongside the main backend's .env and
database file:

    python admin_portal.py
    # or: uvicorn admin_portal:app --host 127.0.0.1 --port 8010

Then open http://127.0.0.1:8010 in a browser.
"""

import csv
import html
import io
import os
import secrets
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials

import admin
import database
import config
from config import DEFAULT_CURRENCY

_basic = HTTPBasic(realm="Geonix Wrench admin", auto_error=False)
_CHALLENGE = {"WWW-Authenticate": 'Basic realm="Geonix Wrench admin"'}


def require_operator(credentials: HTTPBasicCredentials | None = Depends(_basic)) -> None:
    """Basic auth against ADMIN_PORTAL_PASSWORD. Constant-time, any username.

    Optional: with the variable unset the portal serves openly, as it did
    before. That is the operator's choice for a tool on their own machine —
    the trade is that any web page open on that machine can read a local
    port, so the figures are only as private as the browser tabs beside them.
    """
    expected = config.ADMIN_PORTAL_PASSWORD
    if not expected:
        return
    supplied = credentials.password if credentials else ""
    if not secrets.compare_digest(supplied.encode("utf-8"), expected.encode("utf-8")):
        raise HTTPException(status_code=401, detail="Sign in to the admin portal", headers=_CHALLENGE)


def reject_cross_site(request: Request) -> None:
    """Refuse a state-changing request that another site initiated.

    Basic auth alone does not stop this: the browser attaches saved
    credentials to a cross-site form post just as it does to ours. Modern
    browsers label the source of every request in Sec-Fetch-Site, and every
    browser sends Origin on a cross-site POST; either one naming a different
    site is enough to refuse.
    """
    site = request.headers.get("sec-fetch-site")
    if site and site not in ("same-origin", "none"):
        raise HTTPException(status_code=403, detail="Cross-site request refused")
    origin = request.headers.get("origin")
    if origin:
        if urlsplit(origin).netloc.lower() != request.headers.get("host", "").lower():
            raise HTTPException(status_code=403, detail="Cross-site request refused")


app = FastAPI(
    title="Geonix Wrench — Admin Portal",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    dependencies=[Depends(require_operator)],
)


def _csv_safe(value) -> str:
    """Neutralise spreadsheet formula injection.

    Shop names, handles and emails come from customers. A cell that starts
    with =, +, -, @ or a tab/CR becomes a live formula when the export is
    opened in Excel, Numbers or Sheets, so it is prefixed with an apostrophe,
    which those applications read as "this is text".
    """
    text = "" if value is None else str(value)
    if text and text[0] in "=+-@\t\r":
        return "'" + text
    return text

_CURRENCY_SYMBOLS = {"EUR": "€", "USD": "$", "GBP": "£"}


def _money(amount: float, currency: str) -> str:
    symbol = _CURRENCY_SYMBOLS.get(currency, f"{currency} ")
    return f"{symbol}{amount:,.2f}"


def _e(value) -> str:
    return html.escape(str(value)) if value is not None else ""


def _status_pill(status: str | None) -> str:
    tone = "ok" if status in ("active", "trialing") else "muted"
    return f'<span class="pill {tone}">{_e(status or "no subscription")}</span>'


_STYLE = """
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: #0b0b0c;
    color: #f2ede7;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    padding: 40px 24px 80px;
  }
  .wrap { max-width: 1040px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .sub { color: #9a9088; font-size: 13px; margin: 0 0 32px; }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 12px;
    margin-bottom: 40px;
  }
  .card { background: #17161a; border: 1px solid #262328; border-radius: 14px; padding: 16px; }
  .card .value { font-size: 22px; font-weight: 700; color: #fff; }
  .card .label { font-size: 12px; color: #9a9088; margin-top: 4px; }
  .card.accent { border-color: #f5821f55; }
  .card.accent .value { color: #f5821f; }
  section { margin-bottom: 40px; }
  .section-head { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 12px; gap: 16px; flex-wrap: wrap; }
  h2 { font-size: 15px; text-transform: uppercase; letter-spacing: 0.04em; color: #9a9088; margin: 0; }
  .search {
    background: #17161a; border: 1px solid #262328; border-radius: 8px;
    color: #f2ede7; padding: 7px 12px; font-size: 13px; min-width: 220px;
  }
  .search:focus { outline: none; border-color: #f5821f88; }
  table { width: 100%; border-collapse: collapse; background: #17161a; border-radius: 14px; overflow: hidden; }
  th, td { text-align: left; padding: 11px 14px; font-size: 13.5px; border-bottom: 1px solid #262328; }
  th { color: #9a9088; font-weight: 600; font-size: 11.5px; text-transform: uppercase; letter-spacing: 0.03em; }
  tr:last-child td { border-bottom: none; }
  .pill { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 700; }
  .pill.ok { background: #1d3a2a; color: #6cd39a; }
  .pill.muted { background: #262328; color: #9a9088; }
  .empty { color: #9a9088; padding: 16px; background: #17161a; border-radius: 14px; }
  .btn {
    border: none; border-radius: 999px; padding: 5px 13px; font-size: 12px; font-weight: 700;
    cursor: pointer;
  }
  .btn-ghost { background: #262328; color: #cfc7bf; }
  .btn-ghost:hover { background: #322e35; }
  .btn-accent { background: #f5821f; color: #1a1207; }
  .btn-accent:hover { background: #ff9436; }
  .links { display: flex; gap: 14px; }
  .links a { color: #9a9088; font-size: 12.5px; text-decoration: none; border-bottom: 1px dotted #5f5850; }
  .links a:hover { color: #f5821f; border-color: #f5821f; }
  .footer { margin-top: 8px; font-size: 12px; color: #5f5850; }
  .footer code { color: #9a9088; }
"""

_SCRIPT = """
function filterTable(inputId, tableId) {
  var q = document.getElementById(inputId).value.toLowerCase();
  document.querySelectorAll('#' + tableId + ' tbody tr').forEach(function (row) {
    row.style.display = row.textContent.toLowerCase().indexOf(q) !== -1 ? '' : 'none';
  });
}
"""


def _page(body: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Geonix Wrench — Admin Portal</title>
<style>{_STYLE}</style>
</head>
<body>
<div class="wrap">
{body}
</div>
<script>{_SCRIPT}</script>
</body>
</html>
"""


def _stat_tiles(stats: dict, currency: str) -> str:
    tiles = [
        (_money(stats["total_revenue"], currency), "Total revenue", True),
        (_money(stats["total_profit"], currency), "Total profit", True),
        (stats["individual_subscribers"], "Individual subscribers", False),
        (stats["team_subscribers"], "Team subscribers", False),
        (stats["total_active_seats"], "Active team seats", False),
        (_money(stats["avg_revenue_per_shop"], currency), "Avg revenue / shop", False),
        (stats["total_signups"], "Total signups", False),
        (f'+{stats["signups_last_7d"]}', "New signups (7d)", False),
        (stats["total_jobcards"], "Job cards (all time)", False),
        (f'+{stats["jobcards_last_7d"]}', "Job cards (7d)", False),
        (stats["active_device_sessions"], "Devices signed in now", False),
    ]
    cards = "".join(
        f'<div class="card{" accent" if accent else ""}">'
        f'<div class="value">{_e(value)}</div><div class="label">{_e(label)}</div></div>'
        for value, label, accent in tiles
    )
    return f'<div class="grid">{cards}</div>'


def _hide_button(kind: str, ref_id: int) -> str:
    return (
        f'<form method="post" action="/hide/{kind}/{ref_id}" style="display:inline">'
        f'<button class="btn btn-ghost" type="submit">Hide</button></form>'
    )


def _unhide_button(kind: str, ref_id: int) -> str:
    return (
        f'<form method="post" action="/unhide/{kind}/{ref_id}" style="display:inline">'
        f'<button class="btn btn-accent" type="submit">Unhide</button></form>'
    )


def _organizations_section(orgs: list[dict]) -> str:
    if not orgs:
        rows_html = '<div class="empty">No visible shops. Everything might be hidden — check below.</div>'
    else:
        rows = []
        for org in orgs:
            owner = _e(org["owner_handle"] or org["owner_email"] or "—")
            rows.append(
                f"<tr><td>{_e(org['name'])}</td><td>{owner}</td>"
                f"<td>{org['seat_used']}/{org['seat_limit']}</td>"
                f"<td>{_status_pill(org['subscription_status'])}</td>"
                f"<td>{_hide_button(admin.HIDDEN_KIND_ORG, org['id'])}</td></tr>"
            )
        rows_html = (
            '<table id="org-table"><thead><tr><th>Shop</th><th>Owner</th><th>Seats</th>'
            f"<th>Status</th><th></th></tr></thead><tbody>{''.join(rows)}</tbody></table>"
        )

    return f"""
<section>
  <div class="section-head">
    <h2>Organizations</h2>
    <div style="display:flex; gap:10px; align-items:center;">
      <input class="search" id="org-search" type="text" placeholder="Filter by shop or owner…"
        onkeyup="filterTable('org-search','org-table')">
      <div class="links"><a href="/export/organizations.csv">Export CSV</a></div>
    </div>
  </div>
  {rows_html}
</section>
"""


def _individual_subscribers_section(subs: list[dict]) -> str:
    if not subs:
        rows_html = '<div class="empty">No individual subscriptions on record.</div>'
    else:
        rows = []
        for sub in subs:
            who = _e(sub["handle"] or sub["email"])
            rows.append(
                f"<tr><td>{who}</td><td>{_e(sub['plan'])}</td>"
                f"<td>{_status_pill(sub['status'])}</td>"
                f"<td>{_e(sub['current_period_end'] or '—')}</td>"
                f"<td>{_hide_button(admin.HIDDEN_KIND_INDIVIDUAL, sub['user_id'])}</td></tr>"
            )
        rows_html = (
            '<table id="indiv-table"><thead><tr><th>Subscriber</th><th>Plan</th><th>Status</th>'
            f"<th>Renews / ended</th><th></th></tr></thead><tbody>{''.join(rows)}</tbody></table>"
        )

    return f"""
<section>
  <div class="section-head">
    <h2>Individual subscribers</h2>
    <div style="display:flex; gap:10px; align-items:center;">
      <input class="search" id="indiv-search" type="text" placeholder="Filter by name or email…"
        onkeyup="filterTable('indiv-search','indiv-table')">
      <div class="links"><a href="/export/individual-subscribers.csv">Export CSV</a></div>
    </div>
  </div>
  {rows_html}
</section>
"""


def _churned_section(churned: list[dict]) -> str:
    if not churned:
        rows_html = '<div class="empty">Nothing lapsed right now.</div>'
    else:
        rows = []
        for entry in churned:
            scope = "Shop" if entry["scope_type"] == "org" else "Individual"
            rows.append(
                f"<tr><td>{_e(entry['label'])}</td><td>{scope}</td><td>{_e(entry['plan'])}</td>"
                f"<td>{_status_pill(entry['status'])}</td><td>{_e(entry['updated_at'])}</td>"
                f"<td>{_hide_button(entry['kind'], entry['scope_id'])}</td></tr>"
            )
        rows_html = (
            "<table><thead><tr><th>Who</th><th>Scope</th><th>Plan</th><th>Status</th>"
            f"<th>Last updated</th><th></th></tr></thead><tbody>{''.join(rows)}</tbody></table>"
        )

    return f"""
<section>
  <div class="section-head"><h2>Churned / lapsed subscriptions</h2></div>
  {rows_html}
</section>
"""


def _hidden_section(hidden: list[dict]) -> str:
    if not hidden:
        rows_html = '<div class="empty">Nothing hidden.</div>'
    else:
        rows = []
        for entry in hidden:
            kind_label = "Shop" if entry["kind"] == admin.HIDDEN_KIND_ORG else "Individual"
            rows.append(
                f"<tr><td>{_e(entry['label'])}</td><td>{kind_label}</td>"
                f"<td>{_e(entry['hidden_at'])}</td>"
                f"<td>{_unhide_button(entry['kind'], entry['ref_id'])}</td></tr>"
            )
        rows_html = (
            "<table><thead><tr><th>Who</th><th>Kind</th><th>Hidden since</th>"
            f"<th></th></tr></thead><tbody>{''.join(rows)}</tbody></table>"
        )

    return f"""
<section>
  <div class="section-head"><h2>Hidden</h2></div>
  {rows_html}
</section>
"""


@app.get("/", response_class=HTMLResponse)
def dashboard() -> str:
    database.init_db()
    admin.init_portal_db()

    stats = admin.get_stats()
    currency = stats["currency"] or DEFAULT_CURRENCY

    body = "\n".join(
        [
            "<h1>Geonix Wrench — Admin Portal</h1>",
            '<p class="sub">Local only. Refresh the page (⌘R) to update the numbers.</p>',
            _stat_tiles(stats, currency),
            _organizations_section(admin.list_organizations()),
            _individual_subscribers_section(admin.list_individual_subscribers()),
            _churned_section(admin.list_churned_subscriptions()),
            _hidden_section(admin.list_hidden()),
            '<p class="footer">Profit is revenue minus <code>ADMIN_MONTHLY_COSTS</code> '
            f"(currently {_money(float(os.getenv('ADMIN_MONTHLY_COSTS', '0')), currency)}) — "
            "set that env var to your actual recurring costs for a real figure; nothing here "
            "tracks Stripe fees, hosting or payroll on its own.</p>",
        ]
    )
    return _page(body)


@app.post("/hide/{kind}/{ref_id}", dependencies=[Depends(reject_cross_site)])
def hide_item(kind: str, ref_id: int) -> RedirectResponse:
    try:
        admin.hide(kind, ref_id)
    except ValueError:
        raise HTTPException(status_code=404, detail="Unknown kind") from None
    return RedirectResponse("/", status_code=303)


@app.post("/unhide/{kind}/{ref_id}", dependencies=[Depends(reject_cross_site)])
def unhide_item(kind: str, ref_id: int) -> RedirectResponse:
    try:
        admin.unhide(kind, ref_id)
    except ValueError:
        raise HTTPException(status_code=404, detail="Unknown kind") from None
    return RedirectResponse("/", status_code=303)


@app.get("/export/organizations.csv")
def export_organizations_csv() -> Response:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(
        ["id", "name", "owner_email", "owner_handle", "plan", "status", "seat_used", "seat_limit"]
    )
    for org in admin.list_organizations():
        writer.writerow(
            [
                org["id"],
                _csv_safe(org["name"]),
                _csv_safe(org["owner_email"]),
                _csv_safe(org["owner_handle"]),
                org["plan"] or "",
                org["subscription_status"] or "",
                org["seat_used"],
                org["seat_limit"],
            ]
        )
    return Response(
        content=buf.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=organizations.csv"},
    )


@app.get("/export/individual-subscribers.csv")
def export_individual_subscribers_csv() -> Response:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["user_id", "email", "handle", "plan", "status", "current_period_end"])
    for sub in admin.list_individual_subscribers():
        writer.writerow(
            [
                sub["user_id"],
                _csv_safe(sub["email"]),
                _csv_safe(sub["handle"]),
                sub["plan"],
                sub["status"],
                sub["current_period_end"] or "",
            ]
        )
    return Response(
        content=buf.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=individual-subscribers.csv"},
    )


if __name__ == "__main__":
    import uvicorn

    if not config.ADMIN_PORTAL_PASSWORD:
        print(
            "ADMIN_PORTAL_PASSWORD is not set: serving without a login. "
            "Set it in .env to require one."
        )

    uvicorn.run(
        app,
        host=os.getenv("ADMIN_PORTAL_HOST", "127.0.0.1"),
        port=int(os.getenv("ADMIN_PORTAL_PORT", "8010")),
    )
