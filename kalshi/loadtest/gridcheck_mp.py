"""gridcheck.py (2026-10-23 rig) over a pool: every tape price checked against its meta record's price_ranges.
usage: gridcheck_mp.py <seed> <out.json> [set.txt]"""
import gzip, json, glob, sys, collections, os
from decimal import Decimal as D
from multiprocessing import Pool
SEED = sys.argv[1]
def bands(t):
    rec = json.loads(gzip.open(f'{SEED}/tape/meta/fetched-{t}.ndjson.gz', 'rt').readline())['data']
    return [(D(r['start']), D(r['end']), D(r['step'])) for r in rec.get('price_ranges') or []], rec.get('price_level_structure')
def one(t):
    bs, pls = bands(t); n = collections.Counter(); ex = set(); tot = 0; cache = {}
    for f in glob.glob(f'{SEED}/tape/events/{t}/*.ndjson.gz'):
        for line in gzip.open(f, 'rt'):
            ev = json.loads(line)['event']; m = ev.get('msg', {})
            if ev['type'] == 'orderbook_snapshot': ps = [p for p, _ in m.get('yes_dollars_fp', []) + m.get('no_dollars_fp', [])]
            elif ev['type'] == 'orderbook_delta': ps = [m['price_dollars']]
            elif ev['type'] == 'trade': ps = [m['yes_price_dollars']]
            else: ps = []
            for p in ps:
                tot += 1
                g = cache.get(p)
                if g is None:
                    q = D(p); g = cache[p] = any(s <= q <= e and (q - s) % st == 0 for s, e, st in bs)
                if not g: n[ev['type']] += 1; ex.add(p)
    return t, tot, ({'structure': pls, 'off_grid': dict(n), 'examples': sorted(ex)[:5]} if n else None)
if __name__ == '__main__':
    ts = [l.strip() for l in open(sys.argv[3])] if len(sys.argv) > 3 else sorted(os.path.basename(d) for d in glob.glob(f'{SEED}/tape/events/*'))
    bad = {}; tot = 0
    with Pool(os.cpu_count()) as p:
        for t, n, b in p.imap_unordered(one, ts, chunksize=16):
            tot += n
            if b: bad[t] = b
    print(json.dumps({'tapes': len(ts), 'tapes_off_grid': len(bad), 'prices_checked': tot,
                      'off_grid_total': sum(sum(v['off_grid'].values()) for v in bad.values()),
                      'by_structure': collections.Counter(v['structure'] for v in bad.values())}))
    json.dump(bad, open(sys.argv[2], 'w'))
