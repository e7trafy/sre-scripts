# SRE Server Provisioning Scripts

Modular Bash scripts for provisioning Ubuntu 22.04/24.04 and Oracle Linux 8/9 servers.
Each script handles one task, detects server specs for adaptive tuning, and guides you to the next step.

Supports **LAMP** and **LEMP** stacks for **Laravel**, **Moodle**, **Nuxt**, and **Vue** projects.

---

## Requirements

- Root or sudo access
- Ubuntu 22.04/24.04 LTS **or** Oracle Linux 8/9
- Bash 4+

---

## Installation

```bash
git clone https://github.com/e7trafy/sre-scripts.git /opt/sre-scripts
cd /opt/sre-scripts
chmod +x common/lib.sh server/*.sh stack/*.sh tuning/*.sh vhost/*.sh migrate/*.sh ssl/*.sh
```

---

## Step Sequence

| Step | Script | Purpose | Required |
|------|--------|---------|----------|
| 0 | `server/00-block-volume.sh` | Mount Oracle block volume as `/var` | Optional |
| 1 | `server/01-base-setup.sh` | Detect specs, choose LAMP/LEMP, PHP version, DB engine, SSH hardening | Yes |
| 2 | `server/02-firewall.sh` | Configure ufw (Ubuntu) or firewalld (Oracle Linux) | Yes |
| 3 | `stack/03-web-server.sh` | Install Nginx or Apache with secure defaults | Yes |
| 4 | `stack/04-php.sh` | Install PHP-FPM + 15 extensions | Yes |
| 5 | `stack/05-database.sh` | Install MariaDB / MySQL / PostgreSQL | If using DB |
| 6 | `stack/06-node.sh` | Install Node.js + PM2 + Composer | If using Node/PHP |
| 7 | `tuning/07-tune.sh` | Auto-tune PHP-FPM, Nginx/Apache, DB based on server specs | Yes |
| 8 | `vhost/08-vhost.sh` | Create virtual host for a project | Per project |
| 9 | `server/09-ssh-keys.sh` | Generate / import / copy SSH keys | Optional |
| 10 | `migrate/10-migrate-cpanel.sh` | Migrate files + DB from a cPanel/WHM server | Optional |
| 11 | `ssl/11-ssl.sh` | Obtain Let's Encrypt SSL certificate | Per project |

Each script prints a full step map at the end showing your progress and the recommended next step.

---

## Oracle Block Volume Setup (Optional — Step 0)

Run this **before step 1** if you want to mount an Oracle block volume as `/var` (recommended for production — keeps web files, logs, and DB data on a separate, resizable volume).

```bash
# 1. Attach the volume in Oracle Cloud Console first:
#    Compute → Instances → your instance → Attach block volume

# 2. Then run:
sudo bash server/00-block-volume.sh
```

**Handles three scenarios automatically:**

| Scenario | What happens |
|---|---|
| Fresh volume (no filesystem) | Formats with ext4, mounts at `/var` |
| `/var` has existing data | Formats volume, migrates all `/var` data to it, remounts |
| Already mounted at `/var` | Detects and skips — nothing to do |

**Safety:**
- Default confirmation is **No** — will not proceed without explicit yes
- `--dry-run` shows full plan without touching anything
- Uses UUID in `/etc/fstab` (not device path — safer on Oracle Cloud)
- Backs up `/etc/fstab` before modifying

**After running:**
```bash
sudo reboot
df -h /var   # confirm mount survived reboot
```

---

## Migrate Block Storage Back to Boot Disk (Optional)

Reverses step 00. Moves all data from block volumes back to the boot disk so volumes can be detached or replaced.

```bash
sudo bash server/00-block-to-boot.sh
```

Auto-detects the previous scenario from the state file left by step 00.

**What it does:**

| Scenario | Actions |
|---|---|
| dual | Stop MariaDB → rsync `/u02/mysql` → `/var/lib/mysql` → restore config → restart MariaDB → rsync `/u02/appdata` → `/var/www` → unmount + remove fstab entries |
| single | Stop services → rsync `/var` to temp on root disk → unmount block `/var` → move temp → `/var` → restart services → remove fstab entry |

**Safety:**
- Checks available space on boot disk before starting — refuses if not enough
- Data on block volumes is **never erased** — only unmounted after boot copy is verified
- Idempotent: state file at `/etc/sre-helpers/block-to-boot.state` — safe to re-run after interruption
- `--dry-run` shows full plan without touching anything

**After running:** detach volumes from Oracle Cloud Console:
> Compute → Instances → your instance → Attached block volumes → Detach

---

## Fresh Server Setup (Full Stack)

