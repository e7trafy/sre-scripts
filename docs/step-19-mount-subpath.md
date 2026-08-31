# Step 19 — Mount Project as Subpath

Mounts an existing provisioned project at `<host>/<path>/` instead of its own
hostname. The canonical use case: turn `lms.upm.edu.sa` into
`elearning.upm.edu.sa/lms` while keeping the old URL working via 301 redirect.

Script: `vhost/19-mount-subpath.sh`

---

## Quick start (the one command you'll use 90% of the time)

```bash
cd /opt/sre-scripts && git pull

sudo bash vhost/19-mount-subpath.sh \
    --host elearning.upm.edu.sa \
    --sub  lms.upm.edu.sa \
    --path /lms
```

That gives you:

- `https://elearning.upm.edu.sa/lms/` serves the Moodle that used to live at `lms.upm.edu.sa`
- `https://lms.upm.edu.sa/...` returns `301 → https://elearning.upm.edu.sa/lms/...` (bookmarks keep working)
- Moodle's `$CFG->wwwroot` rewritten + caches purged so links/logins go through the new URL

---

## What it requires before you run it

| Prerequisite | Check command |
|---|---|
| Host project already provisioned (steps 1-11) | `ls /etc/nginx/sites-enabled/elearning.upm.edu.sa.conf` |
| Sub-app already provisioned + working at its own domain | `curl -kI https://lms.upm.edu.sa/` |
| Host's SSL cert is valid (Let's Encrypt or wildcard) | `sudo openssl x509 -enddate -noout -in /etc/letsencrypt/live/elearning.upm.edu.sa/fullchain.pem` |
| nginx (not Apache — Apache mount is not implemented in this step) | `nginx -v` |
| Host vhost has the subpath include hook (auto-added by step 8 since 2026-06) | `grep snippets /etc/nginx/sites-enabled/elearning.upm.edu.sa.conf` |

If the host vhost is older and lacks the include hook, the script tells you the
exact line to add and where.

---

## All the flags

```text
--host <domain>          Host project that serves the subpath
--sub <domain>           Sub-app to mount (existing project)
--path <prefix>          Subpath prefix (/lms, /portal, /apps-v2; [A-Za-z0-9_-] only)
--mode <proxy|alias>     proxy = recommended (default), alias = single-vhost
--internal-port <port>   Proxy mode: internal listener port (default: auto-pick 8081+)
--redirect-old <yes|no>  301-redirect the sub-app's old domain (default: yes)
--rewrite-app <yes|no>   Rewrite Moodle wwwroot / Laravel APP_URL (default: yes)
--reset                  Tear down the mount (does NOT re-enable old vhost — manual)
--yes                    Non-interactive
--force                  Allow overwriting an existing mount or skip safety checks
--dry-run                Print planned actions without writing anything
```

---

## Common scenarios — copy-paste blocks

### 1. Moodle under a Laravel host (the upm case)

```bash
sudo bash vhost/19-mount-subpath.sh \
    --host elearning.upm.edu.sa \
    --sub  lms.upm.edu.sa \
    --path /lms
```

Verify after:

```bash
curl -kI https://elearning.upm.edu.sa/lms/                  # expect 200/302
curl -kI https://elearning.upm.edu.sa/lms/login/index.php   # expect 200
curl -kI https://lms.upm.edu.sa/                            # expect 301 → elearning.upm.edu.sa/lms
```

### 2. Test BOTH modes side-by-side on different paths

```bash
# proxy mode on /lms-proxy (keeps old vhost alive)
sudo bash vhost/19-mount-subpath.sh \
    --host elearning.upm.edu.sa \
    --sub  lms.upm.edu.sa \
    --path /lms-proxy \
    --mode proxy \
    --redirect-old no \
    --rewrite-app  no

# alias mode on /lms-alias (keeps old vhost alive)
sudo bash vhost/19-mount-subpath.sh \
    --host elearning.upm.edu.sa \
    --sub  lms.upm.edu.sa \
    --path /lms-alias \
    --mode alias \
    --redirect-old no \
    --rewrite-app  no
```

Both paths now coexist; the sub-app's original `lms.upm.edu.sa` keeps working.
Pick the mode that behaves correctly, then tear the other down.

### 3. Switch modes after the fact

```bash
sudo bash vhost/19-mount-subpath.sh --host elearning.upm.edu.sa --sub lms.upm.edu.sa --path /lms --reset
sudo bash vhost/19-mount-subpath.sh --host elearning.upm.edu.sa --sub lms.upm.edu.sa --path /lms --mode alias --force
```

