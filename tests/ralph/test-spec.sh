#!/usr/bin/env bash
# Integration tests for ralph spec commands
# Tests annotation counting, verbose output, verify/judge runners, and --all flag
# shellcheck disable=SC2329,SC2086,SC2034,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MOCK_CLAUDE="$SCRIPT_DIR/mock-claude"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"
LIB_DIR="$SCRIPT_DIR/lib"

# Source test libraries
source "$LIB_DIR/assertions.sh"
source "$LIB_DIR/fixtures.sh"
source "$LIB_DIR/runner.sh"

init_test_state
setup_colors

#-----------------------------------------------------------------------------
# Helper: check if ralph-spec command is available
#-----------------------------------------------------------------------------
has_ralph_spec() {
  command -v ralph-spec &>/dev/null
}

#-----------------------------------------------------------------------------
# Helper: create a sample spec with mixed annotations for testing
#-----------------------------------------------------------------------------
create_annotated_spec() {
  local spec_file="$1"
  cat > "$spec_file" << 'SPEC'
# Test Feature

## Requirements

Some requirements.

## Success Criteria

- [ ] Fast response time
  [verify](tests/perf-test.sh::test_response_time)
- [ ] Output is human-readable
  [judge](tests/judges/readability.sh::test_readable_output)
- [ ] Works offline
- [x] Basic API works
  [verify](tests/api.sh::test_basic_api)
- [ ] Handles edge cases gracefully
  [judge](tests/judges/edge.sh::test_edge_cases)
- [ ] No security vulnerabilities

## Out of Scope

Nothing relevant.
SPEC
}

