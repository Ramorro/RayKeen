#!/bin/sh
set -eu
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DB_PATH="/opt/etc/raykeen/data/raykeen.db"

. "$BASE_DIR/lib/logger.sh"
. "$BASE_DIR/lib/system.sh"
. "$BASE_DIR/lib/db_init.sh"
. "$BASE_DIR/lib/auth.sh"
. "$BASE_DIR/lib/profiles.sh"
. "$BASE_DIR/lib/subscriptions.sh"
. "$BASE_DIR/lib/xray.sh"
. "$BASE_DIR/lib/tests.sh"
. "$BASE_DIR/lib/monitor.sh"
. "$BASE_DIR/lib/routing.sh"
. "$BASE_DIR/lib/geo.sh"
. "$BASE_DIR/lib/stats.sh"
. "$BASE_DIR/lib/autoselect.sh"
. "$BASE_DIR/lib/backup.sh"

trap 'log_msg INFO "Получен SIGTERM, завершение CGI"; exit 0' TERM

cleanup_tmp 120
check_dependencies || log_msg ERROR "Не найдены обязательные зависимости (curl/sqlite3/qrencode)"
apply_migrations || log_msg ERROR "Ошибка применения миграций"
integrity_check_and_restore || log_msg ERROR "Integrity check БД не пройден"

url_decode() {
  v=$(printf '%s' "$1" | tr '+' ' ')
  printf '%b' "${v//%/\\x}"
}

read_post_data() {
  len=${CONTENT_LENGTH:-0}
  [ "$len" -gt 0 ] || { echo ""; return; }
  dd bs=1 count="$len" 2>/dev/null
}

param_from_kv() {
  key="$1"; data="$2"
  oldIFS=$IFS; IFS='&'
  for pair in $data; do
    IFS=$oldIFS
    k=$(printf '%s' "$pair" | cut -d= -f1)
    val=$(printf '%s' "$pair" | cut -d= -f2-)
    [ "$k" = "$key" ] && { url_decode "$val"; IFS=$oldIFS; return 0; }
    IFS='&'
  done
  IFS=$oldIFS
  echo ""
}

get_param() {
  key="$1"
  query="${QUERY_STRING:-}"
  param_from_kv "$key" "$query"
}

redirect() {
  loc="$1"; cookie="${2:-}"
  printf 'Status: 302 Found\r\n'
  [ -n "$cookie" ] && printf 'Set-Cookie: %s\r\n' "$cookie"
  printf 'Location: %s\r\n\r\n' "$loc"
}

html_header() { printf 'Content-Type: text/html; charset=UTF-8\r\n\r\n'; }

layout_top() {
  title="$1"
  cat <<HTML
<!doctype html><html lang="ru"><head><meta charset="UTF-8"><title>$title</title>
<style>
body{margin:0;font-family:sans-serif;background:#1f2329;color:#e5e7eb}.wrap{display:flex;min-height:100vh}
.sidebar{width:220px;background:#15181d;padding:20px}.main{flex:1;padding:30px}.card{background:#2b313a;padding:16px;border-radius:10px;max-width:1000px;margin-bottom:16px}
input,button,select,textarea{padding:10px;border-radius:8px;border:1px solid #444;background:#1f2329;color:#e5e7eb}
button{background:#2563eb;color:#fff;border:none;cursor:pointer}.btn-red{background:#b91c1c}.btn-gray{background:#4b5563}.row{display:flex;gap:8px;flex-wrap:wrap}
.table{width:100%;border-collapse:collapse}.table td,.table th{border-bottom:1px solid #374151;padding:8px;text-align:left}.mono{font-family:monospace}
.status{font-size:18px}.toast{position:fixed;right:16px;bottom:16px;background:#374151;padding:12px;border-radius:8px;opacity:.95}
a{color:#93c5fd;text-decoration:none}
</style></head><body><div class="wrap"><div class="sidebar"><h3>RayKeen</h3><p><a href="/raykeen/dashboard">Dashboard</a></p><p><a href="/raykeen/profiles">Profiles</a></p><p><a href="/raykeen/subscriptions">Subscriptions</a></p><p><a href="/raykeen/routing">Routing</a></p><p><a href="/raykeen/history">History</a></p><p><a href="/raykeen/backup">Backup</a></p><p><a href="/raykeen/about">About</a></p><p><a href="/raykeen/settings">Settings</a></p><p><a href="/raykeen/logout">Выход</a></p></div><div class="main">
HTML
}

layout_bottom() {
  toast="$1"
  [ -n "$toast" ] && printf '<div class="toast">%s</div>' "$toast"
  cat <<'HTML'
</div></div><script>setTimeout(()=>{document.querySelectorAll('.toast').forEach(t=>t.remove());},4000);</script></body></html>
HTML
}

toast_msg() {
  case "${1:-}" in
    expired) echo "Сессия истекла. Войдите снова." ;;
    bad_login) echo "Неверный пароль." ;;
    pwd_changed) echo "Пароль изменён. Войдите снова." ;;
    need_auth) echo "Требуется авторизация." ;;
    csrf) echo "Ошибка CSRF-токена." ;;
    p_added) echo "Профиль добавлен." ;;
    p_invalid) echo "Профиль невалидный." ;;
    p_deleted) echo "Профили удалены." ;;
    p_toggled) echo "Статус профиля изменён." ;;
    p_copied) echo "Профиль скопирован." ;;
    s_added) echo "Подписка добавлена." ;;
    s_updated) echo "Подписка обновлена." ;;
    s_toggled) echo "Статус подписки изменён." ;;
    s_error) echo "Ошибка обновления подписки." ;;
    x_ok) echo "Команда xray выполнена." ;;
    x_err) echo "Ошибка управления xray." ;;
    p_active) echo "Активный профиль обновлён." ;;
    t_started) echo "Тестирование запущено." ;;
    t_cancel) echo "Тестирование остановлено." ;;
    t_err) echo "Ошибка запуска теста." ;;
    low_ram) echo "Внимание: свободной RAM меньше 50 МБ." ;;
    doh_saved) echo "DoH настройки сохранены." ;;
    doh_checked_ok) echo "DoH URL доступен." ;;
    doh_checked_err) echo "DoH URL недоступен." ;;
    r_saved) echo "Маршрутизация обновлена." ;;
    r_err) echo "Ошибка правила маршрутизации." ;;
    g_ok) echo "Geo-файлы обновлены." ;;
    g_err) echo "Ошибка обновления geo-файлов." ;;
    g_rb) echo "Geo rollback выполнен." ;;
    stats_reset) echo "Счётчики трафика сброшены." ;;
    as_done) echo "Автовыбор выполнен." ;;
    as_saved) echo "Настройки автовыбора сохранены." ;;
    h_cleared) echo "История очищена." ;;
    b_done) echo "Бэкап/импорт выполнен." ;;
    b_err) echo "Ошибка бэкапа/импорта." ;;
    dup) echo "$(get_param msg)" ;;
    *) echo "" ;;
  esac
}

