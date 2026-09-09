#!/usr/bin/env bash
# ============================================================================
# 04-verify.sh
#
# Run this ON THE NEW VPS (as root, or with sudo), after 03-post-migrate.sh
# and after you've worked through its checklist - but BEFORE you decommission
# the old box.
#
# 01-discover.sh's whole reason for existing is "what am I running that I've
# forgotten about?". This closes that loop: it takes the same snapshot here
# and diffs it against the old box's, so "did everything come across?" has an
# answer instead of a feeling.
#
# Read-only. It changes nothing.
#
# Usage:
#   sudo bash 04-verify.sh
# ============================================================================
set -uo pipefail

# Every comparison below is a `comm` between a file sorted by 01-discover.sh on
# the OLD box and one sorted here. Different locales sort differently, and comm
# fed unsorted input reports nonsense rather than failing. Pin the collation and
# re-sort both sides locally so the diff can't depend on either box's settings.
export LC_ALL=C

STATE_DIR="/root/vps-migration"
WORK="$STATE_DIR/verify"
REPORT="$STATE_DIR/verify-report.txt"

OLD_IP=""
OLD_HOSTNAME=""
OLD_KERNEL=""
# shellcheck source=/dev/null
[ -f "$STATE_DIR/meta.env" ] && source "$STATE_DIR/meta.env"

for f in ports.list units-enabled.list units-running.list pkgs.list; do
  if [ ! -f "$STATE_DIR/$f" ]; then
    echo "Missing $STATE_DIR/$f"
    echo
    echo "These snapshots are written by 01-discover.sh on the OLD box and carried"
    echo "here by 02-migrate.sh. Run both, then come back."
    exit 1
  fi
done

mkdir -p "$WORK"
: > "$REPORT"
say() { echo "$@" | tee -a "$REPORT"; }

# Units that differ between two Ubuntu images for reasons that have nothing to
# do with your migration: the provider's guest agent, cloud-init, the kernel.
# Filtering them is the difference between a report you read and one you skim.
# ssh.service is excluded because Ubuntu 24.04 socket-activates sshd: the
# service shows as not-running on a perfectly healthy box while ssh.socket
# handles connections. The ports comparison above already proves sshd is
# listening, so the unit-level entry is pure noise.
NOISE='^(ssh\.service|ssh@|cloud-init|cloud-config|cloud-final|walinuxagent|amazon-ssm-agent|google-(guest|osconfig|shutdown|startup|oslogin)|hv-|open-vm-tools|qemu-guest-agent|getty@|serial-getty@|user@|systemd-|e2scrub|blk-availability|lvm2-|dm-event|multipathd|open-iscsi|iscsid|finalrd|plymouth|kmod-static-nodes|setvtrgb|console-setup|keyboard-setup)'

# ---------------------------------------------------------------------------
# Take the same snapshot here that 01-discover.sh took there.
# ---------------------------------------------------------------------------
ss -tuln 2>/dev/null | tail -n +2 | awk '{print $1, $5}' | sort -u > "$WORK/ports.list"
systemctl list-unit-files --state=enabled --type=service --no-pager --plain 2>/dev/null \
  | awk '$1 ~ /\.service$/ {print $1}' | sort -u > "$WORK/units-enabled.list"
systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null \
  | awk '$1 ~ /\.service$/ {print $1}' | sort -u > "$WORK/units-running.list"
dpkg --get-selections | grep -v deinstall > "$WORK/pkgs.list"

say "============================================================"
say " MIGRATION VERIFICATION"
say " old: ${OLD_HOSTNAME:-unknown} (${OLD_IP:-ip unknown})"
say " new: $(hostname) ($(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}'))"
say " generated: $(date -Is)"
say "============================================================"

