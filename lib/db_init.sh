#!/bin/sh
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DB_PATH="/opt/etc/raykeen/data/raykeen.db"
MIGRATIONS_DIR="$BASE_DIR/migrations"

apply_migrations() {
  mkdir -p /opt/etc/raykeen/data
  [ -f "$DB_PATH" ] || sqlite3 "$DB_PATH" "VACUUM;"
  chmod 600 "$DB_PATH" 2>/dev/null || true

  sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);"
  current=$(sqlite3 "$DB_PATH" "SELECT COALESCE(MAX(version),0) FROM schema_version;")

  for file in "$MIGRATIONS_DIR"/*.sql; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    ver=${name%%.sql}
    ver=${ver#0}
    [ -z "$ver" ] && ver=0
    if [ "$ver" -gt "$current" ]; then
      sqlite3 "$DB_PATH" < "$file" || return 1
      sqlite3 "$DB_PATH" "INSERT INTO schema_version(version) VALUES($ver);"
      current=$ver
    fi
  done
}

integrity_check_and_restore() {
  result=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>/dev/null)
  if [ "$result" != "ok" ]; then
    if [ -f "${DB_PATH}.bak" ]; then
      cp "${DB_PATH}.bak" "$DB_PATH"
      chmod 600 "$DB_PATH" 2>/dev/null || true
      return 0
    fi
    return 1
  fi
  cp "$DB_PATH" "${DB_PATH}.bak" 2>/dev/null || true
  chmod 600 "${DB_PATH}.bak" 2>/dev/null || true
}
