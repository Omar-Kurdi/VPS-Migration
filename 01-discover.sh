#!/usr/bin/env bash
# ============================================================================
# 01-discover.sh
#
# Run this ON THE OLD VPS (as root, or with sudo -E) FIRST.
# It builds an inventory of everything installed/running on the box, so you
# know exactly what needs to move. It does NOT change anything.
#
# Usage:
#   sudo bash 01-discover.sh
#
# Output:
#   ~/vps-migration/inventory.txt   <- read this
#   ~/vps-migration/pkgs.list       <- used later by 03-post-migrate.sh
# ============================================================================
set -uo pipefail

OUT_DIR="$HOME/vps-migration"
mkdir -p "$OUT_DIR"
INV="$OUT_DIR/inventory.txt"
PKGS="$OUT_DIR/pkgs.list"

section() { echo -e "\n\n================ $1 ================\n" >> "$INV"; }

: > "$INV"

echo "Gathering inventory... this is read-only, nothing is changed."

section "OS / KERNEL"
{ lsb_release -a 2>/dev/null; uname -a; } >> "$INV" 2>&1

section "HOSTNAME / NETWORK"
{
  echo "hostname: $(hostname)"
  echo "--- ip a ---"
  ip -brief a
  echo "--- default route ---"
  ip route | grep default
  echo "--- /etc/hosts ---"
  cat /etc/hosts
  echo "--- resolv.conf ---"
  cat /etc/resolv.conf 2>/dev/null
} >> "$INV" 2>&1

section "LISTENING PORTS (what's actually serving traffic)"
ss -tulnp >> "$INV" 2>&1

section "INSTALLED PACKAGES (apt) - full list saved separately to pkgs.list"
dpkg --get-selections | grep -v deinstall > "$PKGS"
echo "Saved $(wc -l < "$PKGS") packages to $PKGS" >> "$INV"

section "MANUALLY INSTALLED (top-level) PACKAGES - the ones that matter most"
apt-mark showmanual | sort >> "$INV" 2>&1

section "SYSTEMD SERVICES - enabled (will run on boot)"
systemctl list-unit-files --state=enabled --type=service --no-pager >> "$INV" 2>&1

section "SYSTEMD SERVICES - currently running"
systemctl list-units --type=service --state=running --no-pager >> "$INV" 2>&1

section "NGINX"
if command -v nginx >/dev/null; then
  echo "nginx installed: $(nginx -v 2>&1)" >> "$INV"
  echo "--- sites-enabled ---" >> "$INV"
  ls -la /etc/nginx/sites-enabled/ >> "$INV" 2>&1
  echo "--- conf.d ---" >> "$INV"
  ls -la /etc/nginx/conf.d/ >> "$INV" 2>&1
  echo "--- nginx -T (full effective config, first 400 lines) ---" >> "$INV"
  nginx -T 2>/dev/null | head -400 >> "$INV"
else
  echo "nginx not installed" >> "$INV"
fi

section "APACHE"
if command -v apache2 >/dev/null || command -v apachectl >/dev/null; then
  echo "apache installed" >> "$INV"
  echo "--- sites-enabled ---" >> "$INV"
  ls -la /etc/apache2/sites-enabled/ >> "$INV" 2>&1
  echo "--- enabled mods ---" >> "$INV"
  ls -la /etc/apache2/mods-enabled/ >> "$INV" 2>&1
else
  echo "apache not installed" >> "$INV"
fi

section "TLS CERTIFICATES (certbot / Let's Encrypt)"
if command -v certbot >/dev/null; then
  certbot certificates >> "$INV" 2>&1
else
  echo "certbot not installed" >> "$INV"
fi
echo "--- contents of /etc/letsencrypt/live (if any) ---" >> "$INV"
ls -la /etc/letsencrypt/live/ >> "$INV" 2>&1

section "WIREGUARD"
if command -v wg >/dev/null; then
  echo "wireguard tools installed" >> "$INV"
  echo "--- interfaces in /etc/wireguard ---" >> "$INV"
  ls -la /etc/wireguard/ >> "$INV" 2>&1
  echo "--- wg show (interface + peer count only, no keys printed) ---" >> "$INV"
  wg show all dump 2>/dev/null | awk '{print "peer/interface entry present"}' | sort | uniq -c >> "$INV"
  echo "--- enabled wg-quick services ---" >> "$INV"
  systemctl list-unit-files 'wg-quick@*' --no-pager >> "$INV" 2>&1
else
  echo "wireguard not installed" >> "$INV"
fi

section "SQUID"
if command -v squid >/dev/null; then
  echo "squid installed: $(squid -v 2>&1 | head -1)" >> "$INV"
  echo "--- /etc/squid/squid.conf exists: $(test -f /etc/squid/squid.conf && echo yes || echo no) ---" >> "$INV"
else
  echo "squid not installed" >> "$INV"
fi

