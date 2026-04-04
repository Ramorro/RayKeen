#!/bin/sh
DB_PATH="/opt/etc/raykeen/data/raykeen.db"

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

db_exec() {
  sqlite3 "$DB_PATH" "$1"
}

db_select() {
  sqlite3 -header -csv "$DB_PATH" "$1"
}

db_insert() {
  table="$1"; columns="$2"; values="$3"
  sqlite3 "$DB_PATH" "INSERT INTO ${table} (${columns}) VALUES (${values});"
}

db_update() {
  table="$1"; set_clause="$2"; where_clause="$3"
  sqlite3 "$DB_PATH" "UPDATE ${table} SET ${set_clause} WHERE ${where_clause};"
}

db_delete() {
  table="$1"; where_clause="$2"
  sqlite3 "$DB_PATH" "DELETE FROM ${table} WHERE ${where_clause};"
}
