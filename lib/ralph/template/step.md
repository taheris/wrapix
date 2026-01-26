# Implementation Step

## Context Pinning

First, read specs/README.md to understand project terminology and context:

{{PINNED_CONTEXT}}

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
   - Create with provenance: `bd create --title="..." --type=task --labels="rl-{{LABEL}}" --deps="discovered-from:{{ISSUE_ID}}"`
   - Do NOT implement discovered tasks in this session—stay focused
5. **Quality Gates**: Before completing, ensure:
   - [ ] All tests pass
   - [ ] Lint checks pass
   - [ ] Changes committed

## Land the Plane

Before outputting RALPH_COMPLETE, follow the **Session Protocol** in `AGENTS.md`.

## Exit Signals

Output ONE of these at the end of your response:

- `RALPH_COMPLETE` - Task finished, all quality gates passed
- `RALPH_BLOCKED: <reason>` - Cannot proceed, explain why
- `RALPH_CLARIFY: <question>` - Need clarification before proceeding
