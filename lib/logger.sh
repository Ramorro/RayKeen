#!/bin/sh
LOG_FILE="/opt/etc/raykeen/logs/raykeen.log"
LOG_MAX_SIZE=$((1024*1024))

get_log_level() {
  sqlite3 /opt/etc/raykeen/data/raykeen.db "SELECT value FROM settings WHERE key='log_level' LIMIT 1;" 2>/dev/null || echo "INFO"
}

rotate_log_if_needed() {
  [ -f "$LOG_FILE" ] || return 0
  size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -ge "$LOG_MAX_SIZE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
    : > "$LOG_FILE"
  fi
}

should_log() {
  current="$1"
  want="$2"
  levels="DEBUG INFO WARN ERROR"
  c_idx=0
  w_idx=0
  idx=1
  for lvl in $levels; do
    [ "$lvl" = "$current" ] && c_idx=$idx
    [ "$lvl" = "$want" ] && w_idx=$idx
    idx=$((idx+1))
  done
  [ "$w_idx" -ge "$c_idx" ]
}

log_msg() {
  level="$1"
  shift
  msg="$*"
  mkdir -p "$(dirname "$LOG_FILE")"
  rotate_log_if_needed
  cfg_level=$(get_log_level)
  should_log "$cfg_level" "$level" || return 0
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG_FILE"
}
