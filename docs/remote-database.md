# Remote SQL Server (external database)

Points the whole stack at an **external MySQL/MariaDB server** instead of
installing one on the web server. Databases and users are still created for you
by steps 13 / 16 / 10 — they just get created on the remote host, and app
configs are wired to reach it.

Configured in: `stack/05-database.sh` (step 5)
Library: `common/dbconn.sh`

---

## Quick start

```bash
cd /opt/sre-scripts && git pull

# Put the remote admin password in a file first — avoids it landing in
# your shell history or in `ps` output.
printf '%s\n' 'THE_ADMIN_PASSWORD' > /root/db-admin.pass
chmod 600 /root/db-admin.pass

sudo bash stack/05-database.sh \
    --remote \
    --db-host db.internal.example.com \
    --db-admin-user admin \
    --db-admin-pass-file /root/db-admin.pass
```

Step 5 then:

1. Installs **client** packages only (no local SQL server).
2. Saves the connection details to `/etc/sre-helpers/setup.conf`.
3. Saves the password to `/etc/sre-helpers/db-admin.pass` (mode `600`).
4. Connects and verifies the admin user can `CREATE`/`DROP` a database.
5. Warns if the remote server's default charset is not `utf8mb4`.

After that, run steps 13 / 16 / 10 exactly as you normally would — nothing
about their usage changes.

Run it with no flags to be prompted interactively (the default answer is
"install locally", so existing workflows are unaffected).

---

## Options

| Flag | Meaning | Default |
|---|---|---|
| `--remote` | Use an external SQL server | — |
| `--local` | Force local install (existing behaviour) | this, if unset |
| `--db-host HOST` | Remote host (implies `--remote`) | — |
| `--db-port PORT` | Remote port | `3306` |
| `--db-admin-user U` | Admin/root-equivalent user | `root` |
| `--db-admin-pass-file F` | Read password from a file **(preferred)** | — |
| `--db-admin-pass P` | Password inline (visible in history) | — |
| `--db-grant-host H` | Host part of `CREATE USER ...@'<H>'` | `%` |
| `--db-client-host H` | Override what apps put in `DB_HOST` | `--db-host` |

`--db-client-host` matters when provisioning reaches the server on one address
(e.g. a public name) but the app should use another (e.g. a private VLAN IP).

---

## What the remote admin user needs

```sql
-- On the remote server, for the admin account this stack uses:
CREATE USER 'admin'@'<web-server-ip>' IDENTIFIED BY '...';
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'<web-server-ip>' WITH GRANT OPTION;
FLUSH PRIVILEGES;
```

`CREATE`, `DROP`, `CREATE USER` and `GRANT OPTION` are all required — the
provisioning steps create a database **and** a dedicated user per project.

Also required on the remote side:

- `bind-address` must not be `127.0.0.1` only
- port `3306/tcp` reachable from the web server (firewall / security list)
- ideally `character-set-server = utf8mb4` (for Arabic content)

---

## Grant host: why the default is `%`

A project's DB user is created as `'user'@'<grant-host>'`. In local mode that is
`localhost`, because the app and the DB share a socket.

Against a remote server, `'user'@'localhost'` would authorise a client running
**on the DB box** — not your web server — so the app would be created
successfully and then fail to authenticate. The default is therefore `%`.

To restrict it to just this server:

```bash
sudo bash stack/05-database.sh --remote \
    --db-host db.internal --db-grant-host 203.0.113.10 \
    --db-admin-pass-file /root/db-admin.pass
```

Note that with a restricted grant host, the web server's IP changing will break
every project's DB login until the grants are updated.

---

## What each project type gets written

| Type | File | Setting |
|---|---|---|
| Laravel | `.env` | `DB_HOST`, `DB_PORT` |
| Moodle | `config.php` | `$CFG->dbhost`, `$CFG->dboptions['dbport']` |
| WordPress | `wp-config.php` | `DB_HOST` as `host:port` |
| phpMyAdmin | `config.inc.php` | `$cfg['Servers'][$i]['host'` / `'port'` |

---

## Config keys

Written to `/etc/sre-helpers/setup.conf`:

```ini
SRE_DB_MODE="remote"          # or "local"
SRE_DB_HOST="db.internal"
SRE_DB_PORT="3306"
SRE_DB_ADMIN_USER="admin"
SRE_DB_GRANT_HOST="%"
SRE_DB_CLIENT_HOST="db.internal"
```

The **password is deliberately not** in this file — it lives in
`/etc/sre-helpers/db-admin.pass` (mode `600`), because `setup.conf` is sourced,
grepped and echoed throughout the scripts.

To switch back to a local server: `sudo bash stack/05-database.sh --local`.

---

## Limitations

- **PostgreSQL is local-only.** Its admin paths use `sudo -u postgres psql`
  (local peer authentication), which has no remote equivalent. Selecting
  PostgreSQL with `--remote` fails with an explanatory error rather than
  silently targeting a local server. MySQL and MariaDB are fully supported.
- **Server-wide charset changes** (`12-fixes.sh` →
  `set-server-default-utf8mb4`) are refused in remote mode: that server's
  `my.cnf` is not ours to edit. Per-database and per-table conversion still
  work remotely.
- **Redis** is unaffected and still installed locally by step 5.
- **Switching mode only affects projects provisioned afterwards.** Flipping an
  existing server to `--remote` does not migrate any data or rewrite any
  existing `.env` / `config.php`: projects already deployed keep pointing at
  the local server, and only newly provisioned/cloned/migrated ones use the
  remote host. Moving an existing project is a manual dump-and-restore plus a
  config edit.

---

## Troubleshooting

Every failure path prints specific checks. Re-running step 5 revalidates the
stored configuration and prints diagnostics without reinstalling anything:

```bash
sudo bash stack/05-database.sh --remote
# (press Enter at each prompt to keep the saved values)
```

To probe the stored config directly from a shell:

```bash
sudo bash -c 'source /opt/sre-scripts/common/lib.sh
              echo "Pointed at: $(db_describe)"
              echo "Grant host: $(db_grant_host)"
              echo "App DB_HOST: $(db_client_host):$(db_client_port)"
              db_check_connection'
```

Common causes when `db_check_connection` fails:

| Symptom | Cause |
|---|---|
| `Can't connect` / timeout | Firewall or `bind-address` on the remote server |
| `Access denied for user` | No grant for the admin user **from this host** |
| Connects, but `CREATE` fails | Admin user lacks `CREATE`/`GRANT OPTION` |
| App 500s, provisioning fine | `--db-grant-host` doesn't cover this server |

---

## Security notes

- Passwords are passed via a per-run `--defaults-extra-file` (mode `600`,
  removed on exit), never on the command line — so they are not visible in
  `ps` to other local users. This applies in local mode too.
- Traffic to a remote SQL server crosses the network. Prefer a private
  network/VLAN, and consider requiring TLS (`REQUIRE SSL` on the DB user).
- `/etc/sre-helpers/db-admin.pass` is a high-value credential: it is
  effectively root on the database server.
