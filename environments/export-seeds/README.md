# export-seeds

Reads your real Clerk, Stripe, Resend and GitHub accounts and writes seed files that Rystic simulators load. You run it with your own keys. It sends GET requests only, to those four services and nowhere else. Python 3.9 or later, standard library only.

```sh
CLERK_SECRET_KEY=sk_... STRIPE_API_KEY=rk_... RESEND_API_KEY=re_... GITHUB_TOKEN=ghp_... \
  python3 export_seeds.py --out ./seeds --github-repo acme/app
```

| Input | Meaning |
|---|---|
| `CLERK_SECRET_KEY`, `STRIPE_API_KEY`, `RESEND_API_KEY`, `GITHUB_TOKEN` | One key per service. A service without its key is skipped. Use read-only keys where the service has them: a Stripe restricted key, a GitHub fine-grained token |
| `--github-repo OWNER/NAME` | A repository whose releases to export. Repeatable. GitHub is skipped without one |
| `--out DIR` | Output directory. Default `./seeds` |
| `--since DATE` | Only objects created at or after this date or time (UTC) |
| `--limit N` | At most N objects of each type, newest first |
| `--no-scrub` | Keep real addresses, secrets and email bodies |

## What it writes

One file per service: `clerk.json`, `stripe.json`, `resend.json`, `github.json`. Each holds the records under `seed` and the time of the export under `clock`, the same time in every file. Files are written readable by you only.

| Service | Exported | Not exported |
|---|---|---|
| Clerk | users, organizations, memberships, with their metadata | invitations, sessions |
| Stripe | products, prices, coupons, customers, subscriptions and their items, invoices and their line items | payment methods, discounts, everything else |
| Resend | sent emails | domains, audiences and contacts: the simulator cannot hold them, so they are counted and skipped |
| GitHub | releases and their assets, metadata only | everything else |

IDs and all other fields are kept as the service returned them, so a Clerk organization ID stored in Stripe metadata still matches. A live-mode Stripe key exports live-mode records unchanged.

It ends with a summary: objects exported per type, objects skipped and why, references to objects that are not in the export (which `--since` and `--limit` cause), and services skipped.

## Scrubbing

On by default. It makes mail undeliverable and removes credentials. It does not anonymise: names, phone numbers and postal addresses stay.

1. Every email address, wherever it appears, is lowercased and moved to a reserved domain: `jane@acme.com` becomes `jane@acme.com.test`. An address already on a reserved domain (`.test`, `.example`, `.invalid`, `.localhost`, `example.com`, `example.net`, `example.org`) stays.
2. Resend email bodies (`html`, `text`) are emptied. Subject, sender and recipients stay.
3. Stripe's `hosted_invoice_url` and `invoice_pdf` are nulled: they open an invoice without a login.
4. A text value under a key named like a secret (`secret`, `token`, `password`, `api_key`, `private_key`, `credential`) is removed, in metadata too.
5. Anything shaped like a Stripe, Resend or GitHub key, a webhook secret or a JWT is replaced with `[dropped]`.

## Load the files

With `rystic up`, name each file in your stack file. The simulators start at the export time.

```yaml
version: 1
project: my-export
services:
  clerk:  {product: clerk-twin,  port: 8080, seed: ./seeds/clerk.json}
  stripe: {product: stripe-twin, port: 8081, seed: ./seeds/stripe.json}
  resend: {product: resend-twin, port: 8082, seed: ./seeds/resend.json}
```

One simulator alone: `rystic run stripe-twin --seed ./seeds/stripe.json`.

No simulator serves releases yet. `github.json` keeps them under `releases` beside an empty `seed`, so a simulator loads it and ignores them.

## Test

```sh
python3 test_export_seeds.py
```

No real account is touched. The unit tests need nothing. The round trip needs the `rystic` CLI with `clerk-twin`, `stripe-twin` and `resend-twin` pulled, and is skipped without them: it exports from three populated simulators, loads the files into three fresh ones with `RYSTIC_SEED_GATE=reject`, and compares every list. It takes about a minute and a half.
