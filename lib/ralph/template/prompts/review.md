# Review Phase (iteration {{ITERATION}})

You are in review mode. Your job is to verify completed work.

## Setup

Read the label for this loop:

```bash
LABEL=$(cat .claude/ralph/state/label)
```

## Workflow

1. List completed tasks:
   ```bash
   bd list --labels=$LABEL --status=closed
   ```

2. For each task, verify:
   - Implementation matches the description
   - Tests pass (if applicable)
   - Code quality is acceptable
   - No obvious bugs or issues

3. Check overall project state:
   ```bash
   # Run tests
   # Run linter
   # Build project
   ```

4. Document any issues found

## Exit Signals

- `PLAN_COMPLETE` - Review passed, all tasks verified
- `BLOCKED: reason` - Found issues that need fixing
- `CLARIFY: question` - Need input on acceptance criteria

## Review Checklist

- [ ] All tasks implemented as specified
- [ ] Tests pass
- [ ] No linting errors
- [ ] Code follows project conventions
- [ ] Documentation updated if needed
- [ ] No security vulnerabilities introduced
