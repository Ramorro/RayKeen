#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"
XRAY_DIR="/opt/etc/raykeen/xray"
XRAY_CFG="$XRAY_DIR/config.json"
XRAY_CFG_BAK="$XRAY_DIR/config.json.bak"
XRAY_LOG="/opt/etc/raykeen/logs/xray.log"
XRAY_PID_FILE="/tmp/raykeen/xray.pid"

sql_escape_x() { printf "%s" "$1" | sed "s/'/''/g"; }
get_setting_x() { sqlite3 "$DB_PATH" "SELECT COALESCE(value,'$2') FROM settings WHERE key='$(sql_escape_x "$1")' LIMIT 1;"; }

xray_bin() { command -v xray 2>/dev/null || command -v xray-core 2>/dev/null || echo ""; }
xray_version() { b=$(xray_bin); [ -n "$b" ] || { echo "not-installed"; return; }; "$b" version 2>/dev/null | head -n 1 | sed 's/^Xray //;s/^xray //'; }

xray_is_running() { [ -f "$XRAY_PID_FILE" ] || return 1; pid=$(cat "$XRAY_PID_FILE" 2>/dev/null || echo ""); [ -n "$pid" ] || return 1; kill -0 "$pid" 2>/dev/null; }
rotate_xray_log() { [ -f "$XRAY_LOG" ] || return 0; size=$(wc -c < "$XRAY_LOG" 2>/dev/null || echo 0); [ "$size" -lt $((1024*1024)) ] || { mv "$XRAY_LOG" "${XRAY_LOG}.1" 2>/dev/null; : > "$XRAY_LOG"; }; }

insert_event() {
  typ="$1"; msg="$2"; pid="${3:-NULL}"
  sqlite3 "$DB_PATH" "INSERT INTO events(type,message,profile_id,created_at) VALUES('$(sql_escape_x "$typ")','$(sql_escape_x "$msg")',$pid,CURRENT_TIMESTAMP);"
  sqlite3 "$DB_PATH" "DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY created_at DESC LIMIT 200);"
}

active_profile_row() { sqlite3 "$DB_PATH" "SELECT id,protocol,name,address,port,uuid_password FROM profiles WHERE active=1 AND enabled=1 LIMIT 1;"; }
set_active_profile() { id=$(printf "%s" "$1" | tr -cd '0-9'); sqlite3 "$DB_PATH" "UPDATE profiles SET active=0; UPDATE profiles SET active=1 WHERE id=$id;"; sqlite3 "$DB_PATH" "UPDATE profiles SET use_count=use_count+1 WHERE id=$id;"; }



build_routing_rules_json() {
  ids=$(sqlite3 "$DB_PATH" "SELECT id,outbound,COALESCE(profile_id,''),enabled FROM routing_columns ORDER BY "order" ASC;")
  out=""
  oldIFS=$IFS; IFS='
'
  for row in $ids; do
    cid=$(printf "%s" "$row" | cut -d'|' -f1)
    outb=$(printf "%s" "$row" | cut -d'|' -f2)
    pid=$(printf "%s" "$row" | cut -d'|' -f3)
    en=$(printf "%s" "$row" | cut -d'|' -f4)
    [ "$en" = "1" ] || continue
    tag="$outb"
    [ "$outb" = "proxy" ] && [ -n "$pid" ] && tag="proxy_${pid}"
    rr=$(sqlite3 -csv "$DB_PATH" "SELECT type,value FROM routing_rules WHERE column_id=$cid AND enabled=1 ORDER BY "order" ASC;")
    [ -n "$rr" ] || continue
    domains=""; ips=""
    while IFS=',' read -r t v; do
      val=$(printf "%s" "$v" | sed 's/^"//;s/"$//;s/"/\"/g')
      if [ "$t" = "domain" ]; then [ -z "$domains" ] && domains=""$val"" || domains="$domains,"$val""; else [ -z "$ips" ] && ips=""$val"" || ips="$ips,"$val""; fi
    done <<EOF2
$rr
EOF2
    rule='{"type":"field","outboundTag":"'"$tag"'"'
    [ -n "$domains" ] && rule="$rule,"domain":[${domains}]"
    [ -n "$ips" ] && rule="$rule,"ip":[${ips}]"
    rule="$rule}"
    [ -z "$out" ] && out="$rule" || out="$out,$rule"
  done
  IFS=$oldIFS
  echo "$out"
}

build_proxy_outbounds_json() {
  out=""
  pids=$(sqlite3 "$DB_PATH" "SELECT DISTINCT profile_id FROM routing_columns WHERE enabled=1 AND outbound='proxy' AND profile_id IS NOT NULL ORDER BY profile_id ASC;")
  for pid in $pids; do
    row=$(sqlite3 "$DB_PATH" "SELECT protocol,address,port,uuid_password FROM profiles WHERE id=$pid LIMIT 1;")
    [ -n "$row" ] || continue
    proto=$(printf "%s" "$row" | cut -d'|' -f1)
    addr=$(printf "%s" "$row" | cut -d'|' -f2)
    port=$(printf "%s" "$row" | cut -d'|' -f3)
    secret=$(printf "%s" "$row" | cut -d'|' -f4)
    item='{"tag":"proxy_'"$pid"'","protocol":"'"$proto"'","settings":{"vnext":[{"address":"'"$addr"'","port":'"${port:-443}"',"users":[{"id":"'"$secret"'"}]}]}}'
    [ -z "$out" ] && out="$item" || out="$out,$item"
  done
  echo "$out"
}

