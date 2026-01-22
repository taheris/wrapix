# Agent Instructions

## Beads Workflow Integration

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT
use markdown TODOs, task lists, or other tracking methods.

### Essential Commands

```bash
# CLI commands for agents
bd ready              # Show issues ready to work (no blockers)
bd list --status=open # All open issues
bd show <id>          # Full issue details with dependencies
bd create --title="..." --type=task --priority=2
bd update <id> --status=in_progress
bd create "..." --priority=1 --deps discovered-from:<parent-id> # Discover new work
bd close <id> --reason="Completed"
bd close <id1> <id2>  # Close multiple issues at once
bd sync               # Commit and push changes
```

### Workflow Pattern

1. **Start**: Run `bd ready` to find actionable work
2. **Claim**: Use `bd update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `bd close <id>`
5. **Sync**: Always run `bd sync` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `bd ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, question, docs
- **Blocking**: `bd dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
git commit -m "..."     # Commit code
bd sync                 # Sync beads (pushes to Dolt remote or commits JSONL)
git push                # Push to remote
```

### Important Rules

- ✅ Check `bd ready` before asking "what should I work on?"
- ✅ Use bd for ALL task tracking
- ✅ Update status as you work (in_progress → closed)
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Use descriptive titles and set appropriate priority/type
- ✅ Run `bd <cmd> --help` to discover available flags
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems
- ❌ Do NOT clutter repo root with planning documents

IMPORTANT: Always Include Issue Descriptions

Issues without descriptions lack context for future work. When creating issues,
always include a meaningful description with:

- Why the issue exists (problem statement or need)
- What needs to be done (scope and approach)
- How you discovered it (if applicable during work)

## ZFC (Zero Framework Cognition) Principles

Core Architecture Principle: This application is pure orchestration that
delegates ALL reasoning to external AI. We build a “thin, safe, deterministic
shell” around AI reasoning with strong guardrails and observability.

✅ ZFC-Compliant (Allowed)

- Pure Orchestration
- IO and Plumbing; Read/write files, list directories, parse JSON,
  serialize/deserialize; Persist to stores, watch events, index documents
- Structural Safety Checks; Schema validation, required fields verification;
  Path traversal prevention, timeout enforcement, cancellation handling
- Policy Enforcement; Budget caps, rate limits, confidence thresholds; “Don’t
  run without approval” gates
- Mechanical Transforms; Parameter substitution (e.g., ${param} replacement);
  Compilation; Formatting and rendering AI-provided data
- State Management; Lifecycle tracking, progress monitoring; Mission journaling,
  escalation policy execution
- Typed Error Handling; Use SDK-provided error classes (instanceof checks);
  Avoid message parsing

❌ ZFC-Violations (Forbidden)

- Local Intelligence/Reasoning
- Ranking/Scoring/Selection; Any algorithm that chooses among alternatives based
  on heuristics or weights
- Plan/Composition/Scheduling; Decisions about dependencies, ordering,
  parallelization, retry policies
- Semantic Analysis; Inferring complexity, scope, file dependencies; Determining
  “what should be done next”
- Heuristic Classification; Keyword-based routing; Fallback decision trees;
  Domain-specific rules
- Quality Judgment; Opinionated validation beyond structural safety;
  Recommendations like “test-first recommended”

🔄 ZFC-Compliant Pattern

The Correct Flow
1. Gather Raw Context (IO only); User intent, project files, constraints,
   mission state
2. Call AI for Decisions; Classification, selection, composition; Ordering,
   validation, next steps
3. Validate Structure; Schema conformance; Safety checks; Policy enforcement
4. Execute Mechanically; Run AI’s decisions without modification

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT
complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs
   follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
