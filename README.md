# SRE Server Provisioning Scripts

Modular Bash scripts for provisioning Ubuntu/Debian and Oracle Linux/RHEL servers. Each script handles one task, detects server specs for adaptive tuning, and recommends the next step.

Supports **LAMP** and **LEMP** stacks serving **Laravel**, **Moodle**, **Nuxt**, and **Vue** projects.

## Quick Start

```bash
git clone https://github.com/YOUR_USERNAME/sre-scripts.git /opt/sre-scripts
cd /opt/sre-scripts
chmod +x common/lib.sh server/*.sh stack/*.sh tuning/*.sh vhost/*.sh ssl/*.sh

sudo bash server/01-base-setup.sh
# Follow the "NEXT STEP" recommendation after each script
```

## Script Sequence

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `server/01-base-setup.sh` | Detect specs, choose stack, install essentials, harden SSH |
| 2 | `server/02-firewall.sh` | Configure ufw or firewalld |
| 3 | `stack/03-web-server.sh` | Install Nginx or Apache |
| 4 | `stack/04-php.sh` | Install PHP-FPM + extensions |
| 5 | `stack/05-database.sh` | Install MySQL/MariaDB/PostgreSQL |
| 6 | `stack/06-node.sh` | Install Node.js + PM2 + Composer |
| 7 | `tuning/07-tune.sh` | Auto-tune based on server specs |
| 8 | `vhost/08-vhost.sh` | Create virtual host for a project |
| 9 | `ssl/09-ssl.sh` | Obtain Let's Encrypt SSL certificate |

## Adding a Project

```bash
sudo bash vhost/08-vhost.sh --domain app.example.com --type laravel
sudo bash ssl/09-ssl.sh --domain app.example.com --email admin@example.com
```

Project types: `laravel`, `moodle`, `nuxt`, `vue`

## Re-running a Step

All scripts are idempotent. After a RAM upgrade:

```bash
sudo bash tuning/07-tune.sh   # Recalculates and applies new values
```

## Common Flags

All scripts support:

```
--dry-run   Preview actions without making changes
--yes       Accept defaults without prompting
--help      Show usage
--config    Override config path (default: /etc/sre-helpers/setup.conf)
```

## Spec-Driven Tuning

Tuning values are calculated from your server's hardware, not hard-coded:

| Server | PHP-FPM Workers | Nginx Connections | DB Buffer Pool |
|--------|----------------|-------------------|----------------|
| 2 CPU / 2GB RAM | 40 | 512 | 512MB |
| 4 CPU / 8GB RAM | 160 | 1024 | 2048MB |
| 8 CPU / 16GB RAM | 200 | 1024 | 4096MB |

## Supported OS

- Ubuntu 22.04 / 24.04 LTS
- Oracle Linux 8 / 9

## Structure

```
common/lib.sh          # Shared library (logging, OS detection, config I/O)
server/                # Base setup and firewall
stack/                 # Package installers (web server, PHP, DB, Node)
tuning/                # Performance tuning calculator
vhost/                 # Virtual host creation + templates
ssl/                   # SSL certificate management
```

## Config

All choices and detected specs are saved to `/etc/sre-helpers/setup.conf`. This file is human-readable, editable, and sourced by all scripts. Config backups go to `/etc/sre-helpers/backups/`.

## License

MIT
