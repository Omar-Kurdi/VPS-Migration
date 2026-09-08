#!/usr/bin/env bash
# ============================================================================
# 03-post-migrate.sh
#
# Run this ON THE NEW VPS (as root, or with sudo -E), AFTER 02-migrate.sh has
# copied files over from the old VPS.
#
# It installs matching packages, fixes ownership/permissions on the copied
# configs, enables services, and prints a manual checklist for the things
# that genuinely need a human decision (DNS, firewall, WireGuard peer IPs).
#
# It deliberately does NOT force-enable ufw automatically - doing that wrong
# over SSH can lock you out. That step is left as a clearly marked manual
# command near the end.
#
# Usage:
#   sudo bash 03-post-migrate.sh
# ============================================================================
set -uo pipefail

PKGLIST="$HOME/vps-migration/pkgs.list"

echo "=== 1. Installing matching packages ==="
if [ -f "$PKGLIST" ]; then
  apt-get update
  echo "Applying package selection from the old VPS (same Ubuntu version assumed)..."
  dpkg --set-selections < "$PKGLIST"
  DEBIAN_FRONTEND=noninteractive apt-get -y dselect-upgrade || \
    echo "!! dselect-upgrade reported issues - some packages may need manual attention (apt list --upgradable)"
else
  echo "No $PKGLIST found - skipping automatic package sync."
  echo "Install what you need manually, e.g.:"
  echo "  apt-get update && apt-get install -y nginx wireguard squid certbot python3-certbot-nginx fail2ban ufw"
fi

echo
echo "=== 2. Fixing ownership/permissions on copied files ==="
if [ -d /var/www ]; then
  chown -R www-data:www-data /var/www 2>/dev/null
  echo "  /var/www ownership set to www-data"
fi
if [ -d /etc/wireguard ]; then
  chmod 700 /etc/wireguard
  chmod 600 /etc/wireguard/*.conf 2>/dev/null
  echo "  /etc/wireguard locked down to 600/700"
fi
if [ -d /etc/letsencrypt ]; then
  chmod -R go-rwx /etc/letsencrypt/archive /etc/letsencrypt/live 2>/dev/null
  echo "  /etc/letsencrypt tightened"
fi

echo
echo "=== 3. Enabling services that have config present ==="
enable_if_present() {
  local unit="$1"
  if systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^${unit}"; then
    systemctl enable --now "$unit" 2>&1 | sed 's/^/  /'
  fi
}

[ -d /etc/nginx/sites-enabled ] || [ -f /etc/nginx/nginx.conf ] && { nginx -t && enable_if_present nginx.service; }
command -v apache2ctl >/dev/null && { apache2ctl configtest && enable_if_present apache2.service; }
command -v squid >/dev/null && { squid -k parse 2>/dev/null; enable_if_present squid.service; }
command -v fail2ban-client >/dev/null && enable_if_present fail2ban.service

if [ -d /etc/wireguard ]; then
  for conf in /etc/wireguard/*.conf; do
    [ -e "$conf" ] || continue
    iface="$(basename "$conf" .conf)"
    echo "  enabling wg-quick@$iface"
    systemctl enable --now "wg-quick@$iface" 2>&1 | sed 's/^/    /'
  done
fi

echo
echo "=== 4. Restoring cron ==="
if [ -d /var/spool/cron/crontabs ]; then
  chown -R root:crontab /var/spool/cron/crontabs 2>/dev/null
  chmod 700 /var/spool/cron/crontabs 2>/dev/null
  systemctl enable --now cron 2>&1 | sed 's/^/  /'
fi

echo
echo "=== 5. Importing database dumps (if any were copied) ==="
DUMP_DIR="/root/vps-migration-dumps"
if [ -d "$DUMP_DIR" ]; then
  for f in "$DUMP_DIR"/mysql-*.sql; do
    [ -e "$f" ] || continue
    db="$(basename "$f" .sql | sed -E 's/^mysql-//; s/-[0-9]{8}-[0-9]{6}$//')"
    echo "  found MySQL dump for db '$db' -> $f"
    echo "    import with: mysql -e \"CREATE DATABASE IF NOT EXISTS \\\`$db\\\`;\" && mysql \"$db\" < \"$f\""
  done
  for f in "$DUMP_DIR"/postgres-all-*.sql; do
    [ -e "$f" ] || continue
    echo "  found Postgres dump -> $f"
    echo "    import with: sudo -u postgres psql -f \"$f\""
  done
  if ! ls "$DUMP_DIR"/*.sql >/dev/null 2>&1; then
    echo "  no dump files found in $DUMP_DIR"
  fi
else
  echo "  no dump directory found - if you use MySQL/Postgres and didn't set DUMP_MYSQL/DUMP_POSTGRES=yes,"
  echo "  dump and copy the databases manually before decommissioning the old VPS."
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

[ ] TLS CERTIFICATES
    Copied certs reference the old domain but were issued to the old
    account/validation path. Once DNS points at the new VPS, run:
      certbot renew --dry-run
      certbot renew
    to make sure the new box can actually renew them. Don't wait for
    them to expire to find out it's broken.

[ ] WIREGUARD - PUBLIC ENDPOINT CHANGED
    The server's public IP is different now. Every WireGuard *client*
    config has an "Endpoint = old.ip:port" line that must be updated to
    the new IP (or better, a DNS name you control, so this never bites
    you again). The server-side keys/configs you copied are otherwise
    unchanged, so peers will connect fine once their Endpoint is fixed.

[ ] SQUID - CHECK FOR HARDCODED OLD IP
    grep -n "old.ip.here" /etc/squid/squid.conf
    Update any ACLs, listen addresses, or upstream references that
    mention the old server's IP.

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

[ ] SSH ACCESS
    Confirm your normal (non-root) user and SSH keys work on the new
    VPS before you rely on it - don't leave yourself only root-key
    access if that's not how you normally operate.

[ ] "OTHER TOOLS YOU COULDN'T REMEMBER"
    Check inventory.txt from 01-discover.sh:
      - "SYSTEMD SERVICES - enabled" section: anything unfamiliar running?
      - "LISTENING PORTS" section: any port you didn't expect?
      - "DOCKER" section: any containers to bring up on the new box?
    Cross-check that same list against `systemctl list-units --type=service --state=running`
    on the NEW VPS once everything above is done - they should roughly match.

[ ] DECOMMISSION OLD VPS
    Only after: sites verified, WireGuard peers reconnecting, DNS fully
    propagated (check with a tool that queries multiple resolvers), and
    at least a few days of normal operation on the new VPS.
EOF
