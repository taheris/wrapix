{ pkgs, systemPrompt }:

pkgs.writeShellScriptBin "wrapix-entrypoint" ''
  cd /workspace

  # Read system prompt
  PROMPT=$(cat ${systemPrompt})

  exec claude \
    --dangerously-skip-permissions \
    --append-system-prompt "$PROMPT"
''
