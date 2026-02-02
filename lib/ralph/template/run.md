# Implementation Step

{{> context-pinning}}

{{> spec-header}}

## Current Spec

Read: {{SPEC_PATH}}

## Issue Details

Issue: {{ISSUE_ID}}
Title: {{TITLE}}

{{DESCRIPTION}}

## Instructions

1. **Understand**: Read the spec and issue thoroughly before making changes
2. **Test Strategy**: Decide between:
   - Property-based tests: For functions with clear invariants, mathematical properties
   - Unit tests: For specific behaviors, edge cases, integration points
3. **Implement**: Write code following the spec
4. **Discovered Work**: If you find tasks outside this issue's scope:
   - Create the issue as a child of the molecule:
     ```bash
     NEW_ID=$(bd create --title="..." --type=task --labels="spec-{{LABEL}}" \
       --parent="{{MOLECULE_ID}}" --silent)
     ```
   - Set execution order if needed:
     - **Blocks current task**: `bd dep add {{ISSUE_ID}} $NEW_ID` (current waits for new)
     - **Depends on current task**: `bd dep add $NEW_ID {{ISSUE_ID}}` (new waits for current)
     - **Independent**: No dep needed—`bd ready` will surface it when unblocked
   - Do NOT implement discovered tasks in this session—stay focused
5. **Quality Gates**: Before completing, ensure:
   - [ ] All tests pass
   - [ ] Lint checks pass
   - [ ] Changes committed
6. **Blocked vs Waiting**: Distinguish dependency blocks from true blocks:
   - Need user input? → `RALPH_BLOCKED: <reason>`
   - Need other beads done? → Add dep with `bd dep add`, output `RALPH_COMPLETE`

## Quality Gates

Before outputting RALPH_COMPLETE:
- [ ] Tests written and passing
- [ ] Lint checks pass
- [ ] Changes staged (`git add`)

Post-step hooks verify compliance automatically.

## Land the Plane

Before outputting RALPH_COMPLETE, follow the **Session Protocol** in `AGENTS.md`.

{{> exit-signals}}

- `RALPH_COMPLETE` - Task finished, all quality gates passed
- `RALPH_BLOCKED: <reason>` - Cannot proceed, explain why
- `RALPH_CLARIFY: <question>` - Need clarification before proceeding
