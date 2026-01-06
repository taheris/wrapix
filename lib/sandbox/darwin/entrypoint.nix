# Darwin entrypoint - same as Linux, invokes Claude with security flags
{ pkgs, systemPrompt }:

pkgs.writeShellScriptBin "wrapix-entrypoint" ''
  cd /workspace

  # Read system prompt
  PROMPT=$(cat ${systemPrompt})

  exec claude \
    --dangerously-skip-permissions \
    --disallowedTools "Bash(curl:*),Bash(wget:*)" \
    --append-system-prompt "$PROMPT"
''
