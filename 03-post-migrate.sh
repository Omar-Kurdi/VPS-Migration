#!/usr/bin/env bash
# ============================================================================
# 03-post-migrate.sh
#
# Run this ON THE NEW VPS (as root, or with sudo), AFTER 02-migrate.sh has
# installed the packages and copied files over from the old VPS.
#
# It recreates non-system accounts with matching UIDs, applies kernel
# networking settings, reloads systemd, enables services whose config is
# present, reports anything copied-but-not-running, hunts down the old
# server's IP in the copied configs, and prints a checklist for the things
# that genuinely need a human decision (DNS, TLS, firewall, WireGuard peers).
#
# It deliberately does NOT:
#   - install packages (02-migrate.sh does that first, by design)
#   - enable ufw (doing that wrong over SSH locks you out permanently)
#   - import databases (silently overwriting a database is unrecoverable)
# Those are printed as commands for you to run deliberately.
#
# Usage:
#   sudo bash 03-post-migrate.sh
# ============================================================================
set -uo pipefail

STATE_DIR="/root/vps-migration"
DUMP_DIR="/var/tmp/vps-migration-dumps"
REVIEW_DIR="/root/vps-migration-review"

OLD_IP=""
OLD_HOSTNAME=""
# shellcheck source=/dev/null
[ -f "$STATE_DIR/meta.env" ] && source "$STATE_DIR/meta.env"

echo "=== 1. Checking the package sync actually happened ==="
if [ -f /var/lib/vps-migration/packages-synced ]; then
  echo "  packages synced at $(cat /var/lib/vps-migration/packages-synced)"
elif [ -f "$STATE_DIR/pkgs.install.list" ]; then
  awk '{print $1}' "$STATE_DIR/pkgs.install.list" | sort -u > /tmp/.vpsm-want.$$
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sed 's/:.*//' | sort -u > /tmp/.vpsm-have.$$
  missing="$(comm -23 /tmp/.vpsm-want.$$ /tmp/.vpsm-have.$$ | wc -l)"
  rm -f /tmp/.vpsm-want.$$ /tmp/.vpsm-have.$$
  echo "  !! no package-sync marker found; $missing packages from the old box are not installed here."
  echo "  !! Run 02-migrate.sh on the OLD box first - it installs packages BEFORE"
  echo "  !! copying configs, so that dpkg never has to guess what to do with a"
  echo "  !! config file it has no record of. Installing now would risk your"
  echo "  !! copied configs being replaced by package defaults."
else
  echo "  no package list found - was 02-migrate.sh run against this box?"
fi

echo
echo "=== 2. Recreating non-system accounts with matching UID/GID ==="
# rsync -a preserved numeric ownership. If the old box's deploy user was uid
# 1001 and nothing here holds 1001, those files are ownerless; if something
# else holds 1001, they silently belong to the wrong account.
if [ -f "$STATE_DIR/users.list" ]; then
  while IFS=: read -r uname uid gid uhome ushell; do
    [ -n "${uname:-}" ] || continue
    if id -u "$uname" >/dev/null 2>&1; then
      cur_uid="$(id -u "$uname")"
      if [ "$cur_uid" != "$uid" ]; then
        echo "  !! '$uname' exists here as uid $cur_uid but was uid $uid on the old box."
        echo "     Files copied from the old box will show the wrong owner. Fix by hand."
      else
        echo "  ok: $uname ($uid)"
      fi
      continue
    fi
    holder="$(getent passwd "$uid" | cut -d: -f1)"
    if [ -n "$holder" ]; then
      echo "  !! uid $uid (wanted by '$uname') is already '$holder' on this box - resolve by hand."
      continue
    fi
    getent group "$gid" >/dev/null 2>&1 || groupadd -g "$gid" "$uname" 2>/dev/null
    if useradd -u "$uid" -g "$gid" -d "$uhome" -s "$ushell" -M "$uname" 2>/dev/null; then
      passwd -l "$uname" >/dev/null 2>&1
      echo "  created $uname (uid $uid, gid $gid, password locked)"
    else
      echo "  !! could not create $uname - create it by hand with uid $uid / gid $gid"
    fi
  done < "$STATE_DIR/users.list"
  echo "  NOTE: accounts are created with the password locked. They log in via the"
  echo "  SSH keys in their home directory, which only moved if COPY_HOME_DIRS=yes."
