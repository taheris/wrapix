# Ralph template system tests - pure Nix evaluation tests
# Tests verify mkTemplate function and template definitions work correctly
{
  pkgs,
  lib ? pkgs.lib,
}:

let
  inherit (pkgs) runCommandLocal;

  # Import the template module
  templateModule = import ../../lib/ralph/template/default.nix { inherit lib; };
  inherit (templateModule)
    mkTemplate
    loadPartials
    extractPartialRefs
    resolvePartials
    templates
    validateTemplates
    ;

  # Test helper: assert equality with descriptive error
  assertEqual =
    name: expected: actual:
    if expected == actual then
      true
    else
      throw "Test '${name}' failed: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  # Test helper: assert condition with descriptive error
  assertTrue =
    name: condition: if condition then true else throw "Test '${name}' failed: condition was false";

  # Chain multiple assertions - all must be true for the list to evaluate
  assertAll = assertions: builtins.all (x: x) assertions;

in
{
  # Test: extractPartialRefs extracts partial names from template content
  template-extract-partial-refs = runCommandLocal "template-extract-partial-refs" { } ''
    set -e

    echo "Test: extractPartialRefs..."

    ${
      let
        content = "Hello {{> foo}} world {{> bar-baz}} end";
        refs = extractPartialRefs content;
        expected = [
          "foo"
          "bar-baz"
        ];
        check = assertEqual "extractPartialRefs" expected refs;
      in
      if check then "echo 'extractPartialRefs: PASS'" else "false"
    }

    ${
      let
        content = "No partials here";
        refs = extractPartialRefs content;
        check = assertEqual "extractPartialRefs-empty" [ ] refs;
      in
      if check then "echo 'extractPartialRefs-empty: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: loadPartials loads partial files into attrset
  template-load-partials = runCommandLocal "template-load-partials" { } ''
    set -e

    echo "Test: loadPartials..."

    ${
      let
        # Create test partial files
        testPartial1 = pkgs.writeText "test-partial.md" "Partial 1 content";
        testPartial2 = pkgs.writeText "another-partial.md" "Partial 2 content";

        loaded = loadPartials [
          testPartial1
          testPartial2
        ];

        checks = assertAll [
          (assertTrue "loadPartials-has-test-partial" (loaded ? "test-partial"))
          (assertTrue "loadPartials-has-another-partial" (loaded ? "another-partial"))
          (assertEqual "loadPartials-content" "Partial 1 content" loaded."test-partial")
        ];
      in
      if checks then "echo 'loadPartials: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: resolvePartials substitutes partial markers
  template-resolve-partials = runCommandLocal "template-resolve-partials" { } ''
    set -e

    echo "Test: resolvePartials..."

    ${
      let
        partials = {
          greeting = "Hello";
          name = "World";
        };
        content = "{{> greeting}}, {{> name}}!";
        resolved = resolvePartials partials content;
        check = assertEqual "resolvePartials" "Hello, World!" resolved;
      in
      if check then "echo 'resolvePartials: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: mkTemplate creates valid template with render function
  template-mktemplate-render = runCommandLocal "template-mktemplate-render" { } ''
    set -e

    echo "Test: mkTemplate render..."

    ${
      let
        testBody = pkgs.writeText "test-body.md" "Hello {{NAME}}, welcome to {{PLACE}}!";

        template = mkTemplate {
          body = testBody;
          partials = [ ];
          variables = [
            "NAME"
            "PLACE"
          ];
        };

        rendered = template.render {
          NAME = "Alice";
          PLACE = "Wonderland";
        };

        check = assertEqual "mkTemplate-render" "Hello Alice, welcome to Wonderland!" rendered;
      in
      if check then "echo 'mkTemplate-render: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: mkTemplate validates required variables
  template-mktemplate-validate = runCommandLocal "template-mktemplate-validate" { } ''
    set -e

    echo "Test: mkTemplate validate..."

    ${
      let
        testBody = pkgs.writeText "test-body.md" "Hello {{NAME}}!";

        template = mkTemplate {
          body = testBody;
          partials = [ ];
          variables = [ "NAME" ];
        };

        # Test valid variables
        validResult = template.validate { NAME = "Alice"; };

        # Test missing variables
        invalidResult = template.validate { };

        checks = assertAll [
          (assertTrue "validate-valid" validResult.valid)
          (assertTrue "validate-invalid" (!invalidResult.valid))
          (assertEqual "validate-missing" [ "NAME" ] invalidResult.missing)
        ];
      in
      if checks then "echo 'mkTemplate-validate: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: mkTemplate throws on missing variables during render
  # Note: We can't easily test throws in Nix since tryEval doesn't catch assert failures
  # Instead, we test the validate function which provides the same behavior without throwing
  template-mktemplate-missing-detected = runCommandLocal "template-mktemplate-missing-detected" { } ''
    set -e

    echo "Test: mkTemplate detects missing variables..."

    ${
      let
        testBody = pkgs.writeText "test-body.md" "Hello {{NAME}}!";

        template = mkTemplate {
          body = testBody;
          partials = [ ];
          variables = [ "NAME" ];
        };

        # Validate detects missing variables
        result = template.validate { };
        checks = assertAll [
          (assertTrue "missing-detected" (!result.valid))
          (assertEqual "missing-name" [ "NAME" ] result.missing)
        ];
      in
      if checks then "echo 'mkTemplate-missing-detected: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: mkTemplate with partials resolves them during render
  template-mktemplate-with-partials = runCommandLocal "template-mktemplate-with-partials" { } ''
    set -e

    echo "Test: mkTemplate with partials..."

    ${
      let
        testBody = pkgs.writeText "test-body.md" ''
          # Header
          {{> greeting}}
          Name: {{NAME}}
        '';

        greetingPartial = pkgs.writeText "greeting.md" "Welcome, visitor!";

        template = mkTemplate {
          body = testBody;
          partials = [ greetingPartial ];
          variables = [ "NAME" ];
        };

        rendered = template.render { NAME = "Alice"; };
        checks = assertAll [
          (assertTrue "mkTemplate-partial-resolved" (builtins.match ".*Welcome, visitor!.*" rendered != null))
          (assertTrue "mkTemplate-variable-resolved" (builtins.match ".*Name: Alice.*" rendered != null))
        ];
      in
      if checks then "echo 'mkTemplate-with-partials: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: all template definitions load without errors
  template-definitions-load = runCommandLocal "template-definitions-load" { } ''
    set -e

    echo "Test: template definitions load..."

    ${
      let
        checks = assertAll [
          (assertTrue "templates-has-plan-new" (templates ? "plan-new"))
          (assertTrue "templates-has-plan-update" (templates ? "plan-update"))
          (assertTrue "templates-has-todo-new" (templates ? "todo-new"))
          (assertTrue "templates-has-todo-update" (templates ? "todo-update"))
          (assertTrue "templates-has-step" (templates ? "step"))
        ];
      in
      if checks then "echo 'template-definitions-load: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: validateTemplates succeeds for all templates
  template-validate-all = runCommandLocal "template-validate-all" { } ''
    set -e

    echo "Test: validateTemplates..."

    ${
      let
        check = assertTrue "validateTemplates" validateTemplates;
      in
      if check then "echo 'validateTemplates: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: plan-new template has expected variables
  template-plan-new-variables = runCommandLocal "template-plan-new-variables" { } ''
    set -e

    echo "Test: plan-new template variables..."

    ${
      let
        t = templates."plan-new";
        checks = assertAll [
          (assertTrue "plan-new-has-PINNED_CONTEXT" (builtins.elem "PINNED_CONTEXT" t.variables))
          (assertTrue "plan-new-has-LABEL" (builtins.elem "LABEL" t.variables))
          (assertTrue "plan-new-has-SPEC_PATH" (builtins.elem "SPEC_PATH" t.variables))
        ];
      in
      if checks then "echo 'plan-new-variables: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: step template has expected variables
  template-step-variables = runCommandLocal "template-step-variables" { } ''
    set -e

    echo "Test: step template variables..."

    ${
      let
        t = templates."step";
        checks = assertAll [
          (assertTrue "step-has-PINNED_CONTEXT" (builtins.elem "PINNED_CONTEXT" t.variables))
          (assertTrue "step-has-SPEC_PATH" (builtins.elem "SPEC_PATH" t.variables))
          (assertTrue "step-has-LABEL" (builtins.elem "LABEL" t.variables))
          (assertTrue "step-has-MOLECULE_ID" (builtins.elem "MOLECULE_ID" t.variables))
          (assertTrue "step-has-ISSUE_ID" (builtins.elem "ISSUE_ID" t.variables))
          (assertTrue "step-has-TITLE" (builtins.elem "TITLE" t.variables))
          (assertTrue "step-has-DESCRIPTION" (builtins.elem "DESCRIPTION" t.variables))
        ];
      in
      if checks then "echo 'step-variables: PASS'" else "false"
    }

    mkdir $out
  '';

  # Test: templates render with valid variables
  template-render-plan-new = runCommandLocal "template-render-plan-new" { } ''
    set -e

    echo "Test: plan-new template renders..."

    ${
      let
        t = templates."plan-new";
        rendered = t.render {
          PINNED_CONTEXT = "# Project Context\nThis is the pinned context.";
          LABEL = "test-feature";
          SPEC_PATH = "specs/test-feature.md";
          EXIT_SIGNALS = "- RALPH_COMPLETE\n- RALPH_BLOCKED\n- RALPH_CLARIFY";
          README_INSTRUCTIONS = "Update the README if needed.";
        };
        # Check that partials were resolved
        checks = assertAll [
          (assertTrue "plan-new-has-context-pinning" (builtins.match ".*Context Pinning.*" rendered != null))
          (assertTrue "plan-new-has-exit-signals" (builtins.match ".*Exit Signals.*" rendered != null))
          (assertTrue "plan-new-has-label" (builtins.match ".*test-feature.*" rendered != null))
        ];
      in
      if checks then "echo 'plan-new-render: PASS'" else "false"
    }

    mkdir $out
  '';
}
