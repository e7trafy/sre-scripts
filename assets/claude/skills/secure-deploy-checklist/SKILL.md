---
name: secure-deploy-checklist
description: Pre-flight security checklist to run before shipping to production. Use when the user says "ready to deploy", "going to prod", "release checklist", or invokes this by name. Verifies secrets hygiene, TLS, auth surface, backup readiness, and rollback plan.
---

# Secure-deploy checklist

Run this before any release that reaches production. Read each item and either confirm from the codebase / server or ask the user to confirm out-of-band.

## Secrets & config

- [ ] No secrets in the repo. Grep the diff: `git diff | grep -iE '(password|secret|token|api[_-]?key|-----BEGIN)'` — false positives are cheap, misses are expensive.
- [ ] `.env` is in `.gitignore` and not tracked (`git ls-files | grep '^\.env$'` returns nothing).
- [ ] `APP_DEBUG=false` in the production `.env`.
- [ ] Any new env var is documented in `.env.example`.

## TLS

- [ ] Certificate is valid for at least 30 more days: `echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null | openssl x509 -noout -enddate`.
- [ ] Full chain is served (leaf + intermediates), not just the leaf.
- [ ] Auto-renewal timer is enabled: `systemctl list-timers | grep certbot`.

## Auth surface

- [ ] Every new route has an authorization check (not just authentication).
- [ ] Rate limits on `/login`, `/register`, `/password/*`, and any endpoint that touches an external service.
- [ ] Session cookies are `HttpOnly`, `Secure`, `SameSite=Lax` (or `Strict`).

## DB

- [ ] Migrations are additive (no `dropColumn`, no `truncate` in a deploy migration).
- [ ] A backup ran within the last 24 hours AND has been verified with a test-restore this month.
- [ ] Binlog is enabled: `SHOW VARIABLES LIKE 'log_bin';` returns `ON`.

## Rollback

- [ ] Previous release is still on disk (Envoyer/Deployer-style: `releases/` symlinks).
- [ ] Migration is either backward-compatible OR you have a written down-migration.
- [ ] Someone other than you knows the rollback command and has run it in staging.

## Monitoring

- [ ] Log aggregation is receiving the new service (grep for a recent line in the aggregator).
- [ ] Uptime check exists and points at the health endpoint.
- [ ] On-call knows the release is going out.

## Output

If all boxes tick: `GO — cleared for deploy` and list any items the user must confirm out-of-band.
If any box fails: `NO-GO — blockers: <list>`. Do not soft-land this. The whole point of the checklist is to catch what excitement to ship glosses over.
