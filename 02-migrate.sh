#!/usr/bin/env bash
# ============================================================================
# 02-migrate.sh
#
# Run this ON THE OLD VPS (as root, or with sudo), AFTER 01-discover.sh
# and after you've reviewed inventory.txt and filled in migrate.conf.
#
# What it does, in order:
#   1. Copies apt sources AND their signing keys to the new box.
#   2. Installs the old box's packages on the new box, over SSH.
#   3. Only then rsyncs your configs and data across, so your configs land
#      on top of a freshly installed package set and win.
#   4. Optionally dumps and copies databases.
#
# That ordering is deliberate. Copying configs first and installing packages
# afterwards leaves dpkg to decide what to do with config files it has no
# record of - not something to leave to a prompt default mid-migration.
#
# Safe to re-run: rsync only copies what changed, so run it once now for the
# bulk copy, then again right before cutover to pick up anything that moved.
# Set DRY_RUN="yes" in migrate.conf for a no-changes preview.
#
# Usage:
#   sudo bash 02-migrate.sh
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/migrate.conf"
STATE_DIR="/root/vps-migration"
DUMP_DIR="/var/tmp/vps-migration-dumps"
REVIEW_DIR="/root/vps-migration-review"

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
DRY_RUN="${DRY_RUN:-no}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-yes}"
OLD_IP="${OLD_IP:-}"
COPY_HOME_DIRS="${COPY_HOME_DIRS:-no}"
DUMP_MYSQL="${DUMP_MYSQL:-no}"
DUMP_POSTGRES="${DUMP_POSTGRES:-no}"
declare -p EXTRA_PATHS >/dev/null 2>&1 || EXTRA_PATHS=()

SSH_OPTS=(-p "$NEW_SSH_PORT" -o StrictHostKeyChecking=accept-new)
[ -n "$NEW_SSH_KEY" ] && SSH_OPTS+=(-i "$NEW_SSH_KEY")

RSYNC_FLAGS=(-a -v -z -R)
if [ "$DRY_RUN" = "yes" ]; then
  RSYNC_FLAGS+=(--dry-run)
  echo "############################################################"
  echo "# DRY RUN - nothing will be changed on either machine.      #"
  echo "# Package install and database dumps are skipped entirely.  #"
  echo "############################################################"
  echo
fi

remote() { ssh "${SSH_OPTS[@]}" "$NEW_USER@$NEW_HOST" "$@"; }

echo "Testing SSH to $NEW_USER@$NEW_HOST:$NEW_SSH_PORT ..."
if ! remote "echo ok" >/dev/null 2>&1; then
  echo "Could not SSH into the new VPS. Fix connectivity/keys before continuing."
  echo "Tip from the old VPS: ssh-copy-id -p $NEW_SSH_PORT -i <key>.pub $NEW_USER@$NEW_HOST"
  exit 1
fi
echo "SSH OK: $(remote 'hostname; lsb_release -ds 2>/dev/null' | tr '\n' ' ')"

# Copy INTO the matching absolute path on the new box.
copy() {
  local src="$1"; shift
  if [ ! -e "$src" ]; then
    echo "  (skip, not present) $src"
    return
  fi
  echo "==> $src"
  # </dev/null matters: copy() is called from inside `find | while read` loops,
  # and ssh would otherwise consume the loop's remaining input and skip files.
  rsync "${RSYNC_FLAGS[@]}" "$@" -e "ssh ${SSH_OPTS[*]}" "$src" "$NEW_USER@$NEW_HOST:/" </dev/null \
    || echo "  !! rsync of $src reported errors - check output above"
}

# Copy to a review directory on the new box INSTEAD of the live path, for
# files that must not be applied without a human reading them first.
stage() {
  local src="$1"
  if [ ! -e "$src" ]; then
    echo "  (skip, not present) $src"
    return
  fi
  echo "==> $src  ->  $REVIEW_DIR$src  (staged, NOT applied)"
  rsync "${RSYNC_FLAGS[@]}" -e "ssh ${SSH_OPTS[*]}" "$src" "$NEW_USER@$NEW_HOST:$REVIEW_DIR/" </dev/null \
    || echo "  !! rsync of $src reported errors - check output above"
}

# ---------------------------------------------------------------------------
# Build the package list to install on the new box.
#
# Anything tied to THIS box's kernel, bootloader or cloud provider is dropped:
# the new VPS has its own, and pulling the old one's in is at best noise and
# at worst an unbootable machine. Packages left off this list keep whatever
# state they already have on the new box - nothing is removed.
# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR"
if [ ! -f "$STATE_DIR/pkgs.list" ]; then
  echo "pkgs.list not found - did you run 01-discover.sh first? Generating one now."
  dpkg --get-selections | grep -v deinstall > "$STATE_DIR/pkgs.list"
fi