### 4. Dry-run first (see exactly what it would do, write nothing)

```bash
sudo bash vhost/19-mount-subpath.sh \
    --host elearning.upm.edu.sa \
    --sub  lms.upm.edu.sa \
    --path /lms \
    --dry-run
```

### 5. Mount a Laravel app under another Laravel app

```bash
sudo bash vhost/19-mount-subpath.sh \
    --host main.example.com \
    --sub  api.example.com \
    --path /api
```

Sub-app's `.env` is rewritten:
- `APP_URL=https://main.example.com/api`
- `ASSET_URL=https://main.example.com/api`
- `TRUSTED_PROXIES=*` (proxy mode only)
- `php artisan config:clear && cache:clear` runs automatically

### 6. Mount a static site

```bash
sudo bash vhost/19-mount-subpath.sh \
    --host main.example.com \
    --sub  docs.example.com \
    --path /docs
```

Nothing to rewrite — files just get served from the sub-app's docroot under
`/docs`.

### 7. Force a specific internal port (proxy mode)

```bash
sudo bash vhost/19-mount-subpath.sh \
    --host elearning.upm.edu.sa \
    --sub  lms.upm.edu.sa \
    --path /lms \
    --internal-port 8090
```

### 8. Tear down completely

```bash
sudo bash vhost/19-mount-subpath.sh \
    --host elearning.upm.edu.sa \
    --sub  lms.upm.edu.sa \
    --path /lms \
    --reset
```

Removes the snippet, internal listener, and 301-redirect vhost. **Does not**
re-enable the sub-app's original public vhost. To restore it:

```bash
sudo ln -sf /etc/nginx/sites-available/lms.upm.edu.sa.conf \
            /etc/nginx/sites-enabled/lms.upm.edu.sa.conf
sudo nginx -t && sudo systemctl reload nginx
```

---

## What files the script creates / touches

| File | Purpose | Survives step 8 re-run? |
|---|---|---|
| `/etc/nginx/snippets/<host>-subpaths/<path>.conf` | The subpath rules (proxy_pass or alias block) | Yes — included from host vhost |
| `/etc/nginx/sites-available/<sub>-internal.conf` + `-enabled/` symlink | Proxy mode only — internal `127.0.0.1:<port>` listener serving the sub-app | Yes |
| `/etc/nginx/sites-available/<sub>-redirect.conf` + `-enabled/` symlink | 301-redirect vhost for the old hostname | Yes |
| `/etc/nginx/sites-enabled/<sub>.conf` | Sub-app's original public vhost — **symlink removed** (file preserved as `.bak`) | N/A |
| Moodle `config.php` | `wwwroot`, `reverseproxy`, `sslproxy`, `sessioncookiepath` rewritten | Yes |
| Laravel `.env` | `APP_URL`, `ASSET_URL`, `TRUSTED_PROXIES` rewritten | Yes |

Backups of all modified files are written as `.bak.<timestamp>` siblings.

---

## How the two modes differ (and why proxy is the default)

### Proxy mode (default — recommended)

```
Browser → https://elearning.upm.edu.sa/lms/login/index.php
       ↓ host vhost: location ^~ /lms/
       ↓ proxy_pass http://127.0.0.1:8081/
       ↓
[internal nginx listener 127.0.0.1:8081]  (uses sub-app's docroot + FPM pool)
       ↓ location ~ \.php$
       ↓ fastcgi_pass unix:/run/php/.../lms.upm.edu.sa.sock
       ↓
[PHP-FPM pool for lms.upm.edu.sa]
       ↓
[Moodle code in /var/www/lms.upm.edu.sa/public_html]
```

Pros: Type-agnostic. Reuses the sub-app's existing FPM pool, docroot, env. The
sub-app is still reachable standalone on `127.0.0.1:8081`, which makes debugging
trivial. Easy to swap modes or paths.

Cons: One extra `127.0.0.1` listener per mount.

### Alias mode

```
Browser → https://elearning.upm.edu.sa/lms/login/index.php
       ↓ host vhost: location ^~ /lms/
       ↓ alias /var/www/lms.upm.edu.sa/public_html/
       ↓ rewrite ^/lms/(.*)$ /$1 break
       ↓ location ~ \.php$ → fastcgi_pass unix:.../lms.upm.edu.sa.sock
       ↓
[PHP-FPM pool for lms.upm.edu.sa]
```

