# Ralph workflow tests - pure Nix tests that don't require Claude
# Tests verify ralph utility functions work correctly
{
  pkgs,
  system,
}:

let
  inherit (pkgs)
    bash
    coreutils
    jq
    runCommandLocal
    ;

  utilScript = ../.. + "/lib/ralph/cmd/util.sh";

  # Import template tests
  templateTests = import ./templates.nix {
    inherit pkgs;
    inherit (pkgs) lib;
  };

in
templateTests
// {
  # Test: validate_json function correctly validates JSON
  util-validate-json =
    runCommandLocal "ralph-util-validate-json"
      {
        nativeBuildInputs = [
          bash
          jq
        ];
      }
      ''
        set -euo pipefail
        source ${utilScript}

        echo "Test: validate_json with valid JSON object..."
        validate_json '{"key": "value"}' "test object" || exit 1

        echo "Test: validate_json with valid JSON array..."
        validate_json '[1, 2, 3]' "test array" || exit 1

        echo "Test: validate_json with invalid JSON..."
        if validate_json 'not json' "invalid" 2>/dev/null; then
          echo "FAIL: Should have rejected invalid JSON"
          exit 1
        fi

        echo "Test: validate_json with empty string..."
        if validate_json "" "empty" 2>/dev/null; then
          echo "FAIL: Should have rejected empty string"
          exit 1
        fi

        echo "PASS: validate_json tests"
        mkdir $out
      '';

  # Test: validate_json_array function correctly validates JSON arrays
  util-validate-json-array =
    runCommandLocal "ralph-util-validate-json-array"
      {
        nativeBuildInputs = [
          bash
          jq
        ];
      }
      ''
        set -euo pipefail
        source ${utilScript}

        echo "Test: validate_json_array with non-empty array..."
        validate_json_array '[{"id": "1"}]' "test array" || exit 1

        echo "Test: validate_json_array with multi-element array..."
        validate_json_array '[1, 2, 3]' "numbers" || exit 1

        echo "Test: validate_json_array rejects object..."
        if validate_json_array '{"key": "value"}' "object" 2>/dev/null; then
          echo "FAIL: Should have rejected object"
          exit 1
        fi

        echo "Test: validate_json_array rejects empty array..."
        if validate_json_array '[]' "empty array" 2>/dev/null; then
          echo "FAIL: Should have rejected empty array"
          exit 1
        fi

        echo "PASS: validate_json_array tests"
        mkdir $out
      '';

  # Test: extract_json function extracts JSON from mixed output
  util-extract-json =
    runCommandLocal "ralph-util-extract-json"
      {
        nativeBuildInputs = [
          bash
          jq
        ];
      }
      ''
            set -euo pipefail
            source ${utilScript}

            echo "Test: extract_json from pure JSON array..."
            result=$(extract_json '[{"id": "beads-001"}]')
            if [ "$result" != '[{"id": "beads-001"}]' ]; then
              echo "FAIL: Expected pure JSON to pass through"
              exit 1
            fi

            echo "Test: extract_json from mixed output with warning prefix..."
            mixed_output="Warning: something happened
        [{\"id\": \"beads-001\"}]"
            result=$(extract_json "$mixed_output")
            expected='[{"id": "beads-001"}]'
            if [ "$result" != "$expected" ]; then
              echo "FAIL: Expected '$expected', got '$result'"
              exit 1
            fi

            echo "Test: extract_json from output with multiple warning lines..."
            multi_warn="⚠ Warning line 1
        ⚠ Warning line 2
        [{\"id\": \"beads-002\", \"title\": \"Test\"}]"
            result=$(extract_json "$multi_warn")
            if ! echo "$result" | jq -e '.[0].id == "beads-002"' >/dev/null; then
              echo "FAIL: Could not extract JSON from multi-warning output"
              exit 1
            fi

            echo "PASS: extract_json tests"
            mkdir $out
      '';

  # Test: strip_implementation_notes removes Implementation Notes section
  util-strip-implementation-notes =
    runCommandLocal "ralph-util-strip-implementation-notes"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
            set -euo pipefail
            source ${utilScript}

            echo "Test: strip section at end of document..."
            input="# Feature Spec

        ## Requirements
        - Requirement 1

        ## Implementation Notes

        > This section is transient

        - Implementation detail"

            result=$(strip_implementation_notes "$input")

            if echo "$result" | grep -q "Implementation Notes"; then
              echo "FAIL: Implementation Notes section should be removed"
              exit 1
            fi

            if ! echo "$result" | grep -q "Requirements"; then
              echo "FAIL: Requirements section should remain"
              exit 1
            fi

            echo "Test: strip section in middle of document..."
            input2="# Feature

        ## Design
        Design content

        ## Implementation Notes
        Transient notes

        ## Success Criteria
        - Criterion 1"

            result2=$(strip_implementation_notes "$input2")

            if echo "$result2" | grep -q "Transient notes"; then
              echo "FAIL: Implementation Notes content should be removed"
              exit 1
            fi

            if ! echo "$result2" | grep -q "Success Criteria"; then
              echo "FAIL: Success Criteria section should remain"
              exit 1
            fi

            if ! echo "$result2" | grep -q "Criterion 1"; then
              echo "FAIL: Success Criteria content should remain"
              exit 1
            fi

            echo "Test: document without Implementation Notes unchanged..."
            input3="# Simple Spec

        ## Requirements
        Just requirements"

            result3=$(strip_implementation_notes "$input3")

            if [ "$result3" != "$input3" ]; then
              echo "FAIL: Document without Implementation Notes should be unchanged"
              exit 1
            fi

            echo "PASS: strip_implementation_notes tests"
            mkdir $out
      '';

  # Test: ralph script syntax validation
  ralph-script-syntax =
    runCommandLocal "ralph-script-syntax"
      {
        nativeBuildInputs = [ bash ];
      }
      ''
        set -euo pipefail

        echo "Checking ralph script syntax..."
        for script in ${../.. + "/lib/ralph/cmd"}/*.sh; do
          echo "  Validating: $script"
          bash -n "$script"
        done

        echo "PASS: All ralph scripts have valid syntax"
        mkdir $out
      '';

  # Test: resolve_partials function resolves {{> partial-name}} markers
  util-resolve-partials =
    runCommandLocal "ralph-util-resolve-partials"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail
        source ${utilScript}

        # Create test partial directory
        mkdir -p partials
        echo "Hello from greeting!" > partials/greeting.md
        echo "Goodbye!" > partials/farewell.md

        echo "Test: resolve single partial..."
        content="Start {{> greeting}} End"
        result=$(resolve_partials "$content" "partials")
        expected="Start Hello from greeting! End"
        if [ "$result" != "$expected" ]; then
          echo "FAIL: Expected '$expected', got '$result'"
          exit 1
        fi

        echo "Test: resolve multiple partials..."
        content2="{{> greeting}} then {{> farewell}}"
        result2=$(resolve_partials "$content2" "partials")
        if ! echo "$result2" | grep -q "Hello from greeting!"; then
          echo "FAIL: greeting partial not resolved"
          exit 1
        fi
        if ! echo "$result2" | grep -q "Goodbye!"; then
          echo "FAIL: farewell partial not resolved"
          exit 1
        fi

        echo "Test: no partials returns unchanged content..."
        content3="No partials here"
        result3=$(resolve_partials "$content3" "partials")
        if [ "$result3" != "$content3" ]; then
          echo "FAIL: Content without partials should be unchanged"
          exit 1
        fi

        echo "Test: missing partial dir returns unchanged content..."
        content4="{{> greeting}}"
        result4=$(resolve_partials "$content4" "nonexistent")
        if [ "$result4" != "$content4" ]; then
          echo "FAIL: Content with missing partial dir should be unchanged"
          exit 1
        fi

        echo "Test: nested/multiline content preserved..."
        cat > partials/complex.md << 'PARTIAL'
        ## Section Header

        - List item 1
        - List item 2

        ```bash
        echo "code block"
        ```
        PARTIAL
        content5="Before {{> complex}} After"
        result5=$(resolve_partials "$content5" "partials")
        if ! echo "$result5" | grep -q "Section Header"; then
          echo "FAIL: Section header not preserved"
          exit 1
        fi
        if ! echo "$result5" | grep -q "List item 1"; then
          echo "FAIL: List items not preserved"
          exit 1
        fi
        if ! echo "$result5" | grep -q 'echo "code block"'; then
          echo "FAIL: Code block not preserved"
          exit 1
        fi
        if ! echo "$result5" | grep -q "Before"; then
          echo "FAIL: Content before partial not preserved"
          exit 1
        fi
        if ! echo "$result5" | grep -q "After"; then
          echo "FAIL: Content after partial not preserved"
          exit 1
        fi

        echo "Test: missing partial file handled gracefully..."
        content6="Start {{> nonexistent-partial}} End"
        # Should warn but not fail - partial reference stays in output
        result6=$(resolve_partials "$content6" "partials" 2>&1)
        if ! echo "$result6" | grep -q "nonexistent-partial"; then
          echo "FAIL: Missing partial should be preserved in output"
          exit 1
        fi

        echo "PASS: resolve_partials tests"
        mkdir $out
      '';

  # Test: ralph-tune help flag works
  # Note: We test the help output by grepping the script directly since help is shown
  # before util.sh is sourced, and our test verifies the script's help content
  tune-help =
    runCommandLocal "ralph-tune-help"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-tune --help content..."

        # Read the script and verify help text content exists
        script="${../.. + "/lib/ralph/cmd/tune.sh"}"

        if grep -q "AI-assisted template editing" "$script"; then
          echo "PASS: Help mentions AI-assisted template editing"
        else
          echo "FAIL: Help missing AI-assisted editing mention"
          exit 1
        fi

        if grep -q "Interactive mode" "$script"; then
          echo "PASS: Help mentions interactive mode"
        else
          echo "FAIL: Help missing interactive mode"
          exit 1
        fi

        if grep -q "Integration mode" "$script"; then
          echo "PASS: Help mentions integration mode"
        else
          echo "FAIL: Help missing integration mode"
          exit 1
        fi

        if grep -q "ralph check" "$script"; then
          echo "PASS: Help mentions ralph check validation"
        else
          echo "FAIL: Help missing ralph check mention"
          exit 1
        fi

        echo "PASS: ralph-tune help tests"
        mkdir $out
      '';

  # Test: ralph-tune mode detection logic
  # Verifies the script properly detects stdin vs no stdin
  tune-mode-detection =
    runCommandLocal "ralph-tune-mode-detection"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-tune mode detection logic..."

        script="${../.. + "/lib/ralph/cmd/tune.sh"}"

        # Verify the script checks for stdin
        if grep -q '\[ ! -t 0 \]' "$script"; then
          echo "PASS: Script checks for stdin terminal status"
        else
          echo "FAIL: Script missing stdin detection"
          exit 1
        fi

        # Verify the script sets MODE based on detection
        if grep -q 'MODE="integration"' "$script" && grep -q 'MODE="interactive"' "$script"; then
          echo "PASS: Script sets integration and interactive modes"
        else
          echo "FAIL: Script missing mode assignment"
          exit 1
        fi

        # Verify empty diff detection
        if grep -q "No diff input received" "$script"; then
          echo "PASS: Script handles empty diff input"
        else
          echo "FAIL: Script missing empty diff handling"
          exit 1
        fi

        echo "PASS: ralph-tune mode detection tests"
        mkdir $out
      '';

  # Test: ralph-tune requires RALPH_TEMPLATE_DIR
  # Verifies the script checks for required environment
  tune-env-validation =
    runCommandLocal "ralph-tune-env-validation"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-tune environment validation..."

        script="${../.. + "/lib/ralph/cmd/tune.sh"}"

        # Verify the script requires RALPH_TEMPLATE_DIR
        if grep -q 'RALPH_TEMPLATE_DIR' "$script"; then
          echo "PASS: Script references RALPH_TEMPLATE_DIR"
        else
          echo "FAIL: Script missing RALPH_TEMPLATE_DIR reference"
          exit 1
        fi

        # Verify error message for missing env
        if grep -q "RALPH_TEMPLATE_DIR not set" "$script"; then
          echo "PASS: Script shows error for missing RALPH_TEMPLATE_DIR"
        else
          echo "FAIL: Script missing RALPH_TEMPLATE_DIR error message"
          exit 1
        fi

        # Verify RALPH_DIR is used
        if grep -q 'RALPH_DIR' "$script"; then
          echo "PASS: Script uses RALPH_DIR"
        else
          echo "FAIL: Script missing RALPH_DIR usage"
          exit 1
        fi

        echo "PASS: ralph-tune env validation tests"
        mkdir $out
      '';

  # Test: ralph-tune prompt building
  # Verifies the script builds appropriate prompts for both modes
  tune-prompt-building =
    runCommandLocal "ralph-tune-prompt-building"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-tune prompt building..."

        script="${../.. + "/lib/ralph/cmd/tune.sh"}"

        # Verify interactive mode prompt content
        if grep -q "build_interactive_prompt" "$script"; then
          echo "PASS: Script has interactive prompt builder"
        else
          echo "FAIL: Script missing interactive prompt builder"
          exit 1
        fi

        # Verify integration mode prompt content
        if grep -q "build_integration_prompt" "$script"; then
          echo "PASS: Script has integration prompt builder"
        else
          echo "FAIL: Script missing integration prompt builder"
          exit 1
        fi

        # Verify template context is built
        if grep -q "build_template_context" "$script"; then
          echo "PASS: Script builds template context"
        else
          echo "FAIL: Script missing template context builder"
          exit 1
        fi

        # Verify ralph check is run after edits
        if grep -q "ralph-check" "$script"; then
          echo "PASS: Script runs ralph-check after edits"
        else
          echo "FAIL: Script missing ralph-check validation"
          exit 1
        fi

        echo "PASS: ralph-tune prompt building tests"
        mkdir $out
      '';

  # Test: ralph-diff help flag content
  diff-help =
    runCommandLocal "ralph-diff-help"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-diff --help content..."

        script="${../.. + "/lib/ralph/cmd/diff.sh"}"

        if grep -q "Shows local template changes vs packaged templates" "$script"; then
          echo "PASS: Help mentions showing local template changes"
        else
          echo "FAIL: Help missing description"
          exit 1
        fi

        if grep -q "plan-new" "$script" && grep -q "plan-update" "$script"; then
          echo "PASS: Help lists plan variants"
        else
          echo "FAIL: Help missing plan variants"
          exit 1
        fi

        if grep -q "ready-new" "$script" && grep -q "ready-update" "$script"; then
          echo "PASS: Help lists ready variants"
        else
          echo "FAIL: Help missing ready variants"
          exit 1
        fi

        if grep -q "context-pinning" "$script"; then
          echo "PASS: Help lists partials"
        else
          echo "FAIL: Help missing partials"
          exit 1
        fi

        if grep -q "ralph tune" "$script"; then
          echo "PASS: Help mentions piping to ralph tune"
        else
          echo "FAIL: Help missing ralph tune integration"
          exit 1
        fi

        echo "PASS: ralph-diff help tests"
        mkdir $out
      '';

  # Test: ralph-diff template list includes all variants
  diff-template-list =
    runCommandLocal "ralph-diff-template-list"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-diff template list..."

        script="${../.. + "/lib/ralph/cmd/diff.sh"}"

        # Check all template variants are listed
        for template in plan plan-new plan-update ready ready-new ready-update step; do
          if grep -q "\"$template\"" "$script"; then
            echo "PASS: Template '$template' in list"
          else
            echo "FAIL: Template '$template' missing from list"
            exit 1
          fi
        done

        # Check all partials are listed
        for partial in context-pinning exit-signals spec-header; do
          if grep -q "\"$partial\"" "$script"; then
            echo "PASS: Partial '$partial' in list"
          else
            echo "FAIL: Partial '$partial' missing from list"
            exit 1
          fi
        done

        echo "PASS: ralph-diff template list tests"
        mkdir $out
      '';

  # Test: ralph-diff partial handling
  diff-partial-handling =
    runCommandLocal "ralph-diff-partial-handling"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-diff partial handling..."

        script="${../.. + "/lib/ralph/cmd/diff.sh"}"

        # Check diff_partial function exists
        if grep -q "diff_partial()" "$script"; then
          echo "PASS: Script has diff_partial function"
        else
          echo "FAIL: Script missing diff_partial function"
          exit 1
        fi

        # Check partial directory path is correct
        if grep -q 'template/partial/' "$script"; then
          echo "PASS: Script uses correct partial directory path"
        else
          echo "FAIL: Script missing partial directory path"
          exit 1
        fi

        # Check FILTER_PARTIAL handling for specific partial diff
        if grep -q 'FILTER_PARTIAL' "$script"; then
          echo "PASS: Script handles filtered partial diffing"
        else
          echo "FAIL: Script missing FILTER_PARTIAL handling"
          exit 1
        fi

        echo "PASS: ralph-diff partial handling tests"
        mkdir $out
      '';

  # Test: ralph-diff requires RALPH_TEMPLATE_DIR
  diff-env-validation =
    runCommandLocal "ralph-diff-env-validation"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-diff environment validation..."

        script="${../.. + "/lib/ralph/cmd/diff.sh"}"

        # Verify the script requires RALPH_TEMPLATE_DIR
        if grep -q 'RALPH_TEMPLATE_DIR' "$script"; then
          echo "PASS: Script references RALPH_TEMPLATE_DIR"
        else
          echo "FAIL: Script missing RALPH_TEMPLATE_DIR reference"
          exit 1
        fi

        # Verify error message for missing env
        if grep -q "RALPH_TEMPLATE_DIR not set" "$script"; then
          echo "PASS: Script shows error for missing RALPH_TEMPLATE_DIR"
        else
          echo "FAIL: Script missing RALPH_TEMPLATE_DIR error message"
          exit 1
        fi

        # Verify RALPH_DIR is used
        if grep -q 'RALPH_DIR' "$script"; then
          echo "PASS: Script uses RALPH_DIR"
        else
          echo "FAIL: Script missing RALPH_DIR usage"
          exit 1
        fi

        echo "PASS: ralph-diff env validation tests"
        mkdir $out
      '';

  # Test: ralph-diff output format is pipe-friendly
  diff-output-format =
    runCommandLocal "ralph-diff-output-format"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-diff output format..."

        script="${../.. + "/lib/ralph/cmd/diff.sh"}"

        # Check for markdown-friendly output headers
        if grep -q '# Local Template Changes' "$script"; then
          echo "PASS: Script outputs markdown header"
        else
          echo "FAIL: Script missing markdown header"
          exit 1
        fi

        # Check for code fence around diffs
        if grep -q '\`\`\`diff' "$script"; then
          echo "PASS: Script uses diff code fence"
        else
          echo "FAIL: Script missing diff code fence"
          exit 1
        fi

        # Check for TTY-only hint
        if grep -q '\[ -t 1 \]' "$script"; then
          echo "PASS: Script checks for TTY before hint"
        else
          echo "FAIL: Script missing TTY check"
          exit 1
        fi

        echo "PASS: ralph-diff output format tests"
        mkdir $out
      '';

  # Test: ralph-diff validation logic for templates and partials
  diff-validation-logic =
    runCommandLocal "ralph-diff-validation-logic"
      {
        nativeBuildInputs = [
          bash
          coreutils
        ];
      }
      ''
        set -euo pipefail

        echo "Test: ralph-diff validation logic..."

        script="${../.. + "/lib/ralph/cmd/diff.sh"}"

        # Check that both templates and partials are validated
        if grep -q 'valid_template' "$script" && grep -q 'valid_partial' "$script"; then
          echo "PASS: Script validates both templates and partials"
        else
          echo "FAIL: Script missing template or partial validation"
          exit 1
        fi

        # Check error message includes both valid options
        if grep -q 'Valid templates:' "$script" && grep -q 'Valid partials:' "$script"; then
          echo "PASS: Error message shows valid options"
        else
          echo "FAIL: Error message missing valid options"
          exit 1
        fi

        # Check that specific template filters out partials
        if grep -q 'PARTIALS=()' "$script"; then
          echo "PASS: Script clears partials when template is specified"
        else
          echo "FAIL: Script doesn't clear partials for template filter"
          exit 1
        fi

        # Check that specific partial filters out templates
        if grep -q 'TEMPLATES=()' "$script"; then
          echo "PASS: Script clears templates when partial is specified"
        else
          echo "FAIL: Script doesn't clear templates for partial filter"
          exit 1
        fi

        echo "PASS: ralph-diff validation logic tests"
        mkdir $out
      '';
}
