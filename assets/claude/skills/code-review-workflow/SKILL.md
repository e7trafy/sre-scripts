---
name: code-review-workflow
description: Run a structured code review on the current change set. Use when the user says "review this", "review my code", "check this PR", or when about to commit. Combines the code-reviewer, security-specialist, and (if the diff touches infra) server-hardening-specialist agents.
---

# Code review workflow

Run this whenever a change is about to be committed or a PR is up for review.

## Steps

1. **Discover the change set**
   - If in git: `git diff --stat` and `git diff --name-only`.
   - If given a specific file/dir: use that.
   - If the diff is empty, ask the user what to review.

2. **Read the changed files in full**
   - Not just the diff — the full file, so you see the surrounding context.
   - Also read one or two sibling files in the same directory to learn the project's conventions.

3. **Invoke `code-reviewer`** with the change set as context. Collect its findings.

4. **If the diff touches** — auth, session, uploads, DB queries, deserialization, file paths, shell exec, template rendering, external HTTP — **also invoke `security-specialist`**.

5. **If the diff touches** — `/etc/`, systemd units, nginx/apache/php-fpm config, firewall rules, SSH config — **also invoke `server-hardening-specialist`**.

6. **Merge findings.** De-duplicate. Group by severity.

7. **Present**: BLOCKING first, then IMPORTANT, then NIT. For each finding: `file:line — what — why — fix`.

8. **End with a verdict**: `LGTM`, `LGTM with nits`, `Needs changes`, or `Blocked — do not merge`.

## Never

- Never approve a diff without reading the changed files. The diff is not enough.
- Never mix "review findings" with "here's how I'd rewrite it." The review names problems; the fix is a separate turn.
- Never invent findings to look thorough. If the code is fine, say so in one line.
