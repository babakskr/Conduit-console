# AI Handoff Log (Operational Template)

This file is the **single coordination point** for multiple AI assistants (e.g., GPT + Gemini) working on the Conduit-console repository **without conflicts**.

## Purpose
- Prevent overlapping edits to the same files.
- Preserve approved behavior (immutability) and reduce regressions.
- Make every change traceable and reversible.

---

## Daily Entry Format (Copy/Paste)

### YYYY-MM-DD — Owner: <AI name / Human>
**Branch:** `<branch-name>`
**Scope:** `<short scope>`
**Baseline / Target:** `stable/v0.1.3` (commit/tag: `<hash or tag>`)

**Files touched (exact list):**
- `path/file1`
- `path/file2`

**Files explicitly NOT touched (immutability guard):**
- `lib/systemd.sh` (native menu)
- `<any other locked module>`

**Change summary (bullets, factual):**
- ...
- ...

**Why (problem statement):**
- ...

**Risk / Regression checklist (tick all that apply):**
- [ ] `bash -n` passes
- [ ] `./conduit-console.sh -h` prints Description/Usage/Options/Examples
- [ ] Dashboard runs >= 30s without exiting/crash
- [ ] Docker data source = runtime (`docker stats`/`docker ps`) + cached `docker logs`
- [ ] No new external dependencies added

**Test evidence (commands + short outputs):**
```bash
bash -n conduit-console.sh
./conduit-console.sh -h | head
```

**Next steps (handoff):**
- ...

**Notes for the other AI(s):**
- DO NOT edit: `...`
- You may edit: `...` (recommended areas)

---

## Ownership & No-Conflict Rules

### File ownership (default)
- GPT: `lib/docker.sh`, `lib/ui.sh`, performance/caching, htop-like loop.
- Gemini: `README.md`, `docs/*`, help text/examples, policy documents.
- Shared (requires review): `conduit-console.sh`, `lib/core.sh`.

### Hard rule
If an AI is working on a file in its branch, **no other AI edits that same file** until merge.

---

## Branch Naming Convention
- `feat/<area>-<short-desc>` (features)
- `fix/<area>-<short-desc>` (bug fixes)
- `docs/<topic>` (documentation)
- `ci/<topic>` (CI workflow changes)

Examples:
- `fix/docker-cache-ttl`
- `feat/ui-htop-loop`
- `docs/help-standard`
- `ci/bash-syntax-check`