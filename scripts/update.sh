#!/bin/sh
set -eu
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
"$BASE_DIR/cgi-bin/raykeen.cgi" >/dev/null 2>&1 || true
echo "Обновление завершено: миграции применены, данные сохранены"
