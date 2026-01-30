# Nix-native template definitions with static validation
#
# Templates are validated at Nix evaluation time:
# - All referenced partials must exist
# - All required variables must be provided during render
# - Partial markers {{> partial-name}} are resolved at render time
{ lib }:

let
  inherit (builtins)
    all
    attrNames
    elem
    filter
    hasAttr
    listToAttrs
    map
    match
    readFile
    replaceStrings
    split
    stringLength
    ;

  inherit (lib)
    assertMsg
    concatStringsSep
    filterAttrs
    foldl'
    hasPrefix
    pipe
    ;

  # Extract partial names from content ({{> partial-name}})
  # Returns list of partial names referenced in the template
  extractPartialRefs =
    content:
    let
      # Split on {{> partial-name}} pattern
      # Nix regex uses POSIX extended regex, need to escape { and }
      parts = split "[{][{]> ([a-z-]+)[}][}]" content;
      # Filter to get only the matched groups (lists with the partial name)
      matches = filter (p: builtins.isList p) parts;
    in
    map builtins.head matches;

  # Resolve a single partial marker in content
  resolvePartial =
    partials: content: name:
    let
      partialContent = partials.${name} or (throw "Partial not found: ${name}");
      marker = "{{> ${name}}}";
    in
    replaceStrings [ marker ] [ partialContent ] content;

  # Resolve all partial markers in content
  resolvePartials =
    partials: content:
    let
      refs = extractPartialRefs content;
    in
    foldl' (resolvePartial partials) content refs;

  # Load partials from a directory as an attrset
  # Takes a list of partial file paths and returns { name = content; }
  loadPartials =
    partialPaths:
    listToAttrs (
      map (path: {
        # Extract name from path: ./partial/context-pinning.md -> context-pinning
        # Also handles Nix store paths: /nix/store/<hash>-context-pinning.md -> context-pinning
        name =
          let
            filename = baseNameOf path;
            # Remove .md extension
            # Nix store hashes are exactly 32 chars of base32 (a-z0-9) followed by hyphen
            # So we match: optional 32-char hash prefix, then the actual name
            nameMatch = match "([a-z0-9]{32}-)?(.+)\\.md" filename;
          in
          if nameMatch != null then
            # Get the second capture group (the actual name without hash)
            builtins.elemAt nameMatch 1
          else
            filename;
        value = readFile path;
      }) partialPaths
    );

  # Create a template with validation
  #
  # Arguments:
  #   body: Path to the template body file
  #   partials: List of paths to partial files (optional)
  #   variables: List of variable names required for rendering
  #
  # Returns an attrset with:
  #   content: Raw template content
  #   variables: List of required variables
  #   partials: Loaded partial contents
  #   render: Function to render template with variables
  #   validate: Function to check if variables are valid
  mkTemplate =
    {
      body,
      partials ? [ ],
      variables,
    }:
    let
      bodyContent = readFile body;
      loadedPartials = loadPartials partials;

      # Validate that all referenced partials exist
      referencedPartials = extractPartialRefs bodyContent;
      missingPartials = filter (p: !(hasAttr p loadedPartials)) referencedPartials;
      _ =
        assert assertMsg (missingPartials == [ ])
          "Missing partials: ${concatStringsSep ", " missingPartials}. Available: ${concatStringsSep ", " (attrNames loadedPartials)}";
        null;
    in
    {
      inherit variables;
      content = bodyContent;
      partials = loadedPartials;

      # Validate that all required variables are present
      # Returns { valid: bool; missing: [string]; }
      validate =
        vars:
        let
          missing = filter (v: !(hasAttr v vars)) variables;
        in
        {
          valid = missing == [ ];
          inherit missing;
        };

      # Render template with provided variables
      # Throws if any required variables are missing
      render =
        vars:
        let
          missing = filter (v: !(hasAttr v vars)) variables;
          _ =
            assert assertMsg (missing == [ ])
              "Missing required variables: ${concatStringsSep ", " missing}. Required: ${concatStringsSep ", " variables}";
            null;

          # First resolve partials
          withPartials = resolvePartials loadedPartials bodyContent;

          # Then substitute variables
          varMarkers = map (v: "{{${v}}}") variables;
          varValues = map (v: vars.${v}) variables;
        in
        replaceStrings varMarkers varValues withPartials;
    };

  # Partial files
  partialDir = ./partial;
  partialFiles = [
    (partialDir + "/context-pinning.md")
    (partialDir + "/exit-signals.md")
    (partialDir + "/spec-header.md")
  ];

  # Template definitions (in let block so validateTemplates can reference them)
  templates = {
    plan-new = mkTemplate {
      body = ./plan-new.md;
      partials = partialFiles;
      variables = [
        "PINNED_CONTEXT"
        "LABEL"
        "SPEC_PATH"
        "EXIT_SIGNALS"
      ];
    };

    plan-update = mkTemplate {
      body = ./plan-update.md;
      partials = partialFiles;
      variables = [
        "PINNED_CONTEXT"
        "LABEL"
        "SPEC_PATH"
        "EXISTING_SPEC"
        "EXIT_SIGNALS"
      ];
    };

    ready-new = mkTemplate {
      body = ./ready-new.md;
      partials = partialFiles;
      variables = [
        "PINNED_CONTEXT"
        "LABEL"
        "SPEC_PATH"
        "SPEC_CONTENT"
        "EXIT_SIGNALS"
      ];
    };

    ready-update = mkTemplate {
      body = ./ready-update.md;
      partials = partialFiles;
      variables = [
        "PINNED_CONTEXT"
        "LABEL"
        "SPEC_PATH"
        "SPEC_CONTENT"
        "MOLECULE_ID"
        "MOLECULE_PROGRESS"
        "NEW_REQUIREMENTS"
        "EXIT_SIGNALS"
      ];
    };

    step = mkTemplate {
      body = ./step.md;
      partials = partialFiles;
      variables = [
        "PINNED_CONTEXT"
        "SPEC_PATH"
        "LABEL"
        "MOLECULE_ID"
        "ISSUE_ID"
        "TITLE"
        "DESCRIPTION"
        "EXIT_SIGNALS"
      ];
    };
  };

  # Validate all templates (for use in flake check)
  # Returns true if all templates are valid, throws otherwise
  validateTemplates =
    let
      templateNames = attrNames templates;
      checkTemplate =
        name:
        let
          t = templates.${name};
          # Force evaluation of the template (triggers partial validation)
          forceContent = t.content;
        in
        forceContent != null;
    in
    all checkTemplate templateNames;

in
{
  inherit
    mkTemplate
    loadPartials
    extractPartialRefs
    resolvePartials
    templates
    validateTemplates
    ;
}
