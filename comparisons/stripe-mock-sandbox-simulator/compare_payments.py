"""Compare recorded runs against Stripe's, step by step, and merge them into one JSON.

Takes the Stripe run plus one or more server runs written by run_payments.py
(or by run_receipts.py), compares each step's result field by field, prints a
table and optionally writes the merged JSON with a verdict per step and server.
Timings, recorded requests and masked object ids are not compared.

    python3 compare_payments.py results-stripe.json results-mock.json results-rystic.json --out results.json
"""
import argparse
import json
import re
from datetime import datetime, timezone

IGNORED = {"ms", "request", "waited_s"}
ID_PREFIXES = "cus|ch|pi|pm|py|re|txn|evt"  # the kinds run_receipts.py masks
MASKED = re.compile(r"^(%s)_…$" % ID_PREFIXES)
ID = re.compile(r"^(%s)_[A-Za-z0-9]+$" % ID_PREFIXES)


def load(path):
    with open(path) as f:
        return json.load(f)


def unit(report):
    """Return (word, list key, number key) for a payments or a receipts run."""
    return ("step", "steps", "step") if "steps" in report else ("call", "calls", "id")


def entries(report):
    _, items, num = unit(report)
    return {str(e[num]): e for e in report.get(items, [])}


def flatten(value, prefix=""):
    if not isinstance(value, dict) or not value and prefix:
        return {prefix: value}
    out = {}
    for key, inner in value.items():
        if key in IGNORED:
            continue
        out.update(flatten(inner, prefix + "." + key if prefix else key))
    return out


def same(want, got):
    if isinstance(want, str) and isinstance(got, str):
        if MASKED.match(want) and ID.match(got) or MASKED.match(got) and ID.match(want):
            return want.split("_", 1)[0] == got.split("_", 1)[0]
    return want == got


def succeeded(result):
    status = result.get("status") if isinstance(result, dict) else None
    return status is None or 200 <= status < 300


def compare_step(ref, got):
    if got is None:
        return {"verdict": "missing"}
    want, have = flatten(ref.get("result", {})), flatten(got.get("result", {}))
    missing = object()
    fields = sorted(k for k in set(want) | set(have) if not same(want.get(k, missing), have.get(k, missing)))
    verdict = {"verdict": "differs" if fields else "match"}
    if fields:
        verdict["fields"] = fields
        ok_ref, ok_got = succeeded(ref.get("result")), succeeded(got.get("result"))
        if ok_ref and not ok_got:
            verdict["note"] = "error where Stripe succeeded"
        elif ok_got and not ok_ref:
            verdict["note"] = "succeeded where Stripe returned an error"
    return verdict


def slug(label, taken):
    base = re.sub(r"[^a-z0-9]+", "_", label.lower()).strip("_") or "server"
    key, n = base, 2
    while key in taken:
        key, n = "%s_%d" % (base, n), n + 1
    return key


def compare(stripe, servers):
    word = unit(stripe)[0]
    keyed = {"stripe": stripe}
    for report in servers:
        if unit(report)[0] != word:
            raise ValueError("%s is not a run of the same script as the Stripe run" % report.get("label"))
        keyed[slug(report.get("label", ""), set(keyed) | {"name"})] = report
    ref = entries(stripe)
    per, agrees = {}, {}
    for key, report in list(keyed.items())[1:]:
        got = entries(report)
        agrees[key] = 0
        for n, step in ref.items():
            verdict = compare_step(step, got.get(n))
            per.setdefault(n, {"name": step.get("name")})[key] = verdict
            agrees[key] += verdict["verdict"] == "match"
    return {"generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "stripe_version": stripe.get("stripe_version"),
            "note": "Each %s's result is compared field by field with Stripe's; timings, recorded requests "
                    "and masked object ids are not compared." % word,
            word + "s": len(ref), "agrees_with_stripe": agrees, "per_" + word: per, "servers": keyed}


def table(merged):
    word = "step" if "per_step" in merged else "call"
    per, keys = merged["per_" + word], list(merged["agrees_with_stripe"])
    labels = [merged["servers"][k].get("label", k) for k in keys]
    rows = [[word, "name"] + labels]
    for n, step in per.items():
        cells = []
        for k in keys:
            v = step[k]
            cell = v["verdict"] if v["verdict"] != "differs" else "differs: " + ", ".join(v["fields"])
            cells.append(cell)
        rows.append([n, step["name"] or ""] + cells)
    total = merged[word + "s"]
    rows.append(["", "agrees with Stripe"] + ["%d/%d" % (merged["agrees_with_stripe"][k], total) for k in keys])
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return "\n".join("  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip() for r in rows) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("stripe", help="the Stripe run's results JSON")
    parser.add_argument("servers", nargs="+", help="one or more server runs' results JSON")
    parser.add_argument("--out", help="write the merged JSON here")
    args = parser.parse_args()
    try:
        merged = compare(load(args.stripe), [load(p) for p in args.servers])
    except ValueError as e:
        parser.error(str(e))
    print(table(merged), end="")
    if args.out:
        with open(args.out, "w") as f:
            f.write(json.dumps(merged, indent=2) + "\n")
        print("wrote " + args.out)


if __name__ == "__main__":
    main()
