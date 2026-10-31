"""Independent fold of a seed tape: the book after every event stamped <= until_ms."""
import gzip, json, glob

def tape_book(seed, ticker, until_ms):
    book = {'yes': {}, 'no': {}}
    for f in sorted(glob.glob(f'{seed}/tape/events/{ticker}/*.ndjson.gz')):
        for line in gzip.open(f, 'rt'):
            d = json.loads(line); ev = d['event']; m = ev.get('msg', {})
            t = m.get('ts_ms') or d['recv_ms']
            if ev['type'] == 'orderbook_snapshot':
                book = {'yes': {p: float(c) for p, c in m.get('yes_dollars_fp', [])},
                        'no': {p: float(c) for p, c in m.get('no_dollars_fp', [])}}
                continue
            if t > until_ms:
                return book
            if ev['type'] == 'orderbook_delta':
                side = book[m['side']]
                side[m['price_dollars']] = round(side.get(m['price_dollars'], 0.0) + float(m['delta_fp']), 2)
                if side[m['price_dollars']] <= 0:
                    del side[m['price_dollars']]
    return book

def twin_book(ob):
    fp = ob.get('orderbook_fp', ob)
    return {'yes': {p: float(c) for p, c in (fp.get('yes_dollars') or [])},
            'no': {p: float(c) for p, c in (fp.get('no_dollars') or [])}}
