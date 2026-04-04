#!/bin/sh

check_file_size() {
  file="$1"; max_bytes="$2"
  [ -f "$file" ] || return 1
  size=$(wc -c < "$file")
  [ "$size" -le "$max_bytes" ]
}

check_free_ram_mb() {
  free_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
  [ -n "$free_kb" ] || free_kb=0
  echo $((free_kb/1024))
}

require_min_ram() {
  min_mb="$1"
  avail_mb=$(check_free_ram_mb)
  [ "$avail_mb" -ge "$min_mb" ]
}

cleanup_tmp() {
  ttl_minutes="${1:-120}"
  mkdir -p /tmp/raykeen/cache /tmp/raykeen/sessions /tmp/raykeen/qr
  find /tmp/raykeen -type f -mmin +"$ttl_minutes" -delete 2>/dev/null
}

check_dependencies() {
  missing=""
  for dep in curl sqlite3 qrencode; do
    command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
  done
  [ -z "$missing" ]
}
