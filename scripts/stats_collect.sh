#!/bin/sh
BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$BASE_DIR/lib/logger.sh"
. "$BASE_DIR/lib/stats.sh"

update_stats_availability
rotate_traffic_stats
if collect_traffic_snapshot >/dev/null 2>&1; then
  log_msg DEBUG "traffic snapshot collected"
else
  log_msg WARN "traffic snapshot skipped (stats API unavailable or no active profile)"
fi