EXCLUDE_RE='^(linux-(image|headers|modules|modules-extra|tools|cloud-tools)-|linux-(generic|virtual|kvm|aws|gcp|azure|oracle)|grub|shim|cloud-init$|cloud-initramfs|walinuxagent|amazon-ssm-agent|google-(guest|compute|osconfig)|open-vm-tools|virtualbox-guest|hyperv-daemons|qemu-guest-agent)'
grep -Ev "$EXCLUDE_RE" "$STATE_DIR/pkgs.list" > "$STATE_DIR/pkgs.install.list"
grep -E  "$EXCLUDE_RE" "$STATE_DIR/pkgs.list" > "$STATE_DIR/pkgs.skipped.list"
echo "Package list: $(wc -l < "$STATE_DIR/pkgs.install.list") to install, \
$(wc -l < "$STATE_DIR/pkgs.skipped.list") skipped as kernel/cloud-provider specific."

# meta.env travels with STATE_DIR and is how 03/04 on the NEW box learn the old
# box's IP - they can't read migrate.conf, it lives here. 01-discover.sh
# auto-detects the IP; an explicit OLD_IP in migrate.conf wins (auto-detection
# gets it wrong when the box sits behind provider NAT).
if [ ! -f "$STATE_DIR/meta.env" ]; then
  {
    echo "OLD_HOSTNAME=\"$(hostname)\""
    echo "OLD_IP=\"${OLD_IP:-}\""
    echo "OLD_OS=\"$(lsb_release -ds 2>/dev/null || echo unknown)\""
    echo "OLD_KERNEL=\"$(uname -r)\""
  } > "$STATE_DIR/meta.env"
elif [ -n "${OLD_IP:-}" ]; then
  sed -i "s|^OLD_IP=.*|OLD_IP=\"$OLD_IP\"|" "$STATE_DIR/meta.env"
fi
# shellcheck source=/dev/null
source "$STATE_DIR/meta.env"
if [ -z "${OLD_IP:-}" ]; then
  echo "!! This box's public IP could not be detected and OLD_IP is unset in migrate.conf."
  echo "!! 03-post-migrate.sh won't be able to find the old IP hardcoded in your"
  echo "!! copied configs. Set OLD_IP in migrate.conf and re-run to get that check."
else
  echo "Old IP recorded as $OLD_IP (03-post-migrate.sh greps the copied configs for it)."
fi

echo
echo "############ PHASE 1: apt sources + signing keys ############"
echo "(sources without their keys means every third-party repo fails NO_PUBKEY"
echo " and the package install quietly half-finishes)"
copy /etc/apt/sources.list
copy /etc/apt/sources.list.d
copy /etc/apt/apt.conf.d
copy /etc/apt/preferences.d
copy /etc/apt/keyrings
copy /etc/apt/trusted.gpg.d
# /usr/share/keyrings holds BOTH distro archive keys (which the new box already
# has, correct for its own release) and hand-placed third-party keys - Docker's
# install docs put theirs here for years. Copying the directory wholesale would
# overwrite the new box's archive keys with this box's, possibly stale ones,
# immediately before phase 2 runs apt-get update. So: copy only the files no
# apt package claims, i.e. the ones somebody put there by hand.
for k in /usr/share/keyrings/*; do
  [ -e "$k" ] || continue
  dpkg -S "$k" >/dev/null 2>&1 && continue
  copy "$k"
done
copy "$STATE_DIR"

echo
echo "############ PHASE 2: install packages on the new box ############"
if [ "$DRY_RUN" = "yes" ]; then
  echo "  (skipped: DRY_RUN=yes)"
elif [ "$INSTALL_PACKAGES" != "yes" ]; then
  echo "  (skipped: INSTALL_PACKAGES=$INSTALL_PACKAGES)"
else
  echo "This runs apt on $NEW_HOST and can take several minutes."
  echo "If your SSH connection is flaky, ctrl-C now and re-run this script"
  echo "inside tmux/screen - a dropped connection mid-apt leaves dpkg wedged."
  echo
  remote 'bash -s' <<'REMOTE_EOF'
set -uo pipefail
LIST=/root/vps-migration/pkgs.install.list
if [ ! -f "$LIST" ]; then
  echo "!! $LIST missing on this box - phase 1 did not complete. Aborting install."
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
echo "--- apt-get update ---"
apt-get update || echo "!! apt-get update reported errors (a repo may be unreachable or unsigned) - continuing"
echo "--- applying package selections ($(wc -l < "$LIST") entries) ---"
dpkg --set-selections < "$LIST"
# --force-confold keeps config files already on disk. On the first run there
# are none, so packages ship their defaults; on later re-runs it protects the
# configs 02-migrate.sh has since copied over.
apt-get -y \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  dselect-upgrade \
  || echo "!! dselect-upgrade reported issues - check 'apt-get -f install' and 'apt list --upgradable' on this box"
mkdir -p /var/lib/vps-migration
date -Is > /var/lib/vps-migration/packages-synced
echo "--- package sync finished ---"
REMOTE_EOF
fi

echo
echo "############ PHASE 3: configs and data ############"

echo
echo "=== Web servers ==="
copy /etc/nginx
copy /etc/apache2
copy /var/www
for d in /home/*/public_html; do copy "$d"; done
copy /srv