get_password_hash() {
  sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='password_hash' LIMIT 1;" 2>/dev/null || true
}

set_password_hash() {
  hash="$1"
  sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('password_hash','$hash') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
}

require_auth() {
  token=$(get_cookie_value raykeen_session || true)
  [ -n "$token" ] || { redirect "/raykeen/?toast=need_auth"; return 1; }
  if ! is_session_valid "$token"; then
    redirect "/raykeen/?toast=expired" "raykeen_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
    return 1
  fi
  refresh_session "$token" || true
  AUTH_TOKEN="$token"; export AUTH_TOKEN
  return 0
}

require_post_csrf() {
  post_data="$1"
  csrf=$(param_from_kv csrf_token "$post_data")
  require_csrf "$AUTH_TOKEN" "$csrf"
}

render_login_page() {
  mode="$1"; msg=$(toast_msg "$(get_param toast)")
  html_header
  cat <<HTML
<!doctype html><html lang="ru"><head><meta charset="UTF-8"><title>RayKeen — вход</title>
<style>body{margin:0;font-family:sans-serif;background:#1f2329;color:#e5e7eb}.wrap{display:flex;min-height:100vh}.sidebar{width:220px;background:#15181d;padding:20px}.main{flex:1;padding:40px}.card{max-width:460px;background:#2b313a;padding:24px;border-radius:10px}input,button{width:100%;padding:10px;margin-top:10px;border-radius:8px;border:1px solid #444}button{background:#2563eb;color:#fff;border:none}.toast{position:fixed;right:16px;bottom:16px;background:#374151;padding:12px;border-radius:8px;opacity:.95}</style>
</head><body><div class="wrap"><div class="sidebar"><h3>RayKeen</h3><p>Авторизация</p></div><div class="main"><div class="card">
HTML
  if [ "$mode" = "setup" ]; then
    cat <<HTML
<h2>Первый вход</h2><p>Логин фиксирован: <b>admin</b>. Задайте пароль.</p>
<form method="post" action="/raykeen/set-password"><input type="password" name="password" placeholder="Новый пароль" required><button>Сохранить пароль</button></form>
HTML
  else
    cat <<HTML
<h2>Вход</h2><p>Логин: <b>admin</b></p>
<form method="post" action="/raykeen/login"><input type="password" name="password" placeholder="Пароль" required><button>Войти</button></form>
HTML
  fi
  echo '</div></div></div>'
  [ -n "$msg" ] && printf '<div class="toast">%s</div>' "$msg"
  echo '<script>setTimeout(()=>{document.querySelectorAll(".toast").forEach(t=>t.remove());},4000);</script></body></html>'
}

render_dashboard() {
  html_header
  layout_top "RayKeen — Dashboard"
  st=$(xray_status)
  ver=$(xray_version)
  active=$(sqlite3 "$DB_PATH" "SELECT COALESCE(name,'(нет)') FROM profiles WHERE active=1 LIMIT 1;")
  logs=$(xray_log_tail 30 | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
  cpu=$(cpu_usage_percent)
  ram=$(ram_free_mb)
  wan=$(wan_rx_tx_bytes)
  rx=$(printf "%s" "$wan" | cut -d'|' -f1)
  tx=$(printf "%s" "$wan" | cut -d'|' -f2)
  iface=$(printf "%s" "$wan" | cut -d'|' -f3)
  temp=$(cpu_temp_c)
  xr_uptime=$(xray_uptime_sec)
  xr_restarts=$(xray_restarts_last_day)
  toast=$(toast_msg "$(get_param toast)")
  [ "$ram" -lt 50 ] && toast="$(toast_msg low_ram)"
  html_header
  layout_top "RayKeen — Dashboard"
  cat <<HTML
<div class="card"><h2>Dashboard</h2><p>Статус xray: <b>$st</b></p><p>Версия xray: <b>$ver</b></p><p>Активный профиль: <b>${active:-нет}</b></p>
<div class="row"><a href="/raykeen/xray/start"><button>Запустить</button></a><a href="/raykeen/xray/stop"><button class="btn-gray">Остановить</button></a><a href="/raykeen/xray/restart"><button class="btn-gray">Перезапустить</button></a><a href="/raykeen/dashboard"><button class="btn-gray">Обновить</button></a></div></div>
<div class="card"><h3>Мониторинг</h3><p>CPU: <b>${cpu}%</b> | RAM свободно: <b>${ram} MB</b> | WAN($iface) RX/TX: <b>${rx}/${tx} bytes</b> | Temp: <b>${temp}°C</b></p><p>Uptime xray: <b>${xr_uptime} сек</b> | Авторестарты за 24ч: <b>${xr_restarts}</b></p></div>
<div class="card"><h3>Трафик</h3>
$(
  update_stats_availability
  av=$(is_stats_available_setting)
  if [ "$av" = "1" ]; then
    s24=$(traffic_sum_24h); in24=$(printf "%s" "$s24" | cut -d'|' -f1); out24=$(printf "%s" "$s24" | cut -d'|' -f2)
    ss=$(traffic_sum_session); ins=$(printf "%s" "$ss" | cut -d'|' -f1); outs=$(printf "%s" "$ss" | cut -d'|' -f2)
    echo '<p>За сессию: IN '${ins}' B / OUT '${outs}' B</p><p>За 24ч: IN '${in24}' B / OUT '${out24}' B</p><form method="post" action="/raykeen/stats/reset"><input type="hidden" name="csrf_token" value="'"$(get_session_csrf "$AUTH_TOKEN")"'"><button class="btn-gray" type="submit">Сбросить счётчики</button></form>'
  else
    echo '<p>Stats API недоступен — виджеты трафика скрыты.</p>'
  fi
)
</div>
<div class="card"><h3>Лог xray (последние 30 строк)</h3><pre style="white-space:pre-wrap">$logs</pre></div>
HTML
  layout_bottom "$toast"
}


profile_status_dot() {
  lat="$1"
  if [ -z "$lat" ]; then echo "⚫"; return; fi
  [ "$lat" -le 200 ] && echo "🟢" && return
  [ "$lat" -le 500 ] && echo "🟡" && return
  echo "🔴"
}

render_profiles() {
  token="$1"
  csrf=$(get_session_csrf "$token")
  protocol=$(get_param protocol); enabled=$(get_param enabled); q=$(get_param q); sort=$(get_param sort)
  toast=$(toast_msg "$(get_param toast)")
  rows=$(profiles_list_csv "$protocol" "$enabled" "$q" "$sort")
  html_header
  layout_top "RayKeen — Profiles"
  cat <<HTML
<div class="card"><h2>Profiles</h2><form method="get" action="/raykeen/profiles" class="row"><input type="text" name="q" placeholder="Поиск имя/адрес" value="$q"><select name="protocol"><option value="">Все протоколы</option><option value="vless">vless</option><option value="vmess">vmess</option><option value="ss">ss</option><option value="trojan">trojan</option></select><select name="enabled"><option value="">Все</option><option value="1">Включённые</option><option value="0">Выключенные</option></select><select name="sort"><option value="name">Сорт: имя</option><option value="protocol">протокол</option><option value="latency">задержка</option><option value="date">дата</option></select><button type="submit">Применить</button></form></div>
<div class="card"><h3>Добавить профиль по URI</h3><form method="post" action="/raykeen/profiles/add-uri" class="row"><input type="hidden" name="csrf_token" value="$csrf"><textarea name="uri" rows="3" style="width:100%" placeholder="vless://..., vmess://..., ss://..., trojan://..." required></textarea><button type="submit">Добавить</button></form></div>
<div class="card"><h3>Тестирование профилей</h3><form method="post" action="/raykeen/profiles/test-method" class="row"><input type="hidden" name="csrf_token" value="$csrf"><select name="method"><option value="http204">HTTP 204</option><option value="tcp">TCP connect</option><option value="icmp">ICMP ping</option></select><button type="submit">Выбрать метод</button></form><form method="post" action="/raykeen/profiles/test-cancel" class="row"><input type="hidden" name="csrf_token" value="$csrf"><button class="btn-red" type="submit">Отменить текущий тест</button></form><p>Прогресс: $(read_progress | awk -F'|' '{print $1" из "$2}') | Статус очереди: $(is_test_running && echo "выполняется" || echo "нет")</p></div>
<div class="card"><h3>Список</h3><form method="post" action="/raykeen/profiles/bulk" class="row"><input type="hidden" name="csrf_token" value="$csrf"><input type="text" name="ids" placeholder="ID через запятую (например 1,2,3)"><button class="btn-red" name="action" value="delete" type="submit">Удалить</button><button class="btn-gray" name="action" value="test" type="submit">Тестировать</button><button class="btn-gray" name="action" value="export" type="submit">Экспортировать URI</button></form><table class="table"><tr><th>ID</th><th>Статус</th><th>Имя</th><th>Протокол</th><th>Адрес</th><th>Порт</th><th>Enabled</th><th>Actions</th></tr>
HTML
  echo "$rows" | tail -n +2 | while IFS=',' read -r id proto name addr port en active lat tested tags notes ex created; do
    clean_name=$(printf "%s" "$name" | sed 's/^"//;s/"$//')
    clean_addr=$(printf "%s" "$addr" | sed 's/^"//;s/"$//')
    clean_lat=$(printf "%s" "$lat" | tr -d '"')
    dot=$(profile_status_dot "$clean_lat")
    printf '<tr><td class="mono">%s</td><td class="status">%s</td><td>%s<br><small>%sms</small></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>' "$id" "$dot" "$clean_name" "${clean_lat:-n/a}" "$proto" "$clean_addr" "$port" "$en"
    printf '<form style="display:inline" method="post" action="/raykeen/profiles/test-one"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">Тест</button></form> ' "$csrf" "$id"
    printf '<form style="display:inline" method="post" action="/raykeen/profiles/toggle"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">On/Off</button></form> ' "$csrf" "$id"
    printf '<form style="display:inline" method="post" action="/raykeen/profiles/activate"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">Сделать активным</button></form> ' "$csrf" "$id"
    printf '<form style="display:inline" method="post" action="/raykeen/profiles/copy"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">Копия</button></form></td></tr>' "$csrf" "$id"
  done
  echo '</table></div>'
  layout_bottom "$toast"
}


render_subscriptions() {
  token="$1"; csrf=$(get_session_csrf "$token"); rows=$(list_subscriptions_csv); toast=$(toast_msg "$(get_param toast)")
  html_header; layout_top "RayKeen — Subscriptions"
  cat <<HTML
<div class="card"><h2>Subscriptions</h2><form method="post" action="/raykeen/subscriptions/add" class="row"><input type="hidden" name="csrf_token" value="$csrf"><input type="text" name="name" placeholder="Название подписки" required><input type="text" name="url" placeholder="URL подписки" required style="min-width:420px"><select name="interval"><option value="manual">вручную</option><option value="daily">раз в день</option><option value="3d">раз в 3 дня</option><option value="weekly">раз в неделю</option></select><button type="submit">Добавить</button></form></div>
<div class="card"><h3>Список подписок</h3><table class="table"><tr><th>ID</th><th>Название</th><th>URL</th><th>Последнее обновление</th><th>Профилей</th><th>Статистика</th><th>Интервал</th><th>Enabled</th><th>Действия</th></tr>
HTML
  echo "$rows" | tail -n +2 | while IFS=',' read -r id name url lastup cnt add upd rem intr en created; do
    n=$(printf "%s" "$name" | sed 's/^"//;s/"$//'); u=$(printf "%s" "$url" | sed 's/^"//;s/"$//')
    printf '<tr><td>%s</td><td>%s</td><td class="mono">%s</td><td>%s</td><td>%s</td><td>+%s / ~%s / -%s</td><td>%s</td><td>%s</td><td><form style="display:inline" method="post" action="/raykeen/subscriptions/update"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">Обновить</button></form> <form style="display:inline" method="post" action="/raykeen/subscriptions/toggle"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">On/Off</button></form></td></tr>' "$id" "$n" "$u" "$lastup" "$cnt" "$add" "$upd" "$rem" "$intr" "$en" "$csrf" "$id" "$csrf" "$id"
  done
  echo '</table></div><div class="card"><form method="post" action="/raykeen/subscriptions/update-all" class="row"><input type="hidden" name="csrf_token" value="'$csrf'"><button type="submit">Обновить все по очереди</button></form></div>'
  layout_bottom "$toast"
}


render_settings() {
  token="$1"
  csrf=$(get_session_csrf "$token")
  de=$(sqlite3 "$DB_PATH" "SELECT COALESCE(value,'0') FROM settings WHERE key='doh_enabled' LIMIT 1;")
  order=$(sqlite3 "$DB_PATH" "SELECT COALESCE(value,'') FROM settings WHERE key='doh_servers_order' LIMIT 1;")
  custom=$(sqlite3 "$DB_PATH" "SELECT COALESCE(value,'') FROM settings WHERE key='doh_custom_url' LIMIT 1;")
  timeout=$(sqlite3 "$DB_PATH" "SELECT COALESCE(value,'3') FROM settings WHERE key='doh_fallback_timeout_sec' LIMIT 1;")
  fakedns=$(sqlite3 "$DB_PATH" "SELECT COALESCE(value,'0') FROM settings WHERE key='doh_fakedns' LIMIT 1;")
  toast=$(toast_msg "$(get_param toast)")
  html_header
  layout_top "RayKeen — Settings"
  cat <<HTML
<div class="card"><h2>Settings / DoH</h2>
<form method="post" action="/raykeen/settings/doh-save" class="row">
<input type="hidden" name="csrf_token" value="$csrf">
<label><input type="checkbox" name="doh_enabled" value="1" $( [ "$de" = "1" ] && echo checked )> Включить DoH</label>
<input type="text" name="doh_servers_order" value="$order" style="min-width:650px" placeholder="Серверы DoH через запятую">
<input type="text" name="doh_custom_url" value="$custom" placeholder="Кастомный DoH URL">
<input type="number" name="doh_fallback_timeout_sec" value="$timeout" min="1" max="30" placeholder="Timeout сек">
<label><input type="checkbox" name="doh_fakedns" value="1" $( [ "$fakedns" = "1" ] && echo checked )> fakeDNS</label>
<button type="submit">Сохранить и применить</button></form>
<form method="post" action="/raykeen/settings/doh-check" class="row"><input type="hidden" name="csrf_token" value="$csrf"><input type="text" name="url" value="$custom" placeholder="URL для проверки"><button class="btn-gray" type="submit">Проверить доступность</button></form>
<div class="card"><h3>Автовыбор профиля</h3>
<form method="post" action="/raykeen/settings/autoselect" class="row"><input type="hidden" name="csrf_token" value="$csrf">
<label><input type="checkbox" name="autoselect_enabled" value="1"> Включить</label>
<input type="text" name="autoselect_protocol" placeholder="Фильтр протокол">
<input type="text" name="autoselect_tag" placeholder="Фильтр тег">
<input type="number" name="autoselect_crash_threshold" value="3" min="1">
<button type="submit">Сохранить</button></form>
<form method="post" action="/raykeen/autoselect/run" class="row"><input type="hidden" name="csrf_token" value="$csrf"><button class="btn-gray" type="submit">Запустить сейчас</button></form>
</div>
HTML
  layout_bottom "$toast"
}

render_routing() {
  token="$1"; csrf=$(get_session_csrf "$token"); cols=$(list_columns_csv); toast=$(toast_msg "$(get_param toast)")
  html_header; layout_top "RayKeen — Routing"
  cat <<HTML
<div class="card"><h2>Routing</h2><p>Порядок колонок = приоритет правил в xray.</p>
<form method="post" action="/raykeen/routing/column-add" class="row"><input type="hidden" name="csrf_token" value="$csrf"><input type="text" name="name" placeholder="Название колонки" required><select name="outbound"><option value="direct">Direct</option><option value="block">Block</option><option value="proxy">Proxy</option></select><input type="text" name="profile_id" placeholder="profile_id (для Proxy)"><button type="submit">Добавить колонку</button></form>
<form method="post" action="/raykeen/routing/preset" class="row"><input type="hidden" name="csrf_token" value="$csrf"><button class="btn-gray" name="preset" value="ru" type="submit">RU-direct</button><button class="btn-gray" name="preset" value="ads" type="submit">ADS-block</button><button class="btn-gray" formaction="/raykeen/routing/export" type="submit">Экспорт JSON</button></form>
</div>
<div class="card"><h3>Geo-файлы</h3><p>Размеры:</p><pre>$(geo_sizes)</pre><form method="post" action="/raykeen/geo/update" class="row"><input type="hidden" name="csrf_token" value="$csrf"><button type="submit">Скачать и обновить geoip/geosite</button></form><form method="post" action="/raykeen/geo/rollback" class="row"><input type="hidden" name="csrf_token" value="$csrf"><button class="btn-gray" type="submit">Откатить .bak</button></form><form method="post" action="/raykeen/geo/settings" class="row"><input type="hidden" name="csrf_token" value="$csrf"><select name="geo_mode"><option value="auto">auto</option><option value="manual">manual</option></select><input type="number" name="geo_update_interval_days" min="1" value="1"><button class="btn-gray" type="submit">Сохранить режим</button></form></div>
HTML
  echo "$cols" | tail -n +2 | while IFS=',' read -r cid name outb pid ord en created; do
    n=$(printf "%s" "$name" | sed 's/^"//;s/"$//')
    printf '<div class="card"><h3>%s (#%s)</h3><p>Outbound: %s | profile_id: %s | enabled: %s</p>' "$n" "$cid" "$outb" "$pid" "$en"
    printf '<form method="post" action="/raykeen/routing/column-move" class="row"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" name="dir" value="up">Вверх</button><button class="btn-gray" name="dir" value="down">Вниз</button><button class="btn-gray" formaction="/raykeen/routing/column-toggle">On/Off</button></form>' "$csrf" "$cid"
    printf '<form method="post" action="/raykeen/routing/rule-add" class="row"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="column_id" value="%s"><select name="type"><option value="domain">domain</option><option value="ip">ip</option><option value="cidr">cidr</option></select><input type="text" name="value" placeholder="значение" required><input type="text" name="comment" placeholder="комментарий"><button type="submit">Добавить правило</button></form>' "$csrf" "$cid"
    rules=$(list_rules_csv "$cid")
    echo '<table class="table"><tr><th>ID</th><th>Type</th><th>Value</th><th>Comment</th><th>Enabled</th><th>Action</th></tr>'
    echo "$rules" | tail -n +2 | while IFS=',' read -r rid rcid t v c ro re; do
      vv=$(printf "%s" "$v" | sed 's/^"//;s/"$//'); cc=$(printf "%s" "$c" | sed 's/^"//;s/"$//')
      printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td><form method="post" action="/raykeen/routing/rule-toggle"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">On/Off</button></form></td></tr>' "$rid" "$t" "$vv" "$cc" "$re" "$csrf" "$rid"
    done
    echo '</table></div>'
  done
  layout_bottom "$toast"
}


render_history() {
  token="$1"
  csrf=$(get_session_csrf "$token")
  t=$(get_param type); d1=$(get_param from); d2=$(get_param to)
  rows=$(events_query_csv "$t" "$d1" "$d2")
  html_header
  layout_top "RayKeen — History"
  cat <<HTML
<div class="card"><h2>History</h2>
<form method="get" action="/raykeen/history" class="row"><input type="text" name="type" placeholder="type" value="$t"><input type="date" name="from" value="$d1"><input type="date" name="to" value="$d2"><button type="submit">Фильтр</button></form>
<form method="post" action="/raykeen/history/export" class="row"><input type="hidden" name="csrf_token" value="$csrf"><input type="hidden" name="type" value="$t"><input type="hidden" name="from" value="$d1"><input type="hidden" name="to" value="$d2"><button class="btn-gray" name="fmt" value="csv" type="submit">Экспорт CSV</button><button class="btn-gray" name="fmt" value="json" type="submit">Экспорт JSON</button></form>
<form method="post" action="/raykeen/history/clear" class="row"><input type="hidden" name="csrf_token" value="$csrf"><input type="number" name="days" min="1" placeholder="старше N дней (пусто=всё)"><button class="btn-red" type="submit">Очистить</button></form>
<table class="table"><tr><th>ID</th><th>Type</th><th>Message</th><th>Profile</th><th>Created</th></tr>
HTML
  echo "$rows" | tail -n +2 | while IFS=',' read -r id ty msg pid created; do
    m=$(printf "%s" "$msg" | sed 's/^"//;s/"$//')
    echo "<tr><td>$id</td><td>$ty</td><td>$m</td><td>$pid</td><td>$created</td></tr>"
  done
  echo "</table></div>"
  layout_bottom "$(toast_msg "$(get_param toast)")"
}

render_backup() {
  token="$1"
  csrf=$(get_session_csrf "$token")
  rows=$(list_backups_csv)
  html_header
  layout_top "RayKeen — Backup"
  cat <<HTML
<div class="card"><h2>Backup</h2>
<form method="post" action="/raykeen/backup/export" class="row"><input type="hidden" name="csrf_token" value="$csrf"><select name="mode"><option value="full">Полный</option><option value="no_password">Без password_hash</option></select><button type="submit">Экспорт</button></form>
<form method="post" enctype="multipart/form-data" action="/raykeen/backup/import" class="row"><input type="hidden" name="csrf_token" value="$csrf"><input type="text" name="archive_path" placeholder="Путь к tar.gz на устройстве"><select name="import_mode"><option value="all">Всё</option><option value="profiles">Только профили</option><option value="routing">Только маршрутизация</option></select><button type="submit">Импорт</button></form>
<table class="table"><tr><th>Файл</th><th>Размер</th><th>Дата</th><th>Скачать</th></tr>
HTML
  echo "$rows" | tail -n +2 | while IFS=',' read -r n sz cr; do
    echo "<tr><td>$n</td><td>$sz</td><td>$cr</td><td><a href="/raykeen/backup/download?name=$n">Скачать</a></td></tr>"
  done
  echo "</table></div>"
  layout_bottom "$(toast_msg "$(get_param toast)")"
}

render_about() {
  html_header
  layout_top "RayKeen — About"
  rv=$(cat "$BASE_DIR/version" 2>/dev/null || echo "unknown")
  xv=$(xray_version)
  arch=$(uname -m)
  up=$(awk '{printf "%d", $1}' /proc/uptime)
  cat <<HTML
<div class="card"><h2>About</h2><p>RayKeen: <b>$rv</b></p><p>xray-core: <b>$xv</b></p><p>Архитектура: <b>$arch</b></p><p>Uptime роутера: <b>$up сек</b></p></div>
HTML
  layout_bottom ""
}

path="${PATH_INFO:-/}"; method="${REQUEST_METHOD:-GET}"; pass_hash=$(get_password_hash)

case "$path" in
  "/"|"")
    if [ -z "$pass_hash" ]; then render_login_page setup; else
      token=$(get_cookie_value raykeen_session || true)
      if [ -n "$token" ] && is_session_valid "$token"; then refresh_session "$token" || true; redirect "/raykeen/dashboard"; else render_login_page login; fi
    fi ;;
  "/login")
    [ "$method" = "POST" ] || { redirect "/raykeen/"; exit 0; }
    post=$(read_post_data); pass=$(param_from_kv password "$post")
    [ -n "$pass_hash" ] || { redirect "/raykeen/"; exit 0; }
    if [ "$(hash_password "$pass")" = "$pass_hash" ]; then
      token=$(create_session); redirect "/raykeen/dashboard" "raykeen_session=$token; Path=/; HttpOnly; SameSite=Strict"
    else
      sleep 2; redirect "/raykeen/?toast=bad_login"
    fi ;;
  "/set-password")
    [ "$method" = "POST" ] || { redirect "/raykeen/"; exit 0; }
    [ -z "$pass_hash" ] || { redirect "/raykeen/"; exit 0; }
    post=$(read_post_data); newp=$(param_from_kv password "$post"); [ -n "$newp" ] || { redirect "/raykeen/"; exit 0; }
    set_password_hash "$(hash_password "$newp")"; invalidate_all_sessions; token=$(create_session)
    redirect "/raykeen/dashboard" "raykeen_session=$token; Path=/; HttpOnly; SameSite=Strict" ;;
  "/dashboard")
    require_auth || exit 0; render_dashboard ;;
  "/settings")
    require_auth || exit 0; render_settings "$AUTH_TOKEN" ;;
  "/settings/doh-save")
    [ "$method" = "POST" ] || { redirect "/raykeen/settings"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/settings?toast=csrf"; exit 0; }
    de=$(param_from_kv doh_enabled "$post"); [ "$de" = "1" ] || de=0
    order=$(param_from_kv doh_servers_order "$post")
    custom=$(param_from_kv doh_custom_url "$post")
    tmo=$(param_from_kv doh_fallback_timeout_sec "$post"); [ -n "$tmo" ] || tmo=3
    fd=$(param_from_kv doh_fakedns "$post"); [ "$fd" = "1" ] || fd=0
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('doh_enabled','$de') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('doh_servers_order','$(printf "%s" "$order" | sed "s/'/''/g")') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('doh_custom_url','$(printf "%s" "$custom" | sed "s/'/''/g")') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('doh_fallback_timeout_sec','$(printf "%s" "$tmo" | tr -cd '0-9')') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('doh_fakedns','$fd') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    apply_xray_config >/dev/null 2>&1 || true
    redirect "/raykeen/settings?toast=doh_saved" ;;
  "/settings/doh-check")
    [ "$method" = "POST" ] || { redirect "/raykeen/settings"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/settings?toast=csrf"; exit 0; }
    u=$(param_from_kv url "$post")
    if check_doh_server "$u"; then redirect "/raykeen/settings?toast=doh_checked_ok"; else redirect "/raykeen/settings?toast=doh_checked_err"; fi ;;
  "/change-password")
    [ "$method" = "POST" ] || { redirect "/raykeen/dashboard"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/dashboard?toast=csrf"; exit 0; }
    newp=$(param_from_kv new_password "$post"); [ -n "$newp" ] || { redirect "/raykeen/settings"; exit 0; }
    set_password_hash "$(hash_password "$newp")"; invalidate_all_sessions
    redirect "/raykeen/?toast=pwd_changed" "raykeen_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" ;;
  "/profiles")
    require_auth || exit 0; render_profiles "$AUTH_TOKEN" ;;
  "/profiles/add-uri")
    [ "$method" = "POST" ] || { redirect "/raykeen/profiles"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/profiles?toast=csrf"; exit 0; }
    uri=$(param_from_kv uri "$post")
    if msg=$(insert_profile_from_uri "$uri"); then
      redirect "/raykeen/profiles?toast=p_added"
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        emsg=$(printf "%s" "$msg" | sed "s/ /+/g")
        redirect "/raykeen/profiles?toast=dup&msg=$emsg"
      else
        redirect "/raykeen/profiles?toast=p_invalid"
      fi
    fi ;;
  "/profiles/test-method")
    [ "$method" = "POST" ] || { redirect "/raykeen/profiles"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/profiles?toast=csrf"; exit 0; }
    tm=$(param_from_kv method "$post"); set_test_method "$tm"
    redirect "/raykeen/profiles" ;;
  "/profiles/test-one")
    [ "$method" = "POST" ] || { redirect "/raykeen/profiles"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/profiles?toast=csrf"; exit 0; }
    id=$(param_from_kv id "$post"); tm=$(get_test_method)
    if run_tests_sequential_bg "$id" "$tm" 5; then redirect "/raykeen/profiles?toast=t_started"; else redirect "/raykeen/profiles?toast=t_err"; fi ;;
  "/profiles/test-cancel")
    [ "$method" = "POST" ] || { redirect "/raykeen/profiles"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/profiles?toast=csrf"; exit 0; }
    cancel_tests
    redirect "/raykeen/profiles?toast=t_cancel" ;;
  "/profiles/toggle")
    [ "$method" = "POST" ] || { redirect "/raykeen/profiles"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/profiles?toast=csrf"; exit 0; }
    id=$(param_from_kv id "$post"); toggle_profile_enabled "$id"
    redirect "/raykeen/profiles?toast=p_toggled" ;;
  "/profiles/copy")
    [ "$method" = "POST" ] || { redirect "/raykeen/profiles"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/profiles?toast=csrf"; exit 0; }
    id=$(param_from_kv id "$post"); copy_profile "$id"
    redirect "/raykeen/profiles?toast=p_copied" ;;
  "/profiles/bulk")
    [ "$method" = "POST" ] || { redirect "/raykeen/profiles"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/profiles?toast=csrf"; exit 0; }
    ids=$(param_from_kv ids "$post"); action=$(param_from_kv action "$post")
    if [ "$action" = "delete" ]; then
      delete_profiles_by_ids "$ids"; redirect "/raykeen/profiles?toast=p_deleted"
    elif [ "$action" = "test" ]; then
      tm=$(get_test_method)
      if run_tests_sequential_bg "$ids" "$tm" 5; then redirect "/raykeen/profiles?toast=t_started"; else redirect "/raykeen/profiles?toast=t_err"; fi
    elif [ "$action" = "export" ]; then
      printf 'Content-Type: text/plain; charset=UTF-8\r\nContent-Disposition: attachment; filename="profiles.txt"\r\n\r\n'
      export_profiles_raw_uri "$ids"
    else
      redirect "/raykeen/profiles"
    fi ;;
  "/profiles/activate")
    [ "$method" = "POST" ] || { redirect "/raykeen/profiles"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/profiles?toast=csrf"; exit 0; }
    id=$(param_from_kv id "$post"); set_active_profile "$id"; apply_xray_config >/dev/null 2>&1 || true
    redirect "/raykeen/profiles?toast=p_active" ;;
  "/xray/start")
    require_auth || exit 0
    if xray_start; then redirect "/raykeen/dashboard?toast=x_ok"; else redirect "/raykeen/dashboard?toast=x_err"; fi ;;
  "/xray/stop")
    require_auth || exit 0
    if xray_stop; then redirect "/raykeen/dashboard?toast=x_ok"; else redirect "/raykeen/dashboard?toast=x_err"; fi ;;
  "/xray/restart")
    require_auth || exit 0
    if xray_restart; then redirect "/raykeen/dashboard?toast=x_ok"; else redirect "/raykeen/dashboard?toast=x_err"; fi ;;
  "/subscriptions")
    require_auth || exit 0; render_subscriptions "$AUTH_TOKEN" ;;
  "/subscriptions/add")
    [ "$method" = "POST" ] || { redirect "/raykeen/subscriptions"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/subscriptions?toast=csrf"; exit 0; }
    name=$(param_from_kv name "$post"); url=$(param_from_kv url "$post"); intr=$(param_from_kv interval "$post")
    if create_subscription "$name" "$url" "$intr" >/dev/null 2>&1; then redirect "/raykeen/subscriptions?toast=s_added"; else redirect "/raykeen/subscriptions?toast=s_error"; fi ;;
  "/subscriptions/toggle")
    [ "$method" = "POST" ] || { redirect "/raykeen/subscriptions"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/subscriptions?toast=csrf"; exit 0; }
    sid=$(param_from_kv id "$post"); set_subscription_enabled "$sid"; redirect "/raykeen/subscriptions?toast=s_toggled" ;;
  "/subscriptions/update")
    [ "$method" = "POST" ] || { redirect "/raykeen/subscriptions"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/subscriptions?toast=csrf"; exit 0; }
    sid=$(param_from_kv id "$post")
    if update_subscription "$sid" >/dev/null 2>&1; then redirect "/raykeen/subscriptions?toast=s_updated"; else redirect "/raykeen/subscriptions?toast=s_error"; fi ;;
  "/subscriptions/update-all")
    [ "$method" = "POST" ] || { redirect "/raykeen/subscriptions"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/subscriptions?toast=csrf"; exit 0; }
    update_all_subscriptions_sequential
    redirect "/raykeen/subscriptions?toast=s_updated" ;;
  "/routing")
    require_auth || exit 0; render_routing "$AUTH_TOKEN" ;;
  "/routing/column-add")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    n=$(param_from_kv name "$post"); o=$(param_from_kv outbound "$post"); p=$(param_from_kv profile_id "$post")
    create_column "$n" "$o" "$p"; apply_xray_config >/dev/null 2>&1 || true
    redirect "/raykeen/routing?toast=r_saved" ;;
  "/routing/column-move")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    id=$(param_from_kv id "$post"); d=$(param_from_kv dir "$post"); move_column "$id" "$d"; apply_xray_config >/dev/null 2>&1 || true
    redirect "/raykeen/routing?toast=r_saved" ;;
  "/routing/column-toggle")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    id=$(param_from_kv id "$post"); toggle_column "$id"; apply_xray_config >/dev/null 2>&1 || true
    redirect "/raykeen/routing?toast=r_saved" ;;
  "/routing/rule-add")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    cid=$(param_from_kv column_id "$post"); t=$(param_from_kv type "$post"); v=$(param_from_kv value "$post"); c=$(param_from_kv comment "$post")
    if add_rule "$cid" "$t" "$v" "$c" >/dev/null 2>&1; then apply_xray_config >/dev/null 2>&1 || true; redirect "/raykeen/routing?toast=r_saved"; else redirect "/raykeen/routing?toast=r_err"; fi ;;
  "/routing/rule-toggle")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    id=$(param_from_kv id "$post"); toggle_rule "$id"; apply_xray_config >/dev/null 2>&1 || true
    redirect "/raykeen/routing?toast=r_saved" ;;
  "/routing/preset")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    pr=$(param_from_kv preset "$post"); [ "$pr" = "ru" ] && apply_preset_ru_direct || apply_preset_ads_block
    apply_xray_config >/dev/null 2>&1 || true
    redirect "/raykeen/routing?toast=r_saved" ;;
  "/routing/export")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    printf 'Content-Type: application/json; charset=UTF-8\r\nContent-Disposition: attachment; filename="routing.json"\r\n\r\n'
    export_routing_json ;;
  "/backup")
    require_auth || exit 0; render_backup "$AUTH_TOKEN" ;;
  "/about")
    require_auth || exit 0; render_about ;;
  "/backup/export")
    [ "$method" = "POST" ] || { redirect "/raykeen/backup"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/backup?toast=csrf"; exit 0; }
    m=$(param_from_kv mode "$post")
    arc=$(make_backup_archive "$m") || { redirect "/raykeen/backup?toast=b_err"; exit 0; }
    printf 'Content-Type: application/gzip\r\nContent-Disposition: attachment; filename="raykeen_backup.tar.gz"\r\n\r\n'
    cat "$arc"
    rm -f "$arc" ;;
  "/backup/import")
    [ "$method" = "POST" ] || { redirect "/raykeen/backup"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/backup?toast=csrf"; exit 0; }
    ap=$(param_from_kv archive_path "$post"); im=$(param_from_kv import_mode "$post")
    if import_backup_archive "$ap" "$im"; then redirect "/raykeen/backup?toast=b_done"; else redirect "/raykeen/backup?toast=b_err"; fi ;;
  "/backup/download")
    require_auth || exit 0
    n=$(get_param name)
    f="/opt/etc/raykeen/backups/$(basename "$n")"
    [ -f "$f" ] || { printf 'Status: 404 Not Found\r\n\r\n'; exit 0; }
    printf 'Content-Type: application/gzip\r\nContent-Disposition: attachment; filename="%s"\r\n\r\n' "$(basename "$f")"
    cat "$f" ;;
  "/profiles/qr")
    require_auth || exit 0
    pid=$(get_param id)
    png=$(make_profile_qr_png "$pid") || { printf 'Status: 404 Not Found\r\n\r\n'; exit 0; }
    printf 'Content-Type: image/png\r\n\r\n'
    cat "$png"
    rm -f "$png" ;;
  "/history")
    require_auth || exit 0; render_history "$AUTH_TOKEN" ;;
  "/history/export")
    [ "$method" = "POST" ] || { redirect "/raykeen/history"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/history?toast=csrf"; exit 0; }
    t=$(param_from_kv type "$post"); d1=$(param_from_kv from "$post"); d2=$(param_from_kv to "$post"); fmt=$(param_from_kv fmt "$post")
    if [ "$fmt" = "json" ]; then
      printf 'Content-Type: application/json; charset=UTF-8\r\nContent-Disposition: attachment; filename="events.json"\r\n\r\n'
      export_events_json "$t" "$d1" "$d2"
    else
      printf 'Content-Type: text/csv; charset=UTF-8\r\nContent-Disposition: attachment; filename="events.csv"\r\n\r\n'
      events_query_csv "$t" "$d1" "$d2"
    fi ;;
  "/history/clear")
    [ "$method" = "POST" ] || { redirect "/raykeen/history"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/history?toast=csrf"; exit 0; }
    days=$(param_from_kv days "$post"); clear_events "$days"
    redirect "/raykeen/history?toast=h_cleared" ;;
  "/settings/autoselect")
    [ "$method" = "POST" ] || { redirect "/raykeen/settings"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/settings?toast=csrf"; exit 0; }
    en=$(param_from_kv autoselect_enabled "$post"); [ "$en" = "1" ] || en=0
    pr=$(param_from_kv autoselect_protocol "$post"); tg=$(param_from_kv autoselect_tag "$post"); th=$(param_from_kv autoselect_crash_threshold "$post")
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('autoselect_enabled','$en') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('autoselect_protocol','$(printf "%s" "$pr" | sed "s/'/''/g")') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('autoselect_tag','$(printf "%s" "$tg" | sed "s/'/''/g")') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('autoselect_crash_threshold','$(printf "%s" "$th" | tr -cd '0-9')') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    redirect "/raykeen/settings?toast=as_saved" ;;
  "/autoselect/run")
    [ "$method" = "POST" ] || { redirect "/raykeen/settings"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/settings?toast=csrf"; exit 0; }
    run_autoselect >/dev/null 2>&1 || true
    redirect "/raykeen/settings?toast=as_done" ;;
  "/stats/reset")
    [ "$method" = "POST" ] || { redirect "/raykeen/dashboard"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/dashboard?toast=csrf"; exit 0; }
    reset_traffic_counters
    redirect "/raykeen/dashboard?toast=stats_reset" ;;
  "/geo/update")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    if geo_update_from_urls >/dev/null 2>&1; then redirect "/raykeen/routing?toast=g_ok"; else redirect "/raykeen/routing?toast=g_err"; fi ;;
  "/geo/rollback")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    geo_rollback; apply_xray_config >/dev/null 2>&1 || true
    redirect "/raykeen/routing?toast=g_rb" ;;
  "/geo/settings")
    [ "$method" = "POST" ] || { redirect "/raykeen/routing"; exit 0; }
    require_auth || exit 0
    post=$(read_post_data); require_post_csrf "$post" || { redirect "/raykeen/routing?toast=csrf"; exit 0; }
    gm=$(param_from_kv geo_mode "$post"); iv=$(param_from_kv geo_update_interval_days "$post")
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('geo_mode','$(printf "%s" "$gm" | sed "s/'/''/g")') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    sqlite3 "$DB_PATH" "INSERT INTO settings(key,value) VALUES('geo_update_interval_days','$(printf "%s" "$iv" | tr -cd '0-9')') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    redirect "/raykeen/routing?toast=g_ok" ;;
  "/health")
    printf "Content-Type: application/json; charset=UTF-8\r\n\r\n"
    render_health_json ;;
  "/logout")
    token=$(get_cookie_value raykeen_session || true)
    [ -n "$token" ] && rm -f "/tmp/raykeen/sessions/$token" 2>/dev/null || true
    redirect "/raykeen/" "raykeen_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" ;;
  *)
    printf 'Status: 404 Not Found\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nNot Found' ;;
esac
