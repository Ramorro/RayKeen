#!/bin/sh
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$BASE_DIR/lib/xray.sh"
. "$BASE_DIR/lib/autoselect.sh"

th=$(get_as_setting autoselect_crash_threshold 3)
en=$(get_as_setting autoselect_enabled 0)
[ "$en" = "1" ] || exit 0
cnt=$(sqlite3 /opt/etc/raykeen/data/raykeen.db "SELECT COUNT(*) FROM events WHERE type='xray_crash' AND created_at >= datetime('now','-1 day');" 2>/dev/null || echo 0)
if [ "$cnt" -ge "$th" ]; then
  run_autoselect >/dev/null 2>&1 || true
fi