else
  echo "  no users.list found - skipping"
fi

echo
echo "=== 3. Permissions on copied files ==="
# No blanket chown here. rsync -a already reproduced the old box's ownership
# correctly; a recursive chown would throw that away and break anything not
# owned by the web user (git checkouts, upload dirs, per-site deploy users).
# Instead: report anything that ended up genuinely ownerless.
if [ -d /etc/wireguard ]; then
  chmod 700 /etc/wireguard
  chmod 600 /etc/wireguard/*.conf 2>/dev/null
  echo "  /etc/wireguard locked down to 700/600"
fi
if [ -d /etc/letsencrypt ]; then
  # Strip world access only. The original blanket "go-rwx" also stripped GROUP
  # access, which silently breaks the common setup where php-fpm or another
  # non-root service reads a cert through a group - and a broken TLS handshake
  # three days later is not traceable back to a chmod nobody logged.
  changed="$(chmod -Rc o-rwx /etc/letsencrypt/archive /etc/letsencrypt/live 2>/dev/null | wc -l)"
  echo "  /etc/letsencrypt: removed world access from $changed path(s); group access left as-is"
fi
orphans="$(find /var/www /srv /opt /home -xdev \( -nouser -o -nogroup \) -printf '%u:%g %p\n' 2>/dev/null | head -20)"
if [ -n "$orphans" ]; then
  echo "  !! files owned by a UID/GID that doesn't exist on this box:"
  echo "$orphans" | sed 's/^/       /'
  echo "     Fix step 2 above rather than chown-ing these to www-data - the"
  echo "     numeric owner is the evidence of which account they belong to."
else
  echo "  no ownerless files under /var/www /srv /opt /home"
fi

echo
echo "=== 4. Applying kernel networking settings ==="
if sysctl --system >/dev/null 2>&1; then
  echo "  sysctl --system applied"
  echo "  net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)"
  if [ -d /etc/wireguard ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
    echo "  !! WireGuard config is present but ip_forward is 0. Peers will connect"
    echo "  !! and handshake, and no traffic will route. Set net.ipv4.ip_forward=1"
    echo "  !! in /etc/sysctl.d/99-wireguard.conf and re-run 'sysctl --system'."
  fi
else
  echo "  !! sysctl --system failed"
fi

echo
echo "=== 5. Reloading systemd and enabling services ==="
systemctl daemon-reload
echo "  daemon-reload done (units copied into /etc/systemd/system are now visible)"

enable_if_present() {
  local unit="$1"
  if systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^${unit}"; then
    systemctl enable --now "$unit" 2>&1 | sed 's/^/  /'
  fi
}

if command -v nginx >/dev/null && [ -f /etc/nginx/nginx.conf ]; then
  if nginx -t; then enable_if_present nginx.service; else echo "  !! nginx config test failed - not starting it"; fi
fi
if command -v apache2ctl >/dev/null; then
  if apache2ctl configtest; then enable_if_present apache2.service; else echo "  !! apache config test failed - not starting it"; fi
fi
command -v squid >/dev/null && { squid -k parse >/dev/null 2>&1 || echo "  !! squid config parse failed"; enable_if_present squid.service; }
command -v fail2ban-client >/dev/null && enable_if_present fail2ban.service
for u in /lib/systemd/system/php*-fpm.service /usr/lib/systemd/system/php*-fpm.service; do
  [ -e "$u" ] && enable_if_present "$(basename "$u")"
done

if [ -d /etc/wireguard ]; then
  for conf in /etc/wireguard/*.conf; do
    [ -e "$conf" ] || continue
    iface="$(basename "$conf" .conf)"
    echo "  enabling wg-quick@$iface"
    systemctl enable --now "wg-quick@$iface" 2>&1 | sed 's/^/    /'
  done
fi

# Certbot's renewal is a timer, and enabling it is easy to forget until a cert
# expires 60 days from now. Snap-installed certbot uses its own timer.
if command -v certbot >/dev/null; then
  enable_if_present certbot.timer
  systemctl list-unit-files --no-pager 2>/dev/null | grep -q '^snap.certbot.renew.timer' \
    && systemctl enable --now snap.certbot.renew.timer 2>&1 | sed 's/^/  /'
elif [ -d /etc/letsencrypt ]; then
  echo "  !! /etc/letsencrypt was copied but certbot is NOT installed here."
  echo "  !! If it was a snap on the old box the package list didn't carry it:"
  echo "  !!   snap install --classic certbot && ln -s /snap/bin/certbot /usr/bin/certbot"
fi

echo
echo "=== 6. Custom units that were copied but are NOT enabled ==="
echo "(these are the 'tools you forgot about' - copied, invisible until reboot)"
found_unenabled="no"
for f in /etc/systemd/system/*.service; do
  [ -e "$f" ] || continue
  unit="$(basename "$f")"
  state="$(systemctl is-enabled "$unit" 2>/dev/null)"
  case "$state" in
    enabled|static|generated|indirect|alias) ;;
    masked)
      # A masked unit is a symlink to /dev/null that rsync reproduced from the
      # old box. The package install in 02 may have enabled this service; the
      # mask then silently overrides that, and "systemctl enable" reports
      # success while the service stays dead. Never report this as fine.
      echo "  $unit  [MASKED - copied from the old box, will not start]"
      echo "      still wanted? systemctl unmask $unit && systemctl enable --now $unit"
      found_unenabled="yes" ;;
    *) echo "  $unit  [$state]  - enable with: systemctl enable --now $unit"; found_unenabled="yes" ;;
  esac
done
[ "$found_unenabled" = "no" ] && echo "  none"

echo
echo "=== 7. Restoring cron ==="
if [ -d /var/spool/cron/crontabs ]; then
  chown root:crontab /var/spool/cron/crontabs 2>/dev/null
  chmod 1730 /var/spool/cron/crontabs 2>/dev/null
  for f in /var/spool/cron/crontabs/*; do
    [ -e "$f" ] || continue
    u="$(basename "$f")"
    if id -u "$u" >/dev/null 2>&1; then
      chown "$u":crontab "$f" 2>/dev/null
      chmod 600 "$f" 2>/dev/null
    else
      echo "  !! crontab for '$u' copied but that account doesn't exist here - cron will ignore it"
    fi
  done
  systemctl enable --now cron 2>&1 | sed 's/^/  /'
fi

echo
echo "=== 8. Database dumps ==="
# Deliberately not imported. There is one dump per database (02-migrate.sh
# overwrites rather than accumulating), so these commands are unambiguous -
# but running them against a database that already has data is not reversible.
if [ -d "$DUMP_DIR" ] && ls "$DUMP_DIR"/*.sql >/dev/null 2>&1; then
  [ -f "$DUMP_DIR/dumped-at.txt" ] && echo "  dumps taken at $(cat "$DUMP_DIR/dumped-at.txt")"
  echo "  NOT imported automatically. Run these yourself once you're happy:"
  for f in "$DUMP_DIR"/mysql-*.sql; do
    [ -e "$f" ] || continue
    db="$(basename "$f" .sql | sed -E 's/^mysql-//')"
    echo "    mysql -e \"CREATE DATABASE IF NOT EXISTS \\\`$db\\\`;\" && mysql \"$db\" < \"$f\""
  done
  [ -e "$DUMP_DIR/postgres-all.sql" ] && echo "    sudo -u postgres psql -f \"$DUMP_DIR/postgres-all.sql\""
else
  echo "  no dumps found in $DUMP_DIR."
  if command -v mysqld >/dev/null || command -v postgres >/dev/null; then
    echo "  !! But a database server IS installed on this box, which means the old box"
    echo "  !! probably had data that has not come across. Check 02-migrate.sh's PHASE 4"
    echo "  !! output on the old VPS - it says why it did not dump - and fix it BEFORE"
    echo "  !! decommissioning that box."
  else
    echo "  No database server here either, so there was most likely nothing to migrate."
  fi
fi

echo
echo "=== 9. Hunting the old server's IP in the copied configs ==="
if [ -n "$OLD_IP" ]; then
  echo "  Old IP: $OLD_IP  (old hostname: ${OLD_HOSTNAME:-unknown})"
  hits="$(grep -rIn --exclude-dir=letsencrypt --exclude-dir=.git "$OLD_IP" /etc /usr/local /root /opt 2>/dev/null | grep -v "^$STATE_DIR" | head -40)"
  if [ -n "$hits" ]; then
    echo "  Every line below still points at the machine you are migrating away from:"
    echo "$hits" | sed 's/^/    /'
    echo "  (nginx listen/proxy_pass, squid ACLs, fail2ban ignoreip, wireguard"
    echo "   Address, monitoring agents - all hide old IPs in plain sight)"
  else
    echo "  No references found. Good."
  fi
else
  echo "  OLD_IP unknown (no meta.env, and none set in migrate.conf on the old box)."
  echo "  Run by hand:  grep -rIn '<old.ip>' /etc /usr/local /root /opt"
fi

if [ -d "$REVIEW_DIR" ]; then
  echo
  echo "=== 10. Files staged for manual review (NOT applied) ==="
  find "$REVIEW_DIR" -type f 2>/dev/null | sed 's/^/  /'
  echo "  The SSH config is here rather than in /etc/ssh on purpose: applying the"
  echo "  old box's sshd_config wouldn't break your current session, it would break"
  echo "  the next reboot. Diff it in, don't copy it in:"
  echo "    diff -u /etc/ssh/sshd_config $REVIEW_DIR/etc/ssh/sshd_config"
fi

echo
echo "============================================================"
echo " MANUAL CHECKLIST - do these before you trust this VPS live"
echo "============================================================"
cat <<'EOF'

[ ] TEST BEFORE DNS CUTOVER
    curl -H "Host: yourdomain.com" http://<new-vps-ip>/
    (repeat for each site/domain; confirms nginx/apache is serving the
    right content before you touch DNS)

[ ] RUN 04-verify.sh
    It diffs this box's listening ports and enabled services against the
    snapshot 01-discover.sh took on the old one. Anything in the "only on
    the old box" column is something you haven't migrated yet.

[ ] TLS CERTIFICATES
    The copied certs will serve HTTPS immediately, but renewal validates
    against whatever DNS currently points at - so it can't work until
    after cutover. Once DNS points here:
      certbot renew --dry-run
      systemctl list-timers | grep -i certbot
    Confirm the timer is actually scheduled. Don't wait for expiry to
    find out it isn't.

[ ] WIREGUARD - PUBLIC ENDPOINT CHANGED
    The server's public IP is different now. Every WireGuard *client*
    config has an "Endpoint = old.ip:port" line that must be updated to
    the new IP (or better, a DNS name you control, so this never bites
    you again). The server-side keys/configs copied over unchanged, so
    peers will connect fine once their Endpoint is fixed.
    Also confirm: ip_forward is 1, and any PostUp/PostDown MASQUERADE
    rule names the interface this box actually has (check `ip -brief a` -
    it is not always eth0).

[ ] SSH CONFIG
    Merge /root/vps-migration-review/etc/ssh/* into this box's config by
    hand, then, keeping your current session open, restart sshd and prove
    a SECOND session connects before you close the first.

[ ] FIREWALL (do this carefully - don't lock yourself out)
    Keep your current SSH session open. In a SECOND terminal/session,
    verify you can still reach the box, then:
      ufw allow OpenSSH        # or your custom SSH port
      ufw allow 'Nginx Full'   # or whatever ports your services need
      ufw enable
    Only close your first session after confirming the second one still
    works through ufw.

[ ] DNS CUTOVER
    Lower your DNS TTLs a day beforehand if possible, then point A/AAAA
    records at the new VPS's IP. Keep the old VPS running until you've
    confirmed traffic has fully shifted (check nginx/apache access logs
    on both).

[ ] DECOMMISSION OLD VPS
    Only after: sites verified, WireGuard peers reconnecting, DNS fully
    propagated (check with a tool that queries multiple resolvers), and
    at least a few days of normal operation on the new VPS.
EOF
