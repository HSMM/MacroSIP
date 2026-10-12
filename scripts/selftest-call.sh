#!/usr/bin/env bash
# End-to-end check: macrosip-cli calls two local pjsua phones that auto-answer and play a tone.
# Verifies two-way RTP, hold/unhold, DTMF, recording (WAV), presence (SUBSCRIBE/NOTIFY),
# a two-leg conference (merge/split) and hang-up. Needs scripts/build-pjsip.sh done.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${TMPDIR:-/tmp}/macrosip-selftest.$$"
mkdir -p "$WORK"
cleanup() {
  kill ${PJ:-} ${PJ2:-} 2>/dev/null || true
  wait ${PJ:-} ${PJ2:-} 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

PORT1=5080        # first phone: call, recording, presence, conference leg 1
PORT2=5081        # second phone: conference leg 2
CLI1=5088         # telnet CLI of the first phone (the selftest changes its presence there)

command -v nc >/dev/null || { echo "selftest needs nc (netcat) to drive the pjsua CLI"; exit 1; }

# 3 s 600 Hz 16 kHz mono WAV for pjsua to play.
python3 -I - "$WORK/tone600.wav" <<'PY'
import math, struct, sys
sr, secs = 16000, 3
pcm = b''.join(struct.pack('<h', int(8000*math.sin(2*math.pi*600*i/sr))) for i in range(sr*secs))
hdr = b'RIFF' + struct.pack('<I', 36+len(pcm)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, sr, sr*2, 2, 16) + b'data' + struct.pack('<I', len(pcm))
open(sys.argv[1], 'wb').write(hdr + pcm)
PY

swift build --product macrosip-cli >/dev/null
# --use-cli --no-cli-console: pjsua must not read stdin; a background job of a
# non-interactive shell gets /dev/null and the classic console quits on EOF at once.
PJOPTS=(--use-cli --no-cli-console --null-audio --auto-answer 200 --no-tcp
        --ip-addr 127.0.0.1 --bound-addr 127.0.0.1
        --play-file "$WORK/tone600.wav" --auto-play --auto-loop)
third_party/pjsip/bin/pjsua "${PJOPTS[@]}" --local-port $PORT1 --rtp-port 4000 \
  --cli-telnet-port $CLI1 > "$WORK/pjsua1.log" 2>&1 &
PJ=$!
third_party/pjsip/bin/pjsua "${PJOPTS[@]}" --local-port $PORT2 --rtp-port 4200 \
  > "$WORK/pjsua2.log" 2>&1 &
PJ2=$!
sleep 2

# pjsua's app sets its accounts online at start, so it answers SUBSCRIBE with an open status.
# The selftest changes that status through the telnet CLI ("T 5" away, "T 2" busy, "T 1"
# available); make sure the CLI answers before relying on it.
{ sleep 0.3; printf 'acc show\r\n'; sleep 0.5; } \
  | nc -w 1 127.0.0.1 $CLI1 2>/dev/null | LC_ALL=C tr -cd '[:print:]\n' > "$WORK/cli1.txt" || true
grep -q "Online status: Online" "$WORK/cli1.txt" || {
  echo "pjsua CLI on telnet 127.0.0.1:$CLI1 did not report an online account:"; cat "$WORK/cli1.txt"; exit 1; }

# Show the summary (or the "SELFTEST FAILED" line); hide PJSIP logs, events and step lines.
"$(swift build --product macrosip-cli --show-bin-path)/macrosip-cli" --selftest \
  --target "sip:test@127.0.0.1:$PORT1" --target2 "sip:test@127.0.0.1:$PORT2" --target-cli $CLI1 \
  --scratch "$WORK" 2>&1 \
  | grep -vE '^\s*(pj[0-9]\||[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+ (\[|===))'
