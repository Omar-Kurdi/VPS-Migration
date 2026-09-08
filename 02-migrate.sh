#!/usr/bin/env bash
# ============================================================================
# 02-migrate.sh
#
# Run this ON THE OLD VPS (as root, or with sudo -E), AFTER 01-discover.sh
# and after you've reviewed inventory.txt and filled in migrate.conf.
#
# It rsyncs the config/data that matters over SSH straight to the new VPS.
# Safe to re-run - rsync only copies what changed, so run it once now to do
# the bulk copy, then run it again right before cutover to pick up anything
# that changed in between.
#
# Usage:
#   sudo bash 02-migrate.sh
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/migrate.conf"

if [ ! -f "$CONF" ]; then
  echo "Missing $CONF"
  echo "Copy migrate.conf.example to migrate.conf and fill in NEW_HOST etc. first."
  exit 1
fi
# shellcheck source=/dev/null
source "$CONF"

: "${NEW_HOST:?Set NEW_HOST in migrate.conf}"
NEW_USER="${NEW_USER:-root}"
NEW_SSH_PORT="${NEW_SSH_PORT:-22}"
NEW_SSH_KEY="${NEW_SSH_KEY:-}"
COPY_HOME_DIRS="${COPY_HOME_DIRS:-no}"
DUMP_MYSQL="${DUMP_MYSQL:-no}"
DUMP_POSTGRES="${DUMP_POSTGRES:-no}"
EXTRA_PATHS=("${EXTRA_PATHS[@]:-}")

SSH_OPTS=(-p "$NEW_SSH_PORT" -o StrictHostKeyChecking=accept-new)
[ -n "$NEW_SSH_KEY" ] && SSH_OPTS+=(-i "$NEW_SSH_KEY")
RSYNC_SSH="ssh ${SSH_OPTS[*]}"

echo "Testing SSH to $NEW_USER@$NEW_HOST:$NEW_SSH_PORT ..."
if ! ssh "${SSH_OPTS[@]}" "$NEW_USER@$NEW_HOST" "echo ok" >/dev/null 2>&1; then
  echo "Could not SSH into the new VPS. Fix connectivity/keys before continuing."
  echo "Tip from the old VPS: ssh-copy-id -p $NEW_SSH_PORT -i <key>.pub $NEW_USER@$NEW_HOST"
  exit 1
fi
echo "SSH OK."

copy() {
  local src="$1"
  if [ ! -e "$src" ]; then
    echo "  (skip, not present) $src"
    return
  fi
  echo "==> rsyncing $src"
  rsync -avzR --relative -e "$RSYNC_SSH" "$src" "$NEW_USER@$NEW_HOST:/" \
    || echo "  !! rsync of $src reported errors - check output above"
}

echo
echo "=== Web servers ==="
copy /etc/nginx
copy /etc/apache2
copy /var/www
for d in /home/*/public_html; do copy "$d"; done
copy /srv

echo
echo "=== TLS certificates ==="
copy /etc/letsencrypt

echo
echo "=== WireGuard ==="
copy /etc/wireguard

echo
echo "=== Squid ==="
copy /etc/squid

echo
echo "=== Firewall ==="
copy /etc/ufw
copy /etc/iptables

echo
echo "=== Cron ==="
copy /var/spool/cron/crontabs
copy /etc/cron.d
copy /etc/cron.daily
copy /etc/cron.hourly
copy /etc/cron.weekly

echo
echo "=== SSH server config (review before applying - do NOT blindly overwrite) ==="
copy /etc/ssh/sshd_config

echo
echo "=== Misc /etc (fail2ban, logrotate, systemd overrides, unattended-upgrades) ==="
copy /etc/fail2ban
copy /etc/logrotate.d
copy /etc/systemd/system
copy /etc/apt/sources.list.d
copy /etc/apt/apt.conf.d

echo
echo "=== Docker (compose files + named volumes, if docker is used) ==="
if command -v docker >/dev/null; then
  find / -maxdepth 4 -iname "docker-compose*.yml" -not -path "*/node_modules/*" 2>/dev/null | while read -r f; do
    copy "$f"
  done
  DOCKER_VOL_ROOT="/var/lib/docker/volumes"
  if [ -d "$DOCKER_VOL_ROOT" ]; then
    echo "  NOTE: not auto-copying $DOCKER_VOL_ROOT (can be huge / contains live DB files)."
    echo "  Stop containers first, then re-run with COPY_HOME_DIRS-style manual rsync if needed:"
    echo "    rsync -avz -e \"$RSYNC_SSH\" $DOCKER_VOL_ROOT/ $NEW_USER@$NEW_HOST:$DOCKER_VOL_ROOT/"
  fi
else
  echo "  docker not installed, skipping"
fi

if [ "$COPY_HOME_DIRS" = "yes" ]; then
  echo
  echo "=== /home (full, as requested by COPY_HOME_DIRS=yes) ==="
  copy /home
fi

echo
echo "=== Your own scripts / custom tools ==="
echo "  (/root, /usr/local/bin, /usr/local/sbin, /opt - copied by default since"
echo "   this is where personal admin scripts like jails.sh usually live)"
copy /root
copy /usr/local/bin
copy /usr/local/sbin
copy /opt

if [ "${#EXTRA_PATHS[@]}" -gt 0 ]; then
  echo
  echo "=== EXTRA_PATHS from migrate.conf ==="
  for p in "${EXTRA_PATHS[@]}"; do
    [ -n "$p" ] && copy "$p"
  done
fi

DUMP_DIR="/root/vps-migration-dumps"
mkdir -p "$DUMP_DIR"

if [ "$DUMP_MYSQL" = "yes" ] && command -v mysqldump >/dev/null; then
  echo
  echo "=== MySQL/MariaDB dump ==="
  ts="$(date +%Y%m%d-%H%M%S)"
  dbs=$(mysql -N -e "SHOW DATABASES;" 2>/dev/null | grep -Ev '^(information_schema|performance_schema|mysql|sys)$')
  for db in $dbs; do
    echo "  dumping $db"
    mysqldump --single-transaction --routines --triggers "$db" > "$DUMP_DIR/mysql-$db-$ts.sql" \
      || echo "  !! dump of $db failed"
  done
  copy "$DUMP_DIR"
fi

if [ "$DUMP_POSTGRES" = "yes" ] && command -v pg_dumpall >/dev/null; then
  echo
  echo "=== PostgreSQL dump (all databases + roles) ==="
  ts="$(date +%Y%m%d-%H%M%S)"
  sudo -u postgres pg_dumpall > "$DUMP_DIR/postgres-all-$ts.sql" \
    || echo "  !! pg_dumpall failed"
  copy "$DUMP_DIR"
fi

echo
echo "=== Package list (for reinstalling equivalent software on the new VPS) ==="
if [ -f "$HOME/vps-migration/pkgs.list" ]; then
  copy "$HOME/vps-migration/pkgs.list"
else
  echo "  pkgs.list not found - did you run 01-discover.sh first? Generating a quick one now."
  dpkg --get-selections | grep -v deinstall > "$HOME/vps-migration/pkgs.list"
  copy "$HOME/vps-migration/pkgs.list"
fi

echo
echo "Done. Files are on $NEW_HOST at the same absolute paths they had here."
echo "Next: log into the NEW VPS and run 03-post-migrate.sh there."
