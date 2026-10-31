"""Harness for the RYS-3809 election-night sample against kalshi-twin."""
import json, os, signal, subprocess, time, urllib.request, urllib.error, glob
from datetime import datetime

SEED = os.path.expanduser(os.environ.get('KT_SEED', '~/data/kalshi-loadtest/2026-10-23/full'))
BIN = os.environ.get('KT_BIN', '/private/tmp/claude-501/-Users-zkiihne/36a291d6-dfa5-5daf-859f-9da661fc657a/scratchpad/kt-main')
PORT = int(os.environ.get('KT_PORT', '8090'))  # :8080 is slack-twin on the MacBook
URL = 'http://localhost:%d' % PORT
WS_URL = 'ws://localhost:%d/trade-api/ws/v2' % PORT
T0_MS = 1793746800000  # 2026-11-03T23:00:00Z
RYSTIC = os.environ.get('KT_RYSTIC')               # boot `rystic run kalshi-twin` instead of KT_BIN
METADATA = os.environ.get('KT_METADATA', 'off')    # RYSTIC_REPLAY_METADATA
INJECT_MODE = os.environ.get('KT_INJECT_MODE', 'post')  # post: shifted POST /_rystic/inject; start: path in /_replay/start (0.0.47+, state_set)
assert INJECT_MODE in ('post', 'start'), INJECT_MODE


def _checkpoint():
    if os.environ.get('KT_CHECKPOINT_MS'):
        return int(os.environ['KT_CHECKPOINT_MS'])
    try:
        start = json.load(open(SEED + '/manifest.json'))['start']
        return int(datetime.fromisoformat(start.replace('Z', '+00:00')).timestamp() * 1000) + 1
    except (OSError, KeyError, ValueError):
        return T0_MS + 1


CHECKPOINT_MS = _checkpoint()   # manifest start + 1 ms = 1793746800001 for the election seed


def markets():
    dot = next(iter(glob.iglob(SEED + '/tape/**/._*', recursive=True)), None)
    if dot:
        raise SystemExit(f"{dot}: AppleDouble files in the seed; find {SEED}/tape -name '._*' -delete")
    return sorted(os.path.basename(p) for p in glob.glob(SEED + '/tape/events/*') if os.path.isdir(p))


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
    if RYSTIC:
        e = dict(os.environ)
        args = [RYSTIC, 'run', 'kalshi-twin', '--tapes', SEED + '/tape', '--port', str(PORT),
                '--env', 'RYSTIC_REPLAY_METADATA=' + METADATA] + sum((['--env', f'{k}={v}'] for k, v in (env or {}).items()), [])
    else:
        e = dict(os.environ, KALSHI_CAPTURE_DIR=SEED + '/tape', RYSTIC_REPLAY_METADATA=METADATA, RYSTIC_ADDR=':%d' % PORT)
        e.update(env or {})
        args = [BIN]
    args += ['--inject', inject] if inject else []
    p = subprocess.Popen(args, env=e, stdout=open(log, 'w'), stderr=subprocess.STDOUT, start_new_session=True)
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
    if p.poll() is not None:
        return
    os.killpg(p.pid, signal.SIGTERM)
    try:
        p.wait(20)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); p.wait()


def tree_stats(pid):
    """(RSS MB, %CPU) of pid and its descendants: under `rystic run` the twin is the CLI's child."""
    kids, val = {}, {}
    for line in subprocess.run(['ps', '-A', '-o', 'pid=,ppid=,rss=,%cpu='], capture_output=True, text=True).stdout.splitlines():
        f = line.split()
        if len(f) == 4:
            kids.setdefault(int(f[1]), []).append(int(f[0])); val[int(f[0])] = (int(f[2]), float(f[3]))
    if pid not in val:
        return None, None
    rss = cpu = 0; todo = [pid]
    while todo:
        q = todo.pop(); r, c = val.get(q, (0, 0.0)); rss += r; cpu += c; todo.extend(kids.get(q, []))
    return rss / 1024, cpu


def rss_mb(p):
    return tree_stats(p.pid)[0]


def start_paused(speed=1, mk=None):
    mk = mk or markets()
    code, body = post('/_replay/start', {"markets": mk, "speed": speed, "rebase": True,
                                          "checkpoints": [CHECKPOINT_MS]})
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
