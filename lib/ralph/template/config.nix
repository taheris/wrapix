{
  # Stream output visibility (what to show during claude execution)
  output = {
    # Core output types
    responses = true; # Assistant text responses (always recommended)
    tool-names = true; # Show tool names like [Bash], [Read]
    tool-inputs = true; # Show tool input parameters
    tool-results = true; # Show tool execution results
    thinking = true; # Show extended thinking content
    stats = false; # Show final stats (cost, tokens, duration)

    # Truncation limits (0 = no limit)
    max-tool-input = 200; # Max chars for tool input display
    max-tool-result = 500; # Max chars for tool result display

    # Output prefixes (customize the bracket prefixes shown in output)
    prefixes = {
      response = "[response] "; # Prefix for assistant text responses
      tool-result = "[result] "; # Prefix for tool results
      tool-error = "[error] "; # Prefix for tool errors
      thinking-start = "<thinking>\n"; # Opening tag for thinking blocks
      thinking-end = "\n</thinking>"; # Closing tag for thinking blocks
      stats-header = "\n[stats]\n"; # Header before stats output
      stats-line = "  "; # Prefix for each stats line
    };
  };

  # Beads integration
  beads = {
    priority = 2; # Default priority (0=critical, 2=medium, 4=backlog)
    default-type = "task";
  };

  prompts = {
    plan = "plan.md";
    ready = "ready.md";
    step = "step.md";
  };

  loop = {
    max-iterations = 0; # 0 = infinite
    pause-on-failure = true;
    # Legacy hooks (deprecated, use 'hooks' section instead)
    pre-hook = ""; # Command to run before each iteration (maps to hooks.pre-step)
    post-hook = ""; # Command to run after each iteration (maps to hooks.post-step)
  };

  # Hook points for ralph loop (FR2)
  # Template variables: {{LABEL}}, {{ISSUE_ID}}, {{STEP_COUNT}}, {{STEP_EXIT_CODE}}
  hooks = {
    pre-loop = "prek run";
    pre-step = "bd sync";
    post-step = "prek run && git add -A && bd sync";
    post-loop = ''
      git add -A
      bd sync
      git commit -m "feat({{LABEL}}): implementation complete"
      git push
      git -C .git/beads-worktrees/beads add -A
      git -C .git/beads-worktrees/beads commit -m "bd sync"
      git push origin beads
    '';
  };

  # Hook failure handling (FR5): block | warn | skip
  hooks-on-failure = "block";

  history = {
    enabled = true;
    max-snapshots = 50;
  };

  failure-patterns = [
    {
      pattern = "error:";
      action = "log";
    } # log | pause | notify
    {
      pattern = "FAILED";
      action = "pause";
    }
    {
      pattern = "Exception";
      action = "pause";
    }
    {
      pattern = "BLOCKED:";
      action = "pause";
    }
    {
      pattern = "panic:";
      action = "pause";
    }
  ];

  exit-signals = {
    complete = "RALPH_COMPLETE";
    blocked = "RALPH_BLOCKED:";
    clarify = "RALPH_CLARIFY:";
  };
}
