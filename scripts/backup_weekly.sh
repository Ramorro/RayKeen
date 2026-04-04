#!/bin/sh
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$BASE_DIR/lib/system.sh"
. "$BASE_DIR/lib/logger.sh"
. "$BASE_DIR/lib/xray.sh"
. "$BASE_DIR/lib/backup.sh"

if weekly_backup_rotate >/dev/null 2>&1; then
  log_msg INFO "Weekly backup created"
else
  log_msg WARN "Weekly backup failed"
fi
