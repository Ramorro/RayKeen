#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"

sql_escape_sub() { printf "%s" "$1" | sed "s/'/''/g"; }

get_setting_or() {
  key="$1"; def="$2"
  val=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='$(sql_escape_sub "$key")' LIMIT 1;" 2>/dev/null || true)
  [ -n "$val" ] && echo "$val" || echo "$def"
}

normalize_subscription_payload() {
  input_file="$1"
  out_file="$2"
  # if appears as base64 blob, decode it; else copy as-is
  raw=$(tr -d '\r\n ' < "$input_file")
  if printf "%s" "$raw" | grep -Eq '^[A-Za-z0-9+/=]+$' && printf "%s" "$raw" | base64 -d >/dev/null 2>&1; then
    printf "%s" "$raw" | base64 -d > "$out_file" 2>/dev/null || cp "$input_file" "$out_file"
  else
    cp "$input_file" "$out_file"
  fi
}

create_subscription() {
  name="$1"; url="$2"; interval="$3"
  eu=$(sql_escape_sub "$url")
  exists=$(sqlite3 "$DB_PATH" "SELECT id FROM subscriptions WHERE url='$eu' LIMIT 1;")
  [ -z "$exists" ] || { echo "Дубликат подписки по URL"; return 2; }
  sqlite3 "$DB_PATH" "INSERT INTO subscriptions(name,url,update_interval,enabled,created_at) VALUES('$(sql_escape_sub "$name")','$eu','$(sql_escape_sub "$interval")',1,CURRENT_TIMESTAMP);"
  echo "OK"
}

list_subscriptions_csv() {
  sqlite3 -header -csv "$DB_PATH" "SELECT id,name,url,last_updated,profile_count,profiles_added,profiles_updated,profiles_removed,update_interval,enabled,created_at FROM subscriptions ORDER BY created_at DESC;"
}

set_subscription_enabled() {
  id=$(printf "%s" "$1" | tr -cd '0-9')
  sqlite3 "$DB_PATH" "UPDATE subscriptions SET enabled=CASE WHEN enabled=1 THEN 0 ELSE 1 END WHERE id=$id;"
}

subscription_should_update_now() {
  id=$(printf "%s" "$1" | tr -cd '0-9')
  row=$(sqlite3 "$DB_PATH" "SELECT COALESCE(last_updated,''), COALESCE(update_interval,'manual') FROM subscriptions WHERE id=$id LIMIT 1;")
  lu=$(printf "%s" "$row" | cut -d'|' -f1)
  intr=$(printf "%s" "$row" | cut -d'|' -f2)
  [ "$intr" = "manual" ] && return 1
  [ -z "$lu" ] && return 0
  now=$(date +%s)
  then=$(date -d "$lu" +%s 2>/dev/null || echo 0)
  case "$intr" in
    daily) need=$((24*3600));;
    3d) need=$((3*24*3600));;
    weekly) need=$((7*24*3600));;
    *) need=$((24*3600));;
  esac
  [ $((now-then)) -ge "$need" ]
}

fetch_subscription_to_file() {
  url="$1"; tmp_file="$2"
  ua=$(get_setting_or subscription_user_agent "RayKeen/0.1")
  timeout=$(get_setting_or subscription_timeout_sec "20")
  code=$(curl -L -sS --max-time "$timeout" -A "$ua" -o "$tmp_file" -w '%{http_code}' "$url" 2>/dev/null || echo "000")
  [ "$code" = "200" ]
}

