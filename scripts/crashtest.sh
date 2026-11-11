#!/bin/zsh
# Phase-1 force-quit cleanup test.
#   scripts/crashtest.sh [private|public] [kill9|abort]
# Plays a test tone with afplay, has Mixer tap it at 30%, kills Mixer, and checks
# that the tone comes back and no taps/aggregates are left behind.
set -u
MODE=${1:-private}
KILL=${2:-kill9}
ROOT=${0:A:h:h}
APP="$ROOT/build/DerivedData/Build/Products/Debug/Mixer.app"
LOG="$HOME/Library/Logs/Mixer/spike.log"
LIST="$ROOT/scripts/out/ca-list"
TONE="$ROOT/scripts/out/tone.wav"

say_step() { echo "\n== $1"; say -r 210 "$1" }

: > "$LOG"
echo "mode=$MODE kill=$KILL"
echo "-- before"; "$LIST"

say_step "Full volume tone"
afplay "$TONE" & AFPLAY=$!
sleep 4

EXTRA=()
[[ $MODE == public ]] && EXTRA=(--spike-public)
open -n "$APP" --args --spike-pid $AFPLAY --spike-gain 0.3 $EXTRA
for i in {1..40}; do grep -q "running=true\|error=" "$LOG" 2>/dev/null && break; sleep 0.25; done
MIXER=$(grep -o 'mixer_pid=[0-9]*' "$LOG" | head -1 | cut -d= -f2)
if ! grep -q "running=true" "$LOG"; then
  echo "!! Mixer did not start the tap"; cat "$LOG"; kill $AFPLAY 2>/dev/null; [[ -n $MIXER ]] && kill $MIXER 2>/dev/null; exit 1
fi
say_step "Mixer on. Tone should be quieter"
sleep 5
echo "-- while running"; "$LIST"
tail -3 "$LOG"

if [[ $KILL == abort ]]; then kill -ABRT $MIXER; else kill -9 $MIXER; fi
KILLED_AT=$(date +%s)
sleep 1
ps -p $MIXER >/dev/null && echo "!! Mixer still alive" || echo "Mixer pid $MIXER is gone"
say_step "Mixer killed. Tone should be full volume again"
sleep 5
echo "-- after kill"; "$LIST"
kill $AFPLAY 2>/dev/null
echo "-- coreaudiod log around the kill"
log show --style compact --start "$(date -r $((KILLED_AT-2)) '+%Y-%m-%d %H:%M:%S')" \
  --predicate 'process == "coreaudiod" AND (eventMessage CONTAINS[c] "tap" OR eventMessage CONTAINS[c] "aggregate" OR eventMessage CONTAINS[c] "client")' 2>/dev/null | tail -25
echo "-- spike log"; cat "$LOG"
