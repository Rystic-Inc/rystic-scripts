# stripe-mock, the Stripe sandbox and a simulator

The same Stripe API calls, sent to three servers and scored against Stripe itself:

- [stripe-mock](https://github.com/stripe/stripe-mock) `v0.206.0`, Stripe's own mock server,
- the Rystic Stripe simulator (`stripe-twin`), run locally,
- Stripe's API in test mode, in a fresh sandbox. Its answers are the reference.

`comparisons/` ships in no release archive: it lives only in this repository.

## Scripts

Python 3, standard library only. Run them from this folder.

| Script | What it does |
|---|---|
| `run_receipts.py` | Sends six calls to one server and writes what came back as JSON: retrieve a customer after creating it, list customers with `limit=3`, charge a card that is declined (`tok_chargeDeclined`), reuse an `Idempotency-Key` with different parameters, retrieve a customer after deleting it, and retrieve a customer that was never created. |
| `run_payments.py` | Runs one nine-step payments flow against one server and writes each step's answer as JSON. A customer pays $50 through a PaymentIntent (and the request is replayed with the same `Idempotency-Key`), the charge and its balance transaction are read, $20 is refunded, then the rest, then a third refund is tried. A second payment is declined. The last two steps list the customer's charges and the events the flow caused. |
| `compare_payments.py` | Takes the Stripe run plus one or more server runs from either script, compares each step's result with Stripe's field by field, prints a table and, with `--out`, writes one merged JSON with a verdict per step and server and each server's count. |
| `test_compare_payments.py`, `test_run_receipts.py` | Unit tests, with fixtures in `testdata/`: `python3 -m unittest`. |

## Reproduce

Start each server on fresh state, run both scripts against it, then compare.

stripe-mock, as its README runs it, pinned to the version compared here:

    docker run --rm -it -p 12111-12112:12111-12112 stripe/stripe-mock:v0.206.0

    python3 run_receipts.py --base-url http://localhost:12111 --key sk_test_... --label "stripe-mock v0.206.0" --out results-stripe-mock-receipts.json
    python3 run_payments.py --base-url http://localhost:12111 --key sk_test_... --label "stripe-mock v0.206.0" --out results-stripe-mock-payments.json

The Rystic simulator, through the public installer. `--port 0` picks a free port and prints it:

    curl -fsSL https://www.rystic.ai/install.sh | sh
    rystic run stripe-twin -d --port 0

    python3 run_receipts.py --base-url http://localhost:PORT --key sk_test_... --label "Rystic stripe-twin" --out results-rystic-receipts.json
    python3 run_payments.py --base-url http://localhost:PORT --key sk_test_... --label "Rystic stripe-twin" --out results-rystic-payments.json

The two local servers do not check the key; `sk_test_...` works as typed.

Stripe, with your own test-mode secret key (`sk_test_...`) from a fresh, empty sandbox. The runs create customers, PaymentIntents, charges and refunds in that sandbox and delete one customer. The key is sent only to the `--base-url` you give and is never printed or written:

    python3 run_receipts.py --base-url https://api.stripe.com --key sk_test_... --label "Stripe test mode" --out results-stripe-receipts.json
    python3 run_payments.py --base-url https://api.stripe.com --key sk_test_... --label "Stripe test mode" --out results-stripe-payments.json

Then compare, the Stripe run first:

    python3 compare_payments.py results-stripe-receipts.json results-stripe-mock-receipts.json results-rystic-receipts.json --out results-receipts.json
    python3 compare_payments.py results-stripe-payments.json results-stripe-mock-payments.json results-rystic-payments.json --out results-payments.json

Stripe attaches a charge's balance transaction a few seconds after the charge, so `run_payments.py` waits up to 30 seconds for it on any server. A server that never attaches one adds those 30 seconds to its run.

## Stripe-Version

Every call sends `Stripe-Version: 2026-06-24.dahlia`, the version the results were recorded with. Change it with `--stripe-version`; each results file records the version it used.

## Masking

Each step records the requests it sent, with object ids masked: `GET /v1/charges/ch_…`, `GET /v1/charges?customer=cus_…&limit=10`. Ids differ per server and per run, and on Stripe they name objects in your account. `cus_doesnotexist`, the id that is never created, is kept as is. Results record statuses, error codes, amounts and flags, never keys or account details; the one id a result can hold is the one a server returns for `cus_doesnotexist`. The test email is `jenny.rosen@example.com`.

## Scoring

A step agrees with Stripe when every field of its recorded result equals Stripe's, nested fields included. An error where Stripe succeeded, a missing field, an extra field and a different value each make the step disagree. A step a server's run never reached (the flow stops when a step it depends on fails) is `missing` and disagrees. The time each step took and the recorded requests are not compared, and a masked id in a result (`ch_…`) matches any id of the same kind. A server that does not answer a request records status `0`. A server's score is the number of steps that agree, out of the steps Stripe ran: out of 6 for the receipts, out of 9 for the payments flow.

## Results

[`results/2026-10-18/`](results/2026-10-18/) holds the published run, recorded on 18 October 2026 (US Pacific) in one session: the six raw runs (`results-<server>-receipts.json`, `results-<server>-payments.json`) and the merged `results-receipts.json` and `results-payments.json`, each stamped with the run's facts under `run`.

- Stripe: the API in test mode, in a sandbox created that day and empty before the run, with `Stripe-Version: 2026-06-24.dahlia`.
- The Rystic simulator: `stripe-twin` v0.0.15, started on fresh state for each script.
- stripe-mock: `stripe/stripe-mock:v0.206.0`, run as its README runs it.

| Server | Receipts agreeing with Stripe | Payments steps agreeing with Stripe | Payments flow wall-clock |
|---|---|---|---|
| Stripe test mode (the reference) | 6/6 | 9/9 | 7.5 s, 2.6 s of it waiting for the balance transaction |
| Rystic stripe-twin v0.0.15 | 6/6 | 8/9 | 0.02 s |
| stripe-mock v0.206.0 | 0/6 | 1/9 | 0.01 s, stopping after step 2 |

The simulator's one disagreement is step 9, the flow's events: it attaches the balance transaction to the charge at once, so the refunds that follow leave `charge.updated` out of its events, where Stripe attached it about 2.6 s later and sent `charge.updated`. stripe-mock's PaymentIntent stays at `requires_payment_method` with nothing received, and its replay returns a different PaymentIntent, so the flow stops there.

To stamp a merged file the same way, pass `--meta KEY=VALUE` to `compare_payments.py`, once per fact.

## Revision log

Each entry links a commit permalink to that run's results folder.

| Date | Change | Results |
|---|---|---|
| 2026-10-18 | First published run. | [`results/2026-10-18/`](results/2026-10-18/) |

## Corrections

If a result here is wrong, [open an issue](https://github.com/Rystic-Inc/rystic-scripts/issues) in this repository, so every correction stays on record, or email founders@rystic.ai. Name the step, the server and what you saw. Each correction we accept gets an entry in the revision log.
