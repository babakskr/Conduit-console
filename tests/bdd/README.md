# Conduit-console BDD Suite

This folder contains Gherkin feature specifications derived from project rules, concepts, and known risks.

## Structure
- `features/00-project-governance.feature`
- `features/01-dashboard-stability.feature`
- `features/02-ui-helpers-and-unbound-vars.feature`
- `features/03-docker-performance-and-source-of-truth.feature`
- `features/04-docker-lifecycle-standards.feature`
- `features/05-help-and-docs.feature`
- `features/06-security-input-validation.feature`
- `features/07-release-and-upstream-tracking.feature`

## Mapping
- AI policy: `docs/AI_DEV_GUIDELINES.md`
- Regression guards: `docs/KNOWN_RISKS.md`
- Handoff checklist: `docs/AI_HANDOFF.md`

## Usage
Use these files as behavior contracts for manual testing, CI checks, or automated BDD runners.
