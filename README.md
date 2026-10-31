# rystic-scripts

Customer scripts for Rystic simulators, one folder per simulator. Each one also ships inside that simulator's release archive.

| Simulator | Scripts |
|---|---|
| kalshi | `check.sh`, `trade-check.sh`, `api-check.py`, `bots/` (simple-bot, balance-watcher, book-reader, random-walker), `recordings/capture-setup.sh`, `loadtest/loadtest.py` |
| github-pulls | `check.sh`, `bots/` (see below) |
| anthropic, clerk, dropbox, gmail, google-drive, linear, lob, notion, okta, paypal, resend, s3, shopify-storefront, slack, stripe, word | `check.sh` |

`environments/` has example multi-twin stacks: stack file plus the compose file Rystic exports from it.

`check.sh` expects the twin binary in the same folder, so copy it next to your installed twin or run the copy that ships in the archive.

`github-pulls/bots/` is a Kalshi market maker, not a GitHub client. It is the code under review in the GitHub twin's `github-pulls_bot_pr_queue` scenario: `bot.py` is the working bot, each file in `variants/` breaks it one way and is one of that scenario's open pull requests, and `test_bot.py` runs them all against a Kalshi twin (`KALSHI_BASE_URL` for one already running, `KALSHI_TWIN_BIN` for a binary, else the one `rystic pull kalshi-twin` installed). It needs `requests`, and the twin's plan must include scenarios, since it loads the `tight_book` scenario.

Docs: https://www.rystic.ai/docs

## License

The scripts in this repository are MIT-licensed (see `LICENSE`). The Rystic simulators they run against are not: they are licensed under the `LICENSE.txt` in each release archive.
