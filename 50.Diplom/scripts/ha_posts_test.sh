#!/usr/bin/env bash
# HA fault-tolerance test: posts via curl + vagrant halt/destroy/up + Restic restore
set -euo pipefail

cd "$(dirname "$0")/.."
BASE_URL="https://lab.diplom.com"
COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

log() { echo "=== [$*] ==="; }

ha_add_post() {
  local title="$1" message="$2"
  local page nonce
  page="$(curl -k -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE_URL/")"
  nonce="$(printf '%s' "$page" | sed -n 's/.*name="demo_forum_nonce" value="\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$nonce" ] || { echo "FAIL: nonce not found"; return 1; }
  curl -k -s -L -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -d "demo_forum_nonce=${nonce}" \
    -d "demo_forum_author=HA-Tester" \
    -d "demo_forum_title=${title}" \
    -d "demo_forum_message=${message}" \
    "$BASE_URL/" >/dev/null
  echo "Added post: $title"
}

ha_check_posts() {
  local html missing=0 t
  html="$(curl -k -s "$BASE_URL/")"
  for t in "$@"; do
    if ! printf '%s' "$html" | grep -Fq "$t"; then
      echo "MISSING on page: $t"
      missing=1
    else
      echo "OK on page: $t"
    fi
  done
  return "$missing"
}

ha_wait_site() {
  local i
  for i in $(seq 1 15); do
    if curl -k -s -o /dev/null -w "%{http_code}" "$BASE_URL/" | grep -q '^200$'; then
      echo "Site ready (try $i)"
      return 0
    fi
    sleep 2
  done
  echo "Site not ready"
  return 1
}

ha_wait_after_failover() {
  sleep 8
  ha_wait_site
}

ha_trigger_db_sync() {
  if vagrant status backend-1 2>/dev/null | grep -q 'running'; then
    vagrant ssh backend-1 -c "sudo systemctl start wp-ha-db-sync.service" 2>/dev/null || true
    sleep 5
  fi
}

ha_wait_posts() {
  local tries="${1:-24}" t
  shift
  for t in $(seq 1 "$tries"); do
    if ha_check_posts "$@"; then
      echo "All posts visible (try $t)"
      return 0
    fi
    echo "Waiting for posts on page (try $t/$tries)..."
    ha_trigger_db_sync
    sleep 5
  done
  echo "FAIL: posts not visible after ${tries} tries"
  ha_check_posts "$@" || true
  return 1
}

ha_cleanup_test_posts() {
  log "Cleanup previous HA test posts"
  for vm in backend-1 backend-2; do
    if vagrant status "$vm" 2>/dev/null | grep -q 'running'; then
      vagrant ssh "$vm" -c "mysql -h 10.10.10.40 -P 6033 -u wp_user -p'WpUserSecure!' -NBe \
        \"DELETE FROM wordpress_db.wp_postmeta WHERE post_id IN (SELECT ID FROM wordpress_db.wp_posts WHERE post_title LIKE 'HA Test Post%'); \
         DELETE FROM wordpress_db.wp_posts WHERE post_title LIKE 'HA Test Post%';\" " 2>/dev/null || true
    fi
  done
}

ha_repl_status() {
  vagrant ssh backend-2 -c "sudo mysql --defaults-file=/root/.my.cnf -e 'SHOW SLAVE STATUS\\G' | egrep 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master'" 2>/dev/null || true
}

ha_db_titles() {
  vagrant ssh backend-1 -c "mysql -h 10.10.10.40 -P 6033 -u wp_user -p'WpUserSecure!' -NBe \
    \"SELECT post_title FROM wordpress_db.wp_posts WHERE post_type='demo_forum_message' AND post_status='publish' ORDER BY ID DESC LIMIT 10\""
}

ha_trigger_restic_backup() {
  log "Restic backup backend_master (перед destroy обоих backend)"
  if vagrant status backend-1 2>/dev/null | grep -q 'running'; then
    vagrant ssh backend-1 -c "sudo systemctl start restic-backup-backend_master.service" 2>/dev/null || true
    for _ in $(seq 1 30); do
      if vagrant ssh backend-1 -c "sudo tail -1 /var/log/restic_backup_master.log" 2>/dev/null \
        | grep -qE 'snapshot|saved|unchanged'; then
        echo "Restic backup finished"
        return 0
      fi
      sleep 2
    done
    echo "WARN: Restic backup may still be running; continuing"
  fi
}

ha_cleanup_test_posts

# --- Phase A: halt backend-1 ---
log "Step 1: halt backend-1"
vagrant halt backend-1

log "Step 2: add post #1"
ha_wait_after_failover
ha_add_post "HA Test Post 1" "Тест #1 после halt backend-1"

log "Step 3: up backend-1"
vagrant up backend-1
ha_wait_site
ha_trigger_db_sync

log "Step 4: check post #1"
ha_wait_posts 24 "HA Test Post 1"
ha_db_titles

# --- Phase B: halt backend-2 ---
log "Step 5: halt backend-2"
vagrant halt backend-2

log "Step 6: add post #2"
ha_wait_after_failover
ha_add_post "HA Test Post 2" "Тест #2 после halt backend-2"

log "Step 7: up backend-2"
vagrant up backend-2
ha_wait_site
ha_trigger_db_sync

log "Step 8: check posts #1 and #2"
ha_wait_posts 24 "HA Test Post 1" "HA Test Post 2"
ha_db_titles

# --- Phase C: destroy backend-1 ---
log "Step 9: destroy backend-1"
vagrant destroy -f backend-1

log "Step 10: check posts #1 and #2"
ha_wait_after_failover
ha_wait_posts 12 "HA Test Post 1" "HA Test Post 2"

log "Step 11: add post #3"
ha_add_post "HA Test Post 3" "Тест #3 при одном backend-2"

log "Step 12: up backend-1 + provision logging"
vagrant up backend-1
vagrant provision logging
ha_wait_site
ha_trigger_db_sync
sleep 10
ha_repl_status

log "Step 13: check posts #1-#3"
ha_wait_posts 24 "HA Test Post 1" "HA Test Post 2" "HA Test Post 3"
ha_db_titles

# --- Phase D: destroy backend-2 ---
log "Step 14: destroy backend-2"
vagrant destroy -f backend-2

log "Step 15: check posts #1-#3"
ha_wait_after_failover
ha_wait_posts 12 "HA Test Post 1" "HA Test Post 2" "HA Test Post 3"

log "Step 16: add post #4"
ha_add_post "HA Test Post 4" "Тест #4 при одном backend-1"

log "Step 17: up backend-2 + provision logging"
vagrant up backend-2
vagrant provision logging
ha_wait_site
ha_trigger_db_sync
sleep 10
ha_repl_status

log "Step 18: check all four posts"
ha_wait_posts 24 "HA Test Post 1" "HA Test Post 2" "HA Test Post 3" "HA Test Post 4"
ha_db_titles

# --- Phase E: destroy both backends (восстановление из Restic) ---
ha_trigger_restic_backup

log "Step 19: destroy backend-1 and backend-2"
vagrant destroy -f backend-1 backend-2

log "Step 20: up backend-1, backend-2 + provision"
vagrant up backend-1
vagrant up backend-2
vagrant provision
ha_wait_site
sleep 15
ha_trigger_db_sync
ha_repl_status

log "Step 21: check all four posts after Restic/peer restore"
ha_wait_posts 36 "HA Test Post 1" "HA Test Post 2" "HA Test Post 3" "HA Test Post 4"
ha_db_titles

log "Final: vagrant status"
vagrant status

log "HA posts test completed successfully (21 steps)"
