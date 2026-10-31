#!/bin/bash
# Run A on the MacBook: all 22,671 tapes, main 6143f912d0e0 + heap-merge diff, rebase, speed 1, windows 00:55-01:10Z and 03:00-03:15Z.
D=$HOME/data/kalshi-loadtest/2026-10-26
cd $D/rig && mkdir -p results
export KT_SEED=$D/full-seed-1 KT_SET=$D/rig/set-all.txt KT_HIST=$D/rig/hist.json KT_INJECT=$D/full-seed-1/inject.json
export KT_BIN=$D/rig/kt-heap KT_PORT=8090 KT_WINS='115,130;240,255' KT_REBASE=1 KT_POLLERS=1 KT_SWEEP=0 KT_LOAD_CAP_S=14400
exec caffeinate -dimsu $HOME/data/kalshi-loadtest/2026-10-23/.venv/bin/python run2.py runA-22671 > results/runA-22671.out 2>&1