update_subscription() {
  sid=$(printf "%s" "$1" | tr -cd '0-9')
  require_min_ram 50 || { echo "Недостаточно RAM"; return 3; }
  row=$(sqlite3 "$DB_PATH" "SELECT COALESCE(url,''), COALESCE(name,''), enabled FROM subscriptions WHERE id=$sid LIMIT 1;")
  url=$(printf "%s" "$row" | cut -d'|' -f1)
  enabled=$(printf "%s" "$row" | cut -d'|' -f3)
  [ -n "$url" ] || { echo "Подписка не найдена"; return 1; }
  [ "$enabled" = "1" ] || { echo "Подписка выключена"; return 4; }

  tmp_raw="/tmp/raykeen/sub_${sid}.raw"
  tmp_norm="/tmp/raykeen/sub_${sid}.txt"
  mkdir -p /tmp/raykeen
  fetch_subscription_to_file "$url" "$tmp_raw" || { echo "HTTP ошибка (не 200)"; return 1; }
  check_file_size "$tmp_raw" $((5*1024*1024)) || { echo "Файл подписки слишком большой"; return 1; }
  normalize_subscription_payload "$tmp_raw" "$tmp_norm"

  old_list=$(sqlite3 "$DB_PATH" "SELECT raw_uri FROM profiles WHERE subscription_id=$sid;")
  old_file="/tmp/raykeen/sub_${sid}_old.txt"
  printf "%s\n" "$old_list" > "$old_file"

  added=0; updated=0; removed=0; invalid=0; dup_cross=0
  new_file="/tmp/raykeen/sub_${sid}_new.txt"
  : > "$new_file"

  while IFS= read -r line; do
    uri=$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$uri" ] || continue
    parse_profile_uri "$uri" >/dev/null 2>&1 || { invalid=$((invalid+1)); continue; }
    # within same subscription duplicates skipped silently
    grep -Fxq "$uri" "$new_file" 2>/dev/null && continue
    echo "$uri" >> "$new_file"
  done < "$tmp_norm"

  sqlite3 "$DB_PATH" "BEGIN TRANSACTION;" || return 1
  while IFS= read -r uri; do
    [ -n "$uri" ] || continue
    e_uri=$(sql_escape_sub "$uri")
    other=$(sqlite3 "$DB_PATH" "SELECT id FROM profiles WHERE raw_uri='$e_uri' AND subscription_id<>$sid LIMIT 1;")
    [ -n "$other" ] && dup_cross=$((dup_cross+1))

    own=$(sqlite3 "$DB_PATH" "SELECT id FROM profiles WHERE raw_uri='$e_uri' AND subscription_id=$sid LIMIT 1;")
    if [ -n "$own" ]; then
      updated=$((updated+1))
    else
      parsed=$(parse_profile_uri "$uri")
      proto=$(printf "%s" "$parsed" | cut -d'|' -f1)
      name=$(printf "%s" "$parsed" | cut -d'|' -f2)
      addr=$(printf "%s" "$parsed" | cut -d'|' -f3)
      port=$(printf "%s" "$parsed" | cut -d'|' -f4 | tr -cd '0-9')
      secret=$(printf "%s" "$parsed" | cut -d'|' -f5)
      sqlite3 "$DB_PATH" "INSERT INTO profiles(protocol,name,address,port,uuid_password,encryption,network,tls,subscription_id,active,enabled,raw_uri,created_at) VALUES('$(sql_escape_sub "$proto")','$(sql_escape_sub "$name")','$(sql_escape_sub "$addr")',$port,'$(sql_escape_sub "$secret")','auto','tcp',0,$sid,0,1,'$e_uri',CURRENT_TIMESTAMP);"
      added=$((added+1))
    fi
  done < "$new_file"

  while IFS= read -r old_uri; do
    [ -n "$old_uri" ] || continue
    grep -Fxq "$old_uri" "$new_file" || {
      e_old=$(sql_escape_sub "$old_uri")
      sqlite3 "$DB_PATH" "DELETE FROM profiles WHERE subscription_id=$sid AND raw_uri='$e_old';"
      removed=$((removed+1))
    }
  done < "$old_file"

  total=$(wc -l < "$new_file" 2>/dev/null || echo 0)
  sqlite3 "$DB_PATH" "UPDATE subscriptions SET last_updated=CURRENT_TIMESTAMP, profile_count=$total, profiles_added=$added, profiles_updated=$updated, profiles_removed=$removed, last_update_stats='invalid=$invalid;dup_cross=$dup_cross' WHERE id=$sid;"
  sqlite3 "$DB_PATH" "COMMIT;"

  invalidate_profiles_cache
  echo "OK added=$added updated=$updated removed=$removed invalid=$invalid dup_cross=$dup_cross"
}

update_all_subscriptions_sequential() {
  ids=$(sqlite3 "$DB_PATH" "SELECT id FROM subscriptions WHERE enabled=1 ORDER BY id ASC;")
  for id in $ids; do
    update_subscription "$id" >/dev/null 2>&1 || true
  done
}
