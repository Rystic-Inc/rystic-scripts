#!/usr/bin/env python3
"""Tests for export_seeds.py. No real account is touched.

    python3 test_export_seeds.py

The unit tests need nothing. The simulator round trip needs the `rystic` CLI
with the clerk, stripe and resend simulators pulled, and is skipped without
them: it exports from three populated simulators, loads the files into three
fresh ones under RYSTIC_SEED_GATE=reject, and compares every list.
"""
import base64
import datetime as dt
import http.server
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
import urllib.parse
import urllib.request

import export_seeds as es


class GetOnly(unittest.TestCase):
    def test_refuses_every_method_but_get(self):
        for method in ("POST", "PUT", "PATCH", "DELETE", "post"):
            with self.assertRaises(PermissionError):
                es.Http().request(method, "http://127.0.0.1:1/never-sent")


class Scrub(unittest.TestCase):
    def setUp(self):
        self.s = es.Scrubber()

    def test_addresses_move_to_a_reserved_domain(self):
        self.assertEqual(self.s.text("Jane@Acme.com"), "jane@acme.com.test")
        self.assertEqual(self.s.text("mail <a.b+c@x.co.uk>, d@y.io"), "mail <a.b+c@x.co.uk.test>, d@y.io.test")
        self.assertEqual(self.s.text("to=jane%40acme.com&x"), "to=jane@acme.com.test&x")

    def test_reserved_addresses_stay(self):
        for a in ("a@acme.test", "a@example.com", "a@mail.example.org", "a@b.example", "a@x.com.test"):
            self.assertEqual(self.s.text(a), a)

    def test_same_address_same_rewrite_everywhere(self):
        out = self.s.value({"a": "jane@acme.com", "b": [{"note": "cc JANE@ACME.COM"}], "jane@acme.com": 1})
        self.assertEqual(out, {"a": "jane@acme.com.test", "b": [{"note": "cc jane@acme.com.test"}],
                               "jane@acme.com.test": 1})
        self.assertEqual(self.s.addresses, {"jane@acme.com"})

    def test_secrets_are_dropped(self):
        out = self.s.value({
            "private_metadata": {"stripe_customer": "cus_123", "api_key": "abc", "webhook_secret": "x"},
            "password_enabled": True, "note": "key sk_live_abcdefghij1234 here",
            "html": "<p>reset</p>", "text": "reset", "hosted_invoice_url": "https://invoice.stripe.com/i/x",
        }, {"html": "", "text": "", "hosted_invoice_url": None})
        self.assertEqual(out, {
            "private_metadata": {"stripe_customer": "cus_123"}, "password_enabled": True,
            "note": "key [dropped] here", "html": "", "text": "", "hosted_invoice_url": None})

    def test_output_holds_no_unreserved_address(self):
        blob = json.dumps(self.s.value({"x": ["a@b.com", "c@d.org x e@f.test"], "g@h.net": {"i": "j@k.dev"}}))
        self.assertEqual(unreserved(blob), [])


def unreserved(text: str) -> list:
    return [m.group(0) for m in es._ADDRESS.finditer(text) if not es.reserved(m.group(2))]


class Stub(http.server.BaseHTTPRequestHandler):
    """A two-page GitHub releases list that answers 429 once per page."""
    limited = set()
    methods = []

    def do_GET(self):
        Stub.methods.append(self.command)
        if self.path not in Stub.limited:
            Stub.limited.add(self.path)
            self.send_response(429)
            self.send_header("Retry-After", "0")
            self.end_headers()
            return
        page = int(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("page", ["1"])[0])
        rows = [{"id": i, "tag_name": f"v{i}", "created_at": f"2026-0{i}-01T00:00:00Z", "author": {"email": "rel@corp.io"},
                 "assets": [{"id": i * 10, "name": "a.tgz", "size": 1}]} for i in ((3, 2) if page == 1 else (1,))]
        self.send_response(200)
        if page == 1:
            self.send_header("Link", f'<http://127.0.0.1:{self.server.server_port}/repos/o/r/releases?per_page=100&page=2>; rel="next"')
        self.end_headers()
        self.wfile.write(json.dumps(rows).encode())

    def log_message(self, *a):
        pass


