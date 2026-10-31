# loadtest.py

Loads every tape in a Kalshi seed into one kalshi-twin as one replay group and reports what the load costs:

1. `prepare`: seconds for `POST /_replay/prepare` (the tape parse), and RSS after it.
2. `start_to_checkpoint`: seconds from `POST /_replay/start` (speed 1, rebase, one checkpoint) to the paused head, plus `rebase_offset_ms` and the inject summary.
3. `inject_post` (post mode only): seconds to `POST /_rystic/inject` the whole schedule, with every `at` shifted by `rebase_offset_ms`.
4. `loaded`: RSS with everything loaded, peak RSS over the run, MB per tape.

RSS is sampled once a second over the twin's process tree (with `--rystic` the twin is the CLI's child). All samples go to `--out`. The twin's log goes to `loadtest-twin-<port>.log` in the current directory. The script stops the twin when it finishes.

Needs only the Python 3 standard library.

## Run

```bash
python3 loadtest.py --seed ~/kt/full-seed-1-v4 --twin ./kalshi-twin --out result.json
```

| Flag | Default | |
|---|---|---|
| `--seed` | required | Seed dir with `manifest.json`, `inject.json` and `tape/events/<ticker>/`. Every directory under `tape/events` is one market. |
| `--twin BIN` / `--rystic CLI` | one required | Boot the binary directly (`RYSTIC_ADDR`, `KALSHI_CAPTURE_DIR=<seed>/tape`, `RYSTIC_REPLAY_METADATA`), or run `rystic run kalshi-twin --tapes <seed>/tape --port N` in the foreground. |
| `--port` | 8080 | |
| `--inject-mode` | `post` | `post`: shifted `POST /_rystic/inject` after the checkpoint. `start`: the file path goes in `/_replay/start`'s `inject`, with ats on tape time. `start` needs kalshi-twin 0.0.47+ and the `state_set` feature. |
| `--inject` | `<seed>/inject.json` | |
| `--metadata` | `off` | `RYSTIC_REPLAY_METADATA` for the twin. |
| `--checkpoint-ms` | `manifest.json` `start` + 1 ms | First pause, in absolute tape ms. Jordan's election seed gives 1793746800001 (2026-11-03T23:00:00.001Z). |
| `--load-timeout-s` | 14400 | |
| `--out` | none | JSON result, including the RSS samples. |

The script refuses a seed that contains macOS `._*` files. A tarball made on a Mac carries them; delete them first with `find <seed>/tape -name '._*' -delete`.

## Expected numbers

For the election seed (full-seed-1-v4: 22,671 tapes, 152.2M frames) on a 16 vCPU / 62 GB Linux host, using rystic-sim main 6143f912d0e0 plus the replay-group heap-merge patch, with metadata off, post mode and rebase on (Run A v4, 2026-10-27):

1. Parse and fold: about 11 min (fold 666.9 s, after a 99.6 s index pass in the old rig).
2. RSS loaded: 26.3 GB (1.16 MB/tape, 181 B/frame).
3. Inject POST: 3.77 s for 55,095 events.
4. Peak RSS: 34.8 GB. That peak was measured during play: two 15-minute windows at 1x, with 3 WebSocket clients subscribed to about 1,000 markets each. This script stops at the loaded state and does not play, so its peak will be close to the loaded RSS. Budget a host for the 34.8 GB.

On a 20-tape slice of the same seed (MacBook, kalshi-twin 0.0.47 through `rystic run`), the whole run took about 10 s and RSS was about 1.1 GB loaded in both modes.
