"""RYS-3809 on a real seed (no clones). usage: run2.py <label>
env: KT_SEED seed dir, KT_SET ticker list, KT_INJECT inject doc, KT_IDX idx.pkl, KT_BIN, KT_PORT,
     KT_WINS 'lo,hi[,speed];...' minutes since T0 (empty = the whole night, the soak), KT_REBASE 1|0,
     KT_LOAD_CAP_S (give up on a load that takes longer), KT_BURST_MIN (default 119 = 00:59Z).
Per window: seek (a window starting at 0 plays from the top), 3 WS clients (separate processes) on ~1,000
markets each + lifecycle, 3 /live_data pollers (200 milestones / 5 s), a min_updated_ts sweeper, a back-to-back
burst reader for test 3, status every 1 s (lag, frames/s from position)."""
import json, sys, time, threading, collections, os, subprocess, atexit, pickle, bisect, random
import multiprocessing
mp = multiprocessing.get_context('fork')
from datetime import datetime, timezone
import websocket
import tw, fold

LABEL = sys.argv[1]
SEED = tw.SEED
T0, MIN = tw.T0_MS, 60_000
REBASE = os.environ.get('KT_REBASE', '1') == '1'
WINS = []
for w in filter(None, os.environ.get('KT_WINS', '').split(';')):
    x = w.split(','); WINS.append((int(x[0]), int(x[1]), float(x[2]) if len(x) > 2 else 1.0))
LOAD_CAP = float(os.environ.get('KT_LOAD_CAP_S', '14400'))
B = int(os.environ.get('KT_BURST_MIN', '119'))
BURST = (T0 + B * MIN, T0 + (B + 4) * MIN)          # 00:59-01:03Z tape
os.makedirs('results', exist_ok=True)
OUT = {'label': LABEL, 'seed': SEED, 'rebase': REBASE, 'wins': WINS, 'bin': tw.BIN, 'windows': []}
log = open(f'results/{LABEL}.log', 'a')


def note(k, v, store=True):
    if store: OUT[k] = v
    print(time.strftime('%H:%M:%S'), k, json.dumps(v, default=str)[:900], file=log, flush=True)
    json.dump(OUT, open(f'results/{LABEL}.json', 'w'), default=str)


