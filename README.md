# VPS migration scripts

Moves everything from your old Ubuntu VPS to the new one: 2 websites, WireGuard,
Squid, and anything else running that you've forgotten about. Same Ubuntu
version on both boxes, so a full config + package copy is safe.

There's no single command that "just makes it work" for a whole server —
too many things (public IP, DNS, TLS validation) genuinely change when you
switch boxes. These scripts do everything that *can* be automated, and give
you a clear, short checklist for the handful of things that need a human
decision.

## Files

- `01-discover.sh` — run on the **old** VPS. Read-only. Builds an inventory
  of what's installed and running, so "some other tools I can't remember"
  stops being a mystery.
- `migrate.conf.example` — copy to `migrate.conf` and fill in the new VPS's
  address/key.
- `02-migrate.sh` — run on the **old** VPS. Copies configs, websites,
  WireGuard, Squid, certs, cron, firewall rules, `/root`, `/usr/local/bin`,
  `/usr/local/sbin`, `/opt` (your own scripts usually live in one of these),
  and (optionally) databases to the new VPS over SSH/rsync. Safe to re-run.
- `03-post-migrate.sh` — run on the **new** VPS. Installs matching packages,
  fixes permissions, enables services, imports any DB dumps, and prints a
  manual checklist for DNS/TLS/firewall/WireGuard-endpoint steps.

## How to run it

1. **On the OLD VPS:**
   ```
   sudo bash 01-discover.sh
   ```
   Read `~/vps-migration/inventory.txt`. This tells you what's actually
   there — confirm the "other tools" you couldn't remember.

2. Get SSH access working from the old VPS to the new one:
   ```
   ssh-keygen -t ed25519 -f ~/.ssh/migrate_key -N ""
   ssh-copy-id -i ~/.ssh/migrate_key.pub root@<new-vps-ip>
   ```

3. **Still on the OLD VPS**, in this scripts folder:
   ```
   cp migrate.conf.example migrate.conf
   nano migrate.conf   # set NEW_HOST, NEW_SSH_KEY=~/.ssh/migrate_key, etc.
   sudo bash 02-migrate.sh
   ```
   This pushes everything to the new VPS at matching paths. Run it once now
   for the bulk copy; run it again right before your final cutover to catch
   anything that changed since.

4. **On the NEW VPS:**
   ```
   sudo bash 03-post-migrate.sh
   ```
   Installs packages, enables services, restores permissions, and prints a
   checklist.

5. Work through the checklist that `03-post-migrate.sh` prints at the end —
   testing sites before DNS cutover, renewing TLS certs, updating WireGuard
   client Endpoint IPs, Squid ACLs, firewall, then the actual DNS switch.

## Things worth knowing up front

- **Your own scripts/tools** (like `jails.sh`): `02-migrate.sh` copies
  `/root`, `/usr/local/bin`, `/usr/local/sbin`, and `/opt` by default, which
  covers where personal admin scripts almost always live. If yours live
  somewhere else (a non-root user's home dir, some other folder), check the
  "CUSTOM / PERSONAL SCRIPTS" section of `inventory.txt` and add the exact
  paths to `EXTRA_PATHS` in `migrate.conf` before running `02-migrate.sh`.
- **WireGuard**: server keys/configs move over untouched. The one thing
  that *must* change is the `Endpoint =` line in every client's config,
  since that points at the old public IP. Consider pointing it at a DNS
  name instead of a raw IP so this never happens again.
- **TLS certs (Let's Encrypt)**: the cert files copy over fine and sites
  will serve HTTPS immediately, but renewal won't work until DNS actually
  points at the new VPS (that's how domain validation works). Run
  `certbot renew --dry-run` after DNS cutover to confirm.
- **Databases**: not dumped by default (`DUMP_MYSQL`/`DUMP_POSTGRES` are
  `no` in the example config) because getting this wrong is the easiest way
  to lose data. Turn them on once you've confirmed `mysqldump`/`pg_dumpall`
  work on your old VPS, or dump manually and copy the `.sql` file yourself.
- **Firewall**: `03-post-migrate.sh` does *not* auto-enable `ufw` — enabling
  it wrong over SSH can lock you out permanently. Follow the checklist,
  which has you verify a second session works before you commit.
- **Docker**: compose files are copied, but named volumes (which can contain
  live database files) are not auto-copied — the script tells you the exact
  `rsync` command to run once you've stopped the containers.

## Keep the old VPS around until you're sure

Don't cancel/shut down the old VPS the moment the scripts finish. Verify
sites load, WireGuard peers reconnect, DNS has fully propagated, and give it
a few days of normal traffic on the new box first.