# --- Listening ports -------------------------------------------------------
# Compared as proto+port. Bind ADDRESSES legitimately differ (the old box's
# public IP doesn't exist here), so comparing the full address would flag
# every service as changed and tell you nothing.
extract_ports() { awk '{n=$2; sub(/.*:/,"",n); if (n ~ /^[0-9]+$/) print $1" "n}' "$1" | sort -u; }
extract_ports "$STATE_DIR/ports.list" > "$WORK/ports.old.norm"
extract_ports "$WORK/ports.list"      > "$WORK/ports.new.norm"

# UDP sockets in the ephemeral range (32768-60999) are client-side sockets
# picked at random on every restart - squid's DNS resolver is the usual source.
# They never match across two boxes and are not services, so comparing them
# strictly produced a permanent "NOT CLEAN" verdict driven entirely by noise.
# They are still listed, just not counted.
is_service_port() { awk '$1=="tcp" || ($1=="udp" && $2+0 < 32768)'; }
is_ephemeral()    { awk '$1=="udp" && $2+0 >= 32768'; }

is_service_port < "$WORK/ports.old.norm" > "$WORK/ports.old.svc"
is_service_port < "$WORK/ports.new.norm" > "$WORK/ports.new.svc"

say ""
say "--- LISTENING PORTS: on the OLD box but not here -----------"
say "    (each line is a service that hasn't been brought up yet)"
missing_ports="$(comm -23 "$WORK/ports.old.svc" "$WORK/ports.new.svc")"
if [ -n "$missing_ports" ]; then
  echo "$missing_ports" | sed 's/^/    /' | tee -a "$REPORT"
else
  say "    none - every port that was serving there is serving here"
fi

say ""
say "--- LISTENING PORTS: here but not on the old box ------------"
say "    (usually harmless base-image services; look for surprises)"
extra_ports="$(comm -13 "$WORK/ports.old.svc" "$WORK/ports.new.svc")"
[ -n "$extra_ports" ] && echo "$extra_ports" | sed 's/^/    /' | tee -a "$REPORT" || say "    none"

eph_old="$(is_ephemeral < "$WORK/ports.old.norm" | wc -l)"
eph_new="$(is_ephemeral < "$WORK/ports.new.norm" | wc -l)"
if [ "$eph_old" -gt 0 ] || [ "$eph_new" -gt 0 ]; then
  say ""
  say "--- ephemeral UDP sockets (informational, not a problem) ---"
  say "    old box had $eph_old, this box has $eph_new. These are randomly"
  say "    numbered client sockets (squid's DNS resolver, etc.) that change on"
  say "    every restart, so they never match and are not counted as missing."
fi

# --- Enabled services ------------------------------------------------------
say ""
say "--- ENABLED SERVICES: on the OLD box but not here ----------"
say "    (a WireGuard port can land in the ephemeral range above, so the"
say "     service-level check below is what actually proves it came up)"
say "    (these will not start on boot - the classic 'forgot about it' case)"
grep -Ev "$NOISE" "$STATE_DIR/units-enabled.list" | sort -u > "$WORK/ue.old"
grep -Ev "$NOISE" "$WORK/units-enabled.list"      | sort -u > "$WORK/ue.new"
missing_units="$(comm -23 "$WORK/ue.old" "$WORK/ue.new")"
if [ -n "$missing_units" ]; then
  echo "$missing_units" | sed 's/^/    /' | tee -a "$REPORT"
  say "    enable one with: systemctl enable --now <unit>"
else
  say "    none"
fi

# --- Running services ------------------------------------------------------
say ""
say "--- RUNNING SERVICES: on the OLD box but not running here ---"
grep -Ev "$NOISE" "$STATE_DIR/units-running.list" | sort -u > "$WORK/ur.old"
grep -Ev "$NOISE" "$WORK/units-running.list"      | sort -u > "$WORK/ur.new"
missing_running="$(comm -23 "$WORK/ur.old" "$WORK/ur.new")"
if [ -n "$missing_running" ]; then
  echo "$missing_running" | sed 's/^/    /' | tee -a "$REPORT"
  say "    check why with: systemctl status <unit>"
