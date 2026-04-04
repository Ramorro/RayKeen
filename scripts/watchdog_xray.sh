#!/bin/sh
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$BASE_DIR/lib/system.sh"
. "$BASE_DIR/lib/logger.sh"
. "$BASE_DIR/lib/xray.sh"

if ! xray_is_running; then
  insert_event "xray_crash" "watchdog: процесс xray не найден"
  xray_restart >/dev/null 2>&1 || true
  exit 0
fi

port=$(sqlite3 /opt/etc/raykeen/data/raykeen.db "SELECT COALESCE(value,'1080') FROM settings WHERE key='socks5_port' LIMIT 1;" 2>/dev/null || echo 1080)
if ! curl -sS --connect-timeout 3 --max-time 5 --socks5-hostname "127.0.0.1:$port" http://connectivitycheck.gstatic.com/generate_204 -o /dev/null 2>/dev/null; then
  insert_event "xray_crash" "watchdog: healthcheck через socks5 неуспешен"
  xray_restart >/dev/null 2>&1 || true
fi

if ! require_min_ram 50; then
  log_msg WARN "Низкая RAM (<50MB) по данным watchdog"
fi
