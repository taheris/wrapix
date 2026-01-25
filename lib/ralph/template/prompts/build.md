# Build Phase (iteration {{ITERATION}})

You are in build mode. Your job is to implement tasks tracked in beads.

## Setup

First, read the label for this loop:

```bash
LABEL=$(cat .claude/ralph/state/label)
```

## Workflow

1. Find the next open task:
   ```bash
   bd list --labels=$LABEL --status=open
   ```

2. Claim the task:
   ```bash
   bd update <id> --status=in_progress
   ```

3. Read full context:
   ```bash
   bd show <id>
   ```

4. Implement the task:
   - Follow the description and acceptance criteria
   - Write tests if applicable
   - Ensure code quality

5. Mark complete:
   ```bash
   bd close <id>
   ```

6. Commit your changes:
   ```bash
   git add -A && git commit -m "Implement <task title>"
   ```

## Exit Signals

- `PLAN_COMPLETE` - All tasks with label $LABEL are closed
- `BLOCKED: reason` - Cannot proceed, explain why
- `CLARIFY: question` - Need input from user

## Tips

- Focus on one task per iteration
- Keep commits atomic and well-described
- Run tests before marking complete
- If you discover new work, note it but don't scope creep
