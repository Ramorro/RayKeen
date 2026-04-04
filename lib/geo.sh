#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"
GEO_DIR="/opt/etc/raykeen/xray"

sql_escape_g() { printf "%s" "$1" | sed "s/'/''/g"; }
get_geo_setting() { sqlite3 "$DB_PATH" "SELECT COALESCE(value,'$2') FROM settings WHERE key='$(sql_escape_g "$1")' LIMIT 1;"; }

geo_file_path() { echo "$GEO_DIR/$1"; }

geo_sizes() {
  for f in geoip.dat geosite.dat; do
    p="$GEO_DIR/$f"
    sz=0; [ -f "$p" ] && sz=$(wc -c < "$p" 2>/dev/null || echo 0)
    echo "$f|$sz"
  done
}

geo_update_from_urls() {
  require_min_ram 50 || { echo "Недостаточно RAM"; return 1; }
  mkdir -p "$GEO_DIR"
  ip_url=$(get_geo_setting geoip_url "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat")
  site_url=$(get_geo_setting geosite_url "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat")

  tmp_ip="$GEO_DIR/geoip.dat.tmp"
  tmp_site="$GEO_DIR/geosite.dat.tmp"
  curl -L -sS --max-time 60 -o "$tmp_ip" "$ip_url" || return 1
  curl -L -sS --max-time 60 -o "$tmp_site" "$site_url" || { rm -f "$tmp_ip"; return 1; }

  # optional checksum if configured
  ip_sha=$(get_geo_setting geoip_sha256 "")
  site_sha=$(get_geo_setting geosite_sha256 "")
  if [ -n "$ip_sha" ]; then
    got=$(sha256sum "$tmp_ip" | awk '{print $1}')
    [ "$got" = "$ip_sha" ] || { rm -f "$tmp_ip" "$tmp_site"; return 1; }
  fi
  if [ -n "$site_sha" ]; then
    got=$(sha256sum "$tmp_site" | awk '{print $1}')
    [ "$got" = "$site_sha" ] || { rm -f "$tmp_ip" "$tmp_site"; return 1; }
  fi

  was_running=0
  xray_is_running && was_running=1
  [ "$was_running" = "1" ] && xray_stop

  [ -f "$GEO_DIR/geoip.dat" ] && cp "$GEO_DIR/geoip.dat" "$GEO_DIR/geoip.dat.bak" 2>/dev/null || true
  [ -f "$GEO_DIR/geosite.dat" ] && cp "$GEO_DIR/geosite.dat" "$GEO_DIR/geosite.dat.bak" 2>/dev/null || true

  mv "$tmp_ip" "$GEO_DIR/geoip.dat"
  mv "$tmp_site" "$GEO_DIR/geosite.dat"

  sqlite3 "$DB_PATH" "INSERT INTO events(type,message,created_at) VALUES('geo_update','geo файлы обновлены',CURRENT_TIMESTAMP);"
  sqlite3 "$DB_PATH" "DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY created_at DESC LIMIT 200);"
  sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('geo_last_updated',datetime('now')) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"

  [ "$was_running" = "1" ] && xray_start >/dev/null 2>&1 || true
  echo "OK"
}

geo_rollback() {
  [ -f "$GEO_DIR/geoip.dat.bak" ] && cp "$GEO_DIR/geoip.dat.bak" "$GEO_DIR/geoip.dat"
  [ -f "$GEO_DIR/geosite.dat.bak" ] && cp "$GEO_DIR/geosite.dat.bak" "$GEO_DIR/geosite.dat"
  sqlite3 "$DB_PATH" "INSERT INTO events(type,message,created_at) VALUES('geo_update','geo rollback выполнен',CURRENT_TIMESTAMP);"
}

geo_should_auto_update() {
  mode=$(get_geo_setting geo_mode auto)
  [ "$mode" = "auto" ] || return 1
  iv=$(get_geo_setting geo_update_interval_days 1)
  last=$(get_geo_setting geo_last_updated "")
  [ -n "$last" ] || return 0
  now=$(date +%s)
  then=$(date -d "$last" +%s 2>/dev/null || echo 0)
  need=$((iv*24*3600))
  [ $((now-then)) -ge "$need" ]
}
