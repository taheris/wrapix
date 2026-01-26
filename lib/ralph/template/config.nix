{
  # Active prompt mode: "plan" | "build" | "review"
  mode = "plan";

  # Spec file handling
  spec = {
    hidden = false; # When true, store plan in state/{label}.md instead of specs/
  };

  # Beads integration
  beads = {
    # Label for issues - leave null to auto-generate random 6-char ID
    # Final label will be prefixed: rl-{label}
    label = null;
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
    pre-hook = ""; # Command to run before each iteration
    post-hook = ""; # Command to run after each iteration
  };

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
    plan-complete = "PLAN_COMPLETE";
    ready-complete = "READY_COMPLETE";
    step-complete = "STEP_COMPLETE";
    step-blocked = "STEP_BLOCKED:";
    step-clarify = "STEP_CLARIFY:";
    blocked = "BLOCKED:";
    clarify = "CLARIFY:";
  };
}
