"""Capture only sanitized diagnostic events from the lab APK for up to 10 min."""
import argparse
import subprocess
import threading

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output')
parser.add_argument('--launch', action='store_true',
                    help='Restart the lab after attaching logcat, to include startup')
args = parser.parse_args()
if args.launch:
    subprocess.run(['adb', 'shell', 'am', 'force-stop', 'com.example.piliplus.debug'],
                   check=True)
    filters = ['-T', '1']
else:
    pid = subprocess.check_output(['adb', 'shell', 'pidof',
                                  'com.example.piliplus.debug']).decode().strip().split()[0]
    filters = ['--pid=' + pid]
process = subprocess.Popen(['adb', 'logcat', *filters, '-s', 'flutter:I'],
                           stdout=subprocess.PIPE, text=True, encoding='utf-8',
                           errors='replace')
deadline = threading.Timer(600, process.terminate)
deadline.start()
try:
    with open(args.output, 'w', encoding='utf-8') as output:
        if args.launch:
            subprocess.run(['adb', 'shell', 'am', 'start', '-n',
                'com.example.piliplus.debug/com.example.piliplus.MainActivity'], check=True)
        for line in process.stdout:
            if any(tag in line for tag in ['PILI_LAB ', 'PILI_NET ', 'PILI_CDN ', 'PILI_RELAY ']):
                output.write(line)
                output.flush()
                if '"event":"complete"' in line or '"event":"fatal"' in line:
                    print(line.strip())
                    break
finally:
    deadline.cancel()
    process.terminate()
    process.wait(timeout=5)
