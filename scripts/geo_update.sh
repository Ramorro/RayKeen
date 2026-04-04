#!/bin/sh
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$BASE_DIR/lib/system.sh"
. "$BASE_DIR/lib/logger.sh"
. "$BASE_DIR/lib/xray.sh"
. "$BASE_DIR/lib/geo.sh"

if geo_should_auto_update; then
  if geo_update_from_urls >/dev/null 2>&1; then
    log_msg INFO "Geo auto-update успешно"
  else
    log_msg WARN "Geo auto-update завершился с ошибкой"
  fi
fi