section "DOCKER"
if command -v docker >/dev/null; then
  echo "docker installed: $(docker --version)" >> "$INV"
  echo "--- containers ---" >> "$INV"
  docker ps -a >> "$INV" 2>&1
  echo "--- images ---" >> "$INV"
  docker images >> "$INV" 2>&1
  echo "--- volumes ---" >> "$INV"
  docker volume ls >> "$INV" 2>&1
  echo "--- compose files found on disk ---" >> "$INV"
  find / -maxdepth 4 -iname "docker-compose*.yml" -not -path "*/node_modules/*" 2>/dev/null >> "$INV"
else
  echo "docker not installed" >> "$INV"
fi

section "DATABASES"
for svc in mysql mariadb postgresql; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
    echo "$svc service unit present" >> "$INV"
  fi
done
if command -v mysql >/dev/null; then
  echo "--- mysql/mariadb databases (excluding system schemas) ---" >> "$INV"
  mysql -N -e "SHOW DATABASES;" 2>/dev/null | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' >> "$INV"
fi
if command -v psql >/dev/null; then
  echo "--- postgres databases ---" >> "$INV"
  sudo -u postgres psql -lqt 2>/dev/null | cut -d '|' -f1 >> "$INV"
fi

section "CRON JOBS (all users)"
for u in $(cut -f1 -d: /etc/passwd); do
  out=$(crontab -u "$u" -l 2>/dev/null)
  if [ -n "$out" ]; then
    echo "--- crontab for $u ---" >> "$INV"
    echo "$out" >> "$INV"
  fi
done
echo "--- /etc/cron.d ---" >> "$INV"
ls -la /etc/cron.d/ >> "$INV" 2>&1

section "FIREWALL"
if command -v ufw >/dev/null; then
  echo "--- ufw status ---" >> "$INV"
  ufw status verbose >> "$INV" 2>&1
fi
echo "--- iptables -S (may be empty if only ufw/nft used) ---" >> "$INV"
iptables -S >> "$INV" 2>&1
echo "--- nft ruleset (if nftables used) ---" >> "$INV"
nft list ruleset >> "$INV" 2>&1

section "USERS WITH LOGIN SHELLS"
awk -F: '($7 ~ /(bash|sh|zsh)$/){print $1, $6, $7}' /etc/passwd >> "$INV"

section "SSH"
echo "--- sshd_config (non-default / uncommented lines) ---" >> "$INV"
grep -Ev '^\s*#|^\s*$' /etc/ssh/sshd_config >> "$INV" 2>&1

section "WEBROOTS - top-level dirs under common paths"
for d in /var/www /srv /home/*/public_html /opt; do
  [ -d "$d" ] && { echo "--- $d ---" >> "$INV"; ls -la "$d" >> "$INV" 2>&1; }
done

section "CUSTOM / PERSONAL SCRIPTS - these are NOT copied automatically by 02-migrate.sh"
echo "Anything listed here (your own .sh/.py/.pl scripts, one-off tools) needs" >> "$INV"
echo "to be added to EXTRA_PATHS in migrate.conf, or it will be left behind." >> "$INV"
echo >> "$INV"
echo "--- executable scripts in /root (top 2 levels) ---" >> "$INV"
find /root -maxdepth 2 -type f \( -perm -u+x -o -name "*.sh" -o -name "*.py" -o -name "*.pl" \) 2>/dev/null >> "$INV"
echo "--- executable scripts under /home/*/ (top 2 levels, excluding public_html) ---" >> "$INV"
find /home -maxdepth 3 -type f \( -perm -u+x -o -name "*.sh" -o -name "*.py" -o -name "*.pl" \) \
  -not -path "*/public_html/*" 2>/dev/null >> "$INV"
echo "--- /usr/local/bin and /usr/local/sbin (custom binaries/scripts, not from apt) ---" >> "$INV"
ls -la /usr/local/bin /usr/local/sbin >> "$INV" 2>&1
echo "--- /opt (third-party / hand-installed software often lives here) ---" >> "$INV"
find /opt -maxdepth 2 2>/dev/null >> "$INV"
echo "--- files in /root and /home/* NOT owned by any apt package (best-effort, may be slow) ---" >> "$INV"
{
  for f in $(find /root /home /usr/local/bin /usr/local/sbin /opt -maxdepth 3 -type f 2>/dev/null); do
    dpkg -S "$f" >/dev/null 2>&1 || echo "$f"
  done
} >> "$INV" 2>&1

section "DISK USAGE (so you know what's big before you copy it)"
{ df -h; echo; du -sh /var/www /etc /home /opt /srv 2>/dev/null; } >> "$INV"

echo -e "\nDone. Review: $INV"
echo "Package list saved: $PKGS"
echo
echo "Next: copy this whole '$OUT_DIR' folder somewhere safe, read inventory.txt,"
echo "then fill in migrate.conf and run 02-migrate.sh from a machine that can"
echo "SSH into both the OLD and NEW VPS (your laptop, or the new VPS itself)."
