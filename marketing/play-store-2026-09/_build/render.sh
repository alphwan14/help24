#!/bin/bash
# Renders every composition twice: 1080x1920 for the Play Console, 2160x3840 for decks.
set -e
BASE="C:/Users/840 g8/Desktop/Projects/help24/marketing/play-store-2026-09"
CHROME="/c/Program Files/Google/Chrome/Application/chrome.exe"
PROF="/c/Users/840G8~1/AppData/Local/Temp/claude/c--Users-840-g8-Desktop-Projects-help24/205a52af-9783-4fe2-b39f-355a9986810d/scratchpad/chromeprof"

shoot () { # shoot <html> <out> <scale>
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-sandbox \
    --user-data-dir="$PROF" --virtual-time-budget=8000 \
    --force-device-scale-factor="$3" --window-size=1080,1920 \
    --screenshot="$2" "$1" >/dev/null 2>&1
}

for f in 01-discover 02-post 03-secure-service 04-job-status 05-messages 06-service-records; do
  shoot "$BASE/_build/html/$f.html" "$BASE/final/$f.png"  1
  shoot "$BASE/_build/html/$f.html" "$BASE/hi-res/$f@2x.png" 2
  printf '%-22s final %8s bytes   hi-res %9s bytes\n' "$f" \
    "$(stat -c%s "$BASE/final/$f.png")" "$(stat -c%s "$BASE/hi-res/$f@2x.png")"
done
