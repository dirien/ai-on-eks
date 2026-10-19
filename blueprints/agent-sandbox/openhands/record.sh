#!/usr/bin/env bash
# Record openhands-demo.tape with Charm VHS and encode the deliverables.
#
#   ./record.sh            # check, record, encode, save the log
#   ./record.sh encode     # re-encode out/openhands-demo-raw.mp4 only
#   ./record.sh log        # re-write the raw log from out/session.log only
#
# Everything lands in ./out/ (git-ignored): openhands-demo.mp4, .webm,
# openhands-demo-poster.png and openhands-raw-<UTC date>.txt, next to the
# VHS raw output and the script(1) session log.
#
# Needs vhs (0.12+), ttyd, ffmpeg (libx264, libvpx-vp9), a Chromium VHS can
# find, and the JetBrains Mono font. kubectl inside the recorded shell uses
# the ambient AWS credentials, or, with ESC_ENV set, the script re-runs
# itself under `pulumi env run "$ESC_ENV"`; the tape never prints them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${ESC_ENV:-}" ] && [ -z "${OPENHANDS_DEMO_IN_ESC:-}" ]; then
  export OPENHANDS_DEMO_IN_ESC=1
  exec pulumi env run "$ESC_ENV" -- bash "$HERE/$(basename "$0")" "$@"
fi
cd "$HERE"
OUT="$HERE/out"
DAY="${DAY:-$(date -u +%F)}"
mkdir -p "$OUT"

record() {
  local r
  for _ in $(seq 1 60); do
    r="$(kubectl -n agent-sandboxes get sandboxwarmpool openhands-pool -o jsonpath='{.status.readyReplicas}')"
    [ "${r:-0}" -ge 2 ] && break
    sleep 5
  done
  ./setup-openhands.sh check
  rm -f out/openhands-demo-raw.mp4 out/session.log out/session.timing
  local rc=0
  vhs openhands-demo.tape || rc=$?
  # Off-screen cleanup after the take: the claim the tape made on screen.
  kubectl delete -f manifests/40-claim.yaml --ignore-not-found
  return "$rc"
}

encode() {
  # H.264 High, yuv420p, 30 fps, no audio, moov atom up front for the browser.
  ffmpeg -y -loglevel error -i out/openhands-demo-raw.mp4 -an -c:v libx264 -profile:v high \
    -pix_fmt yuv420p -preset slow -crf 18 -r 30 -movflags +faststart "$OUT/openhands-demo.mp4"
  ffmpeg -y -loglevel error -i out/openhands-demo-raw.mp4 -an -c:v libvpx-vp9 -b:v 0 -crf 32 \
    -row-mt 1 -deadline good -cpu-used 2 "$OUT/openhands-demo.webm"
  # Poster: POSTER_TS seconds in, default 1 s before the end.
  local dur ts
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/openhands-demo.mp4")"
  ts="${POSTER_TS:-$(python3 -c "print(max(0.0, $dur - 1.0))")}"
  ffmpeg -y -loglevel error -ss "$ts" -i "$OUT/openhands-demo.mp4" -frames:v 1 \
    "$OUT/openhands-demo-poster.png"
  ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate:format=duration \
    -of compact "$OUT/openhands-demo.mp4"
}

save_log() {
  # Raw terminal log, ANSI stripped. Nothing in the session prints secrets;
  # the grep is a backstop for AWS key ids and the pool session key.
  local log="$OUT/openhands-raw-$DAY.txt" key
  {
    echo "# Raw terminal log of the VHS recording (openhands-demo.tape, raw take), $DAY."
    echo "# Captured with script(1) inside the recorded shell. ANSI escape sequences"
    echo "# (colours, cursor moves, hyperlinks) stripped; otherwise unedited. The first"
    echo "# lines are the hidden shell setup; cursor redraws can leave stray characters."
    echo
    sed -E 's/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g; s/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][AB0]//g; s/\r//g' out/session.log
  } > "$log"
  key="$(kubectl -n agent-sandboxes get secret openhands-session-key -o jsonpath='{.data.key}' | base64 -d)"
  if grep -qE 'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|aws_secret_access_key|AWS_SECRET' "$log" \
     || { [ -n "$key" ] && grep -qF "$key" "$log"; }; then
    echo "ERROR: possible secret in $log, not keeping it" >&2; rm -f "$log"; exit 1
  fi
  unset key
  echo "log: $log"
}

case "${1:-all}" in
  all) record; encode; save_log ;;
  encode) encode ;;
  log) save_log ;;
  *) echo "usage: $0 [all|encode|log]" >&2; exit 1 ;;
esac
