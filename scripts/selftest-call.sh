#!/usr/bin/env bash
# End-to-end call check: macrosip-cli calls a local pjsua that auto-answers and plays a tone.
# Verifies two-way RTP, hold/unhold, DTMF and hang-up. Needs scripts/build-pjsip.sh done.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${TMPDIR:-/tmp}/macrosip-selftest.$$"
mkdir -p "$WORK"
trap 'kill ${PJ:-} 2>/dev/null || true; rm -rf "$WORK"' EXIT

# 3 s 600 Hz 16 kHz mono WAV for pjsua to play.
python3 -I - "$WORK/tone600.wav" <<'PY'
import math, struct, sys
sr, secs = 16000, 3
pcm = b''.join(struct.pack('<h', int(8000*math.sin(2*math.pi*600*i/sr))) for i in range(sr*secs))
hdr = b'RIFF' + struct.pack('<I', 36+len(pcm)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, sr, sr*2, 2, 16) + b'data' + struct.pack('<I', len(pcm))
open(sys.argv[1], 'wb').write(hdr + pcm)
PY

swift build --product macrosip-cli >/dev/null
third_party/pjsip/bin/pjsua --null-audio --auto-answer 200 --local-port 5080 --no-tcp \
  --ip-addr 127.0.0.1 --bound-addr 127.0.0.1 \
  --play-file "$WORK/tone600.wav" --auto-play --auto-loop > "$WORK/pjsua.log" 2>&1 &
PJ=$!
sleep 2
"$(swift build --product macrosip-cli --show-bin-path)/macrosip-cli" --selftest 2>&1 | grep -vE '^\s*(pj[0-9]\||[0-9]{2}:[0-9]{2}:[0-9]{2}\.)'
