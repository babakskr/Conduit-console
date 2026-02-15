#!/usr/bin/env bash
set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
BDD_DIR="$ROOT_DIR/tests/bdd"
FEATURE_DIR="$BDD_DIR/features"
REPORT_DIR="$BDD_DIR/reports"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_FILE="$REPORT_DIR/ab-report-$STAMP.txt"

mkdir -p "$REPORT_DIR"

PASS=0
FAIL=0

pass() { printf '[PASS] %s\n' "$*" | tee -a "$REPORT_FILE" >/dev/null; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$*" | tee -a "$REPORT_FILE" >/dev/null; FAIL=$((FAIL+1)); }
section() { printf '\n=== %s ===\n' "$*" | tee -a "$REPORT_FILE" >/dev/null; }

must_exist() {
  local path="$1"
  if [[ -e "$path" ]]; then pass "exists: ${path#$ROOT_DIR/}"; else fail "missing: ${path#$ROOT_DIR/}"; fi
}

must_match() {
  local pattern="$1"; local file="$2"; local msg="$3"
  if rg -n -- "$pattern" "$file" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi
}

must_not_match() {
  local pattern="$1"; local file="$2"; local msg="$3"
  if rg -n -- "$pattern" "$file" >/dev/null 2>&1; then fail "$msg"; else pass "$msg"; fi
}

feature_syntax_check() {
  local f="$1"
  local scenarios
  scenarios=$(rg -c '^\s*Scenario' "$f")
  if [[ "$scenarios" -gt 0 ]]; then pass "feature has scenarios: ${f#$ROOT_DIR/}"; else fail "feature has scenarios: ${f#$ROOT_DIR/}"; fi

  awk '
    BEGIN { in_s=0; g=0; w=0; t=0; bad=0 }
    /^\s*Scenario:/ {
      if (in_s && !(g && w && t)) bad=1
      in_s=1; g=0; w=0; t=0
      next
    }
    in_s && /^\s*Given / { g=1; next }
    in_s && /^\s*When /  { w=1; next }
    in_s && /^\s*Then /  { t=1; next }
    END {
      if (in_s && !(g && w && t)) bad=1
      exit bad
    }
  ' "$f" && pass "G/W/T present in scenarios: ${f#$ROOT_DIR/}" || fail "G/W/T present in scenarios: ${f#$ROOT_DIR/}"
}

ab_a_strict_contracts() {
  section "A: Strict contracts"

  must_exist "$ROOT_DIR/docs/BDD_GHERKIN_STANDARDS.md"
  must_exist "$BDD_DIR/README.md"

  # repo + script contracts
  must_match 'set -u -o pipefail' "$ROOT_DIR/conduit-console.sh" 'conduit-console uses strict mode'
  must_match 'source "\$\{PROJECT_CONF\}"|source "\$\{PROJECT_CONF:-' "$ROOT_DIR/conduit-console.sh" 'project.conf is sourced'
  must_match '--restart unless-stopped' "$ROOT_DIR/conduit-console.sh" 'docker restart policy is unless-stopped'
  if rg -n '^\s*[^#].*\bdocker-compose\b' "$ROOT_DIR/conduit-console.sh" >/dev/null 2>&1; then
    fail 'no docker-compose command usage in core console'
  else
    pass 'no docker-compose command usage in core console'
  fi
  must_match 'docker inspect' "$ROOT_DIR/conduit-console.sh" 'docker inspect is used for runtime parsing'
  must_match '^show_help\(\)' "$ROOT_DIR/conduit-console.sh" 'help function exists in conduit-console'

  # verify README generation contract exists in git_op
  must_match 'README\.md updated|Generating professional.*README\.md' "$ROOT_DIR/git_op.sh" 'git_op contains README generation logic'

  # static syntax
  bash -n "$ROOT_DIR/conduit-console.sh" && pass 'bash -n conduit-console.sh' || fail 'bash -n conduit-console.sh'
  bash -n "$ROOT_DIR/conduit-optimizer.sh" && pass 'bash -n conduit-optimizer.sh' || fail 'bash -n conduit-optimizer.sh'
  bash -n "$ROOT_DIR/lb-wizard.sh" && pass 'bash -n lb-wizard.sh' || fail 'bash -n lb-wizard.sh'
  bash -n "$ROOT_DIR/git_op.sh" && pass 'bash -n git_op.sh' || fail 'bash -n git_op.sh'

  for f in "$FEATURE_DIR"/*.feature; do
    feature_syntax_check "$f"
  done
}

ab_b_logic_and_understandability() {
  section "B: Logic + understandability"

  # Scenario naming style consistency
  if rg -n '^\s*Scenario:\s+(Contract|Regression|Security|Ops):' "$FEATURE_DIR"/*.feature >/dev/null 2>&1; then
    pass 'scenario prefixes are present'
  else
    fail 'scenario prefixes are present'
  fi

  # Verify risk tags used for KR scenarios
  if rg -n '@KR-00[1-9]|@KR-010' "$FEATURE_DIR"/*.feature >/dev/null 2>&1; then
    pass 'KR tags are present'
  else
    fail 'KR tags are present'
  fi

  # Readability heuristic: average step length <= 16 words
  local avg
  avg=$(awk '
    /^\s*(Given|When|Then|And) / {
      n=split($0,a,/ +/); total+=n; count++
    }
    END { if(count==0){print 999}else{printf "%.2f", total/count} }
  ' "$FEATURE_DIR"/*.feature)
  awk -v x="$avg" 'BEGIN{exit (x<=16.0)?0:1}' && pass "average step length is readable (${avg} words)" || fail "average step length is readable (${avg} words)"

  # Verify each feature has domain tags
  local missing=0
  for f in "$FEATURE_DIR"/*.feature; do
    if ! rg -n '^\s*@' "$f" >/dev/null 2>&1; then
      fail "missing tags: ${f#$ROOT_DIR/}"
      missing=1
    else
      pass "tags present: ${f#$ROOT_DIR/}"
    fi
  done

  # Verify key logic statements are anchored by code/docs evidence
  must_match 'dashboard_loop\(\)' "$ROOT_DIR/conduit-console.sh" 'dashboard loop implementation exists'
  must_match 'list_docker_conduits_running' "$ROOT_DIR/conduit-console.sh" 'running-only docker listing function exists'
  must_match 'docker logs --tail' "$ROOT_DIR/conduit-console.sh" 'docker log tail collection exists'
  must_match 'stats_cache' "$ROOT_DIR/conduit-console.sh" 'stats cache concept exists'
  must_match 'README\.md.*auto-generated|README\.md.*auto-generated by `git_op\.sh`|Generating professional.*README\.md' "$ROOT_DIR/docs/AI_DEV_GUIDELINES.md" 'docs declare README generation policy'
}

section "A/B test start"
printf 'Repository: %s\n' "$ROOT_DIR" | tee -a "$REPORT_FILE" >/dev/null
printf 'Timestamp: %s\n' "$(date -Iseconds)" | tee -a "$REPORT_FILE" >/dev/null

ab_a_strict_contracts
ab_b_logic_and_understandability

section "Summary"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL" | tee -a "$REPORT_FILE" >/dev/null

if [[ "$FAIL" -eq 0 ]]; then
  printf 'RESULT=SUCCESS\n' | tee -a "$REPORT_FILE" >/dev/null
  echo "$REPORT_FILE"
  exit 0
else
  printf 'RESULT=FAILED\n' | tee -a "$REPORT_FILE" >/dev/null
  echo "$REPORT_FILE"
  exit 1
fi