#-----------------------------------------------------------------------------
# Test: ralph spec produces correct annotation counts
#-----------------------------------------------------------------------------
test_spec_annotation_counts() {
  CURRENT_TEST="spec_annotation_counts"
  test_header "Ralph Spec Annotation Counts"

  setup_test_env "spec-counts"

  if ! has_ralph_spec; then
    test_skip "ralph-spec command not available (spec.sh not yet implemented)"
    teardown_test_env
    return
  fi

  # Create spec files with known annotations
  create_annotated_spec "$TEST_DIR/specs/test-feature.md"

  # Create a second spec with different counts
  cat > "$TEST_DIR/specs/other-feature.md" << 'SPEC'
# Other Feature

## Success Criteria

- [ ] Criterion A
- [ ] Criterion B
- [ ] Criterion C
  [verify](tests/c-test.sh::test_c)

## Design

Design section.
SPEC

  # Set up current.json
  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  local output
  output=$(ralph-spec 2>&1) || true

  # Should list spec files with annotation counts
  if echo "$output" | grep -q "test-feature.md"; then
    test_pass "Output includes test-feature.md"
  else
    test_fail "Output should include test-feature.md"
  fi

  if echo "$output" | grep -q "other-feature.md"; then
    test_pass "Output includes other-feature.md"
  else
    test_fail "Output should include other-feature.md"
  fi

  # test-feature.md has 2 verify, 2 judge, 2 unannotated
  if echo "$output" | grep "test-feature.md" | grep -q "2 verify"; then
    test_pass "test-feature.md shows 2 verify"
  else
    test_fail "test-feature.md should show 2 verify"
  fi

  if echo "$output" | grep "test-feature.md" | grep -q "2 judge"; then
    test_pass "test-feature.md shows 2 judge"
  else
    test_fail "test-feature.md should show 2 judge"
  fi

  if echo "$output" | grep "test-feature.md" | grep -q "2 unannotated"; then
    test_pass "test-feature.md shows 2 unannotated"
  else
    test_fail "test-feature.md should show 2 unannotated"
  fi

  # Should show totals
  if echo "$output" | grep -qi "total"; then
    test_pass "Output includes totals"
  else
    test_fail "Output should include totals"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: ralph spec --verbose shows per-criterion detail
#-----------------------------------------------------------------------------
test_spec_verbose() {
  CURRENT_TEST="spec_verbose"
  test_header "Ralph Spec --verbose"

  setup_test_env "spec-verbose"

  if ! has_ralph_spec; then
    test_skip "ralph-spec command not available (spec.sh not yet implemented)"
    teardown_test_env
    return
  fi

  create_annotated_spec "$TEST_DIR/specs/test-feature.md"

  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  local output
  output=$(ralph-spec --verbose 2>&1) || true

  # Should show individual criterion text
  if echo "$output" | grep -q "Fast response time"; then
    test_pass "Shows criterion text: Fast response time"
  else
    test_fail "Should show criterion text: Fast response time"
  fi

  if echo "$output" | grep -q "Output is human-readable"; then
    test_pass "Shows criterion text: Output is human-readable"
  else
    test_fail "Should show criterion text: Output is human-readable"
  fi

  if echo "$output" | grep -q "Works offline"; then
    test_pass "Shows unannotated criterion: Works offline"
  else
    test_fail "Should show unannotated criterion: Works offline"
  fi

  # Should indicate annotation types per criterion
  if echo "$output" | grep -q "verify"; then
    test_pass "Shows verify annotation type"
  else
    test_fail "Should show verify annotation type"
  fi

  if echo "$output" | grep -q "judge"; then
    test_pass "Shows judge annotation type"
  else
    test_fail "Should show judge annotation type"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: ralph spec --verify runs shell tests and reports PASS/FAIL/SKIP
#-----------------------------------------------------------------------------
test_spec_verify() {
  CURRENT_TEST="spec_verify"
  test_header "Ralph Spec --verify"

  setup_test_env "spec-verify"

  if ! has_ralph_spec; then
    test_skip "ralph-spec command not available (spec.sh not yet implemented)"
    teardown_test_env
    return
  fi

  # Create a spec with verify and judge annotations
  cat > "$TEST_DIR/specs/test-feature.md" << 'SPEC'
# Test Feature

## Success Criteria

- [ ] Test passes
  [verify](tests/pass-test.sh::test_passes)
- [ ] Test fails
  [verify](tests/fail-test.sh::test_fails)
- [ ] Judge only criterion
  [judge](tests/judges/check.sh::test_judge)
- [ ] No annotation
SPEC

  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  # Create test files: one that passes, one that fails
  mkdir -p "$TEST_DIR/tests/judges"

  cat > "$TEST_DIR/tests/pass-test.sh" << 'TESTFILE'
#!/usr/bin/env bash
test_passes() {
  echo "All good"
  return 0
}
# If function name passed as arg, call it
if [ $# -gt 0 ]; then "$@"; fi
TESTFILE
  chmod +x "$TEST_DIR/tests/pass-test.sh"

  cat > "$TEST_DIR/tests/fail-test.sh" << 'TESTFILE'
#!/usr/bin/env bash
test_fails() {
  echo "Something went wrong"
  return 1
}
# If function name passed as arg, call it
if [ $# -gt 0 ]; then "$@"; fi
TESTFILE
  chmod +x "$TEST_DIR/tests/fail-test.sh"

  local output
  set +e
  output=$(ralph-spec --verify 2>&1)
  local exit_code=$?
  set -e

  # Should show PASS for passing test
  if echo "$output" | grep -q "\[PASS\]"; then
    test_pass "Shows [PASS] for passing test"
  else
    test_fail "Should show [PASS] for passing test"
  fi

  # Should show FAIL for failing test
  if echo "$output" | grep -q "\[FAIL\]"; then
    test_pass "Shows [FAIL] for failing test"
  else
    test_fail "Should show [FAIL] for failing test"
  fi

  # Should show SKIP for judge-only criterion
  if echo "$output" | grep "Judge only criterion" | grep -q "\[SKIP\]"; then
    test_pass "Shows [SKIP] for judge-only criterion"
  else
    test_fail "Should show [SKIP] for judge-only criterion"
  fi

  # Should show SKIP for unannotated criterion
  if echo "$output" | grep "No annotation" | grep -q "\[SKIP\]"; then
    test_pass "Shows [SKIP] for unannotated criterion"
  else
    test_fail "Should show [SKIP] for unannotated criterion"
  fi

  # Should show summary
  if echo "$output" | grep -q "passed"; then
    test_pass "Shows pass count in summary"
  else
    test_fail "Should show pass count in summary"
  fi

  if echo "$output" | grep -q "failed"; then
    test_pass "Shows fail count in summary"
  else
    test_fail "Should show fail count in summary"
  fi

  if echo "$output" | grep -q "skipped"; then
    test_pass "Shows skip count in summary"
  else
    test_fail "Should show skip count in summary"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: ralph spec --judge invokes LLM evaluation (mocked)
#-----------------------------------------------------------------------------
test_spec_judge() {
  CURRENT_TEST="spec_judge"
  test_header "Ralph Spec --judge (Mocked)"

  setup_test_env "spec-judge"

  if ! has_ralph_spec; then
    test_skip "ralph-spec command not available (spec.sh not yet implemented)"
    teardown_test_env
    return
  fi

  # Create a spec with judge annotations
  cat > "$TEST_DIR/specs/test-feature.md" << 'SPEC'
# Test Feature

## Success Criteria

- [ ] Verify only criterion
  [verify](tests/some-test.sh::test_something)
- [ ] Judge criterion
  [judge](tests/judges/quality.sh::test_quality)
- [ ] No annotation
SPEC

  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  # Create judge test file with rubric
  mkdir -p "$TEST_DIR/tests/judges"
  cat > "$TEST_DIR/tests/judges/quality.sh" << 'TESTFILE'
#!/usr/bin/env bash
test_quality() {
  judge_files "lib/output.sh"
  judge_criterion "Output is well-formatted and includes all required fields"
}
TESTFILE

  local output
  set +e
  output=$(ralph-spec --judge 2>&1)
  local exit_code=$?
  set -e

  # Should show SKIP for verify-only criterion
  if echo "$output" | grep "Verify only criterion" | grep -q "\[SKIP\]"; then
    test_pass "Shows [SKIP] for verify-only criterion"
  else
    test_fail "Should show [SKIP] for verify-only criterion"
  fi

  # Should show SKIP for unannotated criterion
  if echo "$output" | grep "No annotation" | grep -q "\[SKIP\]"; then
    test_pass "Shows [SKIP] for unannotated criterion"
  else
    test_fail "Should show [SKIP] for unannotated criterion"
  fi

  # Judge criterion should not be skipped (should show PASS or FAIL)
  if echo "$output" | grep "Judge criterion" | grep -qv "\[SKIP\]"; then
    test_pass "Judge criterion is not skipped"
  else
    test_fail "Judge criterion should not be skipped"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: ralph spec --all runs both verify and judge
#-----------------------------------------------------------------------------
test_spec_all() {
  CURRENT_TEST="spec_all"
  test_header "Ralph Spec --all"

  setup_test_env "spec-all"

  if ! has_ralph_spec; then
    test_skip "ralph-spec command not available (spec.sh not yet implemented)"
    teardown_test_env
    return
  fi

  # Create spec with both verify and judge
  cat > "$TEST_DIR/specs/test-feature.md" << 'SPEC'
# Test Feature

## Success Criteria

- [ ] Verify criterion
  [verify](tests/check.sh::test_check)
- [ ] Judge criterion
  [judge](tests/judges/eval.sh::test_eval)
- [ ] No annotation
SPEC

  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  mkdir -p "$TEST_DIR/tests/judges"
  cat > "$TEST_DIR/tests/check.sh" << 'TESTFILE'
#!/usr/bin/env bash
test_check() { return 0; }
if [ $# -gt 0 ]; then "$@"; fi
TESTFILE
  chmod +x "$TEST_DIR/tests/check.sh"

  cat > "$TEST_DIR/tests/judges/eval.sh" << 'TESTFILE'
#!/usr/bin/env bash
test_eval() {
  judge_files "lib/main.sh"
  judge_criterion "Code is correct"
}
TESTFILE

  local output
  set +e
  output=$(ralph-spec --all 2>&1)
  local exit_code=$?
  set -e

  # --all should NOT skip verify criteria (they run in verify pass)
  if echo "$output" | grep "Verify criterion" | grep -qv "\[SKIP\]"; then
    test_pass "Verify criterion is not skipped with --all"
  else
    test_fail "Verify criterion should not be skipped with --all"
  fi

  # --all should NOT skip judge criteria (they run in judge pass)
  if echo "$output" | grep "Judge criterion" | grep -qv "\[SKIP\]"; then
    test_pass "Judge criterion is not skipped with --all"
  else
    test_fail "Judge criterion should not be skipped with --all"
  fi

  # Unannotated should still be skipped
  if echo "$output" | grep "No annotation" | grep -q "\[SKIP\]"; then
    test_pass "Unannotated criterion still skipped with --all"
  else
    test_fail "Unannotated criterion should be skipped with --all"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: ralph spec with no flags is instant (no test execution)
#-----------------------------------------------------------------------------
test_spec_no_execution_default() {
  CURRENT_TEST="spec_no_execution_default"
  test_header "Ralph Spec Default (No Execution)"

  setup_test_env "spec-no-exec"

  if ! has_ralph_spec; then
    test_skip "ralph-spec command not available (spec.sh not yet implemented)"
    teardown_test_env
    return
  fi

  # Create a spec with verify annotations pointing to slow tests
  cat > "$TEST_DIR/specs/test-feature.md" << 'SPEC'
# Test Feature

## Success Criteria

- [ ] Slow test criterion
  [verify](tests/slow-test.sh::test_slow)
SPEC

  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  # Create a test file that would take time to execute
  mkdir -p "$TEST_DIR/tests"
  cat > "$TEST_DIR/tests/slow-test.sh" << 'TESTFILE'
#!/usr/bin/env bash
test_slow() {
  sleep 10
  return 0
}
if [ $# -gt 0 ]; then "$@"; fi
TESTFILE
  chmod +x "$TEST_DIR/tests/slow-test.sh"

  # ralph spec (no flags) should return quickly without executing tests
  local start_time end_time elapsed
  start_time=$(date +%s)

  set +e
  ralph-spec >/dev/null 2>&1
  set -e

  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  # Should finish in under 5 seconds (the test sleeps for 10)
  if [ "$elapsed" -lt 5 ]; then
    test_pass "Default ralph spec completes quickly (${elapsed}s)"
  else
    test_fail "Default ralph spec took too long (${elapsed}s) - may be executing tests"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: parse_spec_annotations counts verify/judge/unannotated correctly
# This tests the util.sh function directly, independent of spec.sh
#-----------------------------------------------------------------------------
test_spec_annotation_counting() {
  CURRENT_TEST="spec_annotation_counting"
  test_header "Spec Annotation Counting via parse_spec_annotations"

  setup_test_env "spec-counting"

  # Source util.sh directly
  # shellcheck source=../../lib/ralph/cmd/util.sh
  source "$REPO_ROOT/lib/ralph/cmd/util.sh"

  create_annotated_spec "$TEST_DIR/specs/test-feature.md"

  local output
  output=$(parse_spec_annotations "$TEST_DIR/specs/test-feature.md")

  # Count annotations by type
  local verify_count judge_count none_count
  verify_count=$(echo "$output" | awk -F'\t' '$2 == "verify"' | wc -l)
  judge_count=$(echo "$output" | awk -F'\t' '$2 == "judge"' | wc -l)
  none_count=$(echo "$output" | awk -F'\t' '$2 == "none"' | wc -l)

  if [ "$verify_count" -eq 2 ]; then
    test_pass "Counts 2 verify annotations"
  else
    test_fail "Expected 2 verify annotations, got $verify_count"
  fi

  if [ "$judge_count" -eq 2 ]; then
    test_pass "Counts 2 judge annotations"
  else
    test_fail "Expected 2 judge annotations, got $judge_count"
  fi

  if [ "$none_count" -eq 2 ]; then
    test_pass "Counts 2 unannotated criteria"
  else
    test_fail "Expected 2 unannotated criteria, got $none_count"
  fi

  # Verify total criterion count
  local total
  total=$(echo "$output" | wc -l)
  if [ "$total" -eq 6 ]; then
    test_pass "Total criterion count is 6"
  else
    test_fail "Expected 6 total criteria, got $total"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: annotation parsing handles spec with only verify annotations
#-----------------------------------------------------------------------------
test_spec_verify_only() {
  CURRENT_TEST="spec_verify_only"
  test_header "Spec with Only Verify Annotations"

  setup_test_env "spec-verify-only"

  # shellcheck source=../../lib/ralph/cmd/util.sh
  source "$REPO_ROOT/lib/ralph/cmd/util.sh"

  cat > "$TEST_DIR/specs/verify-only.md" << 'SPEC'
# Verify-Only Feature

## Success Criteria

- [ ] First check
  [verify](tests/a.sh::test_a)
- [ ] Second check
  [verify](tests/b.sh::test_b)
- [ ] Third check
  [verify](tests/c.sh)
SPEC

  local output
  output=$(parse_spec_annotations "$TEST_DIR/specs/verify-only.md")

  local verify_count judge_count none_count
  verify_count=$(echo "$output" | awk -F'\t' '$2 == "verify"' | wc -l)
  judge_count=$(echo "$output" | awk -F'\t' '$2 == "judge"' | wc -l)
  none_count=$(echo "$output" | awk -F'\t' '$2 == "none"' | wc -l)

  if [ "$verify_count" -eq 3 ]; then
    test_pass "All 3 annotations are verify"
  else
    test_fail "Expected 3 verify, got $verify_count"
  fi

  if [ "$judge_count" -eq 0 ]; then
    test_pass "No judge annotations"
  else
    test_fail "Expected 0 judge, got $judge_count"
  fi

  if [ "$none_count" -eq 0 ]; then
    test_pass "No unannotated criteria"
  else
    test_fail "Expected 0 unannotated, got $none_count"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: annotation parsing handles spec with only unannotated criteria
#-----------------------------------------------------------------------------
test_spec_all_unannotated() {
  CURRENT_TEST="spec_all_unannotated"
  test_header "Spec with All Unannotated Criteria"

  setup_test_env "spec-unannotated"

  # shellcheck source=../../lib/ralph/cmd/util.sh
  source "$REPO_ROOT/lib/ralph/cmd/util.sh"

  cat > "$TEST_DIR/specs/unannotated.md" << 'SPEC'
# Unannotated Feature

## Success Criteria

- [ ] Criterion one
- [ ] Criterion two
- [ ] Criterion three
- [x] Criterion four (checked)

## Out of Scope

Nothing.
SPEC

  local output
  output=$(parse_spec_annotations "$TEST_DIR/specs/unannotated.md")

  local verify_count judge_count none_count
  verify_count=$(echo "$output" | awk -F'\t' '$2 == "verify"' | wc -l)
  judge_count=$(echo "$output" | awk -F'\t' '$2 == "judge"' | wc -l)
  none_count=$(echo "$output" | awk -F'\t' '$2 == "none"' | wc -l)

  if [ "$verify_count" -eq 0 ] && [ "$judge_count" -eq 0 ]; then
    test_pass "No verify or judge annotations"
  else
    test_fail "Expected 0 verify and 0 judge, got $verify_count verify and $judge_count judge"
  fi

  if [ "$none_count" -eq 4 ]; then
    test_pass "All 4 criteria are unannotated"
  else
    test_fail "Expected 4 unannotated, got $none_count"
  fi

  # Verify checked status is captured
  local checked_count
  checked_count=$(echo "$output" | awk -F'\t' '$5 == "x"' | wc -l)
  if [ "$checked_count" -eq 1 ]; then
    test_pass "One criterion has checked status"
  else
    test_fail "Expected 1 checked criterion, got $checked_count"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: annotation parsing preserves criterion text accurately
#-----------------------------------------------------------------------------
test_spec_criterion_text_preservation() {
  CURRENT_TEST="spec_criterion_text_preservation"
  test_header "Spec Criterion Text Preservation"

  setup_test_env "spec-text"

  # shellcheck source=../../lib/ralph/cmd/util.sh
  source "$REPO_ROOT/lib/ralph/cmd/util.sh"

  cat > "$TEST_DIR/specs/text-test.md" << 'SPEC'
# Text Feature

## Success Criteria

- [ ] `ralph spec` lists all spec files with annotation counts (verify/judge/unannotated)
  [verify](tests/spec-test.sh::test_counts)
- [ ] Criteria with no annotation show as SKIP in verify/judge output
- [ ] `ralph spec --verify` runs shell tests and reports PASS/FAIL/SKIP
  [judge](tests/judges/spec.sh::test_verify)
SPEC

  local output
  output=$(parse_spec_annotations "$TEST_DIR/specs/text-test.md")

  # Check that criterion text with backticks and special chars is preserved
  local line1
  line1=$(echo "$output" | sed -n '1p')
  if echo "$line1" | grep -q 'ralph spec.*lists all spec files'; then
    test_pass "Preserves backtick-containing criterion text"
  else
    test_fail "Should preserve criterion text with backticks: $line1"
  fi

  local line2
  line2=$(echo "$output" | sed -n '2p')
  if echo "$line2" | grep -q 'no annotation show as SKIP'; then
    test_pass "Preserves criterion text with mixed formatting"
  else
    test_fail "Should preserve criterion text: $line2"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: multiple spec files can be parsed independently
#-----------------------------------------------------------------------------
test_spec_multiple_files() {
  CURRENT_TEST="spec_multiple_files"
  test_header "Parse Multiple Spec Files"

  setup_test_env "spec-multi"

  # shellcheck source=../../lib/ralph/cmd/util.sh
  source "$REPO_ROOT/lib/ralph/cmd/util.sh"

  # Create first spec
  cat > "$TEST_DIR/specs/feature-a.md" << 'SPEC'
# Feature A

## Success Criteria

- [ ] A criterion 1
  [verify](tests/a1.sh::test_a1)
- [ ] A criterion 2

## Design

Design A.
SPEC

  # Create second spec
  cat > "$TEST_DIR/specs/feature-b.md" << 'SPEC'
# Feature B

## Success Criteria

- [ ] B criterion 1
  [judge](tests/judges/b1.sh::test_b1)
- [ ] B criterion 2
  [verify](tests/b2.sh::test_b2)
- [ ] B criterion 3
  [verify](tests/b3.sh)
SPEC

  # Parse each file and verify counts
  local output_a output_b
  output_a=$(parse_spec_annotations "$TEST_DIR/specs/feature-a.md")
  output_b=$(parse_spec_annotations "$TEST_DIR/specs/feature-b.md")

  local count_a count_b
  count_a=$(echo "$output_a" | wc -l)
  count_b=$(echo "$output_b" | wc -l)

  if [ "$count_a" -eq 2 ]; then
    test_pass "Feature A has 2 criteria"
  else
    test_fail "Feature A: expected 2 criteria, got $count_a"
  fi

  if [ "$count_b" -eq 3 ]; then
    test_pass "Feature B has 3 criteria"
  else
    test_fail "Feature B: expected 3 criteria, got $count_b"
  fi

  # Verify annotation types for feature B
  local b_verify b_judge
  b_verify=$(echo "$output_b" | awk -F'\t' '$2 == "verify"' | wc -l)
  b_judge=$(echo "$output_b" | awk -F'\t' '$2 == "judge"' | wc -l)

  if [ "$b_verify" -eq 2 ]; then
    test_pass "Feature B has 2 verify annotations"
  else
    test_fail "Feature B: expected 2 verify, got $b_verify"
  fi

  if [ "$b_judge" -eq 1 ]; then
    test_pass "Feature B has 1 judge annotation"
  else
    test_fail "Feature B: expected 1 judge, got $b_judge"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: annotation parsing handles spec where Success Criteria is at EOF
#-----------------------------------------------------------------------------
test_spec_criteria_at_eof() {
  CURRENT_TEST="spec_criteria_at_eof"
  test_header "Success Criteria at End of File"

  setup_test_env "spec-eof"

  # shellcheck source=../../lib/ralph/cmd/util.sh
  source "$REPO_ROOT/lib/ralph/cmd/util.sh"

  # Spec where Success Criteria is the last section (no closing heading)
  cat > "$TEST_DIR/specs/eof-spec.md" << 'SPEC'
# EOF Feature

## Requirements

Some requirements.

## Success Criteria

- [ ] First criterion
  [verify](tests/first.sh::test_first)
- [ ] Second criterion
  [judge](tests/judges/second.sh::test_second)
- [ ] Third criterion (unannotated at EOF)
SPEC

  local output
  output=$(parse_spec_annotations "$TEST_DIR/specs/eof-spec.md")
  local line_count
  line_count=$(echo "$output" | wc -l)

  if [ "$line_count" -eq 3 ]; then
    test_pass "Parses all 3 criteria at EOF"
  else
    test_fail "Expected 3 criteria at EOF, got $line_count"
  fi

  # Last criterion should be unannotated
  local last_line
  last_line=$(echo "$output" | tail -1)
  if echo "$last_line" | grep -qP '\tnone\t'; then
    test_pass "Last criterion at EOF is unannotated"
  else
    test_fail "Last criterion at EOF should be unannotated: $last_line"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Main Test Runner
#-----------------------------------------------------------------------------

ALL_TESTS=(
  test_spec_annotation_counts
  test_spec_verbose
  test_spec_verify
  test_spec_judge
  test_spec_all
  test_spec_no_execution_default
  test_spec_annotation_counting
  test_spec_verify_only
  test_spec_all_unannotated
  test_spec_criterion_text_preservation
  test_spec_multiple_files
  test_spec_criteria_at_eof
)

main() {
  echo "=========================================="
  echo "  Ralph Spec Integration Tests"
  echo "=========================================="
  echo ""
  echo "Test directory: $SCRIPT_DIR"
  echo "Repo root: $REPO_ROOT"
  echo ""

  # Check prerequisites
  check_prerequisites "$MOCK_CLAUDE" "$SCENARIOS_DIR" || exit 1

  run_tests ALL_TESTS "${1:-}"
}

main "$@"