class GitHubAndBackoff(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.env = {"GITHUB_TOKEN": "t", "GITHUB_API_URL": f"http://127.0.0.1:{cls.srv.server_port}"}

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def run_export(self, **kw):
        Stub.limited.clear()
        self.waits = []
        out = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, out)
        run = es.export(self.env, out, repos=["o/r"], http=es.Http(sleep=self.waits.append), **kw)
        with open(os.path.join(out, "github.json")) as f:
            return run, json.load(f)

    def test_pages_backs_off_and_writes_a_loadable_file(self):
        run, doc = self.run_export()
        self.assertEqual([r["id"] for r in doc["releases"]["o/r"]], [3, 2, 1])
        self.assertEqual(self.waits, [0.0, 0.0])            # one 429 per page, Retry-After honoured
        self.assertEqual(doc["seed"], {})                   # a simulator loads it as an empty seed
        self.assertEqual(doc["clock"], run.clock)
        self.assertEqual(doc["releases"]["o/r"][0]["author"]["email"], "rel@corp.io.test")
        self.assertEqual(run.exported["github"], {"releases": 3, "release assets": 3})
        self.assertEqual(set(Stub.methods), {"GET"})
        self.assertIn("clerk (CLERK_SECRET_KEY is not set)", run.no_key)

    def test_since_limit_and_no_scrub(self):
        _, doc = self.run_export(since=dt.datetime(2026, 2, 1, tzinfo=dt.timezone.utc), limit=1, scrub=False)
        self.assertEqual([r["id"] for r in doc["releases"]["o/r"]], [3])
        self.assertEqual(doc["releases"]["o/r"][0]["author"]["email"], "rel@corp.io")

    def test_a_repo_is_required(self):
        run = es.export(self.env, tempfile.mkdtemp(), repos=[])
        self.assertEqual(run.exported, {})
        self.assertIn("github (no --github-repo given)", run.no_key)


# --- simulator round trip ------------------------------------------------------

TWINS = {"clerk": ("clerk-twin", "clerk_acme_tenant"), "stripe": ("stripe-twin", "design_studio"),
         "resend": ("resend-twin", "design_studio")}
AUTH = {"clerk": "Bearer sk_test_sim", "resend": "Bearer re_sim",
        "stripe": "Basic " + base64.b64encode(b"sk_test_sim:").decode()}


def call(url, auth, data=None):
    """A read through the exporter's own client (it backs off), or a form POST
    that sets a source simulator up."""
    if data is None:
        return es.Http().get(url, {"Authorization": auth})
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), headers={"Authorization": auth})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b"null")


def sim_clock(base) -> str:
    with urllib.request.urlopen(f"{base}/_rystic/version", timeout=60) as r:
        return json.load(r)["clock"]


