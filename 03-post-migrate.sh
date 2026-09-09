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

echo "=== 1. Verifying the packages are actually installed ==="
# Always check reality, never a marker file. The bug this replaces wrote a
# success marker whenever the install script reached its end - including when
# it had installed nothing at all.
if [ -f "$STATE_DIR/pkgs.install.list" ]; then
  awk '{print $1}' "$STATE_DIR/pkgs.install.list" | sed 's/:.*//' | sort -u > /tmp/.vpsm-want.$$
  dpkg-query -W -f='${binary:Package} ${Status}\n' 2>/dev/null \
    | awk '$NF=="installed"{sub(/:.*/,"",$1); print $1}' | sort -u > /tmp/.vpsm-have.$$
  want="$(wc -l < /tmp/.vpsm-want.$$)"
  missing="$(comm -23 /tmp/.vpsm-want.$$ /tmp/.vpsm-have.$$ | wc -l)"
  if [ "$missing" -eq 0 ]; then
    echo "  all $want packages from the old box are installed here"
  else
    echo "  !! $missing of $want packages from the old box are NOT installed here."
    comm -23 /tmp/.vpsm-want.$$ /tmp/.vpsm-have.$$ | head -20 | sed 's/^/       /'
    [ "$missing" -gt 20 ] && echo "       ... and $((missing - 20)) more"
    echo "  !! Nothing below can start a service whose package is missing. Re-run"
    echo "  !! 02-migrate.sh on the OLD box, and read /var/lib/vps-migration/package-install.log"
    echo "  !! here for why the install did not take."
  fi
  rm -f /tmp/.vpsm-want.$$ /tmp/.vpsm-have.$$
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
echo "=== 4b. WireGuard server identity (not just the client configs) ==="
# "I'll just regenerate the clients" does not work on its own: the common
# wireguard-install.sh keeps the server's public address in /etc/wireguard/params
# and reads it when generating each new client. Copied unchanged, every client
# you create ON THIS BOX is handed the OLD box's Endpoint - the configs look
# freshly generated and point at a server you are about to switch off.
if [ -f /etc/wireguard/params ]; then
  NEW_PUB_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
  NEW_NIC="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
  PARAM_IP="$(grep -E '^SERVER_PUB_IP=' /etc/wireguard/params | cut -d= -f2- | tr -d '"')"
  PARAM_NIC="$(grep -E '^SERVER_PUB_NIC=' /etc/wireguard/params | cut -d= -f2- | tr -d '"')"

  if [ -n "$PARAM_IP" ] && [ "$PARAM_IP" != "$NEW_PUB_IP" ]; then
    echo "  !! /etc/wireguard/params still says SERVER_PUB_IP=$PARAM_IP"
    echo "  !! This box is $NEW_PUB_IP. Fix this BEFORE generating any new client,"
    echo "  !! or the new configs will point at the old server:"
    echo "  !!   sed -i 's|^SERVER_PUB_IP=.*|SERVER_PUB_IP=$NEW_PUB_IP|' /etc/wireguard/params"
  elif [ -n "$PARAM_IP" ]; then
    echo "  SERVER_PUB_IP already matches this box ($NEW_PUB_IP)"
  fi

  if [ -n "$PARAM_NIC" ] && [ "$PARAM_NIC" != "$NEW_NIC" ]; then
    echo "  !! params says SERVER_PUB_NIC=$PARAM_NIC but this box routes via $NEW_NIC."
    echo "  !! The NAT rule will masquerade out of an interface that does not exist,"
    echo "  !! so peers connect and handshake and still route nothing."
    echo "  !!   sed -i 's|^SERVER_PUB_NIC=.*|SERVER_PUB_NIC=$NEW_NIC|' /etc/wireguard/params"
  fi