```bash
cd /opt/sre-scripts

# Optional: mount block volume first (Oracle Cloud)
sudo bash server/00-block-volume.sh     # Step 0

sudo bash server/01-base-setup.sh       # Step 1 — base setup
sudo bash server/02-firewall.sh         # Step 2 — firewall
sudo bash stack/03-web-server.sh        # Step 3 — web server
sudo bash stack/04-php.sh               # Step 4 — PHP
sudo bash stack/05-database.sh          # Step 5 — database
sudo bash stack/06-node.sh              # Step 6 — Node.js + Composer
sudo bash tuning/07-tune.sh             # Step 7 — tune
```

---

## Adding a Project (Virtual Host + SSL)

```bash
sudo bash vhost/08-vhost.sh             # Step 8 — prompted for domain, type, PHP version
sudo bash ssl/11-ssl.sh                 # Step 11 — SSL for the domain
```

**Project types:** `laravel` `moodle` `nuxt` `vue`

**Document roots by type:**

| Type | Web Root |
|------|----------|
| Laravel | `/var/www/{domain}/current/public` |
| Moodle | `/var/www/{domain}/public_html` |
| Nuxt | `/var/www/{domain}/current` |
| Vue | `/var/www/{domain}/current/dist` |

**Moodle note:** moodledata is stored outside the web root at `/var/www/{domain}/moodledata`.

---

## SSH Key Setup (Optional — Step 9)

Run before migration to enable passwordless SSH to source servers.

```bash
sudo bash server/09-ssh-keys.sh
```

Modes (prompted interactively):
- **generate** — create a new ed25519 or RSA key pair
- **import** — paste an existing private key
- **copy** — push your public key to a remote server (`ssh-copy-id`)
- **show** — display current public keys
- **list** — list all keys on this server

---

## Migrate from cPanel / WHM (Optional — Step 10)

```bash
sudo bash migrate/10-migrate-cpanel.sh
```

Prompts for:
- Source server host, SSH port, SSH user
- Domain to migrate
- Migration mode: `full` (files + DB), `rsync-only`, `db-only`
- rsync exclusion: `smart-exclude` (skip cache/logs), `transfer-all`, `custom-exclude`
- Source DB name, user, and password
- Local DB name and user to create

**Features:**
- Saves state per domain to `/etc/sre-helpers/migrations/<domain>.conf` — safe to re-run
- Ownership fixed to `www-data` immediately after rsync (source UIDs replaced)
- POSIX ACL permissions (`setfacl`) applied during post-migration setup
- Post-migration setup (composer install, cache warm-up) is optional

**Moodle migration extras:**
- Prompts separately for moodledata path on source (auto-detected from `config.php`)
- Syncs web root and moodledata in separate rsync passes
- Writes correct `config.php` with `mysqli`/`pgsql` dbtype, detected table prefix
- Updates `wwwroot` in the Moodle database to match new domain

**Prerequisite:** SSH key must be copied to source server first:
```bash
ssh-copy-id -p <port> <user>@<source-host>
# Then verify:
ssh -p <port> <user>@<source-host> "echo connected"
```

---

## SSL Certificate (Step 11)

```bash
sudo bash ssl/11-ssl.sh
```

Prompts for domain and email. Uses Certbot with the Nginx or Apache plugin (auto-detected from config).

---

## Common Flags

All scripts support:

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview actions without making any changes |
| `--yes` | Accept all defaults, no prompts |
| `--help` | Show usage |
| `--config <path>` | Override config file (default: `/etc/sre-helpers/setup.conf`) |

---

## Spec-Driven Tuning

Tuning values are calculated from your hardware — not hard-coded:

| RAM | PHP-FPM Workers | DB Buffer Pool |
|-----|----------------|----------------|
| 2 GB | 40 | 512 MB |
| 4 GB | 80 | 1 GB |
| 8 GB | 160 | 2 GB |
| 16 GB | 200 (max) | 4 GB |

Nginx workers = number of CPU cores. Re-run step 7 any time after a RAM/CPU upgrade.

---

## Config File

All choices and detected values are saved to `/etc/sre-helpers/setup.conf`:

```ini
WEB_SERVER=nginx
PHP_VERSION=8.3
DB_ENGINE=mariadb
NODE_VERSION=20
CPU_CORES=4
RAM_MB=8192
DISK_TYPE=ssd
```

This file is sourced by every script. Backups are saved to `/etc/sre-helpers/backups/` before each change.

---

## Structure

```
common/lib.sh          # Shared library: logging, OS detection, config, prompts
server/                # 00-block-volume, 00-block-to-boot, 01-base-setup, 02-firewall, 09-ssh-keys
stack/                 # 03-web-server, 04-php, 05-database, 06-node
tuning/                # 07-tune
vhost/                 # 08-vhost + templates/
migrate/               # 10-migrate-cpanel
ssl/                   # 11-ssl
```

---

## Supported OS

| OS | Versions |
|----|---------|
| Ubuntu | 22.04, 24.04 LTS |
| Oracle Linux / RHEL | 8, 9 |

---

## License

MIT