def iso_ms(s):
    d, _, fr = s.rstrip('Z').partition('.')
    return int(datetime.strptime(d, '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc).timestamp() * 1000) + int((fr + '000')[:3] or 0)


def pct(v, q):
    return v[min(len(v) - 1, int(len(v) * q))] if v else None


def dh(d):
    return hash(json.dumps(d, sort_keys=True))


MK = sorted(l.strip() for l in open(os.environ['KT_SET']) if l.strip())
PER = json.load(open(os.environ['KT_HIST']))['per_tape']     # ticker -> [lines, deltas, trades]
EVENTS = json.load(open(os.environ['KT_INJECT']))['events']
TAPE_AT = {e['id']: iso_ms(e['at']) for e in EVENTS}
SETTLE_AT = {e['call']['body']['ticker']: TAPE_AT[e['id']] for e in EVENTS if 'call' in e}
MIDS = list(EVENTS[0]['seed']['state_milestone'])
LD = collections.defaultdict(list)       # milestone -> [(tape_at, details hash, last_updated, event id)]
for e in EVENTS:
    for mid, rec in (e.get('seed') or {}).get('state_live_data', {}).items():
        LD[mid].append((TAPE_AT[e['id']], dh(rec.get('details')), (rec.get('details') or {}).get('last_updated'), e['id']))
for v in LD.values():
    v.sort(key=lambda x: x[0])
BURST_MIDS = sorted({m for m, v in LD.items() if any(BURST[0] + MIN <= a < BURST[0] + 2 * MIN for a, *_ in v)})
busy = sorted(MK, key=lambda t: (-(PER[t][1] + PER[t][2]), t))
rnd = random.Random(3809)
CLIENT_MK = [busy[:1000], busy[1000::max(1, (len(busy) - 1000) // 1000)][:1000], rnd.sample(MK, min(1000, len(MK)))]
BOOKS = [t_ for t_ in busy[:30] + rnd.sample(MK, 30) if t_ not in SETTLE_AT]
KEEP = set(sum(CLIENT_MK, [])) | set(BOOKS)
SEEK_MS = sorted({T0 + w[0] * MIN for w in WINS if w[0] > 0})


def index_one(t):
    import gzip, glob
    from array import array
    al = array('q'); de = array('q'); tr = array('q')
    for f in sorted(glob.glob(f'{SEED}/tape/events/{t}/*.ndjson.gz')):
        for line in gzip.open(f, 'rt'):
            d = json.loads(line); ev = d['event']; ts = ev.get('msg', {}).get('ts_ms') or d['recv_ms']
            al.append(ts)
            if t in KEEP:
                if ev['type'] == 'orderbook_delta': de.append(ts)
                elif ev['type'] == 'trade': tr.append(ts)
    al = sorted(al)
    return t, [bisect.bisect_left(al, ms) for ms in SEEK_MS], ((None, de, tr) if t in KEEP else None)


IDX = {}; SEEKPOS = dict.fromkeys(SEEK_MS, 0)
_t = time.time()
with multiprocessing.get_context('fork').Pool(int(os.environ.get('KT_INDEX_PROCS', os.cpu_count()))) as _pool:
    for t, cnt, arrs in _pool.imap_unordered(index_one, MK, chunksize=32):
        for ms, c_ in zip(SEEK_MS, cnt): SEEKPOS[ms] += c_
        if arrs: IDX[t] = arrs
OUT['index_s'] = round(time.time() - _t, 1)


def expected(tickers, lo, hi):
    """per ticker: tape deltas/trades with lo <= ts <= hi (and ts > T0+1, before its settle)."""
    out = {}
    for t_ in tickers:
        cut = SETTLE_AT.get(t_); a, b = max(lo, T0 + 2), hi
        n = {}
        for k, arr in (('orderbook_delta', IDX[t_][1]), ('trade', IDX[t_][2])):
            top = bisect.bisect_right(arr, b) if cut is None else min(bisect.bisect_right(arr, b), bisect.bisect_left(arr, cut))
            n[k] = max(0, top - bisect.bisect_left(arr, a))
            n[k + '_lt_hi'] = max(0, min(top, bisect.bisect_left(arr, b)) - bisect.bisect_left(arr, a))
        out[t_] = n
    return out


def ws_proc(k, tickers, url, stop, snaps, res_q):
    """One bot: orderbook_delta + trade (500 tickers per subscribe) + lifecycle; seq per sid."""
    msgs = collections.Counter(); per = collections.Counter(); gaps = []; last = {}; persec = collections.Counter()
    life = collections.Counter(); err = None
    try:
        ws = websocket.create_connection(url, timeout=5)
        i = 1
        for ch in ('orderbook_delta', 'trade'):
            for j in range(0, len(tickers), 500):
                ws.send(json.dumps({'id': i, 'cmd': 'subscribe', 'params': {'channels': [ch], 'market_tickers': tickers[j:j + 500]}})); i += 1
        ws.send(json.dumps({'id': i, 'cmd': 'subscribe', 'params': {'channels': ['market_lifecycle_v2']}}))
        while not stop.is_set():
            try:
                m = json.loads(ws.recv())
            except websocket.WebSocketTimeoutException:
                continue
            typ, sid, seq = m.get('type'), m.get('sid'), m.get('seq'); msgs[typ] += 1
            if seq is not None:
                if sid in last and seq != last[sid] + 1:
                    gaps.append([sid, typ, last[sid], seq])
                last[sid] = seq
            msg = m.get('msg') or {}
            if typ in ('orderbook_delta', 'trade'):
                per[(msg.get('market_ticker'), typ)] += 1; persec[int(time.time())] += 1
            elif typ == 'orderbook_snapshot':
                snaps.value += 1
            elif typ == 'market_lifecycle_v2':
                life[msg.get('event_type')] += 1
        ws.close()
    except Exception as e:
        err = repr(e)
    res_q.put((k, {'msgs': dict(msgs), 'per': {f'{a}|{b}': n for (a, b), n in per.items()}, 'gaps': gaps,
                   'persec': dict(persec), 'lifecycle': dict(life), 'err': err}))


class Poll(threading.Thread):
    def __init__(self, ids):
        super().__init__(daemon=True); self.ids = ids[:200]; self.stop = False; self.lat = []; self.errors = collections.Counter()
    def run(self):
        while not self.stop:
            t0 = time.time()
            for mid in self.ids:
                t = time.time(); c, _ = tw.get(f'/trade-api/v2/live_data/milestone/{mid}')
                self.lat.append(round((time.time() - t) * 1000, 2))
                if c not in (200, 404): self.errors[c] += 1
            time.sleep(max(0, 5 - (time.time() - t0)))


class Sweep(threading.Thread):
    """GET /milestones?min_updated_ts= every 5 s, all pages."""
    def __init__(self):
        super().__init__(daemon=True); self.stop = False; self.lat = []; self.errors = collections.Counter(); self.found = 0; self.since = None
    def run(self):
        while not self.stop:
            t0 = time.time(); since = self.since if self.since is not None else 0; cur = None; newest = since
            while True:
                q = f'/trade-api/v2/milestones?min_updated_ts={since}&limit=500' + (f'&cursor={cur}' if cur else '')
                t = time.time(); c, b = tw.get(q); self.lat.append(round((time.time() - t) * 1000, 2))
                if c != 200: self.errors[c] += 1; break
                ms = (b or {}).get('milestones') or []; self.found += len(ms)
                for m in ms:
                    lu = m.get('last_updated_ts')
                    if lu:
                        try: newest = max(newest, iso_ms(lu) // 1000)
                        except Exception: pass
                cur = (b or {}).get('cursor')
                if not cur: break
            self.since = newest
            time.sleep(max(0, 5 - (time.time() - t0)))


def burst_proc(mids, stop, on, url_base, res_q):
    tw.URL = url_base
    reads = []
    while not stop.is_set():
        if not on.is_set():
            time.sleep(0.02); continue
        for mid in mids:
            t = time.time(); c, b = tw.get(f'/trade-api/v2/live_data/milestone/{mid}')
            det = (b or {}).get('live_data', {}).get('details') if isinstance(b, dict) else None
            reads.append((int(t * 1000), int(time.time() * 1000), mid, c, dh(det), (det or {}).get('last_updated')))
    res_q.put(('burst', reads))


def proc_stats(p):
    out = subprocess.run(['ps', '-o', 'rss=,%cpu=', '-p', str(p.pid)], capture_output=True, text=True).stdout.split()
    return (int(out[0]) / 1024, float(out[1])) if out else (None, None)


def status():
    return tw.get('/_replay/status')[1]


p = tw.boot(f'results/{LABEL}.twin.log')
atexit.register(lambda: tw.stop(p))
time.sleep(5)
note('machine', {'host': os.uname().nodename, 'nproc': os.cpu_count(), 'tapes': len(MK), 'idle_rss_mb': proc_stats(p)[0],
                 'tape_lines': sum(PER[t][0] for t in MK), 'frames': sum(PER[t][1] + PER[t][2] for t in MK), 'index_s': OUT['index_s']})

# test 1: fold
peak = [0.0]; folding = [True]; samples = []
def sample_fold():
    t0 = time.time()
    while folding[0]:
        r = proc_stats(p)[0]
        if r: peak[0] = max(peak[0], r); samples.append([round(time.time() - t0), round(r)])
        time.sleep(1)
threading.Thread(target=sample_fold, daemon=True).start()
t = time.time()
try:
    c, b = tw.req('POST', '/_replay/start', {"markets": MK, "speed": 1, "rebase": REBASE, "checkpoints": [T0 + 1]}, timeout=LOAD_CAP)
except Exception as e:
    folding[0] = False
    note('load_timeout', {'after_s': round(time.time() - t), 'err': repr(e), 'rss_mb': proc_stats(p)[0], 'peak_rss_mb': peak[0], 'rss_samples': samples[::30]})
    print('DONE', file=log, flush=True); sys.exit(3)
assert c == 204, (c, b)
for _ in range(1200):
    st = status()
    if st.get('at_checkpoint_ms') or not st.get('playing'): break
    time.sleep(0.5)
fold_s = time.time() - t; folding[0] = False
off = st['rebase_offset_ms'] or 0
lines = st['total']; loaded = proc_stats(p)[0]
note('loaded', {'fold_s': round(fold_s, 1), 'rss_mb': loaded, 'fold_peak_rss_mb': peak[0], 'total': lines,
                'mb_per_tape': round(loaded / len(MK), 3), 'b_per_event': round(loaded * 2 ** 20 / lines, 1),
                'status': {k: v for k, v in st.items() if k not in ('market', 'markets')}, 'rss_samples': samples[::30]})

HOLD = os.environ.get('KT_HOLD_FILE')
if HOLD:
    note('holding', {'file': HOLD, 'rss_mb': proc_stats(p)[0]})
    while not os.path.exists(HOLD): time.sleep(5)
    note('released', {'rss_mb': proc_stats(p)[0]})
t = time.time(); c, _ = tw.post('/_rystic/inject', json.dumps({'events': tw.shifted_inject(off, events=EVENTS)}).encode())
note('inject_post', {'code': c, 's': round(time.time() - t, 2), 'events': len(EVENTS), 'offset_ms': off})

SOAK = not WINS
for wi, (wlo, whi, speed) in enumerate(WINS or [(0, 600, 1.0)]):
    W = {'win': [wlo, whi], 'speed': speed, 'tape': [datetime.fromtimestamp((T0 + wlo * MIN) / 1000, timezone.utc).strftime('%H:%MZ'),
                                                    datetime.fromtimestamp((T0 + whi * MIN) / 1000, timezone.utc).strftime('%H:%MZ')]}
    WLO, WHI = T0 + wlo * MIN, T0 + whi * MIN
    st = status(); head = st['start_ms'] + st['position_ms']
    if wlo > 0 and WLO > head + 1000 or (WLO < head - 1000):
        pos = SEEKPOS[WLO]
        t = time.time(); c, b = tw.post('/_replay/seek', {'position': pos}); assert c in (200, 204), (c, b)
        tw.post('/_replay/play', {'advance_ms': 1, 'speed': speed})
        while status().get('playing'): time.sleep(0.05)
        W['seek'] = {'pos': pos, 's': round(time.time() - t, 1)}
    st = status(); WLO = st['start_ms'] + st['position_ms'] + 1
    stop = mp.Event(); res_q = mp.Queue(); snaps = [mp.Value('i', 0) for _ in range(3)]
    cl = [mp.Process(target=ws_proc, args=(k, CLIENT_MK[k], tw.WS_URL, stop, snaps[k], res_q), daemon=True) for k in range(3)]
    bon = mp.Event(); bp = mp.Process(target=burst_proc, args=(BURST_MIDS, stop, bon, tw.URL, res_q), daemon=True)
    for x in cl + [bp]: x.start()
    polls = [Poll(MIDS[(k * 200) % len(MIDS):] + MIDS[:(k * 200) % len(MIDS)]) for k in range(int(os.environ.get('KT_POLLERS', '3')))]; sw = Sweep()
    for x in polls + ([sw] if os.environ.get('KT_SWEEP', '1') == '1' else []): x.start()
    t = time.time()
    while time.time() - t < 600 and not all(snaps[k].value >= len(CLIENT_MK[k]) for k in range(3)):
        time.sleep(0.5)
    W['subscribed'] = {'snapshots': [s_.value for s_ in snaps], 's': round(time.time() - t, 1)}
    time.sleep(3)
    c, b = tw.post('/_replay/play', {'speed': speed} if SOAK else {'until_ms': WHI, 'speed': speed}); assert c == 204, (c, b)
    st = status(); play_wall = time.time(); lo = st['start_ms'] + st['position_ms']; pos0 = st['position']
    note('play', {'win': W['win'], 'speed': speed, 'tape_ms': lo, 'pos': pos0}, store=False)
    samp, rss, last_note = [], [], 0      # samp: [wall, replay lag ms, wall - twin clock ms, position, head]
    while True:
        s = status(); now = time.time(); h = s['start_ms'] + s['position_ms']
        samp.append([round(now, 3), int((now - play_wall) * 1000 - (h - lo) / speed), int(now * 1000) - (h + off), s['position'], h, bool(s.get('playing'))])
        (bon.set if BURST[0] <= h < BURST[1] else bon.clear)()
        if now - last_note >= 30:
            r, cpu = proc_stats(p); rss.append([int(now - play_wall), r, cpu]); last_note = now
            if len(rss) % 20 == 1:
                note('progress', {'h': round((now - play_wall) / 3600, 2), 'tape': datetime.fromtimestamp(h / 1000, timezone.utc).strftime('%H:%M:%S'),
                                  'rss_mb': r, 'cpu': cpu, 'lag_ms': samp[-1][1]}, store=False)
                if SOAK:
                    W['rss'] = rss; OUT['windows'] = [W]; json.dump(OUT, open(f'results/{LABEL}.json', 'w'), default=str)
        if (s.get('done') or not s.get('playing')) and now - play_wall > 5:
            break
        time.sleep(max(0.0, 1 - (time.time() - now)))
    end_wall = time.time()
    time.sleep(8)
    stop.set()
    for x in polls + [sw]: x.stop = True
    res = {}
    for _ in range(4):
        k, v = res_q.get(timeout=600); res[k] = v
    for x in cl + [bp]: x.join(30)
    lv = sorted(x[1] for x in samp if x[5] and x[4] < WHI)
    # frames/s the twin applied: position over wall, per sample and rolled over 10 s / 60 s
    fps = [(samp[i][3] - samp[i - 1][3]) / (samp[i][0] - samp[i - 1][0]) for i in range(1, len(samp)) if samp[i][0] > samp[i - 1][0]]
    def roll(n):
        return max(((samp[i][3] - samp[i - n][3]) / (samp[i][0] - samp[i - n][0]) for i in range(n, len(samp))), default=None)
    behind = [samp[i] for i in range(len(samp)) if samp[i][1] > 500]
    W['lag_ms'] = {'p50': pct(lv, .5), 'p99': pct(lv, .99), 'max': lv[-1], 'n': len(lv)}
    W['frames_per_s'] = {'mean': round((samp[-1][3] - pos0) / max(1e-9, samp[-1][0] - play_wall)), 'max_1s': round(max(fps)) if fps else None,
                         'max_10s': round(roll(10) or 0), 'max_60s': round(roll(60) or 0),
                         'required_mean': round((samp[-1][3] - pos0) / ((samp[-1][4] - lo) / speed / 1000)) if samp[-1][4] > lo else None}
    W['wall_s'] = round(end_wall - play_wall, 1); W['lag_over_500_samples'] = len(behind)
    W['rss'] = rss
    W['ws'] = [{'markets': len(CLIENT_MK[k]), 'msgs': res[k]['msgs'], 'gap_count': len(res[k]['gaps']), 'gaps': res[k]['gaps'][:10],
                'err': res[k]['err'], 'lifecycle': res[k]['lifecycle'], 'max_frames_1s': max(res[k]['persec'].values(), default=0)} for k in range(3)]
    W['live_data'] = [{'n': len(q.lat), 'p50_ms': pct(sorted(q.lat), .5), 'p99_ms': pct(sorted(q.lat), .99), 'max_ms': max(q.lat, default=None), 'errors': dict(q.errors)} for q in polls]
    W['min_updated_ts'] = {'calls': len(sw.lat), 'p50_ms': pct(sorted(sw.lat), .5), 'p99_ms': pct(sorted(sw.lat), .99), 'found': sw.found, 'errors': dict(sw.errors)}
    hi_seen = WHI if not SOAK else 10 ** 15
    exp = expected(sorted(set(sum(CLIENT_MK, []))), WLO, hi_seen)
    short = []; exp_n = []; got_n = []
    for k in range(3):
        per = collections.Counter({tuple(kk.split('|')): v for kk, v in res[k]['per'].items()})
        e_ = g_ = 0
        for t_ in CLIENT_MK[k]:
            for typ in ('orderbook_delta', 'trade'):
                e_ += exp[t_][typ]; g_ += per[(t_, typ)]
                if per[(t_, typ)] != exp[t_][typ]:
                    short.append([k, t_, typ, exp[t_][typ], exp[t_][typ + '_lt_hi'], per[(t_, typ)]])
        exp_n.append(e_); got_n.append(g_)
    W['dropped'] = {'expected': exp_n, 'received': got_n, 'mismatch_n': len(short), 'mismatch': short[:30],
                    'mismatch_explained_by_hi_edge': sum(1 for x in short if x[4] == x[5])}
    chk = BOOKS
    books = {t_: fold.twin_book(tw.get(f'/trade-api/v2/markets/{t_}/orderbook')[1]) == fold.tape_book(SEED, t_, WHI if not SOAK else 10 ** 15) for t_ in chk}
    W['books_equal_fold'] = {'n': len(books), 'equal': sum(books.values()), 'unequal': [k for k, v in books.items() if not v][:10]}
    inj = tw.inject_view()['events']; fired = {e['id']: e for e in inj}
    d = []; errs = []
    for e in inj:
        a = TAPE_AT[e['id']]
        if not (WLO <= a <= samp[-1][4]): continue
        if not e.get('fired_at'): errs.append([e['id'], 'unfired']); continue
        d.append(iso_ms(e['fired_at']) - (a + off))
        if e.get('error'): errs.append([e['id'], e['error']])
    d.sort()
    W['inject'] = {'in_window': len(d), 'unfired_or_error': len(errs), 'errors': errs[:10], 'over_1s': sum(1 for x in d if abs(x) > 1000),
                   'fire_minus_at_ms': [d[0], pct(d, .5), pct(d, .99), d[-1]] if d else None,
                   'settles_fired': sum(1 for e in inj if 'call' in e and e.get('fired_at')), 'settles': sum(1 for e in inj if 'call' in e)}
    # test 3: map each read's wall time onto the twin clock from the status samples
    reads = res['burst']
    if reads and not any(BURST[0] < T0 + pw[1] * MIN and T0 + pw[0] * MIN < BURST[1] for pw in WINS[:wi]):
        ws_ = [x[0] for x in samp]
        def twin(ms):
            w = ms / 1000; i = bisect.bisect_left(ws_, w)
            if i <= 0: return samp[0][4] + off
            if i >= len(samp): return samp[-1][4] + off
            a, b_ = samp[i - 1], samp[i]; f = (w - a[0]) / (b_[0] - a[0])
            return int(a[4] + f * (b_[4] - a[4])) + off
        firedat = {e['id']: iso_ms(e['fired_at']) for e in inj if e.get('fired_at')}
        ok = race = bug = n404 = 0; bugs = []; races = []
        for r0, r1, mid, c, det, lu in reads:
            t0_, t1_ = twin(r0), twin(r1)
            seeds = [x for x in LD[mid] if x[3] in firedat]
            done = [x for x in seeds if firedat[x[3]] <= t1_]
            if not done:
                n404 += 1; continue
            before = [x for x in done if firedat[x[3]] <= t0_]
            hashes_ok = {x[1] for x in seeds if firedat[x[3]] >= t0_ - 5} | {done[-1][1]} | ({before[-1][1]} if before else set())
            if c == 200 and det in hashes_ok:
                ok += 1
            else:
                newer = [x for x in done if x[0] > max([y[0] for y in seeds if y[1] == det] or [0])]
                gap = t0_ - firedat[newer[0][3]] if newer else None
                if newer and gap is not None and gap > 50:
                    bug += 1; bugs.append([mid, c, lu, newer[0][3], gap])
                else:
                    race += 1; races.append([mid, c, lu, newer[0][3] if newer else None, gap])
        final_bad = []
        for mid in BURST_MIDS:
            seeds = [x for x in LD[mid] if x[3] in firedat]
            if not seeds: continue
            c, b = tw.get(f'/trade-api/v2/live_data/milestone/{mid}')
            det = (b or {}).get('live_data', {}).get('details') if isinstance(b, dict) else None
            if dh(det) != max(seeds, key=lambda x: (firedat[x[3]], x[0]))[1]: final_bad.append(mid)
        bl = sorted(x[1] for x in samp if BURST[0] <= x[4] < BURST[1] and x[5] and x[4] < WHI)
        W['test3'] = {'reads': len(reads), 'served_newest_fired': ok, 'stale_race_le_50ms': race, 'stale_bug_gt_50ms': bug, 'pre_seed': n404,
                      'newest_pct': round(100 * ok / max(1, ok + race + bug), 3),
                      'bugs': bugs[:20], 'races': races[:20], 'burst_milestones': len(BURST_MIDS),
                      'final_not_newest': final_bad[:10], 'final_not_newest_n': len(final_bad),
                      'lag_ms_in_burst': {'p99': pct(bl, .99), 'max': bl[-1] if bl else None}}
        json.dump({'reads': reads[:200000], 'samp': samp}, open(f'results/{LABEL}.w{wi}.test3.json', 'w'))
    W['samp'] = samp[::5] if SOAK else samp
    OUT['windows'].append(W)
    note(f'window{wi}', {k: v for k, v in W.items() if k not in ('samp', 'rss')}, store=False)
print('DONE', file=log, flush=True)
