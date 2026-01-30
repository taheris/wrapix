# Implementation Step

{{> context-pinning}}

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
   - First create the issue: `bd create --title="..." --type=task --labels="spec-{{LABEL}}"`
   - Then bond it to the molecule with the appropriate type:
     - **Sequential**: `bd mol bond {{MOLECULE_ID}} <new-issue-id> --type sequential`
       Use when discovered work blocks current task completion
     - **Parallel**: `bd mol bond {{MOLECULE_ID}} <new-issue-id> --type parallel`
       Use when work is independent and can be done anytime
   - Do NOT implement discovered tasks in this session—stay focused
5. **Quality Gates**: Before completing, ensure:
   - [ ] All tests pass
   - [ ] Lint checks pass
   - [ ] Changes committed

## Land the Plane

Before outputting RALPH_COMPLETE, follow the **Session Protocol** in `AGENTS.md`.

{{> exit-signals}}

- `RALPH_COMPLETE` - Task finished, all quality gates passed
- `RALPH_BLOCKED: <reason>` - Cannot proceed, explain why
- `RALPH_CLARIFY: <question>` - Need clarification before proceeding
