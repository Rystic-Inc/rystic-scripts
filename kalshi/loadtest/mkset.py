"""usage: mkset.py <seed> <hist.json> <N> <out_dir>: the N tapes with the most frames (delta+trade), always
including every /_settle market in inject.json; writes set-N.txt and inject-N.json (settles outside the set dropped)."""
import json, sys
SEED, H, N, OUT = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
per = json.load(open(H))['per_tape']
ev = json.load(open(SEED + '/inject.json'))['events']
must = {e['call']['body']['ticker'] for e in ev if 'call' in e}
order = sorted(per, key=lambda t: (-(per[t][1] + per[t][2]), t))
chosen = list(must)
for t in order:
    if len(chosen) >= N: break
    if t not in must: chosen.append(t)
s = set(chosen)
kept = [e for e in ev if 'call' not in e or e['call']['body']['ticker'] in s]
open(f'{OUT}/set-{N}.txt', 'w').write('\n'.join(sorted(s)) + '\n')
json.dump({'events': kept}, open(f'{OUT}/inject-{N}.json', 'w'), separators=(',', ':'))
fr = sum(per[t][1] + per[t][2] for t in s); ln = sum(per[t][0] for t in s)
print(json.dumps({'n': len(s), 'frames': fr, 'lines': ln, 'share': fr / sum(v[1] + v[2] for v in per.values()),
                  'inject_events': len(kept), 'dropped_settles': len(ev) - len(kept), 'min_frames': min(per[t][1] + per[t][2] for t in s)}))
