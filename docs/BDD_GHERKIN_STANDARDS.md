# Gherkin BDD Standards for Conduit-console

## Purpose
This file defines how to write Behavior-Driven Development (BDD) scenarios for this repository.
It is derived from:
- `docs/AI_DEV_GUIDELINES.md`
- `docs/KNOWN_RISKS.md`
- `docs/AI_HANDOFF.md`
- runtime patterns in `conduit-console.sh`

## Project Concepts
- The product is a Bash TUI manager for Native (systemd) and Docker Conduit instances.
- Native and Docker flows are separate domains and must remain separated.
- Runtime truth for Docker state is Docker itself (`docker ps`, `docker stats`, cached `docker logs`).
- `project.conf` is the source of truth for project branding values.
- Release operations are governed by `git_op.sh`.

## BDD Writing Rules
- Use plain English only.
- Every `Feature` must represent one behavior contract.
- Every `Scenario` must have deterministic Given/When/Then steps.
- Prefer observable outcomes (exit code, output contract, state change).
- Tag scenarios with risk IDs when relevant, for example: `@KR-004`.
- Keep scenarios implementation-agnostic; avoid embedding shell internals in step text.
- Include negative paths for security and regression-critical behavior.

## Mandatory Rule Coverage
Every BDD suite for this repo must cover these rules:
1. Bash safety baseline: scripts use `set -u -o pipefail` and avoid unstable behavior.
2. Dashboard persistence: live dashboard does not become one-shot (KR-001).
3. UI helper integrity: referenced helper functions exist (KR-002).
4. Unbound variable protection with safe defaults (KR-003).
5. Docker performance contract: bounded calls, cache TTL, no refresh blocking (KR-004).
6. Docker source of truth: runtime data over local metadata (KR-005).
7. Docker create/run command contract and no unsupported flag injection (KR-006).
8. No systemd unit generation for Docker instances (KR-007).
9. Help contract: Description, Usage, Options, Examples (KR-008).
10. Input validation and quoting to prevent command injection (KR-009).
11. Upstream change monitoring expectation (KR-010).
12. Release workflow contract: use `git_op.sh` as project protocol.

## Scenario Design Conventions
- Use one of these prefixes in scenario titles:
  - `Contract:` for policy-level behavior
  - `Regression:` for known risk prevention
  - `Security:` for abuse-case prevention
  - `Ops:` for operational/release behavior
- Use `Background` only for shared environment assumptions.
- Keep each scenario focused on one assertion set.
- Use `Scenario Outline` only when the same behavior repeats with small data variations.

## Suggested Tags
- Domain tags: `@native`, `@docker`, `@dashboard`, `@release`, `@docs`, `@security`
- Risk tags: `@KR-001` ... `@KR-010`
- Execution tags: `@smoke`, `@critical`, `@slow`

## Step Vocabulary (Recommended)
Use stable wording to keep scenarios readable and automatable:
- Given the console is started with valid prerequisites
- Given Docker is available/unavailable
- When the operator opens the dashboard
- When the operator creates a Docker instance
- Then the dashboard continues refreshing
- Then only running Docker containers are listed
- Then no Docker systemd unit is created
- Then help output contains Description, Usage, Options, and Examples
- Then unsafe input is rejected with an error

## Test Evidence Expectations
For each implemented scenario, record evidence in CI or handoff notes:
- command run
- concise output snippet
- pass/fail result

Minimum smoke evidence:
- `bash -n conduit-console.sh`
- `./conduit-console.sh -h`
- dashboard stability run >= 30 seconds (KR-001)

## Folder Standard
Place BDD assets under:
- `tests/bdd/README.md`
- `tests/bdd/features/*.feature`

Recommended grouping:
- governance and architecture contracts
- dashboard/runtime contracts
- docker contracts
- docs/help contracts
- security contracts
- release/upstream contracts
