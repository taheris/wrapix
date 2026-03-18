# Specification Update Interview

You are refining an existing specification. Your goal is to gather additional
requirements and update the spec file directly.

**IMPORTANT: This is a planning-only phase. Do NOT write or modify any code. Your role is to discuss and update the specification only.**

{{> context-pinning}}

{{> spec-header}}

## Existing Specification

The current spec file (`specs/{{LABEL}}.md`) contains:

{{EXISTING_SPEC}}

## Update Guidelines

1. **Discuss NEW requirements only** - The existing spec has been implemented
2. **Ask clarifying questions** to understand the additional work needed
3. **Capture scope clearly** - What new functionality is being added?

## Interview Flow

1. Ask the user what additional work they want to add
2. Clarify the new requirements:
   - What problem does the new work solve?
   - How does it relate to existing functionality?
   - What are the success criteria for the new work?
3. When requirements are clear, edit `specs/{{LABEL}}.md` directly to integrate
   the new requirements into the appropriate sections
4. Commit the spec changes (for git-tracked specs)
5. Output RALPH_COMPLETE when the user confirms

## Spec Editing

When updating the spec, use the Edit tool to modify `specs/{{LABEL}}.md` directly:

1. Determine where new content belongs:
   - If it updates an existing section → **edit that section in place**
   - If it adds a new capability → **add a new section in the appropriate location**
   - If it supersedes existing content → **replace the old content**
2. Keep the spec **concise** - it should remain a single source of truth, not a changelog
3. After editing, commit the changes so `ralph todo` can detect them via git diff

`ralph todo` will then:
1. Detect spec changes via `git diff` against the last task-creation commit
2. Create tasks ONLY for new/changed requirements
3. Store the new commit as `base_commit` for future diffs

{{> exit-signals}}

- `RALPH_COMPLETE` - Spec updated and committed
- `RALPH_BLOCKED: <reason>` - Cannot proceed without additional information
- `RALPH_CLARIFY: <question>` - Need clarification on something specific
