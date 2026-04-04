#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"
TEST_DIR="/tmp/raykeen/tests"
QUEUE_LOCK="$TEST_DIR/queue.lock"
CURRENT_PID_FILE="$TEST_DIR/current.pid"
PROGRESS_FILE="$TEST_DIR/progress"

sql_escape_t() { printf "%s" "$1" | sed "s/'/''/g"; }

get_socks_port() {
  sqlite3 "$DB_PATH" "SELECT COALESCE(value,'1080') FROM settings WHERE key='socks5_port' LIMIT 1;"
}

get_test_method() {
  sqlite3 "$DB_PATH" "SELECT COALESCE(value,'http204') FROM settings WHERE key='test_method' LIMIT 1;"
}

set_test_method() {
  m="$1"
  sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('test_method','$(sql_escape_t "$m")') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
}

is_test_running() {
  [ -f "$CURRENT_PID_FILE" ] || return 1
  pid=$(cat "$CURRENT_PID_FILE" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

cancel_tests() {
  if is_test_running; then
    pid=$(cat "$CURRENT_PID_FILE")
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$CURRENT_PID_FILE" "$QUEUE_LOCK"
}

write_progress() {
  done="$1"; total="$2"
  mkdir -p "$TEST_DIR"
  echo "$done|$total" > "$PROGRESS_FILE"
}

read_progress() {
  [ -f "$PROGRESS_FILE" ] && cat "$PROGRESS_FILE" || echo "0|0"
}

save_test_result() {
  pid="$1"; latency="$2"; msg="$3"
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  sqlite3 "$DB_PATH" "UPDATE profiles SET last_tested='$now', last_latency=$latency WHERE id=$(printf "%s" "$pid" | tr -cd '0-9');"
  sqlite3 "$DB_PATH" "INSERT INTO events(type,message,profile_id,created_at) VALUES('test_result','$(sql_escape_t "$msg")',$(printf "%s" "$pid" | tr -cd '0-9'),CURRENT_TIMESTAMP);"
  sqlite3 "$DB_PATH" "DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY created_at DESC LIMIT 200);"
  invalidate_profiles_cache
}

_test_http204() {
  timeout="$1"; port="$2"
  out=$(curl -sS -o /dev/null -w '%{time_total}' --connect-timeout "$timeout" --max-time "$timeout" --socks5-hostname "127.0.0.1:$port" http://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)
  [ -n "$out" ] || return 1
  ms=$(awk -v t="$out" 'BEGIN{printf "%d", t*1000}')
  echo "$ms"
}

_test_tcp() {
  timeout="$1"; port="$2"
  out=$(curl -sS -o /dev/null -w '%{time_connect}' --connect-timeout "$timeout" --max-time "$timeout" --socks5-hostname "127.0.0.1:$port" http://example.com 2>/dev/null || true)
  [ -n "$out" ] || return 1
  awk -v t="$out" 'BEGIN{printf "%d", t*1000}'
}

_test_icmp_sim() {
  timeout="$1"; port="$2"
  # через socks5 реальный ICMP недоступен; эмуляция через HTTPS RTT
  out=$(curl -sS -o /dev/null -w '%{time_total}' --connect-timeout "$timeout" --max-time "$timeout" --socks5-hostname "127.0.0.1:$port" https://1.1.1.1 2>/dev/null || true)
  [ -n "$out" ] || return 1
  awk -v t="$out" 'BEGIN{printf "%d", t*1000}'
}

test_profile_once() {
  profile_id="$1"; method="$2"; timeout="${3:-5}"
  en=$(sqlite3 "$DB_PATH" "SELECT COALESCE(enabled,0) FROM profiles WHERE id=$(printf "%s" "$profile_id" | tr -cd '0-9') LIMIT 1;")
  [ "$en" = "1" ] || { save_test_result "$profile_id" 9999 "Профиль выключен"; return 2; }
  xray_is_running || { save_test_result "$profile_id" 9999 "xray не запущен"; return 3; }
  port=$(get_socks_port)
  case "$method" in
    tcp) lat=$(_test_tcp "$timeout" "$port") || { save_test_result "$profile_id" 9999 "TCP timeout"; return 1; } ;;
    icmp) lat=$(_test_icmp_sim "$timeout" "$port") || { save_test_result "$profile_id" 9999 "ICMP timeout"; return 1; } ;;
    *) lat=$(_test_http204 "$timeout" "$port") || { save_test_result "$profile_id" 9999 "HTTP204 timeout"; return 1; } ;;
  esac
  save_test_result "$profile_id" "${lat:-9999}" "OK $method ${lat}ms"
}

run_tests_sequential_bg() {
  ids_csv="$1"; method="$2"; timeout="${3:-5}"
  mkdir -p "$TEST_DIR"
  [ -f "$QUEUE_LOCK" ] && return 1
  : > "$QUEUE_LOCK"

  IFS=','; set -- $ids_csv; IFS=' '
  total=$#
  write_progress 0 "$total"

  (
    echo $$ > "$CURRENT_PID_FILE"
    i=0
    for id in "$@"; do
      i=$((i+1))
      test_profile_once "$id" "$method" "$timeout" || true
      write_progress "$i" "$total"
    done
    rm -f "$CURRENT_PID_FILE" "$QUEUE_LOCK"
  ) &
}
