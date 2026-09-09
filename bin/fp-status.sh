#!/usr/bin/env bash
# Zimixin fingerprint widget — status collector.
# Queries the fingerprint-ocv daemon (D-Bus) via the python action script and
# writes a small JSON file. On ANY query failure it keeps the last known status
# (bar button never collapses to an empty label from a transient hiccup).
# Refreshes only on demand (panel open / right-click), never on a timer —
# fingerprint-ocv can abort on concurrent D-Bus queries.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${FP_STATUS_FILE:-$HOME/.local/state/omarchy/fingerprint/status.json}"
PY="$HERE/fp-action.py"
mkdir -p "$(dirname "$OUT")"

# Preserve the previous file as the fallback.
prev=""
if [[ -f "$OUT" ]]; then
  prev=$(cat "$OUT" 2>/dev/null)
fi

# Always write a fresh non-empty file so the FileView at startup has something
# even if the first live query fails. Live refresh only replaces it when ok.
if [[ -z "$prev" ]]; then
  printf '{"ready":true,"enrolled":false,"count":0,"names":[],"finger_present":false,"daemon_up":false,"generated_at":0,"stale":true}\n' > "$OUT.$$"
  mv -f "$OUT.$$" "$OUT"
  prev=$(cat "$OUT" 2>/dev/null)
fi

# Live query through fp-action.py (python-dbus, gives us the name array).
# The python script itself is our daemon liveness probe: if it answers with
# ready:true the driver is up; a daemon_up field rides along to drive the
# widget's driver-control button label.
if out=$(timeout 8 "$PY" status 2>/dev/null); then
  # augment with daemon_up=true (a successful python-dbus reply == driver alive)
  out_up=$(printf '%s' "$out" | sed 's/"ready" *: *true/"ready": true, "daemon_up": true/')
  if printf '%s' "$out" | grep -q '"ready" *: *true'; then
    printf '%s\n' "$out_up" > "$OUT.$$"
    mv -f "$OUT.$$" "$OUT"
    cat "$OUT"
    exit 0
  fi
fi

# Failed: keep prior values but mark stale + daemon likely down.
prev_stale=$(printf '%s' "$prev" | sed 's/"stale": *[a-z]*/"stale": true/; s/"daemon_up": *[a-z]*/"daemon_up": false/')
printf '%s\n' "$prev_stale" > "$OUT.$$"
mv -f "$OUT.$$" "$OUT"
cat "$OUT"
exit 0