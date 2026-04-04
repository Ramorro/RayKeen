#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"

sql_escape_r() { printf "%s" "$1" | sed "s/'/''/g"; }

validate_domain_rule() {
  v="$1"
  printf "%s" "$v" | grep -Eq '^([*]\.)?([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$'
}

validate_ip_rule() {
  v="$1"
  printf "%s" "$v" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$'
}

validate_cidr_rule() {
  v="$1"
  printf "%s" "$v" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9a-fA-F:]+/[0-9]{1,3}$'
}

validate_rule_value() {
  t="$1"; v="$2"
  case "$t" in
    domain) validate_domain_rule "$v" ;;
    ip) validate_ip_rule "$v" ;;
    cidr) validate_cidr_rule "$v" ;;
    *) return 1 ;;
  esac
}

list_columns_csv() {
  sqlite3 -header -csv "$DB_PATH" "SELECT id,name,outbound,profile_id,\"order\",enabled,created_at FROM routing_columns ORDER BY \"order\" ASC, id ASC;"
}

list_rules_csv() {
  cid=$(printf "%s" "$1" | tr -cd '0-9')
  sqlite3 -header -csv "$DB_PATH" "SELECT id,column_id,type,value,comment,\"order\",enabled FROM routing_rules WHERE column_id=$cid ORDER BY \"order\" ASC, id ASC;"
}

create_column() {
  name="$1"; outbound="$2"; profile_id="$3"
  maxo=$(sqlite3 "$DB_PATH" "SELECT COALESCE(MAX(\"order\"),0)+1 FROM routing_columns;")
  [ -n "$profile_id" ] || profile_id="NULL"
  sqlite3 "$DB_PATH" "INSERT INTO routing_columns(name,outbound,profile_id,\"order\",enabled,created_at) VALUES('$(sql_escape_r "$name")','$(sql_escape_r "$outbound")',$profile_id,$maxo,1,CURRENT_TIMESTAMP);"
}

add_rule() {
  cid=$(printf "%s" "$1" | tr -cd '0-9')
  typ="$2"; val="$3"; comment="$4"
  validate_rule_value "$typ" "$val" || { echo "Невалидное значение для типа $typ"; return 1; }
  d=$(sqlite3 "$DB_PATH" "SELECT rc.name FROM routing_rules rr JOIN routing_columns rc ON rc.id=rr.column_id WHERE rr.value='$(sql_escape_r "$val")' LIMIT 1;")
  [ -z "$d" ] || { echo "Дубликат правила уже есть в колонке: $d"; return 2; }
  maxo=$(sqlite3 "$DB_PATH" "SELECT COALESCE(MAX(\"order\"),0)+1 FROM routing_rules WHERE column_id=$cid;")
  sqlite3 "$DB_PATH" "INSERT INTO routing_rules(column_id,type,value,comment,\"order\",enabled) VALUES($cid,'$(sql_escape_r "$typ")','$(sql_escape_r "$val")','$(sql_escape_r "$comment")',$maxo,1);"
}

toggle_column() { cid=$(printf "%s" "$1" | tr -cd '0-9'); sqlite3 "$DB_PATH" "UPDATE routing_columns SET enabled=CASE WHEN enabled=1 THEN 0 ELSE 1 END WHERE id=$cid;"; }
toggle_rule() { rid=$(printf "%s" "$1" | tr -cd '0-9'); sqlite3 "$DB_PATH" "UPDATE routing_rules SET enabled=CASE WHEN enabled=1 THEN 0 ELSE 1 END WHERE id=$rid;"; }

move_column() {
  cid=$(printf "%s" "$1" | tr -cd '0-9'); dir="$2"
  cur=$(sqlite3 "$DB_PATH" "SELECT \"order\" FROM routing_columns WHERE id=$cid;")
  [ -n "$cur" ] || return 1
  if [ "$dir" = "up" ]; then
    nid=$(sqlite3 "$DB_PATH" "SELECT id FROM routing_columns WHERE \"order\" < $cur ORDER BY \"order\" DESC LIMIT 1;")
  else
    nid=$(sqlite3 "$DB_PATH" "SELECT id FROM routing_columns WHERE \"order\" > $cur ORDER BY \"order\" ASC LIMIT 1;")
  fi
  [ -n "$nid" ] || return 0
  norder=$(sqlite3 "$DB_PATH" "SELECT \"order\" FROM routing_columns WHERE id=$nid;")
  sqlite3 "$DB_PATH" "UPDATE routing_columns SET \"order\"=$norder WHERE id=$cid; UPDATE routing_columns SET \"order\"=$cur WHERE id=$nid;"
}

export_routing_json() {
  printf '{"columns":['
  first=1
  ids=$(sqlite3 "$DB_PATH" "SELECT id FROM routing_columns ORDER BY \"order\" ASC;")
  for cid in $ids; do
    row=$(sqlite3 "$DB_PATH" "SELECT name,outbound,COALESCE(profile_id,''),\"order\",enabled FROM routing_columns WHERE id=$cid;")
    name=$(printf "%s" "$row" | cut -d'|' -f1 | sed 's/"/\\"/g')
    outb=$(printf "%s" "$row" | cut -d'|' -f2)
    pid=$(printf "%s" "$row" | cut -d'|' -f3)
    ord=$(printf "%s" "$row" | cut -d'|' -f4)
    en=$(printf "%s" "$row" | cut -d'|' -f5)
    [ $first -eq 1 ] || printf ','
    first=0
    printf '{"id":%s,"name":"%s","outbound":"%s","profile_id":"%s","order":%s,"enabled":%s,"rules":[' "$cid" "$name" "$outb" "$pid" "$ord" "$en"
    rf=1
    sqlite3 -csv "$DB_PATH" "SELECT type,value,COALESCE(comment,''),\"order\",enabled FROM routing_rules WHERE column_id=$cid ORDER BY \"order\" ASC;" | while IFS=',' read -r t v c ro re; do
      [ $rf -eq 1 ] || printf ','
      rf=0
      printf '{"type":"%s","value":"%s","comment":"%s","order":%s,"enabled":%s}' "$t" "$v" "$c" "$ro" "$re"
    done
    printf ']}'
  done
  printf ']}'
}

apply_preset_ru_direct() {
  create_column "RU-direct" "direct" ""
  cid=$(sqlite3 "$DB_PATH" "SELECT id FROM routing_columns WHERE name='RU-direct' ORDER BY id DESC LIMIT 1;")
  for d in '*.ru' 'yandex.ru' 'vk.com'; do add_rule "$cid" domain "$d" "preset" >/dev/null 2>&1 || true; done
}

apply_preset_ads_block() {
  create_column "ADS-block" "block" ""
  cid=$(sqlite3 "$DB_PATH" "SELECT id FROM routing_columns WHERE name='ADS-block' ORDER BY id DESC LIMIT 1;")
  for d in 'doubleclick.net' 'googlesyndication.com' 'adservice.google.com'; do add_rule "$cid" domain "$d" "preset" >/dev/null 2>&1 || true; done
}
