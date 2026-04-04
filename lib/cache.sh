#!/bin/sh
CACHE_DIR="/tmp/raykeen/cache"

cache_set() {
  key="$1"; value="$2"
  mkdir -p "$CACHE_DIR"
  printf "%s" "$value" > "$CACHE_DIR/$key"
}

cache_get() {
  key="$1"
  [ -f "$CACHE_DIR/$key" ] && cat "$CACHE_DIR/$key"
}

cache_invalidate() {
  key="$1"
  rm -f "$CACHE_DIR/$key"
}
