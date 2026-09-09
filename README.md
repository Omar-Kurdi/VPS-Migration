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
  stops being a mystery. Also writes machine-readable snapshots that
  `04-verify.sh` later diffs against.
- `migrate.conf.example` — copy to `migrate.conf` and fill in the new VPS's
  address/key.
- `02-migrate.sh` — run on the **old** VPS. Installs the old box's packages
  on the new one, then copies configs, websites, WireGuard, Squid, PHP,
  certs, cron, sysctl, firewall rules, `/root`, `/usr/local/bin`,
  `/usr/local/sbin`, `/opt`, and (optionally) databases over SSH/rsync.
  Safe to re-run; supports a dry run.
- `03-post-migrate.sh` — run on the **new** VPS. Recreates user accounts with
  matching UIDs, applies sysctl, reloads systemd, enables services, finds the
  old server's IP hiding in your configs, and prints a manual checklist.
- `04-verify.sh` — run on the **new** VPS, before you cancel the old one.
  Diffs listening ports, enabled services and packages against the old box
  and tells you what didn't make it.

## How to run it

1. **On the OLD VPS:**
   ```bash
   sudo bash 01-discover.sh
   ```
   Read `/root/vps-migration/inventory.txt`. This tells you what's actually
   there — confirm the "other tools" you couldn't remember.

2. Get SSH access working from the old VPS to the new one:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/migrate_key -N ""
   ssh-copy-id -i ~/.ssh/migrate_key.pub root@<new-vps-ip>
   ```

3. **Still on the OLD VPS**, in this scripts folder:
   ```bash
   cp migrate.conf.example migrate.conf
   nano migrate.conf   # set NEW_HOST and NEW_SSH_KEY
   ```
   `NEW_SSH_KEY` is the **absolute** path to the private key from step 2 —
   `readlink -f ~/.ssh/migrate_key` prints it. A `~` will not work: the
   config is sourced, and a tilde inside quotes stays a literal tilde that
   ssh cannot resolve. Confirm it works before going further:
   ```bash
   ssh -i /root/.ssh/migrate_key root@<new-vps-ip> 'hostname'
   ```
   Do a preview first — set `DRY_RUN="yes"`, run it, and confirm the host it
   reports is the box you think it is. This script pushes to `/` on a remote
   machine as root; one typo in `NEW_HOST` is worth thirty seconds of paranoia.
   ```bash
   sudo bash 02-migrate.sh
   ```
   Then set `DRY_RUN="no"` and run it for real. Do it inside `tmux` or
   `screen` — it runs `apt` on the new box over SSH, and a dropped connection
   mid-install leaves dpkg in a state you have to clean up by hand.

   Run it once now for the bulk copy, then again right before your final
   cutover to catch anything that changed in between.

4. **On the NEW VPS:**
   ```bash
   sudo bash 03-post-migrate.sh
   ```

5. Work through the checklist it prints — testing sites before DNS cutover,
   merging the staged SSH config, renewing TLS certs, updating WireGuard
   client Endpoint IPs, firewall, then the actual DNS switch.

6. **On the NEW VPS, before you cancel the old one:**
   ```bash
   sudo bash 04-verify.sh
   ```
   Anything it lists under "on the OLD box but not here" is something you
   haven't migrated yet.

## Why packages are installed before configs are copied

`02-migrate.sh` installs the old box's package set on the new box *first*,
and only then copies your config files across. The reverse order — configs
first, packages second — leaves dpkg unpacking a package whose config file
is already sitting on disk with different contents and no record of how it
got there. What happens next depends on conffile prompt defaults. That's a
fine thing to be relaxed about when installing a text editor and a bad thing
to be relaxed about halfway through a server migration.

Installing first means package defaults land first and your configs land on
top of them, which is the outcome you want and doesn't depend on a default.

## Things worth knowing up front

- **Your own scripts/tools** (like `jails.sh`): `02-migrate.sh` copies
  `/root`, `/usr/local/bin`, `/usr/local/sbin`, and `/opt` by default, which
  covers where personal admin scripts almost always live. If yours live
  somewhere else, check the "CUSTOM / PERSONAL SCRIPTS" section of
  `inventory.txt` and add the exact paths to `EXTRA_PATHS` in `migrate.conf`.
- **SSH config is staged, not applied.** The old box's `sshd_config` is
  copied to `/root/vps-migration-review/etc/ssh/` on the new box instead of
  into `/etc/ssh`. Dropping it in live wouldn't break your current session —
  it would break the next reboot, weeks later, when a `Port`, an `AllowUsers`
  naming an account that doesn't exist yet, or a `ListenAddress` pinned to
  the *old* public IP finally takes effect with nobody watching. Diff it in
  by hand.
- **WireGuard**: server keys/configs move over untouched. Two things must
  change: the `Endpoint =` line in every *client* config (it points at the
  old public IP — consider using a DNS name so this never happens again),
  and any `PostUp` MASQUERADE rule that names an interface the new box
  might not have. `03-post-migrate.sh` also checks `ip_forward`, because
  without it peers connect, handshake, and route nothing — a failure that
  looks exactly like success.
- **File ownership**: `rsync -a` already preserves it correctly, so nothing
  here chowns `/var/www` wholesale. Instead `03-post-migrate.sh` recreates
  the old box's non-system accounts with their original UID/GID, and reports
  any file whose owner still doesn't resolve. If it reports a UID collision,
  fix the account — don't chown the files, since the numeric owner is the
  only remaining evidence of who they belonged to.
- **TLS certs (Let's Encrypt)**: the cert files copy over fine and sites
  will serve HTTPS immediately, but renewal can't work until DNS actually
  points at the new VPS — that's how domain validation works. After cutover
  run `certbot renew --dry-run` and confirm the renewal *timer* is scheduled.
  If certbot was a snap on the old box, the apt package list won't carry it
  and you'll need to `snap install --classic certbot` yourself.
- **Databases**: handled automatically. `DUMP_MYSQL`/`DUMP_POSTGRES` default
  to `auto` — if a database server is installed and reachable, it's dumped and
  copied; if none is installed, the step is skipped; if one is installed but
  unreachable, you get a loud warning instead of a silent skip. You don't need
  to know in advance whether you have a database or which one it is;
  `01-discover.sh` prints a plain verdict either way.
  Dumping is read-only and can't lose data — the risky step is the import, so
  that stays manual: you get one dump file per database (overwritten each run,
  so there's never ambiguity about which is current) and
  `03-post-migrate.sh` prints the import commands for you to run deliberately.
- **Firewall**: `03-post-migrate.sh` does *not* auto-enable `ufw` — enabling
  it wrong over SSH can lock you out permanently. Follow the checklist,
  which has you verify a second session works before you commit.
- **Docker**: compose files are copied, but named volumes (which can contain
  live database files) are not auto-copied — the script prints the exact
  `rsync` command to run once you've stopped the containers.
- **What is deliberately not copied**: `/etc/netplan`, `/etc/fstab`,
  `/etc/hostname`, `/etc/default/grub`, kernel and bootloader packages, the
  distro's own apt archive keyrings, and cloud-provider guest agents. These
  describe the hardware and network the old box was sitting on, not your
  setup. `grub` in particular is the same shape of trap as `sshd_config`:
  a bootloader line written for the old box's disks and console changes
  nothing at all until the next reboot, and then changes everything at once.

## Keep the old VPS around until you're sure

Don't cancel/shut down the old VPS the moment the scripts finish. Run
`04-verify.sh`, verify sites load, confirm WireGuard peers reconnect, check
DNS has fully propagated, and give it a few days of normal traffic on the
new box first.
