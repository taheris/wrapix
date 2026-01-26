# Task Decomposition

Convert a specification into implementable beads tasks as a molecule.

## Context Pinning

First, read specs/README.md for project terminology and context:

{{PINNED_CONTEXT}}

## Current Specification

Label: {{LABEL}}
Spec file: {{SPEC_PATH}}
Mode: {{MODE}}
{{MOLECULE_CONTEXT}}

## Instructions

{{WORKFLOW_INSTRUCTIONS}}

## Task Breakdown Guidelines

- Each task should be self-contained with enough context for a fresh agent
- Order tasks by dependencies (what must be done first)
- Keep tasks focused - one clear objective per task
- Include test tasks where appropriate
- Consider: setup, implementation, tests, documentation

{{OUTPUT_FORMAT}}

{{README_UPDATE_SECTION}}

## Exit Signals

Output ONE of these at the end of your response:

- `RALPH_COMPLETE` - All tasks created, dependencies set, molecule ID stored
- `RALPH_BLOCKED: <reason>` - Cannot decompose spec (missing information, unclear requirements)