compose_doh_servers_json() {
  enabled=$(get_setting_x doh_enabled 0)
  [ "$enabled" = "1" ] || { echo ""; return; }
  order=$(get_setting_x doh_servers_order "https://dns.quad9.net/dns-query,https://dns.adguard-dns.com/dns-query,https://doh.dns.sb/dns-query")
  custom=$(get_setting_x doh_custom_url "")
  fallback_timeout=$(get_setting_x doh_fallback_timeout_sec 3)
  out=""
  IFS=','
  for s in $order; do
    [ -n "$s" ] || continue
    esc=$(printf "%s" "$s" | sed 's/"/\\"/g')
    [ -z "$out" ] && out="\"$esc\"" || out="$out,\"$esc\""
  done
  IFS=' '
  [ -n "$custom" ] && out="$out,\"$(printf "%s" "$custom" | sed 's/"/\\"/g')\""
  [ -n "$out" ] || return
  echo "\"dns\":{\"servers\":[${out}],\"queryStrategy\":\"UseIP\",\"disableCache\":false,\"tag\":\"dns_in\",\"clientIp\":\"\"},\"policy\":{\"levels\":{\"0\":{\"connIdle\":300}},\"system\":{\"statsOutboundUplink\":true,\"statsOutboundDownlink\":true}},\"routing\":{\"domainStrategy\":\"AsIs\"},\"_doh_fallback_timeout\":$fallback_timeout"
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
  socks_port=$(get_setting_x socks5_port 1080)
  bind=$(get_setting_x bind_interface localhost)
  [ "$bind" = "localhost" ] && bind="127.0.0.1"
  [ "$bind" = "all" ] && bind="0.0.0.0"

  dns_extra=$(compose_doh_servers_json)
  route_rules=$(build_routing_rules_json)
  extra_outbounds=$(build_proxy_outbounds_json)
  fake_dns=$(get_setting_x doh_fakedns 0)
  [ "$fake_dns" = "1" ] && fake_line=',"fakedns":[{"ipPool":"198.18.0.0/15","poolSize":65535}]' || fake_line=''

  tmp="$XRAY_CFG.tmp"
  cat > "$tmp" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"tag":"socks-in","port": ${socks_port:-1080},"listen":"$bind","protocol":"socks","settings":{"auth":"noauth","udp":true}}],
  "outbounds": [
    {"tag": "proxy","protocol": "$proto","settings": {"vnext": [{"address":"$addr","port": ${port:-443},"users":[{"id":"$secret"}]}]}},
    {"tag":"direct","protocol":"freedom"},
    {"tag":"block","protocol":"blackhole"}${extra_outbounds:+,${extra_outbounds}}
  ],
  "routing": {"rules":[{"type":"field","outboundTag":"proxy","network":"tcp,udp"}${route_rules:+,${route_rules}}]},
  "stats": {},
  "api": {"tag":"api","services":["StatsService"]}
  ${dns_extra:+,${dns_extra}}
  ${fake_line}
}
JSON
  echo "$tmp|$pid"
}

validate_xray_config() { cfg="$1"; b=$(xray_bin); [ -n "$b" ] || return 1; "$b" run -test -config "$cfg" >/dev/null 2>&1; }

apply_xray_config() {
  meta=$(generate_xray_config_tmp) || return 1
  tmp=$(printf "%s" "$meta" | cut -d'|' -f1)
  if validate_xray_config "$tmp"; then
    [ -f "$XRAY_CFG" ] && cp "$XRAY_CFG" "$XRAY_CFG_BAK" 2>/dev/null || true
    mv "$tmp" "$XRAY_CFG"; return 0
  fi
  rm -f "$tmp"; insert_event "config_rollback" "Конфиг не прошёл xray run -test"; return 1
}

xray_start() { xray_is_running && return 0; b=$(xray_bin); [ -n "$b" ] || return 1; apply_xray_config || return 1; rotate_xray_log; "$b" run -config "$XRAY_CFG" >> "$XRAY_LOG" 2>&1 & pid=$!; echo "$pid" > "$XRAY_PID_FILE"; sleep 1; if kill -0 "$pid" 2>/dev/null; then insert_event "xray_restart" "xray запущен"; return 0; fi; [ -f "$XRAY_CFG_BAK" ] && cp "$XRAY_CFG_BAK" "$XRAY_CFG"; insert_event "config_rollback" "xray не стартовал, выполнен откат"; return 1; }
xray_stop() { xray_is_running || return 0; pid=$(cat "$XRAY_PID_FILE"); kill -TERM "$pid" 2>/dev/null || true; sleep 3; kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true; rm -f "$XRAY_PID_FILE"; insert_event "xray_restart" "xray остановлен"; }
xray_restart() { xray_stop; xray_start; }
xray_status() { xray_is_running && echo "running" || echo "stopped"; }
xray_log_tail() { lines="${1:-40}"; [ -f "$XRAY_LOG" ] && tail -n "$lines" "$XRAY_LOG" || echo "Лог xray пуст"; }

check_doh_server() {
  url="$1"
  [ -n "$url" ] || return 1
  curl -sS --connect-timeout 3 --max-time 5 "$url" -o /dev/null 2>/dev/null
}
