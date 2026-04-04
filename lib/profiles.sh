#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

invalidate_profiles_cache() {
  rm -f /tmp/raykeen/cache/profiles.cache 2>/dev/null || true
}

validate_vless_uri() {
  printf "%s" "$1" | grep -Eq '^vless://[^@]+@[^:/?#]+:[0-9]+'
}

validate_trojan_uri() {
  printf "%s" "$1" | grep -Eq '^trojan://[^@]+@[^:/?#]+:[0-9]+'
}

validate_ss_uri() {
  printf "%s" "$1" | grep -Eq '^ss://.+'
}

validate_vmess_uri() {
  raw="${1#vmess://}"
  printf "%s" "$raw" | base64 -d >/dev/null 2>&1
}

parse_vless_uri() {
  uri="$1"
  part=${uri#vless://}
  user=${part%%@*}
  hostp=${part#*@}
  host=${hostp%%:*}
  rest=${hostp#*:}
  port=${rest%%[/?#]*}
  name=$(printf "%s" "$uri" | sed -n 's/.*#//p')
  [ -n "$name" ] || name="$host"
  echo "vless|$name|$host|$port|$user"
}

parse_trojan_uri() {
  uri="$1"
  part=${uri#trojan://}
  pass=${part%%@*}
  hostp=${part#*@}
  host=${hostp%%:*}
  rest=${hostp#*:}
  port=${rest%%[/?#]*}
  name=$(printf "%s" "$uri" | sed -n 's/.*#//p')
  [ -n "$name" ] || name="$host"
  echo "trojan|$name|$host|$port|$pass"
}

parse_ss_uri() {
  uri="$1"
  payload=${uri#ss://}
  main=${payload%%#*}
  name=${payload#*#}
  [ "$name" = "$payload" ] && name="shadowsocks"
  creds_host=$(printf "%s" "$main" | base64 -d 2>/dev/null || printf "%s" "$main")
  host=${creds_host##*@}
  addr=${host%%:*}
  port=${host##*:}
  pass=${creds_host%%@*}
  echo "ss|$name|$addr|$port|$pass"
}

parse_vmess_uri() {
  raw=${1#vmess://}
  json=$(printf "%s" "$raw" | base64 -d 2>/dev/null || true)
  [ -n "$json" ] || return 1
  name=$(printf "%s" "$json" | sed -n 's/.*"ps"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  addr=$(printf "%s" "$json" | sed -n 's/.*"add"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  port=$(printf "%s" "$json" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\?\([0-9]*\)"\?.*/\1/p')
  uuid=$(printf "%s" "$json" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$name" ] || name="$addr"
  echo "vmess|$name|$addr|$port|$uuid"
}

parse_profile_uri() {
  uri="$1"
  case "$uri" in
    vless://*) validate_vless_uri "$uri" || return 1; parse_vless_uri "$uri" ;;
    vmess://*) validate_vmess_uri "$uri" || return 1; parse_vmess_uri "$uri" ;;
    ss://*) validate_ss_uri "$uri" || return 1; parse_ss_uri "$uri" ;;
    trojan://*) validate_trojan_uri "$uri" || return 1; parse_trojan_uri "$uri" ;;
    *) return 1 ;;
  esac
}

insert_profile_from_uri() {
  uri="$1"
  parsed=$(parse_profile_uri "$uri") || { echo "Невалидный URI"; return 1; }
  proto=$(printf "%s" "$parsed" | cut -d'|' -f1)
  name=$(printf "%s" "$parsed" | cut -d'|' -f2)
  addr=$(printf "%s" "$parsed" | cut -d'|' -f3)
  port=$(printf "%s" "$parsed" | cut -d'|' -f4)
  secret=$(printf "%s" "$parsed" | cut -d'|' -f5)

  e_uri=$(sql_escape "$uri")
  dup=$(sqlite3 "$DB_PATH" "SELECT COALESCE(name,''), COALESCE(created_at,'') FROM profiles WHERE raw_uri='$e_uri' LIMIT 1;")
  if [ -n "$dup" ]; then
    dname=$(printf "%s" "$dup" | cut -d'|' -f1)
    ddt=$(printf "%s" "$dup" | cut -d'|' -f2)
    echo "Дубликат: ${dname:-без имени}, добавлен $ddt"
    return 2
  fi

  sqlite3 "$DB_PATH" "INSERT INTO profiles(protocol,name,address,port,uuid_password,encryption,network,tls,active,enabled,raw_uri,created_at) VALUES('$(sql_escape "$proto")','$(sql_escape "$name")','$(sql_escape "$addr")',$(printf "%s" "$port" | tr -cd '0-9'),'$(sql_escape "$secret")','auto','tcp',0,0,1,'$e_uri',CURRENT_TIMESTAMP);"
  invalidate_profiles_cache
  echo "OK"
}

list_profiles_sql() {
  protocol="$1"; enabled="$2"; q="$3"; sort="$4"
  where="1=1"
  [ -n "$protocol" ] && where="$where AND protocol='$(sql_escape "$protocol")'"
  [ -n "$enabled" ] && where="$where AND enabled=$(printf "%s" "$enabled" | tr -cd '0-9')"
  if [ -n "$q" ]; then
    eq=$(sql_escape "$q")
    where="$where AND (name LIKE '%$eq%' OR address LIKE '%$eq%')"
  fi
  case "$sort" in
    protocol) order="protocol COLLATE NOCASE ASC" ;;
    latency) order="last_latency IS NULL, last_latency ASC" ;;
    date) order="created_at DESC" ;;
    *) order="name COLLATE NOCASE ASC" ;;
  esac
  echo "SELECT id,protocol,name,address,port,enabled,active,last_latency,last_tested,tags,notes,exclude_from_autoselect,created_at FROM profiles WHERE $where ORDER BY $order;"
}

profiles_list_csv() {
  protocol="$1"; enabled="$2"; q="$3"; sort="$4"
  cache_key="/tmp/raykeen/cache/profiles.cache"
  if [ -z "$protocol$enabled$q$sort" ] && [ -f "$cache_key" ]; then
    cat "$cache_key"
    return 0
  fi
  sql=$(list_profiles_sql "$protocol" "$enabled" "$q" "$sort")
  out=$(sqlite3 -header -csv "$DB_PATH" "$sql")
  if [ -z "$protocol$enabled$q$sort" ]; then
    mkdir -p /tmp/raykeen/cache
    printf "%s" "$out" > "$cache_key"
  fi
  printf "%s" "$out"
}

toggle_profile_enabled() {
  id="$1"
  sqlite3 "$DB_PATH" "UPDATE profiles SET enabled=CASE WHEN enabled=1 THEN 0 ELSE 1 END WHERE id=$(printf "%s" "$id" | tr -cd '0-9');"
  invalidate_profiles_cache
}

delete_profiles_by_ids() {
  ids="$1"
  clean=$(printf "%s" "$ids" | tr -cd '0-9,')
  [ -n "$clean" ] || return 0
  sqlite3 "$DB_PATH" "DELETE FROM profiles WHERE id IN ($clean);"
  invalidate_profiles_cache
}

copy_profile() {
  id="$1"
  sid=$(printf "%s" "$id" | tr -cd '0-9')
  sqlite3 "$DB_PATH" "INSERT INTO profiles(protocol,name,address,port,uuid_password,encryption,network,tls,subscription_id,active,enabled,last_tested,last_latency,tags,notes,use_count,exclude_from_autoselect,created_at,raw_uri)
  SELECT protocol,name || ' (копия)',address,port,uuid_password,encryption,network,tls,subscription_id,0,enabled,last_tested,last_latency,tags,notes,use_count,exclude_from_autoselect,CURRENT_TIMESTAMP,raw_uri FROM profiles WHERE id=$sid;"
  invalidate_profiles_cache
}

export_profiles_raw_uri() {
  ids="$1"
  clean=$(printf "%s" "$ids" | tr -cd '0-9,')
  [ -z "$clean" ] && clean="SELECT id FROM profiles"
  if [ "$clean" = "SELECT id FROM profiles" ]; then
    sqlite3 "$DB_PATH" "SELECT raw_uri FROM profiles WHERE raw_uri IS NOT NULL AND raw_uri<>'';"
  else
    sqlite3 "$DB_PATH" "SELECT raw_uri FROM profiles WHERE id IN ($clean) AND raw_uri IS NOT NULL AND raw_uri<>'';"
  fi
}
