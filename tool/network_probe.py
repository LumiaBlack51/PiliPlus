"""Measure playurl candidates on a USB Android device (no root or credentials).

Usage: python tool/network_probe.py BV1fK4y1t7hj --rounds 2 --output measurements.json
Only timings and CDN hostnames are saved; signed URLs are not written to output.
The phone must provide curl. Probes are serial to avoid competing for bandwidth.
"""
import argparse
import json
import shlex
import subprocess
import time
from urllib.parse import urlencode, urlsplit

FIELDS = ('http_code', 'exitcode', 'size_download', 'speed_download',
          'time_namelookup', 'time_connect', 'time_appconnect',
          'time_starttransfer', 'time_total')
FORMAT = '{' + ','.join('"' + k + '":"%{' + k + '}"' for k in FIELDS) + '}'


def shell(command, timeout=25):
    result = subprocess.run(
        ['adb', 'shell', command], capture_output=True, timeout=timeout,
        encoding='utf-8', errors='replace',
    )
    return result.stdout


def api(path, params):
    url = 'https://api.bilibili.com' + path + '?' + urlencode(params)
    raw = shell('curl -sS --connect-timeout 5 --max-time 15 -H '
                + shlex.quote('Referer: https://www.bilibili.com')
                + ' ' + shlex.quote(url))
    response = json.loads(raw)
    if response.get('code') != 0:
        raise RuntimeError('API code ' + str(response.get('code')))
    return response['data']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bvid')
    parser.add_argument('--rounds', type=int, default=2)
    parser.add_argument('--mib', type=int, default=4)
    parser.add_argument('--quality', type=int, default=80)
    parser.add_argument('--output', default='network-measurements.json')
    args = parser.parse_args()
    if not 1 <= args.rounds <= 5 or not 1 <= args.mib <= 8:
        parser.error('rounds must be 1..5; mib must be 1..8')
    info = api('/x/web-interface/view', {'bvid': args.bvid})
    play = api('/x/player/playurl', dict(bvid=args.bvid, cid=info['cid'],
               qn=args.quality, fnval=4048, fourk=1, try_look=1))
    dash = play.get('dash') or {}
    videos = [v for v in dash.get('video', []) if v['id'] == args.quality]
    if not videos:
        raise RuntimeError('Requested quality is unavailable to this guest session')
    results = []
    for round_index in range(args.rounds):
        for track in videos:
            candidates = list(dict.fromkeys([
                track.get('baseUrl') or track['base_url'],
                *(track.get('backupUrl') or track.get('backup_url') or []),
            ]))[:4]
            # Alternate order to reduce order-dependent cache/network effects.
            if round_index % 2:
                candidates.reverse()
            for url in candidates:
                start = (round_index + 1) * 1024 * 1024
                end = start + args.mib * 1024 * 1024 - 1
                command = ('curl -sS -o /dev/null --connect-timeout 4 --max-time 12 '
                    f'--range {start}-{end} -A Mozilla/5.0 -H '
                    + shlex.quote('Referer: https://www.bilibili.com')
                    + ' -w ' + shlex.quote(FORMAT) + ' ' + shlex.quote(url))
                raw = {k: float(v) for k, v in json.loads(shell(command)).items()}
                row = dict(timestamp=time.time(), round=round_index + 1,
                           bvid=args.bvid, quality=track['id'], codec=track['codecs'],
                           bitrate=track['bandwidth'], host=urlsplit(url).hostname)
                for key in FIELDS:
                    row[key] = raw.get(key)
                row['tcp_ms'] = 1000 * (raw['time_connect'] - raw['time_namelookup'])
                row['tls_ms'] = 1000 * (raw['time_appconnect'] - raw['time_connect'])
                results.append(row)
                print(json.dumps(row), flush=True)
                with open(args.output, 'w', encoding='utf-8') as output:
                    json.dump(results, output, indent=2)


if __name__ == '__main__':
    main()
