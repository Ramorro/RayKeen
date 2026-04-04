#!/bin/sh
set -eu

BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TARGET_ROOT="/opt/etc/raykeen"
APP_DIR="$TARGET_ROOT/app"
LIGHTTPD_CONF="/opt/etc/lighttpd/lighttpd.conf"
LIGHTTPD_RK_CONF="/opt/etc/lighttpd/conf.d/90-raykeen.conf"
WEB_PORT=3333

mkdir -p "$TARGET_ROOT"/data "$TARGET_ROOT"/logs "$TARGET_ROOT"/backups /tmp/raykeen/cache /tmp/raykeen/sessions /tmp/raykeen/qr
[ -f "$TARGET_ROOT/data/raykeen.db" ] && chmod 600 "$TARGET_ROOT/data/raykeen.db" || true

# deps check
for dep in curl sqlite3 qrencode xray-core; do
  if ! opkg list-installed | grep -q "^$dep "; then
    echo "Установите пакет: $dep"
  fi
done

# reserve ports check
for p in 3000 2121 2222 90; do
  if netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ":$p$"; then
    echo "Порт $p уже занят (зарезервирован) — установка продолжается без изменений этого порта"
  fi
done
if netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ":${WEB_PORT}$"; then
  echo "ОШИБКА: порт ${WEB_PORT} уже занят, выберите другой веб-порт перед установкой"
  exit 1
fi

# install app files
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -r "$BASE_DIR"/cgi-bin "$BASE_DIR"/lib "$BASE_DIR"/migrations "$BASE_DIR"/scripts "$BASE_DIR"/version "$APP_DIR"/
chmod +x "$APP_DIR"/cgi-bin/raykeen.cgi "$APP_DIR"/scripts/*.sh "$APP_DIR"/lib/*.sh

# configure lighttpd endpoint /raykeen/ on :3333
mkdir -p /opt/etc/lighttpd/conf.d
cat > "$LIGHTTPD_RK_CONF" <<CONF
\$SERVER["socket"] == ":${WEB_PORT}" {
  server.document-root = "${APP_DIR}"
  cgi.assign = ( ".cgi" => "/bin/sh" )
  alias.url += ( "/raykeen/" => "${APP_DIR}/cgi-bin/raykeen.cgi" )
}
CONF

if [ -f "$LIGHTTPD_CONF" ] && ! grep -q "90-raykeen.conf" "$LIGHTTPD_CONF"; then
  printf '\ninclude "conf.d/90-raykeen.conf"\n' >> "$LIGHTTPD_CONF"
fi

echo "RayKeen установлен в $APP_DIR"
echo "Веб-морда: http://<router-ip>:${WEB_PORT}/raykeen/"
echo "Перезапустите lighttpd для применения конфига."