fi
# The live NAT rules are in wg0.conf's PostUp, which params does not drive.
for conf in /etc/wireguard/*.conf; do
  [ -e "$conf" ] || continue
  for nic in $(grep -oE '\-(A|D) POSTROUTING.*-o [A-Za-z0-9@._-]+' "$conf" 2>/dev/null | grep -oE '\-o [A-Za-z0-9@._-]+' | awk '{print $2}' | sort -u); do
    ip link show "$nic" >/dev/null 2>&1 || {
      echo "  !! $conf masquerades out of '$nic', which does not exist on this box."
      echo "  !! Replace it with '${NEW_NIC:-your real interface}' or traffic will not route."
    }
  done
done

echo
echo "=== 4c. Firewall rules naming interfaces this box does not have ==="
# Same failure as the WireGuard NIC, one layer down. ufw's rule files are
# copied verbatim, and iptables happily accepts a rule naming an interface
# that does not exist - it just never matches. Worse, some ufw operations
# fail outright with a bare "ERROR: problem running" when reloading such a
# ruleset, with no indication of which line is at fault.
fw_bad="no"
for f in /etc/ufw/before.rules /etc/ufw/before6.rules /etc/ufw/after.rules \
         /etc/ufw/after6.rules /etc/ufw/user.rules /etc/ufw/user6.rules; do
  [ -f "$f" ] || continue
  for nic in $(grep -oE '\-[io] [A-Za-z0-9@._-]+' "$f" 2>/dev/null | awk '{print $2}' | sort -u); do
    # A wg interface only exists while its tunnel is up, so its absence here
    # is not evidence of a stale rule - skip anything with a matching config.
    [ -f "/etc/wireguard/${nic}.conf" ] && continue
    ip link show "$nic" >/dev/null 2>&1 || {
      echo "  !! $f references interface '$nic', which does not exist on this box"
      fw_bad="yes"
    }
  done
done
if [ "$fw_bad" = "yes" ]; then
  echo "  !! Fix before enabling ufw. This box routes via '${NEW_NIC:-$(ip route get 1.1.1.1 2>/dev/null | awk '"'"'{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'"'"')}':"
  echo "  !!   sed -i 's/\\bOLDNIC\\b/NEWNIC/g' /etc/ufw/*.rules"
else
  echo "  none - every interface named in the ufw rules exists here"
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
echo "=== 5b. Global npm packages (apt does not carry these) ==="
# pm2 is the reason this exists: its systemd unit and its saved process list
# both copy across, but pm2 itself is an npm global in /usr/lib/node_modules
# with a symlink in /usr/bin, so nothing in the apt package list brings it.
if [ -s "$STATE_DIR/npm-global.list" ]; then
  if command -v npm >/dev/null; then
    to_install=""
    while read -r pkg; do
      [ -n "$pkg" ] || continue
      if npm ls -g --depth=0 "$pkg" >/dev/null 2>&1; then
        echo "  ok: $pkg"
      else
        to_install="$to_install $pkg"
      fi
    done < "$STATE_DIR/npm-global.list"
    if [ -n "$to_install" ]; then
      echo "  installing:$to_install"
      # shellcheck disable=SC2086
      npm install -g $to_install 2>&1 | tail -5 | sed 's/^/    /'
    fi
  else
    echo "  !! npm is not installed here, but the old box had global npm packages:"
    sed 's/^/       /' "$STATE_DIR/npm-global.list"
  fi
else
  echo "  none recorded on the old box"
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
  # Logs, pm2 state dumps and backups mention the old IP as a matter of record,
  # not as configuration - and one of them is a single 10KB JSON line that
  # buries the findings that matter. Exclude them, and truncate what remains.
  hits="$(grep -rIn \
      --exclude-dir=letsencrypt --exclude-dir=.git --exclude-dir=logs \
      --exclude-dir=node_modules --exclude-dir=.cache \
      --exclude='*.log' --exclude='*.bak' --exclude='dump.pm2*' --exclude='*.gz' \
      "$OLD_IP" /etc /usr/local /root /opt 2>/dev/null \
    | grep -v "^$STATE_DIR" | cut -c1-160 | head -40)"
  if [ -n "$hits" ]; then
    echo "  Every line below still points at the machine you are migrating away from:"
    echo "$hits" | sed 's/^/    /'
    echo "  (nginx listen/proxy_pass, squid ACLs, fail2ban ignoreip, wireguard"
    echo "   Address, monitoring agents - all hide old IPs in plain sight)"
    echo "  Logs, backups and pm2 state dumps are excluded: they record the old IP"
    echo "  as history, which is correct, and there is nothing to change in them."
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
    DNS still points at the old box, so you cannot just visit the domain.
    These commands connect to the NEW box's IP while telling it which site
    you want, which is how you test a vhost before cutover.

    First, list the domains this box is configured to serve. Use nginx -T,
    which prints the FULL effective config - server blocks live in conf.d or
    any other include just as often as in sites-enabled:
      nginx -T 2>/dev/null | grep -oP 'server_name\s+\K[^;]+' \
        | tr ' ' '\n' | grep -Ev '^(_)?$' | sort -u

    Then for each one, over plain HTTP ("-H" is a literal curl flag meaning
    "send this header" - type it exactly, and replace only the domain and IP):
      curl -sI -H "Host: example.com" http://NEW_IP/

    And over HTTPS, which also proves the copied certificate works:
      curl -sI --resolve example.com:443:NEW_IP https://example.com/

    CAREFUL: the host in --resolve must be the SAME host as in the URL.
    "--resolve a.com:443:NEW_IP https://b.com" is not an error - curl simply
    ignores the override and resolves b.com through real DNS, which still
    points at the OLD box. You get a 200 from the server you were trying not
    to test. Change both names together, or you are testing nothing.

    A 200 or a 301 to your own site is success. A 404, or the default
    "Welcome to nginx" page, means the vhost is not being matched.

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
