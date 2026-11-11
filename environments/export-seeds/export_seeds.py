#!/usr/bin/env python3
"""Export your real Clerk, Stripe, Resend and GitHub accounts as seed files
for Rystic simulators.

    CLERK_SECRET_KEY=sk_... STRIPE_API_KEY=rk_... RESEND_API_KEY=re_... \\
        python3 export_seeds.py --out ./seeds

It only sends GET requests, to the four services and nowhere else. A service
without a key is skipped. Python 3.9+, standard library only. README.md beside
this file says what is exported, what scrubbing does and how to load the files.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RESERVED_TLDS = {"test", "example", "invalid", "localhost"}
RESERVED_DOMAINS = ("example.com", "example.net", "example.org")


# --- HTTP: GET only ----------------------------------------------------------

class Http:
    """The script's only way to the network. It refuses any method but GET,
    retries 429 and 5xx with backoff, and honours Retry-After."""

    def __init__(self, retries: int = 8, sleep=time.sleep, timeout: int = 60):
        self.retries, self.sleep, self.timeout = retries, sleep, timeout
        self.requests = 0

    def request(self, method: str, url: str, headers: dict | None = None):
        if method.upper() != "GET":
            raise PermissionError(f"export_seeds only sends GET requests; refused {method} {url}")
        req = urllib.request.Request(url, method="GET", headers={
            "Accept": "application/json", "User-Agent": "rystic-export-seeds", **(headers or {})})
        for attempt in range(self.retries + 1):
            self.requests += 1
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as r:
                    return json.loads(r.read().decode() or "null"), r.headers
            except urllib.error.HTTPError as e:
                limited = e.code == 429 or (e.code == 403 and e.headers.get("X-RateLimit-Remaining") == "0")
                if not (limited or e.code >= 500) or attempt == self.retries:
                    body = e.read().decode(errors="replace")[:300]
                    raise ExportError(f"GET {url.split('?')[0]} answered {e.code}: {body}", e.code) from None
                self.sleep(self._wait(e.headers, attempt))
            except (urllib.error.URLError, TimeoutError) as e:
                if attempt == self.retries:
                    raise ExportError(f"GET {url.split('?')[0]} failed: {e}") from None
                self.sleep(min(2 ** attempt, 60))

    def get(self, url: str, headers: dict | None = None):
        return self.request("GET", url, headers)[0]

    @staticmethod
    def _wait(headers, attempt: int) -> float:
        after = headers.get("Retry-After")
        if after and after.replace(".", "", 1).isdigit():
            return min(float(after), 120)
        reset = headers.get("X-RateLimit-Reset")
        if reset and reset.isdigit():
            return min(max(int(reset) - time.time(), 1), 120)
        return min(2 ** attempt, 60)


class ExportError(Exception):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


# --- scrubbing ---------------------------------------------------------------

_AT = r"(?:@|%40|&#0*64;|&#[xX]0*40;|&commat;|\\u0040|\\x40)"
_ADDRESS = re.compile(
    r"([A-Za-z0-9!#$&'*+/=?^_`{|}~.-]{1,254})" + _AT +
    r"([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+)")
_SECRET_KEY = re.compile(r"secret|token|passw(or)?d|api[_-]?key|private[_-]?key|credential", re.I)
_SECRET_VALUE = re.compile(
    r"\b(?:(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{10,}|whsec_[A-Za-z0-9+/=]{10,}|re_[A-Za-z0-9]{8,}_[A-Za-z0-9]{8,}"
    r"|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}"
    r"|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})")
# Fields that carry a message body or a link that opens without a login: the
# key stays, and its text is replaced by the value here.
NULLED = {"resend": {"html": "", "text": ""}, "stripe": {"hosted_invoice_url": None, "invoice_pdf": None}}
NOTHING: dict = {}
DROPPED = "[dropped]"


def reserved(domain: str) -> bool:
    d = domain.lower()
    return d.rsplit(".", 1)[-1] in RESERVED_TLDS or any(d == r or d.endswith("." + r) for r in RESERVED_DOMAINS)


class Scrubber:
    """Rewrites every email address onto a reserved domain and drops secrets.
    The rewrite is a pure function of the address, so one address reads the
    same in every file. It makes mail undeliverable; it does not anonymise."""

    def __init__(self):
        self.addresses: set[str] = set()
        self.secrets = 0

    def text(self, s: str) -> str:
        def address(m: re.Match) -> str:
            local, domain = m.group(1).lower(), m.group(2).lower()
            if not reserved(domain):
                self.addresses.add(f"{local}@{domain}")
                domain += ".test"
            return f"{local}@{domain}"

        def secret(m: re.Match) -> str:
            self.secrets += 1
            return DROPPED
        return _ADDRESS.sub(address, _SECRET_VALUE.sub(secret, s))

    def value(self, v, nulled=NOTHING):
        if isinstance(v, str):
            return self.text(v)
        if isinstance(v, list):
            return [self.value(x, nulled) for x in v]
        if isinstance(v, dict):
            out = {}
            for k, x in v.items():
                if k in nulled and isinstance(x, str):
                    self.secrets += 1
                    out[k] = nulled[k]
                elif isinstance(x, str) and x and _SECRET_KEY.search(k):
                    self.secrets += 1
                else:
                    out[self.text(k)] = self.value(x, nulled)
            return out
        return v


# --- a run -------------------------------------------------------------------

class Run:
    def __init__(self, http: Http, since: dt.datetime | None = None, limit: int | None = None, log=None):
        self.http, self.since, self.limit = http, since, limit
        self.log = log or (lambda s: None)
        self.exported: dict[str, dict[str, int]] = {}
        self.skipped: list[tuple[str, str, object, str]] = []   # service, type, count, why
        self.dangling: list[str] = []
        self.no_key: list[str] = []
        self.failed: list[tuple[str, str]] = []

    @property
    def since_s(self) -> int | None:
        return int(self.since.timestamp()) if self.since else None

    def take(self, pages, created=None):
        """Records from an iterator, newest first when `created` is given:
        stops at --limit, and at the first record older than --since."""
        out = []
        for rec in pages:
            if created and self.since_s is not None and created(rec) < self.since_s:
                break
            out.append(rec)
            if self.limit is not None and len(out) >= self.limit:
                break
        return out

    def count(self, service: str, typ: str, n: int):
        self.exported.setdefault(service, {})[typ] = n
        self.log(f"  {service}: {n} {typ}")

    def skip(self, service: str, typ: str, count, why: str):
        self.skipped.append((service, typ, count, why))

    def refs(self, service: str, what: str, wanted: dict[str, set], have: set):
        for ref, holders in sorted(wanted.items()):
            if ref and ref not in have:
                self.dangling.append(f"{service}: {what} {ref} is not in the export "
                                     f"(named by {len(holders)} record(s), e.g. {sorted(holders)[0]})")


def keyed(records, *fields) -> dict:
    return {"/".join(str(r[f]) for f in fields): r for r in records}


def _ref(v):
    return v.get("id") if isinstance(v, dict) else v


# --- Clerk -------------------------------------------------------------------

def export_clerk(run: Run, key: str, base: str) -> dict:
    h = {"Authorization": f"Bearer {key}"}

    def pages(path: str, size: int, extra: str = ""):
        offset = 0
        while True:
            body = run.http.get(f"{base}{path}?limit={size}&offset={offset}{extra}", h)
            rows = body if isinstance(body, list) else body.get("data", [])
            yield from rows
            if len(rows) < size:
                return
            offset += size

    ms = lambda r: r.get("created_at", 0) // 1000
    users = run.take(pages("/v1/users", 500, "&order_by=-created_at"), ms)
    orgs = run.take(pages("/v1/organizations", 500, "&include_members_count=true&order_by=-created_at"), ms)
    members = []
    for org in orgs:
        for m in pages(f"/v1/organizations/{org['id']}/memberships", 500):
            # A membership's nested organization has fields the list leaves out.
            for k, v in (m.get("organization") or {}).items():
                org.setdefault(k, v)
            # The simulator files a membership under its two ids, not the nested organization.
            rec = {k: v for k, v in m.items() if k != "organization"}
            rec["organization_id"] = org["id"]
            rec["user_id"] = (m.get("public_user_data") or {}).get("user_id", "")
            members.append(rec)
    run.count("clerk", "users", len(users))
    run.count("clerk", "organizations", len(orgs))
    run.count("clerk", "memberships", len(members))
    wanted: dict[str, set] = {}
    for m in members:
        wanted.setdefault(m["user_id"], set()).add(m["id"])
    run.refs("clerk", "user", wanted, {u["id"] for u in users})
    return {"state_user": keyed(users, "id"), "state_organization": keyed(orgs, "id"),
            "state_organization_membership": keyed(members, "organization_id", "user_id")}


# --- Stripe ------------------------------------------------------------------

def export_stripe(run: Run, key: str, base: str) -> dict:
    h = {"Authorization": "Basic " + base64.b64encode(f"{key}:".encode()).decode()}

    def pages(path: str, extra: str = "", since: bool = True):
        q = "limit=100" + extra
        if since and run.since_s is not None:
            q += f"&created[gte]={run.since_s}"
        after = ""
        while True:
            body = run.http.get(f"{base}{path}?{q}{after}", h)
            rows = body.get("data", [])
            yield from rows
            if not body.get("has_more") or not rows:
                return
            after = "&starting_after=" + urllib.parse.quote(str(rows[-1]["id"]))

    def children(parent: dict, field: str, path: str) -> list:
        """A nested list in full: Stripe embeds the first page only."""
        sub = parent.get(field) or {}
        if sub.get("has_more"):
            return list(pages(path, since=False))
        return list(sub.get("data", []))

    products = run.take(pages("/v1/products"))
    prices = run.take(pages("/v1/prices"))
    coupons = run.take(pages("/v1/coupons"))
    customers = run.take(pages("/v1/customers"))
    subs = run.take(pages("/v1/subscriptions", "&status=all"))
    invoices = run.take(pages("/v1/invoices"))
    items, lines = [], []
    for s in subs:
        items += _sub_items(s, pages)
    for inv in invoices:
        for line in children(inv, "lines", f"/v1/invoices/{inv['id']}/lines"):
            lines.append({**line, "invoice": line.get("invoice") or inv["id"]})
    for typ, rows in (("products", products), ("prices", prices), ("coupons", coupons), ("customers", customers),
                      ("subscriptions", subs), ("subscription items", items), ("invoices", invoices),
                      ("invoice line items", lines)):
        run.count("stripe", typ, len(rows))
    if any(r.get("livemode") for r in customers + subs + invoices + products):
        run.log("  stripe: this is a live-mode key; records keep livemode: true")

    def wanted(rows, ref) -> dict[str, set]:
        out: dict[str, set] = {}
        for r in rows:
            out.setdefault(ref(r), set()).add(r["id"])
        return out
    cust = {c["id"] for c in customers}
    run.refs("stripe", "product", wanted(prices, lambda p: _ref(p.get("product"))), {p["id"] for p in products})
    run.refs("stripe", "customer", wanted(subs + invoices, lambda r: _ref(r.get("customer"))), cust)
    run.refs("stripe", "price", wanted(items, lambda i: _ref(i.get("price"))), {p["id"] for p in prices})
    held = sum(1 for r in subs + customers if r.get("discounts") or r.get("discount"))
    if held:
        run.skip("stripe", "discounts", held, "Stripe has no list for discounts; the records that carry one keep its id")
    run.skip("stripe", "payment methods", "all", "card and bank details are not exported")
    return {"state_product": keyed(products, "id"), "state_price": keyed(prices, "id"),
            "state_coupon": keyed(coupons, "id"), "state_customer": keyed(customers, "id"),
            "state_subscription": keyed(subs, "id"), "state_subscription_item": keyed(items, "id"),
            "state_invoice": keyed(invoices, "id"), "state_invoice_line_item": keyed(lines, "invoice", "id")}


def _sub_items(sub: dict, pages) -> list:
    emb = sub.get("items") or {}
    if emb.get("has_more"):
        rows = list(pages("/v1/subscription_items", f"&subscription={sub['id']}", since=False))
    else:
        rows = list(emb.get("data", []))
    return [{**i, "subscription": i.get("subscription") or sub["id"]} for i in rows]


# --- Resend ------------------------------------------------------------------

def export_resend(run: Run, key: str, base: str) -> dict:
    h = {"Authorization": f"Bearer {key}"}

    def pages(path: str):
        after = ""
        while True:
            body = run.http.get(f"{base}{path}?limit=100{after}", h)
            rows = body.get("data", [])
            yield from rows
            if not body.get("has_more") or not rows:
                return
            after = "&after=" + urllib.parse.quote(str(rows[-1]["id"]))

    def sent(e: dict) -> int:
        s = re.sub(r"(\.\d+)?\+00$", "+00:00", str(e.get("created_at", "")).replace(" ", "T"))
        try:
            return int(dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
        except ValueError:
            return 2 ** 62

    listed = run.take(pages("/emails"), sent)
    # The list leaves out the body and a few fields; each email's own GET has them.
    emails = [run.http.get(f"{base}/emails/{e['id']}", h) for e in listed]
    run.count("resend", "emails", len(emails))
    why = "the Resend simulator has no register for them"
    for typ, path in (("domains", "/domains"), ("audiences", "/audiences")):
        try:
            rows = list(pages(path))
        except ExportError as e:
            run.skip("resend", typ, "?", f"{why}; they could not be counted ({e.status or 'no answer'})")
            continue
        run.skip("resend", typ, len(rows), why)
        if typ == "audiences":
            try:
                n = sum(len(list(pages(f"/audiences/{a['id']}/contacts"))) for a in rows)
                run.skip("resend", "contacts", n, why)
            except ExportError as e:
                run.skip("resend", "contacts", "?", f"{why}; they could not be counted ({e.status or 'no answer'})")
    return {"state_email": keyed(emails, "id")}


# --- GitHub ------------------------------------------------------------------

def export_github(run: Run, key: str, base: str, repos: list[str]) -> dict:
    h = {"Authorization": f"Bearer {key}", "Accept": "application/vnd.github+json",
         "X-GitHub-Api-Version": "2022-11-28"}

    def pages(url: str):
        while url:
            body, headers = run.http.request("GET", url, h)
            yield from body
            m = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link") or "")
            url = m.group(1) if m else ""

    def made(r: dict) -> int:
        return int(dt.datetime.fromisoformat(r["created_at"].replace("Z", "+00:00")).timestamp())

    out = {}
    for repo in repos:
        rows = [r for r in pages(f"{base}/repos/{repo}/releases?per_page=100")
                if run.since_s is None or made(r) >= run.since_s]
        out[repo] = rows[:run.limit] if run.limit is not None else rows
    run.count("github", "releases", sum(len(v) for v in out.values()))
    run.count("github", "release assets", sum(len(r.get("assets", [])) for v in out.values() for r in v))
    return out


# --- files and summary -------------------------------------------------------

SERVICES = (
    ("clerk", "CLERK_SECRET_KEY", "CLERK_API_URL", "https://api.clerk.com"),
    ("stripe", "STRIPE_API_KEY", "STRIPE_API_URL", "https://api.stripe.com"),
    ("resend", "RESEND_API_KEY", "RESEND_API_URL", "https://api.resend.com"),
    ("github", "GITHUB_TOKEN", "GITHUB_API_URL", "https://api.github.com"),
)


def export(env: dict, out_dir: str, *, scrub: bool = True, since=None, limit=None, repos=(),
           http: Http | None = None, log=None, now: dt.datetime | None = None) -> Run:
    run = Run(http or Http(), since, limit, log)
    clock = (now or dt.datetime.now(dt.timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    scrubber = Scrubber()
    os.makedirs(out_dir, exist_ok=True)
    for name, key_var, url_var, default in SERVICES:
        key = env.get(key_var, "")
        base = (env.get(url_var) or default).rstrip("/")
        if not key:
            run.no_key.append(f"{name} ({key_var} is not set)")
            continue
        if name == "github" and not repos:
            run.no_key.append("github (no --github-repo given)")
            continue
        run.log(f"{name}: reading {base}")
        try:
            if name == "github":
                # Nothing seeds releases yet: the simulator loads this file as an
                # empty seed and ignores the `releases` key.
                doc = {"seed": {}, "releases": export_github(run, key, base, list(repos))}
            else:
                doc = {"seed": {"clerk": export_clerk, "stripe": export_stripe, "resend": export_resend}[name](run, key, base)}
        except ExportError as e:
            run.failed.append((name, str(e)))
            run.exported.pop(name, None)
            continue
        if scrub:
            doc = scrubber.value(doc, NULLED.get(name, NOTHING))
        doc = {"name": f"export-{name}", "clock": clock, "exported_at": clock, "scrubbed": scrub, **doc}
        path = os.path.join(out_dir, f"{name}.json")
        with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
            f.write("\n")
    run.clock, run.scrub, run.scrubber, run.out_dir = clock, scrub, scrubber, out_dir
    return run


def summary(run: Run) -> str:
    lines = [f"Exported at {run.clock} to {run.out_dir} ({run.http.requests} GET requests)"]
    for service, types in run.exported.items():
        lines.append(f"  {service}.json: " + ", ".join(f"{n} {t}" for t, n in types.items()))
    if run.scrub:
        lines.append(f"Scrubbed: {len(run.scrubber.addresses)} distinct address(es) rewritten to .test, "
                     f"{run.scrubber.secrets} secret(s) and body field(s) dropped")
    else:
        lines.append("NOT scrubbed (--no-scrub): the files hold real addresses and secrets. "
                     "They load with `rystic up`; rystic-site's SCENARIO= refuses them.")
    if run.skipped:
        lines.append("Skipped:")
        lines += [f"  {s} {t} ({n}): {why}" for s, t, n, why in run.skipped]
    if run.dangling:
        lines.append(f"Dangling references ({len(run.dangling)}):")
        lines += [f"  {d}" for d in run.dangling[:50]]
        if len(run.dangling) > 50:
            lines.append(f"  ... and {len(run.dangling) - 50} more")
    if run.no_key:
        lines.append("Services skipped: " + "; ".join(run.no_key))
    if run.failed:
        lines.append("FAILED (no file written):")
        lines += [f"  {s}: {why}" for s, why in run.failed]
    return "\n".join(lines)


def parse_since(s: str) -> dt.datetime:
    try:
        d = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        raise argparse.ArgumentTypeError(f"{s!r} is not a date (2026-01-31) or a time (2026-01-31T12:00:00Z)")
    return d if d.tzinfo else d.replace(tzinfo=dt.timezone.utc)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default="./seeds", help="output directory (default ./seeds)")
    p.add_argument("--github-repo", action="append", default=[], metavar="OWNER/NAME",
                   help="a repository whose releases to export; repeatable")
    p.add_argument("--since", type=parse_since, help="only objects created at or after this date or time (UTC)")
    p.add_argument("--limit", type=int, help="at most this many objects of each type, newest first")
    p.add_argument("--no-scrub", action="store_true", help="keep real email addresses, secrets and email bodies")
    a = p.parse_args(argv)
    run = export(dict(os.environ), a.out, scrub=not a.no_scrub, since=a.since, limit=a.limit,
                 repos=a.github_repo, log=lambda s: print(s, file=sys.stderr))
    print(summary(run))
    return 1 if run.failed or not run.exported else 0


if __name__ == "__main__":
    sys.exit(main())
