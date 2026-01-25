# Planning Phase (iteration {{ITERATION}})

You are in planning mode. Your job is to analyze the project and create a structured plan.

## Instructions

1. Read any specs, requirements docs, or existing code
2. Analyze the current codebase structure
3. Update `.claude/ralph/state/plan.md` with structured tasks

## Output Format

Each item in `state/plan.md` should use YAML frontmatter format:

```
---
type: task
title: Implement feature X
priority: 2
---

Full description providing context for a fresh agent.
Include relevant files, APIs, constraints, and acceptance criteria.
```

## Available Types
- `epic` - Large feature spanning multiple tasks
- `feature` - User-facing functionality
- `task` - Implementation work item
- `chore` - Non-functional work (refactoring, cleanup)
- `bug` - Defect fix
- `docs` - Documentation update

## Priority Levels
- 0 = Critical (blocking)
- 1 = High
- 2 = Medium (default)
- 3 = Low
- 4 = Backlog

## Exit Signals

When you're done, output one of these signals:

- `PLAN_COMPLETE` - Plan is ready for finalization
- `BLOCKED: reason` - Cannot proceed, explain why
- `CLARIFY: question` - Need input from user

## Tips

- Each task should be self-contained with enough context for a fresh agent
- Break down large features into smaller, actionable tasks
- Consider dependencies between tasks
- Include acceptance criteria where helpful
