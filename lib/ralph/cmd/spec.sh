#!/usr/bin/env bash
set -euo pipefail

# ralph spec [--verbose] [--verify] [--judge] [--all]
# Query spec annotations across all spec files.
#
# Default (no flags): fast annotation index — counts [verify], [judge],
# and unannotated criteria per spec file. No test execution, no LLM calls.
#
# --verbose: expand to per-criterion detail showing each criterion and its
#            annotation type.
# --verify:  run all [verify] shell tests from the current spec's criteria.
# --judge:   run all [judge] LLM evaluations from the current spec's criteria.
# --all:     run both --verify and --judge.

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

SPECS_DIR="specs"

#-----------------------------------------------------------------------------
# Helper: run a [verify] test
#-----------------------------------------------------------------------------
run_verify_test() {
  local criterion="$1"
  local file_path="$2"
  local function_name="$3"

  if [ ! -f "$file_path" ]; then
    echo "  [FAIL] $criterion"
    echo "         $file_path not found"
    ((failed++)) || true
    has_failure=true
    return
  fi

  local exit_code test_output
  if [ -n "$function_name" ]; then
    test_output=$("$file_path" "$function_name" 2>&1) && exit_code=0 || exit_code=$?
  else
    test_output=$("$file_path" 2>&1) && exit_code=0 || exit_code=$?
  fi

  if [ "$exit_code" -eq 0 ]; then
    echo "  [PASS] $criterion"
    echo "         $file_path${function_name:+::$function_name} (exit 0)"
    ((passed++)) || true
  else
    echo "  [FAIL] $criterion"
    echo "         $file_path${function_name:+::$function_name} (exit $exit_code)"
    ((failed++)) || true
    has_failure=true
  fi

  # Show captured output in verbose mode
  if [ "$VERBOSE" = "true" ] && [ -n "$test_output" ]; then
    echo "$test_output" | while IFS= read -r line; do
      echo "         | $line"
    done
  fi
}

#-----------------------------------------------------------------------------
# Helper: run a [judge] test
#-----------------------------------------------------------------------------
run_judge_test() {
  local criterion="$1"
  local file_path="$2"
  local function_name="$3"

  if [ ! -f "$file_path" ]; then
    echo "  [FAIL] $criterion"
    echo "         $file_path not found"
    ((failed++)) || true
    has_failure=true
    return
  fi

  # Reset judge state, source the test file, and call the rubric function
  judge_reset

  # shellcheck disable=SC1090
  source "$file_path"
  if [ -n "$function_name" ] && declare -f "$function_name" >/dev/null 2>&1; then
    "$function_name"
  fi

  # Invoke LLM judge via run_judge
  local judge_exit=0
  run_judge && judge_exit=0 || judge_exit=$?

  if [ "$judge_exit" -eq 0 ]; then
    echo "  [PASS] $criterion"
    if [ -n "$JUDGE_REASONING" ]; then
      echo "         \"$JUDGE_REASONING\""
    fi
    ((passed++)) || true
  elif [ "$judge_exit" -eq 2 ]; then
    # Error (missing files, LLM unavailable, etc.) — report as FAIL with reason
    echo "  [FAIL] $criterion"
    echo "         $JUDGE_REASONING"
    ((failed++)) || true
    has_failure=true
  else
    echo "  [FAIL] $criterion"
    if [ -n "$JUDGE_REASONING" ]; then
      echo "         \"$JUDGE_REASONING\""
    fi
    ((failed++)) || true
    has_failure=true
  fi
}

