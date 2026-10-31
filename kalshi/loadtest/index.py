"""Index a real seed's tapes. usage: index.py <seed> <out_dir> [--full]
hist.json: per tape-second (since T0) delta+trade counts over all tapes, and per-tape totals.
--full: idx.pkl = {ticker: (all_ts array('q'), delta_ts, trade_ts)} for seek positions and window counts."""
import gzip, json, os, sys, glob, collections, pickle
from array import array
from multiprocessing import Pool
SEED, OUT = sys.argv[1], sys.argv[2]; FULL = '--full' in sys.argv
T0 = 1793746800000

def one(t):
    al, de, tr = array('q'), array('q'), array('q'); sec = collections.Counter()
    for f in sorted(glob.glob(f'{SEED}/tape/events/{t}/*.ndjson.gz')):
        for line in gzip.open(f, 'rt'):
            d = json.loads(line); ev = d['event']; ts = ev.get('msg', {}).get('ts_ms') or d['recv_ms']
            al.append(ts); typ = ev['type']
            if typ == 'orderbook_delta': de.append(ts); sec[(ts - T0) // 1000] += 1
            elif typ == 'trade': tr.append(ts); sec[(ts - T0) // 1000] += 1
    return t, (al, de, tr) if FULL else None, sec, (len(al), len(de), len(tr))

if __name__ == '__main__':
    ts = sorted(os.path.basename(p) for p in glob.glob(SEED + '/tape/events/*'))
    if os.environ.get('KT_SET'): ts = [l.strip() for l in open(os.environ['KT_SET']) if l.strip()]
    hist = collections.Counter(); per = {}; idx = {}
    with Pool(os.cpu_count()) as p:
        for t, a, sec, n in p.imap_unordered(one, ts, chunksize=16):
            hist.update(sec); per[t] = n
            if FULL: idx[t] = a
    os.makedirs(OUT, exist_ok=True)
    json.dump({'per_sec': {str(k): v for k, v in sorted(hist.items())}, 'per_tape': per}, open(f'{OUT}/hist.json', 'w'))
    if FULL: pickle.dump(idx, open(f'{OUT}/idx.pkl', 'wb'), protocol=5)
    print('tapes', len(per), 'lines', sum(v[0] for v in per.values()), 'deltas', sum(v[1] for v in per.values()), 'trades', sum(v[2] for v in per.values()))
