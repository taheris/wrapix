# Post-Epic Review

{{> context-pinning}}

{{> spec-header}}

{{> companions-context}}

## Current Spec

Read: {{SPEC_PATH}}

## Beads Summary

{{BEADS_SUMMARY}}

## Review Context

- **Base commit**: {{BASE_COMMIT}}
- **Molecule**: {{MOLECULE_ID}}

## Instructions

You are an independent reviewer assessing the completed work for spec **{{LABEL}}**.

1. **Read the spec** at `{{SPEC_PATH}}` thoroughly
2. **Explore the codebase** — read implementation code, test files, `CLAUDE.md`, and related specs as needed
3. **Run `git diff {{BASE_COMMIT}}..HEAD`** to see all changes made during implementation
4. **Run `git log {{BASE_COMMIT}}..HEAD --oneline`** to understand the commit history
5. **Assess** the deliverable against these criteria:
   - **Spec compliance**: Does the implementation match the spec's requirements?
   - **Code quality**: Is the code well-structured, readable, and maintainable?
   - **Test adequacy**: Are there sufficient tests covering the implemented features?
   - **Coherence**: Do all the pieces fit together? Are there inconsistencies?

## Creating Follow-Up Work

For actionable issues found during review:
```bash
NEW_ID=$(bd create --title="..." --type=bug --labels="spec-{{LABEL}}" \
  --parent="{{MOLECULE_ID}}" --silent)
bd mol bond "$NEW_ID" "{{MOLECULE_ID}}"
```

For ambiguous items that need human judgment:
```bash
bd human <id>
```

## Completion

When your review is complete, emit RALPH_COMPLETE. The orchestrator determines
pass/fail by comparing bead counts before and after your review.

{{> exit-signals}}

- `RALPH_COMPLETE` - Review finished
- `RALPH_BLOCKED: <reason>` - Cannot proceed, explain why
- `RALPH_CLARIFY: <question>` - Need human decision before proceeding
