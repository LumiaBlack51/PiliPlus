"""Summarize lab logs without treating startup or an intentional seek as underrun."""
import collections
import datetime
import json
import sys

groups = collections.defaultdict(list)
for line in open(sys.argv[1], encoding='utf-8'):
    if 'PILI_LAB ' not in line:
        continue
    raw = line.split('PILI_LAB ', 1)[1]
    try:
        row = json.loads(raw)
    except json.JSONDecodeError:
        # Older lab builds exceeded Android's per-line log limit. Preserve only
        # the complete prefix; never invent the missing properties.
        if '"event":"sample"' not in raw or ',"demuxer-cache-state"' not in raw:
            continue
        row = json.loads(raw.split(',"demuxer-cache-state"', 1)[0] + '}')
    row['wall'] = datetime.datetime.strptime('2000-' + line[:18],
                                             '%Y-%m-%d %H:%M:%S.%f').timestamp()
    if row.get('test'):
        groups[row['test']].append(row)

for name, rows in groups.items():
    waiting = None
    intentional = True
    spans = []
    initializing = True
    for row in rows:
        if row['event'] == 'start':
            initializing = True
        if row['event'] == 'sample' and float(row.get('time-pos') or 0) > 0.2:
            initializing = False
        if row['event'] in ('start', 'seek'):
            intentional = True
        if row['event'] == 'buffering':
            if row['active']:
                waiting = (row['wall'], intentional or initializing)
            else:
                if waiting is not None:
                    spans.append((round(row['wall'] - waiting[0], 3), waiting[1]))
                waiting = None
                intentional = False
    unfinished = None
    if waiting is not None:
        unfinished = round(rows[-1]['wall'] - waiting[0], 3)
        spans.append((unfinished, waiting[1]))
    samples = [r for r in rows if r['event'] == 'sample']
    result = dict(test=name, samples=len(samples),
                  startup_seek_buffers=[s[0] for s in spans if s[1]],
                  underruns=[s[0] for s in spans if not s[1]],
                  stall_seconds=round(sum(s[0] for s in spans if not s[1]), 3),
                  unfinished_buffer_seconds=unfinished,
                  paused_samples=sum(r.get('paused-for-cache') == 'yes' for r in samples),
                  decoder_drops=max((int(r.get('decoder-frame-drop-count') or 0)
                                     for r in samples), default=0),
                  errors=sum(r['event'] in ('error', 'fatal') or
                             (r['event'] == 'mpv' and r.get('level') in ('error', 'fatal'))
                             for r in rows),
                  complete=any(r['event'] == 'end' for r in rows))
    print(json.dumps(result))
