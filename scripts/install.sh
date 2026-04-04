#!/bin/sh
set -eu
TARGET_ROOT="/opt/etc/raykeen"
mkdir -p "$TARGET_ROOT"/data "$TARGET_ROOT"/logs "$TARGET_ROOT"/backups /tmp/raykeen/cache /tmp/raykeen/sessions /tmp/raykeen/qr
[ -f "$TARGET_ROOT/data/raykeen.db" ] && chmod 600 "$TARGET_ROOT/data/raykeen.db" || true

for dep in curl sqlite3 qrencode xray-core; do
  if ! opkg list-installed | grep -q "^$dep "; then
    echo "Установите пакет: $dep"
  fi
done

echo "Проверьте конфиг lighttpd: алиас /raykeen/ на cgi-bin/raykeen.cgi, порт 3333"
echo "Убедитесь, что порты 3000,2121,2222,90 и занятый 1080 не конфликтуют"
