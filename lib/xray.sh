#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"
XRAY_DIR="/opt/etc/raykeen/xray"
XRAY_CFG="$XRAY_DIR/config.json"
XRAY_CFG_BAK="$XRAY_DIR/config.json.bak"
XRAY_LOG="/opt/etc/raykeen/logs/xray.log"
XRAY_PID_FILE="/tmp/raykeen/xray.pid"

sql_escape_x() { printf "%s" "$1" | sed "s/'/''/g"; }

xray_bin() {
  command -v xray 2>/dev/null || command -v xray-core 2>/dev/null || echo ""
}

xray_version() {
  b=$(xray_bin)
  [ -n "$b" ] || { echo "not-installed"; return; }
  "$b" version 2>/dev/null | head -n 1 | sed 's/^Xray //;s/^xray //'
}

xray_is_running() {
  [ -f "$XRAY_PID_FILE" ] || return 1
  pid=$(cat "$XRAY_PID_FILE" 2>/dev/null || echo "")
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

rotate_xray_log() {
  [ -f "$XRAY_LOG" ] || return 0
  size=$(wc -c < "$XRAY_LOG" 2>/dev/null || echo 0)
  [ "$size" -lt $((1024*1024)) ] || { mv "$XRAY_LOG" "${XRAY_LOG}.1" 2>/dev/null; : > "$XRAY_LOG"; }
}

insert_event() {
  typ="$1"; msg="$2"; pid="${3:-NULL}"
  sqlite3 "$DB_PATH" "INSERT INTO events(type,message,profile_id,created_at) VALUES('$(sql_escape_x "$typ")','$(sql_escape_x "$msg")',$pid,CURRENT_TIMESTAMP);"
  sqlite3 "$DB_PATH" "DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY created_at DESC LIMIT 200);"
}

active_profile_row() {
  sqlite3 "$DB_PATH" "SELECT id,protocol,name,address,port,uuid_password FROM profiles WHERE active=1 AND enabled=1 LIMIT 1;"
}

set_active_profile() {
  id=$(printf "%s" "$1" | tr -cd '0-9')
  sqlite3 "$DB_PATH" "UPDATE profiles SET active=0; UPDATE profiles SET active=1 WHERE id=$id;"
  sqlite3 "$DB_PATH" "UPDATE profiles SET use_count=use_count+1 WHERE id=$id;"
}

generate_xray_config_tmp() {
  mkdir -p "$XRAY_DIR" /opt/etc/raykeen/logs
  row=$(active_profile_row)
  [ -n "$row" ] || return 1
  pid=$(printf "%s" "$row" | cut -d'|' -f1)
  proto=$(printf "%s" "$row" | cut -d'|' -f2)
  addr=$(printf "%s" "$row" | cut -d'|' -f4)
  port=$(printf "%s" "$row" | cut -d'|' -f5)
  secret=$(printf "%s" "$row" | cut -d'|' -f6)

  socks_port=$(sqlite3 "$DB_PATH" "SELECT COALESCE(value,'1080') FROM settings WHERE key='socks5_port' LIMIT 1;")
  bind=$(sqlite3 "$DB_PATH" "SELECT COALESCE(value,'127.0.0.1') FROM settings WHERE key='bind_interface' LIMIT 1;")
  [ "$bind" = "localhost" ] && bind="127.0.0.1"
  [ "$bind" = "all" ] && bind="0.0.0.0"

  tmp="$XRAY_CFG.tmp"
  cat > "$tmp" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag":"socks-in","port": ${socks_port:-1080},"listen":"$bind","protocol":"socks","settings":{"auth":"noauth","udp":true}}],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "$proto",
      "settings": {
        "vnext": [{"address":"$addr","port": ${port:-443},"users":[{"id":"$secret"}]}]
      }
    },
    {"tag":"direct","protocol":"freedom"},
    {"tag":"block","protocol":"blackhole"}
  ],
  "routing": {"rules":[{"type":"field","outboundTag":"proxy","network":"tcp,udp"}]},
  "stats": {},
  "api": {"tag":"api","services":["StatsService"]}
}
JSON
  echo "$tmp|$pid"
}

validate_xray_config() {
  cfg="$1"
  b=$(xray_bin)
  [ -n "$b" ] || return 1
  "$b" run -test -config "$cfg" >/dev/null 2>&1
}

apply_xray_config() {
  meta=$(generate_xray_config_tmp) || return 1
  tmp=$(printf "%s" "$meta" | cut -d'|' -f1)
  if validate_xray_config "$tmp"; then
    [ -f "$XRAY_CFG" ] && cp "$XRAY_CFG" "$XRAY_CFG_BAK" 2>/dev/null || true
    mv "$tmp" "$XRAY_CFG"
    return 0
  fi
  rm -f "$tmp"
  insert_event "config_rollback" "Конфиг не прошёл xray run -test"
  return 1
}

xray_start() {
  xray_is_running && return 0
  b=$(xray_bin)
  [ -n "$b" ] || return 1
  apply_xray_config || return 1
  rotate_xray_log
  "$b" run -config "$XRAY_CFG" >> "$XRAY_LOG" 2>&1 &
  pid=$!
  echo "$pid" > "$XRAY_PID_FILE"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    insert_event "xray_restart" "xray запущен"
    return 0
  fi
  [ -f "$XRAY_CFG_BAK" ] && cp "$XRAY_CFG_BAK" "$XRAY_CFG"
  insert_event "config_rollback" "xray не стартовал, выполнен откат"
  return 1
}

xray_stop() {
  xray_is_running || return 0
  pid=$(cat "$XRAY_PID_FILE")
  kill -TERM "$pid" 2>/dev/null || true
  sleep 3
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  rm -f "$XRAY_PID_FILE"
  insert_event "xray_restart" "xray остановлен"
}

xray_restart() {
  xray_stop
  xray_start
}

xray_status() {
  if xray_is_running; then echo "running"; else echo "stopped"; fi
}

xray_log_tail() {
  lines="${1:-40}"
  [ -f "$XRAY_LOG" ] && tail -n "$lines" "$XRAY_LOG" || echo "Лог xray пуст"
}
