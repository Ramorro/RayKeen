#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"

sql_escape_s() { printf "%s" "$1" | sed "s/'/''/g"; }

stats_api_available() {
  # lightweight probe for xray API port (best-effort)
  curl -sS --connect-timeout 1 --max-time 2 http://127.0.0.1:10085/ >/dev/null 2>&1
}

update_stats_availability() {
  v=0
  stats_api_available && v=1
  sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('stats_api_available','$v') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
}

is_stats_available_setting() {
  sqlite3 "$DB_PATH" "SELECT COALESCE(value,'0') FROM settings WHERE key='stats_api_available' LIMIT 1;"
}

collect_traffic_snapshot() {
  # fallback collector: use proc net counters as aggregate when API unavailable
  avail=$(is_stats_available_setting)
  [ "$avail" = "1" ] || return 1
  active=$(sqlite3 "$DB_PATH" "SELECT id FROM profiles WHERE active=1 LIMIT 1;")
  [ -n "$active" ] || return 1
  rx=$(awk -F'[: ]+' 'NR>2 && $1!="lo" {sum+=$2} END{print sum+0}' /proc/net/dev)
  tx=$(awk -F'[: ]+' 'NR>2 && $1!="lo" {sum+=$10} END{print sum+0}' /proc/net/dev)
  lat=$(sqlite3 "$DB_PATH" "SELECT COALESCE(last_latency,0) FROM profiles WHERE id=$active LIMIT 1;")
  sqlite3 "$DB_PATH" "INSERT INTO traffic_stats(profile_id,bytes_in,bytes_out,latency,snapshot_at,created_at) VALUES($active,$rx,$tx,$lat,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP);"
}

rotate_traffic_stats() {
  sqlite3 "$DB_PATH" "DELETE FROM traffic_stats WHERE created_at < datetime('now','-7 day');"
}

traffic_sum_24h() {
  sqlite3 "$DB_PATH" "SELECT COALESCE(MAX(bytes_in)-MIN(bytes_in),0), COALESCE(MAX(bytes_out)-MIN(bytes_out),0) FROM traffic_stats WHERE created_at >= datetime('now','-1 day');"
}

traffic_sum_session() {
  sqlite3 "$DB_PATH" "SELECT COALESCE(MAX(bytes_in)-MIN(bytes_in),0), COALESCE(MAX(bytes_out)-MIN(bytes_out),0) FROM traffic_stats WHERE created_at >= datetime('now','-6 hour');"
}

reset_traffic_counters() {
  sqlite3 "$DB_PATH" "DELETE FROM traffic_stats;"
}
