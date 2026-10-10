# rystic-scripts

Customer scripts for Rystic simulators, one folder per simulator. Each one also ships inside that simulator's release archive.

| Simulator | Scripts |
|---|---|
| kalshi | `check.sh`, `trade-check.sh`, `api-check.py`, `bots/` (simple-bot, balance-watcher, book-reader, random-walker), `recordings/capture-setup.sh` |
| github-pulls | `check.sh`, `bots/` (bot.py, test_bot.py, variants/) |
| linear, lob, notion, okta, paypal, resend, s3, slack, stripe | `check.sh` |

`environments/` has example multi-twin stacks: stack file plus the compose file Rystic exports from it.

`check.sh` expects the twin binary in the same folder, so copy it next to your installed twin or run the copy that ships in the archive.

Docs: https://www.rystic.ai/docs
