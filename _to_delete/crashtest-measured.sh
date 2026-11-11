#!/bin/zsh
# Objective version of the force-quit test (no speech, no ears needed).
# An unmuted global "observer" tap measures the system mix while a muting tap
# (gain 0) silences afplay, then the muting Mixer is killed.
#   scripts/crashtest-measured.sh [private|public] [kill9|abort|quit]
set -u
MODE=${1:-private}
KILL=${2:-kill9}
ROOT=${0:A:h:h}
APP="$ROOT/build/DerivedData/Build/Products/Debug/Mixer.app"
LOGDIR="$HOME/Library/Logs/Mixer"
TONE="$ROOT/scripts/out/tone.wav"
mkdir -p "$LOGDIR"; : > "$LOGDIR/spike.log"; : > "$LOGDIR/observe.log"

mark() { echo "$(date +%s.%N | cut -c1-14) MARK $1" >> "$LOGDIR/observe.log"; }

open -n "$APP" --args --observe
for i in {1..40}; do grep -q "running=true\|error=\|permission=denied\|permission=unknown" "$LOGDIR/observe.log" && break; sleep 0.25; done
OBS=$(grep -o 'mixer_pid=[0-9]*' "$LOGDIR/observe.log" | cut -d= -f2)
grep -q "running=true" "$LOGDIR/observe.log" || { echo "observer failed:"; cat "$LOGDIR/observe.log"; exit 1; }
sleep 1.5; mark "silence"
sleep 1.5
afplay "$TONE" & AFPLAY=$!
sleep 0.5; mark "tone_full"
sleep 3
EXTRA=(); [[ $MODE == public ]] && EXTRA=(--spike-public)
open -n "$APP" --args --spike-pid $AFPLAY --spike-gain 0 $EXTRA
for i in {1..40}; do grep -q "running=true\|error=" "$LOGDIR/spike.log" && break; sleep 0.25; done
MIXER=$(grep -o 'mixer_pid=[0-9]*' "$LOGDIR/spike.log" | cut -d= -f2)
sleep 0.5; mark "muted_by_mixer"
sleep 3
case $KILL in
  abort) kill -ABRT $MIXER ;;
  quit)  osascript -e "tell application id \"com.jrortizdesign.mixer\" to quit" 2>/dev/null; kill -TERM $MIXER ;;
  *)     kill -9 $MIXER ;;
esac
sleep 0.5; mark "after_kill"
sleep 3; mark "end"
kill $AFPLAY 2>/dev/null; kill $OBS 2>/dev/null
sleep 0.3

# Average observer peak per phase.
awk '
  /MARK/ { phase=$3; next }
  /input_peak=/ && phase != "" { split($0, a, "input_peak="); s[phase]+=a[2]; n[phase]++ }
  END { for (p in s) printf "%-16s avg_peak=%.4f (n=%d)\n", p, s[p]/n[p], n[p] }
' "$LOGDIR/observe.log" | sort
echo "-- spike log"; grep -v callbacks "$LOGDIR/spike.log"
echo "-- visible leftovers"; "$ROOT/scripts/out/ca-list"
