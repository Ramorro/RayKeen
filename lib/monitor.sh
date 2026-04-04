#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"

cpu_usage_percent() {
  read -r _ u1 n1 s1 i1 iw1 irq1 sirq1 st1 _ < /proc/stat
  t1=$((u1+n1+s1+i1+iw1+irq1+sirq1+st1))
  idle1=$((i1+iw1))
  sleep 1
  read -r _ u2 n2 s2 i2 iw2 irq2 sirq2 st2 _ < /proc/stat
  t2=$((u2+n2+s2+i2+iw2+irq2+sirq2+st2))
  idle2=$((i2+iw2))
  dt=$((t2-t1)); didle=$((idle2-idle1))
  [ "$dt" -gt 0 ] || { echo 0; return; }
  echo $(( (100*(dt-didle))/dt ))
}

ram_free_mb() {
  awk '/MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo
}

wan_rx_tx_bytes() {
  iface=$(awk -F: 'NR>2 {gsub(/ /,"",$1); if($1!="lo"){print $1; exit}}' /proc/net/dev)
  [ -n "$iface" ] || { echo "0|0|na"; return; }
  rx=$(awk -F'[: ]+' -v i="$iface" '$1==i {print $2}' /proc/net/dev)
  tx=$(awk -F'[: ]+' -v i="$iface" '$1==i {print $10}' /proc/net/dev)
  echo "${rx:-0}|${tx:-0}|$iface"
}

cpu_temp_c() {
  for f in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$f" ] || continue
    v=$(cat "$f" 2>/dev/null || true)
    [ -n "$v" ] || continue
    awk -v t="$v" 'BEGIN{ if(t>1000) printf "%.1f", t/1000; else printf "%.1f", t }'
    return
  done
  echo "n/a"
}

router_uptime_sec() {
  awk '{printf "%d", $1}' /proc/uptime
}

xray_uptime_sec() {
  ts=$(sqlite3 "$DB_PATH" "SELECT created_at FROM events WHERE type='xray_restart' ORDER BY id DESC LIMIT 1;")
  [ -n "$ts" ] || { echo 0; return; }
  now=$(date +%s)
  then=$(date -d "$ts" +%s 2>/dev/null || echo "$now")
  echo $((now-then))
}

xray_restarts_last_day() {
  sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM events WHERE type='xray_crash' AND created_at >= datetime('now','-1 day');"
}

render_health_json() {
  xr=$(xray_status)
  db="ok"
  sqlite3 "$DB_PATH" 'SELECT 1;' >/dev/null 2>&1 || db="error"
  ru=$(router_uptime_sec)
  xu=$(xray_uptime_sec)
  ram=$(ram_free_mb)
  ver=$(cat "$BASE_DIR/version" 2>/dev/null || echo "unknown")
  printf '{"xray":"%s","db":"%s","router_uptime_sec":%s,"xray_uptime_sec":%s,"free_ram_mb":%s,"raykeen_version":"%s"}\n' "$xr" "$db" "$ru" "$xu" "$ram" "$ver"
}