echo
echo "=== PHP (FPM pools, php.ini - the sites won't run without these) ==="
copy /etc/php

echo
echo "=== TLS certificates ==="
copy /etc/letsencrypt

echo
echo "=== WireGuard ==="
copy /etc/wireguard

echo
echo "=== Kernel networking settings ==="
echo "(ip_forward lives here; without it WireGuard comes up, peers handshake,"
echo " and nothing routes - the failure that looks exactly like success)"
copy /etc/sysctl.conf
copy /etc/sysctl.d

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
echo "=== Service defaults and misc /etc ==="
# grub excluded: a GRUB_CMDLINE_LINUX written for the old box's disks/console
# does nothing at all until the next reboot, and then does everything at once.
copy /etc/default --exclude=grub --exclude=grub.d
copy /etc/fail2ban
copy /etc/logrotate.d
copy /etc/systemd/system
copy /etc/mysql
copy /etc/postgresql

echo
echo "=== SSH server config - STAGED FOR REVIEW, NOT APPLIED ==="
echo "The old box's sshd_config can contain a Port, an AllowUsers naming an"
echo "account that doesn't exist here yet, or a ListenAddress pinned to the OLD"
echo "public IP. Dropping it in live wouldn't break your current session - it"
echo "would break the next reboot, with nobody watching. Merge it by hand."
stage /etc/ssh/sshd_config
stage /etc/ssh/sshd_config.d

echo
echo "=== Docker (compose files + named volumes, if docker is used) ==="
if command -v docker >/dev/null; then
  find / -maxdepth 4 -iname "docker-compose*.yml" -not -path "*/node_modules/*" 2>/dev/null | while read -r f; do
    copy "$f"
  done
  DOCKER_VOL_ROOT="/var/lib/docker/volumes"
  if [ -d "$DOCKER_VOL_ROOT" ]; then
    echo "  NOTE: not auto-copying $DOCKER_VOL_ROOT (can be huge / contains live DB files)."
    echo "  Stop the containers first, then copy them by hand:"
    echo "    rsync -avz -e \"ssh ${SSH_OPTS[*]}\" $DOCKER_VOL_ROOT/ $NEW_USER@$NEW_HOST:$DOCKER_VOL_ROOT/"
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

echo
echo "############ PHASE 4: databases ############"
if [ "$DRY_RUN" = "yes" ]; then
  echo "  (skipped: DRY_RUN=yes)"
else
  mkdir -p "$DUMP_DIR"
  chmod 700 "$DUMP_DIR"
  did_dump="no"

  if [ "$DUMP_MYSQL" = "yes" ] && command -v mysqldump >/dev/null; then
    echo
    echo "=== MySQL/MariaDB dump ==="
    # One file per database, overwritten each run. Timestamped filenames would
    # pile up across the re-runs this script is designed for, and 03 would then
    # offer you several import commands per database with no hint which is
    # current - the shortest path to restoring a stale dump over a fresh one.
    dbs=$(mysql -N -e "SHOW DATABASES;" 2>/dev/null | grep -Ev '^(information_schema|performance_schema|mysql|sys)$')
    for db in $dbs; do
      echo "  dumping $db"
      if mysqldump --single-transaction --routines --triggers "$db" > "$DUMP_DIR/mysql-$db.sql.part"; then
        mv "$DUMP_DIR/mysql-$db.sql.part" "$DUMP_DIR/mysql-$db.sql"
        did_dump="yes"
      else
        echo "  !! dump of $db failed - leaving the previous dump (if any) in place"
        rm -f "$DUMP_DIR/mysql-$db.sql.part"
      fi
    done
  fi

  if [ "$DUMP_POSTGRES" = "yes" ] && command -v pg_dumpall >/dev/null; then
    echo
    echo "=== PostgreSQL dump (all databases + roles) ==="
    if sudo -u postgres pg_dumpall > "$DUMP_DIR/postgres-all.sql.part"; then
      mv "$DUMP_DIR/postgres-all.sql.part" "$DUMP_DIR/postgres-all.sql"
      did_dump="yes"
    else
      echo "  !! pg_dumpall failed - leaving the previous dump (if any) in place"
      rm -f "$DUMP_DIR/postgres-all.sql.part"
    fi
  fi

  if [ "$did_dump" = "yes" ]; then
    date -Is > "$DUMP_DIR/dumped-at.txt"
    copy "$DUMP_DIR"
  else
    echo "  no dumps taken (DUMP_MYSQL=$DUMP_MYSQL, DUMP_POSTGRES=$DUMP_POSTGRES)"
  fi
fi

echo
if [ "$DRY_RUN" = "yes" ]; then
  echo "DRY RUN complete. Nothing was changed. Set DRY_RUN=\"no\" to do it for real."
else
  echo "Done. Files are on $NEW_HOST at the same absolute paths they had here."
  echo "SSH config was staged to $REVIEW_DIR on the new box for you to merge by hand."
  echo "Next: log into the NEW VPS and run 03-post-migrate.sh there."
fi
