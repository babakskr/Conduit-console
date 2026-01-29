# KNOWN_RISKS (Single Source of Truth for Regressions)

This document lists **known regressions** observed in Conduit-console and the required **guards** to prevent reintroducing them.
Every change MUST reference which risk(s) it addresses.

---

## KR-001 — Live Dashboard becomes one-shot (exits after first render)

### Symptom
- Dashboard prints once and exits immediately.

### Root causes (common)
- `dashboard_loop()` calls `dashboard()` once and returns.
- Non-blocking input logic mistakenly triggers exit.
- Unhandled error causes script termination.

### Guard
- Implement a persistent loop with explicit exit keys.
- Add smoke test: run dashboard for >= 30 seconds.

---

## KR-002 — Missing UI helper functions (e.g., term_cols, repeat_char)

### Symptom
- Errors like: `term_cols: command not found`, `repeat_char: command not found`.

### Root causes
- Helper functions removed/renamed during edits.
- Partial merges / copy-paste issues.

### Guard
- All UI helpers must live in `lib/ui.sh` (or a dedicated section) and be unit-tested via `bash -n`.
- CI should fail if referenced helpers are missing.

---

## KR-003 — `set -u` crashes on unbound variables (e.g., tup, tdown)

### Symptom
- `unbound variable` and script exit.

### Root causes
- Variables not initialized in all paths.
- Typos in variable names.

### Guard
- Initialize dashboard totals to safe defaults before use.
- Use `${var:-default}` when rendering.

---

## KR-004 — Docker section becomes slow / blocks refresh

### Symptom
- Dashboard stalls for seconds/minutes, especially with many containers.

### Root causes
- Running `docker logs` for each container on every refresh.
- Serial per-container commands with no TTL/cache.
- Using `docker ps -a` causing unnecessary work on stopped containers.

### Guard (Performance Contract)
- In each refresh:
  - Max 1 call to `docker stats --no-stream`.
  - `docker logs` only via cache with TTL (default 10–15s).
  - Use bounded concurrency for log updates (e.g., 2–4).
- Show only **running** containers in dashboard view by default.

---

## KR-005 — Docker source-of-truth drift (wrong data source)

### Symptom
- Dashboard shows docker instances that are deleted/stopped.
- Values (-m/-b) mismatch actual runtime.

### Root causes
- Using local folders (`docker-instances/`) as truth for runtime state.
- Parsing config files instead of container runtime.

### Guard
- Runtime truth:
  - Containers list: `docker stats` / `docker ps` (running).
  - Stats line: last `[STATS]` from `docker logs` with cache.
- Local folders are **metadata only**, never status truth.

---

## KR-006 — Wrong docker create/run command (unknown command errors)

### Symptom
- Errors like: `unknown command "conduit start ... for "conduit"`.

### Root causes
- Wrapping commands incorrectly or double-prefixing executable.
- Passing unsupported flags (e.g., forcing `-d /home/conduit/data --stats-file ...` when upstream does not require it).

### Guard
- Use upstream recommended docker run pattern:
  - `docker run -d --name ... -v ... --restart unless-stopped ghcr.io/ssmirr/conduit/conduit:latest`
- Avoid injecting extra args unless explicitly confirmed supported.

---

## KR-007 — Unintended systemd units for Docker

### Symptom
- Created `*-docker.service` units for docker instances.

### Root cause
- Docker create flow generates systemd service files.

### Guard
- Docker lifecycle managed by Docker + restart policy.
- Do NOT generate systemd units for docker.

---

## KR-008 — Help/Docs standard violated (missing -h output)

### Symptom
- Scripts do not provide required help output.

### Guard
- Every script must implement `-h/--help` with:
  - Description, Usage, Options, at least 2 Examples.
- CI should validate help exists.

---

## KR-009 — Security: command injection via user inputs

### Symptom
- Arbitrary command execution possible via unsanitized instance names or user choices.

### Guard
- Whitelist instance patterns, e.g., `^conduit[0-9]+$` or `^Conduit[0-9]+\.docker$`.
- Never eval user input.
- Quote variables and use arrays for command invocation.

---

## KR-010 — Upstream changes not tracked

### Symptom
- Docker/run flags or output format changes upstream break parsing.

### Guard
- Scheduled upstream check (weekly) to open an issue when a new upstream release appears.
- Keep parser resilient to small format changes.
