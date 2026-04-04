#!/bin/sh
SESS_DIR="/tmp/raykeen/sessions"
SESSION_TTL="${RAYKEEN_SESSION_TTL:-1800}"

hash_password() {
  printf "%s" "$1" | sha256sum | awk '{print $1}'
}

new_token() {
  seed="$(date +%s)-$$-$RANDOM-$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  printf "%s" "$seed" | sha256sum | awk '{print $1}'
}

create_session() {
  token=$(new_token)
  csrf=$(new_token)
  now=$(date +%s)
  exp=$((now + SESSION_TTL))
  mkdir -p "$SESS_DIR"
  {
    echo "user=admin"
    echo "expires_at=$exp"
    echo "csrf=$csrf"
  } > "$SESS_DIR/$token"
  chmod 600 "$SESS_DIR/$token" 2>/dev/null || true
  echo "$token"
}

session_file() {
  echo "$SESS_DIR/$1"
}

get_cookie_value() {
  key="$1"
  cookie="${HTTP_COOKIE:-}"
  oldIFS=$IFS
  IFS=';'
  for pair in $cookie; do
    IFS=$oldIFS
    trimmed=$(printf "%s" "$pair" | sed 's/^ *//;s/ *$//')
    case "$trimmed" in
      "$key"=*) echo "${trimmed#*=}"; return 0 ;;
    esac
    IFS=';'
  done
  IFS=$oldIFS
  return 1
}

is_session_valid() {
  token="$1"
  file=$(session_file "$token")
  [ -f "$file" ] || return 1
  now=$(date +%s)
  exp=$(awk -F= '$1=="expires_at"{print $2}' "$file" 2>/dev/null)
  [ -n "$exp" ] || return 1
  [ "$exp" -gt "$now" ] || { rm -f "$file"; return 1; }
  return 0
}

refresh_session() {
  token="$1"
  file=$(session_file "$token")
  [ -f "$file" ] || return 1
  now=$(date +%s)
  exp=$((now + SESSION_TTL))
  tmp="${file}.tmp"
  awk -F= -v exp="$exp" 'BEGIN{u=0}
    $1=="expires_at"{$2=exp;u=1}
    {print $1"="$2}
    END{if(u==0) print "expires_at="exp}' "$file" > "$tmp"
  mv "$tmp" "$file"
}

get_session_csrf() {
  token="$1"
  file=$(session_file "$token")
  awk -F= '$1=="csrf"{print $2}' "$file" 2>/dev/null
}

invalidate_all_sessions() {
  rm -f "$SESS_DIR"/* 2>/dev/null || true
}

require_csrf() {
  token="$1"
  posted="$2"
  expected=$(get_session_csrf "$token")
  [ -n "$expected" ] && [ "$posted" = "$expected" ]
}