else
  say "    none"
fi

# --- Failed units ----------------------------------------------------------
say ""
say "--- UNITS IN A FAILED STATE ON THIS BOX --------------------"
failed="$(systemctl list-units --state=failed --no-pager --plain 2>/dev/null | awk '$1 ~ /\./ {print $1}')"
[ -n "$failed" ] && echo "$failed" | sed 's/^/    /' | tee -a "$REPORT" || say "    none"

# --- Packages --------------------------------------------------------------
say ""
say "--- PACKAGES on the OLD box but not installed here ---------"
PKG_NOISE='^(linux-(image|headers|modules|modules-extra|tools|cloud-tools)-|linux-(generic|virtual|kvm|aws|gcp|azure|oracle)|grub|shim|cloud-init|cloud-initramfs|walinuxagent|amazon-ssm-agent|google-(guest|compute|osconfig)|open-vm-tools|virtualbox-guest|hyperv-daemons|qemu-guest-agent)'
awk '{print $1}' "$STATE_DIR/pkgs.list" | grep -Ev "$PKG_NOISE" | sort -u > "$WORK/pkgs.old.norm"
awk '{print $1}' "$WORK/pkgs.list"      | sort -u > "$WORK/pkgs.new.norm"
missing_pkgs="$(comm -23 "$WORK/pkgs.old.norm" "$WORK/pkgs.new.norm")"
if [ -n "$missing_pkgs" ]; then
  say "    $(echo "$missing_pkgs" | wc -l) missing (kernel/cloud packages already excluded):"
  echo "$missing_pkgs" | head -40 | sed 's/^/    /' | tee -a "$REPORT"
  [ "$(echo "$missing_pkgs" | wc -l)" -gt 40 ] && say "    ... (full list: $WORK/pkgs.old.norm vs $WORK/pkgs.new.norm)"
else
  say "    none"
fi

# --- Snaps -----------------------------------------------------------------
if [ -f "$STATE_DIR/snaps.list" ]; then
  say ""
  say "--- SNAPS on the old box (never migrated automatically) ----"
  tail -n +2 "$STATE_DIR/snaps.list" | awk '{print $1}' | while read -r s; do
    [ -n "$s" ] || continue
    if command -v snap >/dev/null && snap list "$s" >/dev/null 2>&1; then
      say "    ok      $s"
    else
      say "    MISSING $s   -> snap install $s"
    fi
  done
fi

# --- npm globals -----------------------------------------------------------
if [ -s "$STATE_DIR/npm-global.list" ]; then
  say ""
  say "--- GLOBAL npm PACKAGES from the old box --------------------"
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    if command -v npm >/dev/null && npm ls -g --depth=0 "$pkg" >/dev/null 2>&1; then
      say "    ok      $pkg"
    else
      say "    MISSING $pkg   -> npm install -g $pkg"
    fi
  done < "$STATE_DIR/npm-global.list"
fi

# --- Cron ------------------------------------------------------------------
say ""
say "--- CRONTABS present but owned by a missing account ---------"
cron_orphans="no"
for f in /var/spool/cron/crontabs/*; do
  [ -e "$f" ] || continue
  u="$(basename "$f")"
  id -u "$u" >/dev/null 2>&1 || { say "    $u (crontab copied, account missing - cron ignores it)"; cron_orphans="yes"; }
done
[ "$cron_orphans" = "no" ] && say "    none"

say ""
say "============================================================"
if [ -n "$missing_ports$missing_units$missing_running$missing_pkgs$failed" ]; then
  say " NOT CLEAN. Work through the sections above before you"
  say " decommission ${OLD_HOSTNAME:-the old box}."
else
  say " Clean: ports, services and packages all match the old box."
  say " That covers what was RUNNING. It does not prove your sites"
  say " serve the right content or that TLS renews - test those by"
  say " hand from 03-post-migrate.sh's checklist."
fi
say "============================================================"
say ""
say "Report saved to $REPORT"