#-----------------------------------------------------------------------------
# Show annotation index for all spec files
#-----------------------------------------------------------------------------
show_annotation_index() {
  # Find all spec files (excluding README.md)
  local spec_files=()
  for f in "$SPECS_DIR"/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "README.md" ] && continue
    spec_files+=("$f")
  done

  if [ ${#spec_files[@]} -eq 0 ]; then
    echo "No spec files found in $SPECS_DIR/"
    return 0
  fi

  echo "Ralph Specs"
  echo "============================"

  local total_verify=0
  local total_judge=0
  local total_unannotated=0

  for spec_file in "${spec_files[@]}"; do
    local spec_name
    spec_name=$(basename "$spec_file")

    # Parse annotations; skip files without success criteria
    local annotations
    annotations=$(parse_spec_annotations "$spec_file" 2>/dev/null) || continue
    if [ -z "$annotations" ]; then
      continue
    fi

    # Count by annotation type
    local verify_count judge_count none_count
    verify_count=$(echo "$annotations" | awk -F'\t' '$2 == "verify"' | wc -l)
    judge_count=$(echo "$annotations" | awk -F'\t' '$2 == "judge"' | wc -l)
    none_count=$(echo "$annotations" | awk -F'\t' '$2 == "none"' | wc -l)

    # Trim whitespace from wc -l output
    verify_count=$((verify_count))
    judge_count=$((judge_count))
    none_count=$((none_count))

    total_verify=$((total_verify + verify_count))
    total_judge=$((total_judge + judge_count))
    total_unannotated=$((total_unannotated + none_count))

    # Display summary line
    printf '  %-24s %d verify, %d judge, %d unannotated\n' \
      "$spec_name" "$verify_count" "$judge_count" "$none_count"

    # Verbose: show per-criterion detail with annotation type and test path
    if [ "$VERBOSE" = "true" ]; then
      while IFS=$'\t' read -r criterion ann_type ann_file_path ann_function_name _checked; do
        if [ "$ann_type" != "none" ] && [ -n "$ann_file_path" ]; then
          local test_ref="$ann_file_path"
          if [ -n "$ann_function_name" ]; then
            test_ref="${test_ref}::${ann_function_name}"
          fi
          printf '    [%-6s] %s → %s\n' "$ann_type" "$criterion" "$test_ref"
        else
          printf '    [%-6s] %s\n' "$ann_type" "$criterion"
        fi
      done <<< "$annotations"
    fi
  done

  echo ""
  printf 'Total: %d verify, %d judge, %d unannotated\n' \
    "$total_verify" "$total_judge" "$total_unannotated"
}

#-----------------------------------------------------------------------------
# Run verify/judge tests for the current spec
#-----------------------------------------------------------------------------
run_spec_tests() {
  local ralph_dir="${RALPH_DIR:-.wrapix/ralph}"
  local current_file="$ralph_dir/state/current.json"

  if [ ! -f "$current_file" ]; then
    error "No active feature. Run 'ralph plan <label>' first."
  fi

  local label spec_hidden spec_file molecule_id
  label=$(jq -r '.label // empty' "$current_file")
  spec_hidden=$(jq -r '.hidden // false' "$current_file")
  molecule_id=$(jq -r '.molecule // empty' "$current_file")

  if [ -z "$label" ]; then
    error "No label in current.json. Run 'ralph plan <label>' first."
  fi

  if [ "$spec_hidden" = "true" ]; then
    spec_file="$ralph_dir/state/$label.md"
  else
    spec_file="$SPECS_DIR/$label.md"
  fi

  if [ ! -f "$spec_file" ]; then
    error "Spec file not found: $spec_file"
  fi

  # Parse annotations from the current spec
  local annotations
  annotations=$(parse_spec_annotations "$spec_file") || {
    echo "No success criteria found in $spec_file"
    return 0
  }

  if [ -z "$annotations" ]; then
    echo "No success criteria found in $spec_file"
    return 0
  fi

  # Determine mode label
  local mode_label=""
  if [ "$VERIFY" = "true" ] && [ "$JUDGE" = "true" ]; then
    mode_label="Verify+Judge"
  elif [ "$VERIFY" = "true" ]; then
    mode_label="Verify"
  else
    mode_label="Judge"
  fi

  local header_text="Ralph $mode_label: $label"
  if [ -n "$molecule_id" ]; then
    header_text="$header_text ($molecule_id)"
  fi
  echo "$header_text"
  printf '=%.0s' $(seq 1 ${#header_text})
  echo ""

  passed=0
  failed=0
  skipped=0
  has_failure=false

  while IFS=$'\t' read -r criterion ann_type file_path function_name _checked <&3; do
    if [ "$VERIFY" = "true" ] && [ "$JUDGE" = "true" ]; then
      # --all mode: run both verify and judge, skip only unannotated
      if [ "$ann_type" = "none" ]; then
        echo "  [SKIP] $criterion (no annotation)"
        ((skipped++)) || true
      elif [ "$ann_type" = "verify" ]; then
        run_verify_test "$criterion" "$file_path" "$function_name"
      elif [ "$ann_type" = "judge" ]; then
        run_judge_test "$criterion" "$file_path" "$function_name"
      fi
    elif [ "$VERIFY" = "true" ]; then
      if [ "$ann_type" = "verify" ]; then
        run_verify_test "$criterion" "$file_path" "$function_name"
      elif [ "$ann_type" = "none" ]; then
        echo "  [SKIP] $criterion (no annotation)"
        ((skipped++)) || true
      fi
      # judge-only criteria are silently omitted in verify mode
    elif [ "$JUDGE" = "true" ]; then
      if [ "$ann_type" = "judge" ]; then
        run_judge_test "$criterion" "$file_path" "$function_name"
      elif [ "$ann_type" = "none" ]; then
        echo "  [SKIP] $criterion (no annotation)"
        ((skipped++)) || true
      fi
      # verify-only criteria are silently omitted in judge mode
    fi
  done 3<<< "$annotations"

  echo ""
  echo "$passed passed, $failed failed, $skipped skipped"

  if [ "$has_failure" = "true" ]; then
    return 1
  fi
  return 0
}

#-----------------------------------------------------------------------------
# Parse arguments
#-----------------------------------------------------------------------------
VERBOSE=false
VERIFY=false
JUDGE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --verify)
      VERIFY=true
      shift
      ;;
    --judge)
      JUDGE=true
      shift
      ;;
    --all)
      VERIFY=true
      JUDGE=true
      shift
      ;;
    -h|--help)
      echo "Usage: ralph spec [--verbose] [--verify] [--judge] [--all]"
      echo ""
      echo "Query spec annotations across all spec files."
      echo ""
      echo "Options:"
      echo "  --verbose, -v  Show per-criterion detail"
      echo "  --verify       Run [verify] shell tests from current spec"
      echo "  --judge        Run [judge] LLM evaluations from current spec"
      echo "  --all          Run both --verify and --judge"
      echo "  --help, -h     Show this help message"
      echo ""
      echo "Default mode (no flags) is instant: scans annotations without"
      echo "executing tests or invoking LLMs."
      exit 0
      ;;
    *)
      error "Unknown option: $1
Run 'ralph spec --help' for usage."
      ;;
  esac
done

#-----------------------------------------------------------------------------
# Main dispatch
#-----------------------------------------------------------------------------
if [ "$VERIFY" = "true" ] || [ "$JUDGE" = "true" ]; then
  run_spec_tests
else
  show_annotation_index
fi
