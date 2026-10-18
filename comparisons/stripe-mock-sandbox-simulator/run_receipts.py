"""Send the same six Stripe API calls to one server and record what came back.

Covers retrieve-after-create, list pagination, a declined card, idempotency-key
reuse, retrieve-after-delete and a missing customer, written as comparable JSON.

    python3 run_receipts.py --base-url http://127.0.0.1:12111 --key sk_test_... --label stripe-mock
    python3 run_receipts.py --base-url http://127.0.0.1:PORT --key sk_test_... --label rystic
    python3 run_receipts.py --base-url https://api.stripe.com --key sk_test_... --label stripe

Against Stripe, use your own test-mode secret key: the run creates customers and
a declined charge in that account, and deletes the first customer.
"""
import argparse
import base64
import json
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

API_VERSION = "2026-06-24.dahlia"


ID_PREFIXES = "cus|ch|pi|pm|py|re|txn|evt"


def mask(request):
    """Mask the object ids in a recorded request line, keeping its shape."""
    # Object ids differ per server and run, and name objects in the caller's account.
    return re.sub(r"(?<=[/=])(%s)_(?!doesnotexist\b)[A-Za-z0-9]+" % ID_PREFIXES, r"\1_…", request)


class Client:
    def __init__(self, base_url, key, version=API_VERSION):
        self.base_url = base_url.rstrip("/")
        self.version = version
        token = base64.b64encode((key + ":").encode()).decode()
        self.auth = "Basic " + token
        self.sent = []

    def call(self, method, path, params=None, headers=None):
        """Send one request; return (status, parsed JSON body or None), status 0 if no answer."""
        self.sent.append(mask(method + " " + path))
        data = urllib.parse.urlencode(params).encode() if params else None
        req = urllib.request.Request(self.base_url + path, data=data, method=method)
        req.add_header("Authorization", self.auth)
        req.add_header("Stripe-Version", self.version)
        if data is not None:
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
        for name, value in (headers or {}).items():
            req.add_header(name, value)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as err:
            status, raw = err.code, err.read()
        except OSError:
            return 0, None  # no answer (refused, reset or timed out) is status 0
        try:
            return status, json.loads(raw)
        except ValueError:
            return status, None

    def take_sent(self):
        sent, self.sent = self.sent, []
        return sent


def error_of(body):
    if isinstance(body, dict) and isinstance(body.get("error"), dict):
        return body["error"]
    return None


def field(body, name):
    return body.get(name) if isinstance(body, dict) else None


def run(client):
    calls = []

    def record(name, result):
        calls.append({"id": len(calls) + 1, "name": name,
                      "request": client.take_sent(), "result": result})

    # 1. Create a customer, then read it back.
    _, created = client.call("POST", "/v1/customers",
                             {"email": "jenny.rosen@example.com", "name": "Jenny Rosen"})
    customer_id = field(created, "id") or "cus_missing"
    status, body = client.call("GET", "/v1/customers/" + customer_id)
    record("retrieve a customer after creating it",
           {"status": status, "email": field(body, "email")})

    # 2. Create four more customers, then list three.
    for letter in "abcd":
        client.call("POST", "/v1/customers", {"email": letter + "@example.com"})
    status, body = client.call("GET", "/v1/customers?limit=3")
    data = field(body, "data")
    record("list customers with limit=3",
           {"status": status, "data_count": len(data) if isinstance(data, list) else None,
            "has_more": field(body, "has_more")})

    # 3. Charge a card token that Stripe always declines.
    status, body = client.call("POST", "/v1/charges",
                               {"amount": "2000", "currency": "usd",
                                "source": "tok_chargeDeclined"})
    err = error_of(body)
    if err:
        result = {"status": status, "error_code": err.get("code"),
                  "decline_code": err.get("decline_code")}
    else:
        result = {"status": status, "charge_status": field(body, "status")}
    record("charge a card that is declined", result)

    # 4. Reuse one idempotency key with a different request body.
    key = {"Idempotency-Key": str(uuid.uuid4())}
    client.call("POST", "/v1/customers", {"email": "first@example.com"}, key)
    status, body = client.call("POST", "/v1/customers", {"email": "second@example.com"}, key)
    err = error_of(body)
    if err:
        result = {"status": status, "error_type": err.get("type")}
    else:
        result = {"status": status, "email": field(body, "email")}
    record("reuse an idempotency key with different parameters", result)

    # 5. Delete the first customer, then read it back.
    client.call("DELETE", "/v1/customers/" + customer_id)
    status, body = client.call("GET", "/v1/customers/" + customer_id)
    record("retrieve a customer after deleting it",
           {"status": status, "deleted": field(body, "deleted"),
            "email": field(body, "email")})

    # 6. Retrieve a customer that was never created.
    status, body = client.call("GET", "/v1/customers/cus_doesnotexist")
    err = error_of(body)
    if err:
        result = {"status": status, "error_code": err.get("code")}
    else:
        result = {"status": status, "id": field(body, "id")}
    record("retrieve a customer that does not exist", result)
    return calls


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--key", required=True, help="secret key; never printed")
    parser.add_argument("--label", required=True)
    parser.add_argument("--out", help="output file (default: stdout)")
    parser.add_argument("--stripe-version", default=API_VERSION, help="Stripe-Version header sent on every call")
    args = parser.parse_args()

    run_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    calls = run(Client(args.base_url, args.key, args.stripe_version))
    report = {"label": args.label, "base_url": args.base_url, "stripe_version": args.stripe_version,
              "run_at": run_at, "calls": calls}
    text = json.dumps(report, indent=2) + "\n"
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
        print("wrote " + args.out)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
