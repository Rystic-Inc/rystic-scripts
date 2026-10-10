# Environments

Example multi-twin stacks. Each folder holds the stack file (`rystic.yaml`) and the `docker-compose.yaml` that `rystic export compose` generates from it.

| Environment | Twins (scenario) | Ports |
|---|---|---|
| `stripe-ci` | stripe (design_studio) | 8080 |
| `kalshi-bot` | kalshi (thin_book), kalshi (flash_crash) | 8080, 8081 |
| `coding-agent` | github-pulls (bot_pr_queue), linear (triage_inbox), slack (design_studio) | 8080–8082 |
| `design-studio` | stripe, paypal, slack, resend, okta, lob, all one company (design_studio) | 8080–8085 |

Native:

```sh
rystic up -f rystic.yaml
```

Docker:

```sh
rystic login ./rystic-license.json   # also logs docker in to registry.rystic.ai
cp .env.example .env                 # set RYSTIC_LICENSE
docker compose up
```

These files pin images by tag. To pin your own build by digest, run `rystic export compose -o .`.
