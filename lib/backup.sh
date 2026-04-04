#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"
BACKUP_DIR="/opt/etc/raykeen/backups"

make_backup_archive() {
  mode="$1" # full|no_password
  mkdir -p "$BACKUP_DIR" /tmp/raykeen
  ts=$(date +%Y%m%d_%H%M%S)
  dump="/tmp/raykeen/raykeen_${ts}.sql"
  out="/tmp/raykeen/raykeen_${ts}.tar.gz"
  sqlite3 "$DB_PATH" .dump > "$dump"
  if [ "$mode" = "no_password" ]; then
    sed -i "/password_hash/d" "$dump"
  fi
  tar -czf "$out" -C /tmp/raykeen "raykeen_${ts}.sql"
  rm -f "$dump"
  echo "$out"
}

list_backups_csv() {
  mkdir -p "$BACKUP_DIR"
  printf 'name,size,created\n'
  for f in "$BACKUP_DIR"/*.tar.gz; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    size=$(wc -c < "$f" 2>/dev/null || echo 0)
    c=$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
    printf '%s,%s,%s\n' "$name" "$size" "$c"
  done
}

weekly_backup_rotate() {
  mkdir -p "$BACKUP_DIR"
  arc=$(make_backup_archive full)
  cp "$arc" "$BACKUP_DIR/$(basename "$arc")"
  ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f
}

import_backup_archive() {
  archive="$1"
  mode="$2" # all|profiles|routing
  [ -f "$archive" ] || return 1
  require_min_ram 50 || return 1
  tmpd="/tmp/raykeen/import_$$"
  mkdir -p "$tmpd"
  tar -xzf "$archive" -C "$tmpd" || return 1
  sql=$(find "$tmpd" -name '*.sql' | head -n1)
  [ -n "$sql" ] || return 1

  newdb="$tmpd/new.db"
  sqlite3 "$newdb" < "$sql" || return 1
  chk=$(sqlite3 "$newdb" "PRAGMA integrity_check;" 2>/dev/null)
  [ "$chk" = "ok" ] || return 1

  was=0; xray_is_running && was=1
  [ "$was" = "1" ] && xray_stop

  case "$mode" in
    profiles)
      sqlite3 "$DB_PATH" "ATTACH '$newdb' AS n; DELETE FROM profiles; INSERT INTO profiles SELECT * FROM n.profiles; DETACH n;" ;;
    routing)
      sqlite3 "$DB_PATH" "ATTACH '$newdb' AS n; DELETE FROM routing_rules; DELETE FROM routing_columns; INSERT INTO routing_columns SELECT * FROM n.routing_columns; INSERT INTO routing_rules SELECT * FROM n.routing_rules; DETACH n;" ;;
    *)
      cp "$DB_PATH" "$DB_PATH.bak" 2>/dev/null || true
      cp "$newdb" "$DB_PATH" ;;
  esac

  [ "$was" = "1" ] && xray_start >/dev/null 2>&1 || true
  rm -rf "$tmpd"
}

make_profile_qr_png() {
  pid=$(printf "%s" "$1" | tr -cd '0-9')
  uri=$(sqlite3 "$DB_PATH" "SELECT raw_uri FROM profiles WHERE id=$pid LIMIT 1;")
  [ -n "$uri" ] || return 1
  out="/tmp/raykeen/qr_${pid}_$$.png"
  qrencode -o "$out" "$uri" || return 1
  echo "$out"
}
