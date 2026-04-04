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
</style></head><body><div class="wrap"><div class="sidebar"><h3>RayKeen</h3><p><a href="/raykeen/dashboard">Dashboard</a></p><p><a href="/raykeen/profiles">Profiles</a></p><p><a href="/raykeen/subscriptions">Subscriptions</a></p><p><a href="/raykeen/settings">Settings</a></p><p><a href="/raykeen/logout">Выход</a></p></div><div class="main">
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
  cat <<HTML
<div class="card"><h2>Dashboard</h2><p>Статус xray: <b>$st</b></p><p>Версия xray: <b>$ver</b></p><p>Активный профиль: <b>${active:-нет}</b></p>
<div class="row"><a href="/raykeen/xray/start"><button>Запустить</button></a><a href="/raykeen/xray/stop"><button class="btn-gray">Остановить</button></a><a href="/raykeen/xray/restart"><button class="btn-gray">Перезапустить</button></a></div></div>
<div class="card"><h3>Лог xray (последние 30 строк)</h3><pre style="white-space:pre-wrap">$logs</pre></div>
HTML
  layout_bottom "$(toast_msg "$(get_param toast)")"
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
  protocol=$(get_param protocol)
  enabled=$(get_param enabled)
  q=$(get_param q)
  sort=$(get_param sort)
  toast=$(toast_msg "$(get_param toast)")

  rows=$(profiles_list_csv "$protocol" "$enabled" "$q" "$sort")

  html_header
  layout_top "RayKeen — Profiles"
  cat <<HTML
<div class="card"><h2>Profiles</h2>
<form method="get" action="/raykeen/profiles" class="row">
<input type="text" name="q" placeholder="Поиск имя/адрес" value="$q">
<select name="protocol"><option value="">Все протоколы</option><option value="vless">vless</option><option value="vmess">vmess</option><option value="ss">ss</option><option value="trojan">trojan</option></select>
<select name="enabled"><option value="">Все</option><option value="1">Включённые</option><option value="0">Выключенные</option></select>
<select name="sort"><option value="name">Сорт: имя</option><option value="protocol">протокол</option><option value="latency">задержка</option><option value="date">дата</option></select>
<button type="submit">Применить</button></form>
</div>
<div class="card"><h3>Добавить профиль по URI</h3>
<form method="post" action="/raykeen/profiles/add-uri" class="row">
<input type="hidden" name="csrf_token" value="$csrf">
<textarea name="uri" rows="3" style="width:100%" placeholder="vless://..., vmess://..., ss://..., trojan://..." required></textarea>
<button type="submit">Добавить</button></form>
</div>
<div class="card"><h3>Список</h3>
<form method="post" action="/raykeen/profiles/bulk" class="row">
<input type="hidden" name="csrf_token" value="$csrf">
<input type="text" name="ids" placeholder="ID через запятую (например 1,2,3)">
<button class="btn-red" name="action" value="delete" type="submit">Удалить</button>
<button class="btn-gray" name="action" value="export" type="submit">Экспортировать URI</button>
</form>
<table class="table"><tr><th>ID</th><th>Статус</th><th>Имя</th><th>Протокол</th><th>Адрес</th><th>Порт</th><th>Enabled</th><th>Actions</th></tr>
HTML
  echo "$rows" | tail -n +2 | while IFS=',' read -r id proto name addr port en active lat tested tags notes ex created; do
    clean_name=$(printf "%s" "$name" | sed 's/^"//;s/"$//')
    clean_addr=$(printf "%s" "$addr" | sed 's/^"//;s/"$//')
    clean_lat=$(printf "%s" "$lat" | tr -d '"')
    dot=$(profile_status_dot "$clean_lat")
    printf '<tr><td class="mono">%s</td><td class="status">%s</td><td>%s<br><small>%sms</small></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>' "$id" "$dot" "$clean_name" "${clean_lat:-n/a}" "$proto" "$clean_addr" "$port" "$en"
    printf '<form style="display:inline" method="post" action="/raykeen/profiles/toggle"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">On/Off</button></form> ' "$csrf" "$id"
    printf '<form style="display:inline" method="post" action="/raykeen/profiles/activate"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">Сделать активным</button></form> ' "$csrf" "$id"
    printf '<form style="display:inline" method="post" action="/raykeen/profiles/copy"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">Копия</button></form>' "$csrf" "$id"
    printf '</td></tr>'
  done
  cat <<HTML
</table></div>
HTML
  layout_bottom "$toast"
}


render_subscriptions() {
  token="$1"
  csrf=$(get_session_csrf "$token")
  rows=$(list_subscriptions_csv)
  toast=$(toast_msg "$(get_param toast)")
  html_header
  layout_top "RayKeen — Subscriptions"
  cat <<HTML
<div class="card"><h2>Subscriptions</h2>
<form method="post" action="/raykeen/subscriptions/add" class="row">
<input type="hidden" name="csrf_token" value="$csrf">
<input type="text" name="name" placeholder="Название подписки" required>
<input type="text" name="url" placeholder="URL подписки" required style="min-width:420px">
<select name="interval"><option value="manual">вручную</option><option value="daily">раз в день</option><option value="3d">раз в 3 дня</option><option value="weekly">раз в неделю</option></select>
<button type="submit">Добавить</button></form></div>
<div class="card"><h3>Список подписок</h3>
<table class="table"><tr><th>ID</th><th>Название</th><th>URL</th><th>Последнее обновление</th><th>Профилей</th><th>Статистика</th><th>Интервал</th><th>Enabled</th><th>Действия</th></tr>
HTML
  echo "$rows" | tail -n +2 | while IFS=',' read -r id name url lastup cnt add upd rem intr en created; do
    n=$(printf "%s" "$name" | sed 's/^"//;s/"$//')
    u=$(printf "%s" "$url" | sed 's/^"//;s/"$//')
    printf '<tr><td>%s</td><td>%s</td><td class="mono">%s</td><td>%s</td><td>%s</td><td>+%s / ~%s / -%s</td><td>%s</td><td>%s</td><td>' "$id" "$n" "$u" "$lastup" "$cnt" "$add" "$upd" "$rem" "$intr" "$en"
    printf '<form style="display:inline" method="post" action="/raykeen/subscriptions/update"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">Обновить</button></form> ' "$csrf" "$id"
    printf '<form style="display:inline" method="post" action="/raykeen/subscriptions/toggle"><input type="hidden" name="csrf_token" value="%s"><input type="hidden" name="id" value="%s"><button class="btn-gray" type="submit">On/Off</button></form>' "$csrf" "$id"
    printf '</td></tr>'
  done
  cat <<HTML
</table></div>
<div class="card"><form method="post" action="/raykeen/subscriptions/update-all" class="row"><input type="hidden" name="csrf_token" value="$csrf"><button type="submit">Обновить все по очереди</button></form></div>
HTML
  layout_bottom "$toast"
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
  "/dashboard"|"/settings")
    require_auth || exit 0; render_dashboard ;;
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
  "/logout")
    token=$(get_cookie_value raykeen_session || true)
    [ -n "$token" ] && rm -f "/tmp/raykeen/sessions/$token" 2>/dev/null || true
    redirect "/raykeen/" "raykeen_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" ;;
  *)
    printf 'Status: 404 Not Found\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nNot Found' ;;
esac
