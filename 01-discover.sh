#!/usr/bin/env bash
# ============================================================================
# 01-discover.sh
#
# Run this ON THE OLD VPS (as root, or with sudo) FIRST.
# It builds an inventory of everything installed/running on the box, so you
# know exactly what needs to move. It does NOT change anything.
#
# Usage:
#   sudo bash 01-discover.sh
#
# Output (all under /root/vps-migration):
#   inventory.txt        <- read this, it's for humans
#   pkgs.list            <- used later by 02-migrate.sh
#   ports.list           }
#   units-enabled.list   } machine-diffable snapshots, used by 04-verify.sh
#   units-running.list   }   on the new box to prove nothing was missed
#   users.list           <- non-system accounts + their UID/GID
#   meta.env             <- old hostname / public IP, used by later scripts
# ============================================================================
set -uo pipefail

STATE_DIR="/root/vps-migration"
mkdir -p "$STATE_DIR"
INV="$STATE_DIR/inventory.txt"
PKGS="$STATE_DIR/pkgs.list"

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
apt-mark showmanual 2>/dev/null | sort | tee "$STATE_DIR/pkgs-manual.list" >> "$INV"

section "SNAP PACKAGES (NOT covered by the apt package list)"
if command -v snap >/dev/null; then
  snap list 2>/dev/null | tee "$STATE_DIR/snaps.list" >> "$INV"
  echo "NOTE: snaps are not reinstalled automatically. If certbot is a snap here," >> "$INV"
  echo "install it as a snap on the new box too, or /etc/letsencrypt will be orphaned." >> "$INV"
else
  echo "snapd not installed" >> "$INV"
fi

section "SYSTEMD SERVICES - enabled (will run on boot)"
systemctl list-unit-files --state=enabled --type=service --no-pager >> "$INV" 2>&1

section "SYSTEMD SERVICES - currently running"
systemctl list-units --type=service --state=running --no-pager >> "$INV" 2>&1

section "SYSTEMD TIMERS (cron's modern equivalent - easy to forget)"
systemctl list-timers --all --no-pager >> "$INV" 2>&1

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

section "PHP (if the sites are PHP, /etc/php and the FPM pool configs must move)"
if command -v php >/dev/null; then
  php -v 2>&1 | head -1 >> "$INV"
  ls -la /etc/php/ >> "$INV" 2>&1
  echo "--- php-fpm pools ---" >> "$INV"
  find /etc/php -name "*.conf" -path "*pool.d*" 2>/dev/null >> "$INV"
else
  echo "php not installed" >> "$INV"
fi

section "TLS CERTIFICATES (certbot / Let's Encrypt)"
if command -v certbot >/dev/null; then
  certbot certificates >> "$INV" 2>&1
  echo "--- how certbot is installed (apt vs snap matters on the new box) ---" >> "$INV"
  command -v certbot >> "$INV"
  dpkg -S "$(command -v certbot)" >> "$INV" 2>&1 || echo "not an apt file - probably a snap" >> "$INV"
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
  echo "--- wg show (public keys only; private keys are never printed) ---" >> "$INV"
  wg show all >> "$INV" 2>&1
  echo "--- enabled wg-quick services ---" >> "$INV"
  systemctl list-unit-files 'wg-quick@*' --no-pager >> "$INV" 2>&1
else
  echo "wireguard not installed" >> "$INV"
fi

section "IP FORWARDING / SYSCTL (WireGuard and Squid silently break without this)"
{
  echo "net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
  echo "net.ipv6.conf.all.forwarding = $(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)"
  echo "--- non-default lines in /etc/sysctl.conf ---"
  grep -Ev '^\s*#|^\s*$' /etc/sysctl.conf 2>/dev/null
  echo "--- /etc/sysctl.d ---"
  ls -la /etc/sysctl.d/ 2>/dev/null
} >> "$INV" 2>&1

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
echo "--- sshd_config.d drop-ins (cloud images put real settings here) ---" >> "$INV"
grep -Ev '^\s*#|^\s*$' /etc/ssh/sshd_config.d/* >> "$INV" 2>&1

section "WEBROOTS - top-level dirs under common paths"
for d in /var/www /srv /home/*/public_html /opt; do
  [ -d "$d" ] && { echo "--- $d ---" >> "$INV"; ls -la "$d" >> "$INV" 2>&1; }
done

section "CUSTOM / PERSONAL SCRIPTS - check these are covered by 02-migrate.sh"
echo "02-migrate.sh copies /root, /usr/local/bin, /usr/local/sbin and /opt by" >> "$INV"
echo "default. Anything listed below that is OUTSIDE those paths needs to be" >> "$INV"
echo "added to EXTRA_PATHS in migrate.conf, or it will be left behind." >> "$INV"
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

echo "--- files NOT owned by any apt package (i.e. things you put there yourself) ---" >> "$INV"
echo "Scanning... (this is the slow part, usually 10-60s)"
find /root /home /usr/local/bin /usr/local/sbin /opt -maxdepth 3 \
     \( -type d \( -name node_modules -o -name .git -o -name .cache -o -name vendor \
                   -o -name __pycache__ -o -name .venv \) -prune \) -o -type f -print0 2>/dev/null \
  | xargs -0 -r -n 100 dpkg -S 2>&1 >/dev/null \
  | sed -n 's/^dpkg-query: no path found matching pattern //p' >> "$INV"

section "DISK USAGE (so you know what's big before you copy it)"
{ df -h; echo; du -sh /var/www /etc /home /opt /srv 2>/dev/null; } >> "$INV"

# ---------------------------------------------------------------------------
# Machine-diffable snapshots. 04-verify.sh on the NEW box diffs against these
# to prove that everything that was listening/enabled here is listening/enabled
# there. Keep the formats stable and sorted.
# ---------------------------------------------------------------------------
export LC_ALL=C   # 04-verify.sh comm's these against files sorted on the new box
ss -tuln 2>/dev/null | tail -n +2 | awk '{print $1, $5}' | sort -u > "$STATE_DIR/ports.list"

systemctl list-unit-files --state=enabled --type=service --no-pager --plain 2>/dev/null \
  | awk '$1 ~ /\.service$/ {print $1}' | sort -u > "$STATE_DIR/units-enabled.list"

systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null \
  | awk '$1 ~ /\.service$/ {print $1}' | sort -u > "$STATE_DIR/units-running.list"

# Non-system accounts, so the new box can recreate them with matching UID/GID.
# Without this, copied files owned by uid 1001 land on whoever holds 1001 there.
awk -F: '($3 >= 1000 && $3 < 65534){print $1":"$3":"$4":"$6":"$7}' /etc/passwd \
  | sort > "$STATE_DIR/users.list"

OLD_IP_GUESS="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
{
  echo "OLD_HOSTNAME=\"$(hostname)\""
  echo "OLD_IP=\"${OLD_IP_GUESS:-}\""
  echo "OLD_OS=\"$(lsb_release -ds 2>/dev/null || echo unknown)\""
  echo "OLD_KERNEL=\"$(uname -r)\""
  echo "DISCOVERED_AT=\"$(date -Is)\""
} > "$STATE_DIR/meta.env"

echo
echo "Done. Read $INV"
echo "Detected this box's outbound IP as: ${OLD_IP_GUESS:-<could not detect - set OLD_IP in migrate.conf>}"
echo "Snapshots for 04-verify.sh written to $STATE_DIR/*.list"