Pros: No extra listener. Single vhost.

Cons: `alias` + `fastcgi_split_path_info` is a famous nginx footgun.
`SCRIPT_FILENAME` resolution gets twitchy when the sub-app uses PATH_INFO
heavily (Moodle does). If something misroutes, switch to proxy and the
problem usually disappears.

**Critical detail (both modes):** the snippet uses `location ^~ /lms/`, not
`location /lms/`. The `^~` modifier beats the host vhost's regex
`location ~ \.php$`. Without it, every `/lms/*.php` would be intercepted by
the host's PHP block and tried under the host's docroot, returning 404 for
Moodle URLs. This is the #1 silent breakage in subpath mounts.

---

## Diagnosing common breakage

### Moodle login loops or shows wrong base URL

```bash
# Confirm wwwroot is right
sudo grep wwwroot /var/www/lms.upm.edu.sa/public_html/config.php
# Should show: $CFG->wwwroot = 'https://elearning.upm.edu.sa/lms';

# Confirm reverseproxy flags (proxy mode + https)
sudo grep -E 'reverseproxy|sslproxy' /var/www/lms.upm.edu.sa/public_html/config.php

# Force a cache purge
sudo -u www-data php /var/www/lms.upm.edu.sa/public_html/admin/cli/purge_caches.php
```

### Stuck at 404 / "Page not found" on /lms

```bash
# Check the snippet is included from the host vhost
sudo grep "snippets/elearning.upm.edu.sa-subpaths" /etc/nginx/sites-enabled/elearning.upm.edu.sa.conf

# Check the snippet exists and uses ^~ (not bare prefix)
sudo cat /etc/nginx/snippets/elearning.upm.edu.sa-subpaths/lms.conf
# Expect: location ^~ /lms/ { ... }

# Check nginx error log for the host
sudo tail -50 /var/log/nginx/elearning.upm.edu.sa-error.log
```

### 502 / 503 / 504 (proxy mode)

```bash
# Is the internal listener up?
sudo ss -lnt | grep 8081

# Is the sub-app's FPM pool up?
sudo systemctl status php8.3-fpm
sudo ls -la /run/php/ | grep lms

# Tail the internal listener's error log
sudo tail -50 /var/log/nginx/lms.upm.edu.sa-internal-error.log
```

### Old hostname doesn't redirect

```bash
# Confirm the 301 vhost exists and is enabled
sudo ls -la /etc/nginx/sites-enabled/lms.upm.edu.sa-redirect.conf

# Confirm the original vhost is disabled (no symlink in sites-enabled)
sudo ls -la /etc/nginx/sites-enabled/ | grep lms.upm.edu.sa

# If the original symlink is still there, the script's --redirect-old skipped.
# Re-run with --redirect-old yes --force
```

### Image / asset URLs still point at the old hostname

Moodle stores some URLs inside the database (course-summary HTML, link
plugins). The script does NOT search-replace the DB. If you see broken
images, run a one-time search-replace on the moodle database:

```bash
# Pick the moodle DB name from config.php first:
sudo grep dbname /var/www/lms.upm.edu.sa/public_html/config.php

# Then run (replace DB name + table prefix accordingly):
mysql -uroot -p <dbname> -e "
UPDATE mdl_block_html       SET configdata = REPLACE(configdata, 'lms.upm.edu.sa', 'elearning.upm.edu.sa/lms');
UPDATE mdl_course_sections  SET summary    = REPLACE(summary,    'lms.upm.edu.sa', 'elearning.upm.edu.sa/lms');
UPDATE mdl_label            SET intro      = REPLACE(intro,      'lms.upm.edu.sa', 'elearning.upm.edu.sa/lms');
UPDATE mdl_page             SET content    = REPLACE(content,    'lms.upm.edu.sa', 'elearning.upm.edu.sa/lms');
"
sudo -u www-data php /var/www/lms.upm.edu.sa/public_html/admin/cli/purge_caches.php
```

---

## Limitations

- **nginx-only.** Apache + ProxyPass equivalent is not in this step yet.
- **No automatic DB search-replace** for in-content URLs (Moodle / WordPress).
- **No automatic update** of external integrations (LTI tool URLs, SSO
  return URLs, webhook callbacks). If the sub-app talks to outside systems,
  update those URLs in their respective admin panels.
- **One mount per path per host.** Running again with the same `--host` +
  `--path` requires `--force` and overwrites the snippet.