@unittest.skipUnless(shutil.which("rystic"), "the rystic CLI is not installed")
class SimulatorRoundTrip(unittest.TestCase):
    maxDiff = 3000
    """Export from populated simulators, load into fresh ones, compare each GET."""

    @classmethod
    def setUpClass(cls):
        cls.names, cls.out = [], tempfile.mkdtemp()
        cls.addClassCleanup(cls.stop)
        cls.src = {svc: cls.start(svc, "--scenario", scenario) for svc, (_, scenario) in TWINS.items()}
        cls.populate_stripe(cls.src["stripe"])
        env = {"CLERK_SECRET_KEY": "sk_test_sim", "STRIPE_API_KEY": "sk_test_sim", "RESEND_API_KEY": "re_sim",
               **{f"{svc.upper()}_API_URL": url for svc, url in cls.src.items()}}
        # A real export happens now; a simulator's "now" is its own clock, and a
        # later one would have Stripe bill the months in between.
        now = dt.datetime.fromisoformat(sim_clock(cls.src["stripe"]).replace("Z", "+00:00"))
        cls.run_ = es.export(env, cls.out, now=now)
        cls.dst = {svc: cls.start(svc, "--seed", os.path.join(cls.out, f"{svc}.json"), gate="reject") for svc in TWINS}

    @classmethod
    def start(cls, svc, *args, gate=None):
        name = f"export-seeds-test-{os.getpid()}-{len(cls.names)}"
        args += ("--env", f"RYSTIC_SEED_GATE={gate}") if gate else ()
        p = subprocess.run(["rystic", "run", TWINS[svc][0], "-d", "--name", name, "--port", "0", *args, "--json"],
                           capture_output=True, text=True)
        if p.returncode != 0:
            raise unittest.SkipTest(f"rystic run {TWINS[svc][0]} failed: {(p.stderr or p.stdout).strip()[:300]}")
        cls.names.append(name)
        return f"http://localhost:{json.loads(p.stdout)['data']['port']}"

    @classmethod
    def stop(cls):
        if cls.names:
            subprocess.run(["rystic", "stop", *cls.names], capture_output=True)
            subprocess.run(["rystic", "rm", *cls.names], capture_output=True)
        shutil.rmtree(cls.out, ignore_errors=True)

    @staticmethod
    def populate_stripe(base):
        """The shipped world has customers only; add the billing objects."""
        a = AUTH["stripe"]
        post = lambda path, data: call(f"{base}/v1/{path}", a, data)
        post("products", {"id": "prod_plan", "name": "Plan", "metadata[clerk_org]": "org_31acme000000000000000001"})
        price = post("prices", {"product": "prod_plan", "unit_amount": 2000, "currency": "usd", "recurring[interval]": "month"})
        post("coupons", {"id": "TWENTY", "percent_off": 20, "duration": "once"})
        customer = call(f"{base}/v1/customers?limit=1", a)["data"][0]["id"]
        post("subscriptions", {"customer": customer, "items[0][price]": price["id"],
                               "collection_method": "send_invoice", "days_until_due": 30})

    def lists(self, svc, base):
        a = AUTH[svc]
        if svc == "clerk":
            orgs = call(f"{base}/v1/organizations?limit=500&include_members_count=true", a)["data"]
            members = [m for o in orgs for m in call(f"{base}/v1/organizations/{o['id']}/memberships?limit=500", a)["data"]]
            return {"users": call(f"{base}/v1/users?limit=500", a), "organizations": orgs, "memberships": members}
        if svc == "stripe":
            out = {}
            for typ in ("products", "prices", "coupons", "customers", "subscriptions", "invoices"):
                rows, after = [], ""
                while True:
                    page = call(f"{base}/v1/{typ}?limit=100{'&status=all' if typ == 'subscriptions' else ''}{after}", a)
                    rows += page["data"]
                    if not page["has_more"]:
                        break
                    after = f"&starting_after={rows[-1]['id']}"
                out[typ] = rows
            return out
        listed, after = [], ""
        while True:
            page = call(f"{base}/emails?limit=100{after}", a)
            listed += page["data"]
            if not page["has_more"]:
                break
            after = f"&after={listed[-1]['id']}"
        # Every email as the list gives it, and the newest 25 in full.
        return {"emails": listed, "emails in full": [call(f"{base}/emails/{e['id']}", a) for e in listed[:25]]}

    def plain(self, svc, rows):
        """Rows without the serving simulator's origin: Clerk's image URLs carry it."""
        if svc == "clerk":
            # The Clerk simulator adds a null logo_url to a seeded membership's
            # nested organization; the organization itself compares in full.
            for r in rows:
                if isinstance(r.get("organization"), dict):
                    r["organization"].pop("logo_url", None)
        blob = json.dumps(rows)
        for origin in (self.src[svc], self.dst[svc], "https://img.clerk.com"):
            blob = blob.replace(origin, "ORIGIN")
        return json.loads(blob)

    def test_each_get_returns_what_the_source_returned(self):
        for svc in TWINS:
            src, dst = self.lists(svc, self.src[svc]), self.lists(svc, self.dst[svc])
            scrub = es.Scrubber()
            for typ, rows in src.items():
                with self.subTest(service=svc, type=typ):
                    self.assertGreater(len(rows), 0, "the source holds none, so the comparison proves nothing")
                    # The same scrub the export applied, and each simulator's own origin taken out.
                    want = self.plain(svc, scrub.value(rows, es.NULLED.get(svc, es.NOTHING)))
                    got = self.plain(svc, dst[typ])
                    by_id = lambda rs: {r["id"]: r for r in rs}
                    self.assertEqual(sorted(by_id(got)), sorted(by_id(want)))
                    self.assertEqual(by_id(got), by_id(want))

    def test_files_are_world_documents_on_one_clock(self):
        docs = {}
        for svc in TWINS:
            with open(os.path.join(self.out, f"{svc}.json")) as f:
                docs[svc] = json.load(f)
        self.assertEqual({d["clock"] for d in docs.values()}, {self.run_.clock})
        for svc, d in docs.items():
            self.assertTrue(d["seed"], svc)
            self.assertEqual(unreserved(json.dumps(d)), [], svc)
        for e in docs["resend"]["seed"]["state_email"].values():
            self.assertEqual((e["html"], e["text"]), ("", ""))

    def test_the_fresh_simulators_start_on_the_export_clock(self):
        for svc, base in self.dst.items():
            with self.subTest(service=svc):
                self.assertEqual(sim_clock(base)[:10], self.run_.clock[:10])

    def test_summary_counts(self):
        self.assertEqual(self.run_.exported["clerk"], {"users": 5, "organizations": 1, "memberships": 5})
        self.assertEqual(self.run_.exported["resend"], {"emails": 595})
        st = self.run_.exported["stripe"]
        self.assertEqual((st["products"], st["prices"], st["coupons"], st["subscriptions"], st["subscription items"],
                          st["invoices"], st["invoice line items"]), (1, 1, 1, 1, 1, 1, 1))
        self.assertEqual(self.run_.failed, [])
        self.assertEqual(self.run_.dangling, [])
        self.assertIn("domains", [t for _, t, _, _ in self.run_.skipped])


if __name__ == "__main__":
    unittest.main(verbosity=2)
