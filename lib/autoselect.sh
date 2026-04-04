#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"

sql_escape_a() { printf "%s" "$1" | sed "s/'/''/g"; }

get_as_setting() { sqlite3 "$DB_PATH" "SELECT COALESCE(value,'$2') FROM settings WHERE key='$(sql_escape_a "$1")' LIMIT 1;"; }

select_best_profile() {
  proto=$(get_as_setting autoselect_protocol "")
  tag=$(get_as_setting autoselect_tag "")
  where="enabled=1 AND exclude_from_autoselect=0"
  [ -n "$proto" ] && where="$where AND protocol='$(sql_escape_a "$proto")'"
  [ -n "$tag" ] && where="$where AND tags LIKE '%$(sql_escape_a "$tag")%'"
  sqlite3 "$DB_PATH" "SELECT id FROM profiles WHERE $where ORDER BY last_latency IS NULL, last_latency ASC LIMIT 1;"
}

run_autoselect() {
  enabled=$(get_as_setting autoselect_enabled 0)
  [ "$enabled" = "1" ] || { echo "disabled"; return 1; }
  best=$(select_best_profile)
  [ -n "$best" ] || { echo "no-profile"; return 1; }
  set_active_profile "$best"
  apply_xray_config >/dev/null 2>&1 || true
  sqlite3 "$DB_PATH" "UPDATE profiles SET use_count=use_count+1 WHERE id=$best;"
  sqlite3 "$DB_PATH" "INSERT INTO events(type,message,profile_id,created_at) VALUES('profile_switch','Автовыбор профиля',${best},CURRENT_TIMESTAMP);"
  sqlite3 "$DB_PATH" "DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY created_at DESC LIMIT 200);"
  echo "$best"
}

events_query_csv() {
  type="$1"; from="$2"; to="$3"
  where="1=1"
  [ -n "$type" ] && where="$where AND type='$(sql_escape_a "$type")'"
  [ -n "$from" ] && where="$where AND created_at >= '$(sql_escape_a "$from") 00:00:00'"
  [ -n "$to" ] && where="$where AND created_at <= '$(sql_escape_a "$to") 23:59:59'"
  sqlite3 -header -csv "$DB_PATH" "SELECT id,type,message,COALESCE(profile_id,''),created_at FROM events WHERE $where ORDER BY created_at DESC LIMIT 200;"
}

clear_events() {
  days="$1"
  if [ -z "$days" ]; then
    sqlite3 "$DB_PATH" "DELETE FROM events;"
  else
    sqlite3 "$DB_PATH" "DELETE FROM events WHERE created_at < datetime('now','-$(printf "%s" "$days" | tr -cd '0-9') day');"
  fi
}

export_events_json() {
  rows=$(events_query_csv "$1" "$2" "$3" | tail -n +2)
  printf '['
  first=1
  echo "$rows" | while IFS=',' read -r id t m pid c; do
    [ -n "$id" ] || continue
    [ $first -eq 1 ] || printf ','
    first=0
    mm=$(printf "%s" "$m" | sed 's/^"//;s/"$//;s/"/\\"/g')
    printf '{"id":%s,"type":"%s","message":"%s","profile_id":"%s","created_at":"%s"}' "$id" "$t" "$mm" "$pid" "$c"
  done
  printf ']'
}
