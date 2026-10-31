"""Harness for the RYS-3809 election-night sample against kalshi-twin."""
import json, os, subprocess, time, urllib.request, urllib.error, glob

SEED = os.path.expanduser(os.environ.get('KT_SEED', '~/data/kalshi-loadtest/2026-10-23/full'))
BIN = os.environ.get('KT_BIN', '/private/tmp/claude-501/-Users-zkiihne/36a291d6-dfa5-5daf-859f-9da661fc657a/scratchpad/kt-main')
PORT = int(os.environ.get('KT_PORT', '8090'))  # :8080 is slack-twin on the MacBook
URL = 'http://localhost:%d' % PORT
WS_URL = 'ws://localhost:%d/trade-api/ws/v2' % PORT
T0_MS = 1793746800000  # 2026-11-03T23:00:00Z


def markets():
    return sorted(os.path.basename(p) for p in glob.glob(SEED + '/tape/events/*'))


def req(method, path, body=None, timeout=7200):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    r = urllib.request.Request(URL + path, data=data, method=method, headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read()
            code = resp.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    try:
        return code, json.loads(raw) if raw else None
    except ValueError:
        return code, raw.decode(errors='replace')


def get(path):
    return req('GET', path)


def post(path, body=None):
    return req('POST', path, body if body is not None else b'')


def boot(log, env=None, inject=None):
    import socket
    with socket.socket() as so:
        if so.connect_ex(('127.0.0.1', PORT)) == 0:
            raise RuntimeError(':%d already has' % PORT + ' a listener; stop it first')
    e = dict(os.environ, KALSHI_CAPTURE_DIR=SEED + '/tape', RYSTIC_REPLAY_METADATA='off', RYSTIC_ADDR=':%d' % PORT)
    e.update(env or {})
    args = [BIN] + (['--inject', inject] if inject else [])
    p = subprocess.Popen(args, env=e, stdout=open(log, 'w'), stderr=subprocess.STDOUT)
    for _ in range(240):
        try:
            if get('/_replay/status')[0] == 200 and p.poll() is None:
                return p
        except Exception:
            pass
        if p.poll() is not None:
            raise RuntimeError('twin exited: ' + open(log).read()[-2000:])
        time.sleep(0.5)
    raise RuntimeError('twin did not come up')


def stop(p):
    p.terminate()
    try:
        p.wait(20)
    except subprocess.TimeoutExpired:
        p.kill(); p.wait()


def rss_mb(p):
    out = subprocess.run(['ps', '-o', 'rss=', '-p', str(p.pid)], capture_output=True, text=True).stdout.strip()
    return int(out) / 1024 if out else None


def start_paused(speed=1, mk=None):
    mk = mk or markets()
    code, body = post('/_replay/start', {"markets": mk, "speed": speed, "rebase": True,
                                          "checkpoints": [T0_MS + 1]})
    assert code == 204, (code, body)
    for _ in range(600):
        st = get('/_replay/status')[1]
        if st.get('at_checkpoint_ms') or not st.get('playing'):
            return st
        time.sleep(0.5)
    return st


def shifted_inject(offset_ms, path=SEED + '/inject.json', events=None):
    """Jordan's launcher: shift every `at` by the rebase offset."""
    from datetime import datetime, timezone, timedelta
    ev = events if events is not None else json.load(open(path))['events']
    out = []
    for e in ev:
        t = datetime.fromisoformat(e['at'].replace('Z', '+00:00')) + timedelta(milliseconds=offset_ms)
        e2 = dict(e); e2['at'] = t.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
        out.append(e2)
    return out


def inject_view():
    return get('/_rystic/inject')[1]


def wait_done(poll=10, until_ms=None, on_tick=None):
    while True:
        st = get('/_replay/status')[1]
        if on_tick:
            on_tick(st)
        if st.get('done') or (until_ms and st.get('position_ms', 0) >= until_ms) or (not st.get('playing') and st.get('at_checkpoint_ms')):
            return st
        time.sleep(poll)
