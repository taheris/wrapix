# Gas City Integration

Integrate [Gas City](https://github.com/gastownhall/gascity) into wrapix as the
multi-agent orchestration layer, with opinionated Nix defaults that let consumers
run autonomous ops loops with minimal configuration.

## Problem Statement

Wrapix provides secure sandboxed containers and Ralph drives single-agent
spec-to-implementation workflows. But production systems need continuous,
autonomous operation: monitoring for errors, fixing them, reviewing fixes for
quality, and deploying safely. This requires coordinating multiple agent roles
running concurrently — something Ralph was not designed for.

Gas City is an orchestration SDK that manages parallel AI agent sessions via a
Kubernetes-style reconciliation loop. By integrating Gas City as the orchestration
layer and wrapix as the execution environment, consumers get a complete autonomous
ops pipeline with good defaults and minimal configuration.

## Requirements

### Architecture

- Gas City (`gc`) binary bundled as a Nix dependency, pinned in the flake
- Wrapix generates `city.toml` from Nix expressions — consumers never write TOML
- Provider implemented as a shell script using Gas City's `exec:<script>` pattern
- Provider translates `gc` commands to `podman` operations
- One city per project; service containers are managed by the wrapix provider
  script via podman, not gc's native service abstraction (which handles
  workflow/proxy_process types, not OCI containers)
- `mkSandbox` remains the foundational primitive, unchanged
- `mkCity` uses `mkSandbox` internally for agent container images
- `mkCity` generates `city.toml`, the provider script, and container images at
  Nix build time — these are deterministic outputs in the Nix store
- All agents use a custom `scale_check` — a single `bd list` query instead
  of gc's default two-query check, which times out under dolt contention
  (gc hardcodes a 30s timeout for scale_check that cannot be configured)

**Components inside the gc container:**

| Component | Role |
|-----------|------|
| `gc start --foreground` | Controller — reconciliation loop, convergence, orders, scheduling |
| Provider script | Translates gc commands to podman operations, manages worktrees, mounts bead context |
| Post-gate order | Event-gated order triggered by `convergence.terminated` — merge, branch cleanup, deploy bead creation |
| Gate condition script | Bridges convergence gate and reviewer session — nudges reviewer, waits for verdict |
| Entrypoint wrapper | Init bead check, starts `podman events` watcher, then exec's `gc start --foreground` |

### Deployment Model

- gc runs in a container with the podman socket mounted (sibling container
  pattern), using `gc start --foreground` for per-city controller mode (gc
  defaults to a machine-wide supervisor since v0.13+)
- The gc container has no direct host access beyond the podman socket and
  workspace mount
- All containers (services, agents) share a podman network per city
- Service containers are built from Nix packages via `dockerTools.buildLayeredImage`
- NixOS module generates systemd units, a podman network
  (`wrapix-<city-name>`), and invokes `mkCity` to produce `city.toml` and
  container images

### Roles

Four roles in the ops loop:

| Role | Job | Lifetime | Workspace Access | Podman Socket |
|------|-----|----------|-----------------|---------------|
| **Scout** | Watches service containers, detects errors, creates beads | Persistent | Read-only + `.beads/` rw | Read-only (logs, inspect) |
| **Worker** | Picks up a bead, investigates, writes the fix | Ephemeral (per bead) | Read-write (own worktree) | None |
| **Reviewer** | Reviews every worker's output before merge, enforces style guidelines | Persistent | Read-only + `.beads/` rw | None |
| **Director** | Human operator, makes structural decisions | Always | Full | Full |

### Ops Loop

```
Scout (watching) --> creates bead --> Worker (fixes) --> Reviewer (reviews)
   ^                                                          |
   |                                              +-----------+
   |                                              v           v
   |                                           merge       reject --> Worker retry
   |                                              |           |
   |                                              v           v (loop > 1)
   +------------------------------------------ deploy     Director notified
```

- Scout is a persistent session. gc orders poke it on a polling interval
  (configurable, default 5 minutes). gc's `session_sleep` auto-suspends
  idle scouts; the next order or gc mail restarts it fresh. This keeps
  context clean while maintaining addressability for gc mail.
- Hybrid event trigger: the entrypoint wrapper starts a background process
  watching `podman events` for service container lifecycle events (die, oom,
  restart) and wakes the scout immediately via `gc nudge scout --message "..."`.
  Nudge is push-based (directly sends to the session). Service containers are
  not gc sessions, so gc hooks don't cover them.
- In addition to event-driven detection, the scout scans `podman logs` for
  error patterns using regex matching.
  Patterns are defined in `docs/orchestration.md` under `## Scout Rules`:
  - **Immediate** patterns (e.g., `FATAL|PANIC|panic:`) create a P0 bead
  - **Batched** patterns (e.g., `ERROR|Exception`) are collected over one poll
    cycle, then one bead per unique pattern
  - **Ignore** patterns suppress known noise
  - Defaults if the section doesn't exist: `FATAL|PANIC|panic:` immediate,
    `ERROR|Exception` batched
- Scout deduplicates — if a bead exists for the same error pattern, it appends
  rather than creating a new one
- Queue overflow protection: scout collapses related errors into a single bead
  across poll cycles, and stops creating new beads after a cap (configurable
  via `scout.maxBeads`, default: 10 open beads). Director is notified when
  the cap is reached.
- Workers run in isolated git worktrees with clean state per bead (see
  Session Lifecycle for details)
- **gc convergence owns the worker→reviewer loop end-to-end.** Worker
  executes the fix, reviewer is the gate, max iterations = 2. gc manages
  session lifecycle, handoff between worker and reviewer, and escalation.
  After 2 failed iterations, convergence escalates to the director via
  notification. An event-gated order (`on: convergence.terminated`) triggers
  the post-gate logic (merge, deploy) when convergence approves.
- Reviewer enforces `docs/style-guidelines.md` mechanically; flags anything
  outside documented rules for director review via `bd label add <id> human`
- After reviewer approval, deploy is gated by risk tier (see Deploy section)

### Ad-hoc Director Requests

Two paths for the director to inject work:

- **Investigation**: `gc mail send --to scout -s "investigate" -m "..."` —
  the scout picks this up on its next order cycle, investigates, and creates
  a bead if it finds something actionable. Lightweight, no bead created
  upfront, no entry into the worker→reviewer loop unless warranted.
- **Urgent fix**: `bd create --priority=0` — creates a P0 bead that bypasses
  cooldown and enters the full ops loop (worker→reviewer→merge→deploy).

### Merge

The post-gate order fires on `convergence.terminated` events. It checks
`terminal_reason=approved` and handles merge:

- Linear history only: `git merge --ff-only gc-<bead-id>`
- If fast-forward fails (main advanced): rebase the branch onto main, run
  `prek` (pre-commit stage), then fast-forward merge. If tests fail after
  rebase, reject back to a new worker with the failure details.
- If rebase has conflicts: reject back to a new worker with conflict details
  as context — no automatic conflict resolution
- Reviewer does not run tests — it reviews code quality against
  `docs/style-guidelines.md` only
- After merge: `rm -rf .wrapix/worktree/gc-<bead-id>` + `git worktree prune`
  and `git branch -d gc-<bead-id>`. `git worktree remove` cannot be used
  because the provider rewrites the worktree's `.git` file with a
  container-internal path. On rejection, old branch is also deleted — the
  new worker creates a fresh one.

#### Reviewer Gate

The worker→reviewer handoff is managed by gc convergence with
`gate_mode=condition`. The gate condition script:

1. Reads `commit_range` from bead metadata (set by the provider script
   after worker commits via `bd update <bead-id> --set-metadata "commit_range=<range>"`)
2. Nudges the reviewer session with the commit range via `gc nudge reviewer`
3. Polls bead metadata for `review_verdict` (approve/reject), set by the
   reviewer via `bd update <bead-id> --set-metadata "review_verdict=approve"`
4. Returns exit 0 on approve, exit 1 on reject — gc convergence uses this
   to decide whether to iterate or terminate

The reviewer reads the bead from `.beads/`, diffs the commits, and reviews
against `docs/style-guidelines.md`. Bead ID and role type are injected via
the formula's `env` configuration, not `runtime.Config` directly.

### Notifications

- The post-gate order and entrypoint wrapper call `wrapix-notify` (the
  notification client) for director-facing events. `wrapix-notifyd` is the
  daemon and must not be called directly (it blocks).
  - `bd label add <id> human` flags (reviewer flagged something outside
    documented rules)
  - Convergence escalation (max iterations reached — worker→reviewer loop
    failed twice)
  - Deploy approval needed
  - Periodic digest (hot spots, fix counts, rejection rates) — generated
    by a cooldown-gated digest order on a configurable interval
- The gc container mounts the notify socket (same pattern as podman socket)
- Future: migrate to beads hooks when available, so standalone `ralph run`
  users also get notifications

### Deploy

- After reviewer approval, the post-gate order creates a deploy bead
  summarizing the change and its risk classification
- Default: deploy beads are flagged for director approval via
  `bd label add <id> human`. The director runs `nix build` on the host,
  then restarts the affected containers manually
  (`podman stop && podman rm && podman run`).
- Consumer can opt into auto-deploy for low-risk changes by defining an
  `## Auto-deploy` section in `docs/orchestration.md`. When the reviewer
  classifies a change as low-risk per these rules, the post-gate order
  skips the human label. A cooldown-gated deploy order polls for
  unflagged deploy beads and restarts containers automatically (still
  requires the director or CI to have pre-built the images).
- The gc container does not run Nix builds. Rolling restarts and database
  migrations are out of scope for v1.

### Build-to-Ops Transition

- No automatic escalation from ops to build mode, ever
- The system surfaces patterns for the director to interpret:
  - Worker observations: "this is a patch, the real fix needs restructuring"
    (flagged via `bd label add <id> human`)
  - Reviewer observations: "third patch to this module this week"
    (flagged via `bd label add <id> human`)
  - Periodic digest: hot spots, fix counts, rejection rates (see
    Notifications section)
- Director decides when to initiate `ralph plan` for a spec-driven redesign
- During a build: creating a spec bead implicitly holds the affected area.
  The spec bead's description should name the modules/files under redesign.
  The reviewer checks for active spec beads and rejects worker fixes that
  touch held areas. When the spec bead closes, the hold lifts automatically.
- Build complete to ops: automatic — scout watches new code, no explicit handoff

### Context Hierarchy

| File | Shared | Pinned | Purpose |
|------|--------|--------|---------|
| `docs/README.md` | git | Always (baked into formulas) | Project overview, terminology |
| `docs/architecture.md` | git | On demand (referenced by formulas when needed) | System design |
| `docs/orchestration.md` | git | On demand (loaded by ops formulas at session start) | Ops config, deploy commands, role rules |
| `docs/style-guidelines.md` | git | On demand (loaded by reviewer formula at session start) | Code standards the reviewer enforces |
| `.wrapix/orchestration.md` | local | On demand (loaded by ops formulas at session start) | Dynamic/temporal overrides |

- `ralph sync` always scaffolds missing docs files for any project:
  `docs/README.md` (project overview), `docs/architecture.md` (system design),
  `docs/style-guidelines.md` (code standards). These are useful with or
  without Gas City.
- When `ralph sync` detects `mkCity` in the flake, it additionally scaffolds
  `docs/orchestration.md` from the built city config with placeholder sections
  for deploy commands, scout rules, and auto-deploy criteria.
- All scaffolded files are created as beads flagged for director review via
  `bd label add <id> human`
- Director reviews and approves scaffolded files before running `gc start`
- The entrypoint wrapper checks for unresolved scaffolding beads (created by
  `ralph sync`) before starting gc. If any exist, it prints a warning listing
  the pending reviews and exits.
- `.wrapix/orchestration.md` is tool-managed — updated by gc commands, not
  manually edited

### Anti-Slop

- Reviewer enforces `docs/style-guidelines.md` mechanically
- Changes outside documented rules are flagged for director, not auto-decided
- Director decisions feed back into `docs/style-guidelines.md`, growing the rules
  organically
- Reviewer also sweeps `.wrapix/orchestration.md` for stale dynamic context
  (expired dated entries, undated entries older than 7 days)

### Nix API

Flake API — minimal:

```nix
wrapix.mkCity {
  services.api.package = myApp;
}
```

Flake API — full options:

```nix
wrapix.mkCity {
  # workspace defaults to flake root
  profile = wrapix.profiles.rust;

  services = {
    api = {
      package = myApp;
      # Service container options follow NixOS oci-containers schema
      # (ports, environment, volumes, cmd, etc.)
    };
    db = {
      package = pkgs.postgresql_16;
    };
  };

  # Agent configuration
  agent = "claude";           # default, only option for now

  # Scaling and pacing
  workers = 1;                # max concurrent workers (default: 1)
  cooldown = "2h";            # time between task dispatches (default: "0")
  scout.interval = "5m";      # polling interval (default: "5m")
  scout.maxBeads = 10;         # bead cap before scout pauses (default: 10)

  # Resource limits per role (optional, default: no limits)
  resources = {
    worker = { cpus = 2; memory = "4g"; };
    scout = { cpus = 1; memory = "2g"; };
    reviewer = { cpus = 1; memory = "2g"; };
  };

  # Secrets — string = env var name, absolute path = file
  secrets.claude = "ANTHROPIC_API_KEY";                     # reads host env var
  secrets.deployKey = config.sops.secrets.deploy-key.path;  # reads file (absolute path)
}
```

NixOS module (the module receives `wrapix` via the flake's NixOS module imports):

```nix
services.wrapix.cities.myapp = {
  workspace = "/var/lib/myapp";    # required on NixOS (no flake root)
  profile = "rust";                # string shorthand resolved by the module
  services = {
    api.package = myApp;
    db.package = pkgs.postgresql_16;
  };
  secrets.claude = config.sops.secrets.claude-api-key.path;
};
```

### Provider Interface

Shell script implementing Gas City's `exec:<script>` provider pattern.
The script receives a command and arguments, translates to podman operations.

**Persistent roles (scout, reviewer)** — full tmux-based interaction:

| gc method | Provider action |
|-----------|----------------|
| `Start` | `podman run -d` with tmux as PID 1 |
| `Stop` | `podman stop && podman rm` |
| `Interrupt` | `podman exec tmux send-keys C-c` |
| `IsRunning` | `podman inspect --format '{{.State.Running}}'` |
| `Attach` | `podman exec -it tmux attach` |
| `Peek` | `podman exec tmux capture-pane` |
| `SendKeys` | `podman exec tmux send-keys` |
| `Nudge` | Wait for idle + `podman exec tmux send-keys` |
| `GetLastActivity` | `podman exec tmux display -p '#{pane_last_activity}'` |
| `ClearScrollback` | `podman exec tmux clear-history` |
| `IsAttached` | Return false (not tracked in v1) |
| `RunLive` | No-op (unsupported by exec provider — returns nil without calling script) |

**Ephemeral workers** — no tmux, container exit signals completion:

| gc method | Provider action |
|-----------|----------------|
| `Start` | `podman run -d` with task command as entrypoint |
| `Stop` | `podman stop && podman rm` |
| `IsRunning` | `podman inspect --format '{{.State.Running}}'` |
| `Peek` | `podman logs --tail` |
| `Interrupt` / `SendKeys` / `Nudge` | No-op (worker runs to completion or is stopped) |
| `IsAttached` / `Attach` / `GetLastActivity` / `ClearScrollback` / `RunLive` | No-op |

**Shared across both modes:**

| gc method | Provider action |
|-----------|----------------|
| `ListRunning` | `podman ps --filter label=gc-city=<name>` |
| `SetMeta/GetMeta/RemoveMeta` | Container-internal files at `/tmp/gc-meta/<key>` via `podman exec` (gc session metadata — separate from bead metadata managed by `bd update --set-metadata`) |
| `CopyTo` | `podman cp` |
| `ProcessAlive` | Persistent: `podman exec pgrep`. Ephemeral: delegates to `IsRunning` |
| `CheckImage` | `podman image exists <image>` |
| `Capabilities` | Returns empty (exec provider hardcodes all false) |

Container labeling convention:
- `gc-city=<city-name>`
- `gc-role=worker|scout|reviewer`
- `gc-bead=<bead-id>` (workers only)

### Session Lifecycle

**Persistent roles (scout, reviewer):**
- Started with the city, stopped with the city
- `podman run -d` with tmux server as PID 1
- gc interacts via `podman exec tmux send-keys` / `capture-pane`

**Ephemeral workers:**
- One container per bead, clean state every time
- Workers discover beads via gc's pull model: `bd ready --metadata-field
  gc.routed_to=worker --unassigned` (gc routes beads via its
  `EffectiveSlingQuery` which sets `gc.routed_to=<agent_template>`)
- The provider script's `Start` handler creates the git worktree:
  `git worktree add .wrapix/worktree/gc-<bead-id> -b gc-<bead-id>`
- The provider rewrites the worktree's `.git` file to
  `gitdir: /mnt/git/worktrees/gc-<bead-id>` and mounts the main `.git`
  at `/mnt/git:rw` so git operations work inside the container
- Worker container mounts the worktree as its workspace (`/workspace:rw`),
  `.beads/` as read-only, and receives a `.task` file built from the bead
  description, acceptance criteria, and any reviewer notes from prior attempts
- Worker commits to the branch, then exits. A background monitor sets
  `commit_range` and `branch_name` on the bead metadata after exit.
- gc convergence detects worker completion and hands off to the reviewer gate
- After convergence completes (approved or escalated), the post-gate order
  handles merge and worktree cleanup:
  `rm -rf .wrapix/worktree/gc-<bead-id>` + `git worktree prune`

**Crash recovery:**
- The gc container runs as a systemd service with `Restart=always`
- On restart: scan `podman ps --filter label=gc-city=<name>` for running containers
- Reconcile against beads state (desired vs actual)
- Orphaned workers (no matching in-progress bead): stop and remove
- Workers that finished (commits on branch, bead still open): re-enter convergence
- Stale worktrees in `.wrapix/worktree/gc-*`: clean up orphans

### Beads Sync

Two modes depending on execution path:

| Mode | Beads access | Sync mechanism |
|------|-------------|----------------|
| `ralph run` (standalone) | Container has bd + dolt, does its own pull/push | Existing behavior, unchanged |
| `gc start` (orchestrated) | gc container, scout, and reviewer have bd | Ephemeral workers have no bd/dolt access |

In gc mode, the gc container (provider script, gate script, post-gate order),
scout, and reviewer all have bd access for bead creation, metadata, and
status updates. Only ephemeral workers are isolated — they receive their task
via environment variables and a mounted task file, with no direct bd access.

The provider script's `Start` handler passes the bead ID, task
description, and relevant context to the worker via environment variables and
a mounted task file. The task file contains the bead description, acceptance
criteria, and any reviewer notes from prior attempts. The worker reads these,
executes the task using `wrapix-agent`, commits results to its worktree
branch, and exits. A background monitor in the provider script sets
`commit_range` and `branch_name` on the bead metadata via
`bd update --set-metadata` after the worker exits, so the gate condition
script can read this context when bridging to the reviewer.
The post-gate order reads bead state and updates it based on the container
exit code and branch contents. No dolt sync between containers.

### Ralph Integration

Ralph stays as the standalone workflow tool. Gas City is additive:

| Phase | Ralph (standalone) | Gas City (orchestrated) |
|-------|-------------------|------------------------|
| Spec authoring | `ralph plan` | `ralph plan` (unchanged) |
| Work decomposition | `ralph todo` | `ralph todo` (unchanged) |
| Execution | `ralph run` (single agent, one container) | `gc start` (multi-agent, parallel workers) |

`ralph todo` produces beads. Both `ralph run` and `gc start` consume them.
No changes to `ralph todo` needed — beads are the interface.

### Agent Abstraction

The agent tool (Claude, Codex, Gemini) is a configuration option, not baked into
the container image:

```nix
wrapix.mkCity {
  agent = "claude";    # default, only option for now
}
```

The provider script calls a `wrapix-agent` wrapper that translates to the
configured agent's CLI. For claude, this invokes `claude` in both modes —
ephemeral workers receive their task via a mounted prompt file and `docs/`
context, persistent roles run as interactive sessions. The wrapper handles
prompt construction and output capture. One place to swap, all roles benefit.
Future agent providers require only a new entry in the
agent registry and the corresponding package in the Nix closure.

Role behavior is defined as gc formulas. `mkCity` generates default formulas
for scout, worker, and reviewer roles. Consumers can override formulas to
customize role behavior without modifying the provider script or container
images.

### Secrets

- Secrets are never baked into images — always injected at runtime
- `secrets.claude` is required — city fails to start if not set
- String starting with `/` = file path (works with sops-nix, agenix, or plain files)
- Any other string = host environment variable name
- The gc container receives secrets from the host; the provider script passes
  them to agent containers at start

```nix
# Option A: env var (no leading /)
secrets.claude = "ANTHROPIC_API_KEY";

# Option B: file path (works with sops-nix, agenix, etc.)
secrets.claude = config.sops.secrets.claude-api-key.path;  # resolves to /run/secrets/...

# Additional secrets (optional)
secrets.deployKey = config.sops.secrets.deploy-key.path;
```

### Resource Limits and Pacing

**Compute:** Podman-native resource limits per role:

```nix
resources = {
  worker = { cpus = 2; memory = "4g"; };
  scout = { cpus = 1; memory = "2g"; };
  reviewer = { cpus = 1; memory = "2g"; };
};
```

Default: no limits.

**Pacing:** Two controls plus automatic backpressure:

- `workers` — max concurrent workers (default: 1)
- `cooldown` — time between task dispatches (default: `"0"`)
- P0 beads bypass cooldown — dispatched immediately regardless of pacing.
  The director can create P0 beads directly (`bd create --priority=0`) to
  inject urgent work into the ops loop without waiting.
- Reactive backpressure (automatic): when any agent hits a rate limit,
  gc pauses dispatching until the window resets

```nix
workers = 1;
cooldown = "2h";     # supports "30m", "1h", "2h30m", etc.
```

### Platform Support

| Platform | `ralph plan/todo/run` | `mkCity` (ops) |
|----------|----------------------|----------------|
| Linux | Yes | Yes (production) |
| macOS | Yes (existing wrapix support) | Not supported |

### Testing

Layered testing via `nix flake check` and pre-commit hooks:

| Layer | What | Hook | Automated |
|-------|------|------|-----------|
| 1. Nix evaluation | `mkCity` evaluates, `city.toml` valid, TOML generation | `nix-flake-check` (pre-push) | On push |
| 2. Unit tests | Shell syntax, gate exit codes, provider commands, scout parsing, config validation | `nix-flake-check` (pre-push) | On push |
| 3. Integration | Full ops loop: gc → provider.sh → podman → container → mock claude | `city-integration` (pre-push) | On push (requires podman, skips gracefully if missing) |

Unit tests live in `tests/city/unit.nix` and run inside the Nix sandbox (no
podman needed). The integration test lives in `tests/city/integration.nix`
and exercises the real stack end-to-end:

- Phase 1 (happy path): gc starts scout + reviewer via podman, scout creates
  bead, director slings into convergence, worker commits in worktree,
  reviewer approves, post-gate merges and creates deploy bead
- Phase 2 (merge conflict): conflicting change on main, post-gate detects
  rebase conflict, rejects back to worker with failure context
- Phase 3 (escalation): convergence ends with non-approved reason, post-gate
  cleans up worktree and branch

```yaml
# .pre-commit-config.yaml
- id: nix-flake-check
  stages: [pre-push]
  entry: nix flake check

- id: city-integration
  stages: [pre-push]
  entry: nix run .#test-city
  files: ^(lib/city/|tests/city|specs/gas-city)
```

### Upgrades

- Director rebuilds the flake on the host (`nix build`), then restarts the
  city (`gc stop && gc start --foreground`)
- gc does not detect or apply upgrades automatically
- In-flight workers are stopped; their beads remain open and are picked up
  after restart
- Graceful drain (wait for active workers) is out of scope for v1

### Migration

No breaking changes. Gas City is additive:

1. **No change** — existing `mkSandbox` + `ralph` users are unaffected
2. **Try gc** — add `mkCity` alongside existing setup, use `gc start` instead
   of `ralph run`
3. **Full ops** — define services in `mkCity`, get the autonomous ops loop

### CLI Surface

No new commands. Existing tools compose:

| Tool | Domain | Used for |
|------|--------|----------|
| `gc` | Orchestration | `gc start --foreground`, `gc stop`, `gc status`, `gc session attach/peek/nudge` |
| `bd` | Work tracking | `bd ready`, `bd human`, `bd close` |
| `ralph` | Spec workflow + setup | `ralph plan`, `ralph todo`, `ralph run` (fallback), `ralph sync` (city setup) |

## Affected Files/Modules

| Area | Files | Change |
|------|-------|--------|
| Nix API | `lib/city/default.nix` | `mkCity` function |
| Provider | `lib/city/provider.sh` | Shell script for `exec:<script>` |
| NixOS module | `modules/city.nix` | `services.wrapix.cities` |
| Agent wrapper | `lib/city/agent.sh` | `wrapix-agent` CLI abstraction |
| Formulas | `lib/city/formulas/` | Default scout, worker, reviewer formulas |
| Post-gate order | `lib/city/post-gate.sh` | Event-gated order: merge, branch cleanup, deploy bead creation |
| Orders | `lib/city/orders/post-gate/order.toml` | gc order definition for post-gate event trigger |
| Gate condition | `lib/city/gate.sh` | Convergence gate: nudge reviewer, wait for verdict |
| Recovery | `lib/city/recovery.sh` | Crash recovery: reconcile containers vs bead state |
| Entrypoint | `lib/city/entrypoint.sh` | Init bead check, podman events watcher, exec gc |
| Unit tests | `tests/city/unit.nix` | Nix-sandbox tests for all components |
| Integration tests | `tests/city/integration.nix` | Full ops loop via podman |
| Flake | `flake.nix` | Add gc dependency, expose mkCity |
| Sandbox | `lib/sandbox/default.nix` | No changes (mkCity uses mkSandbox) |
| Ralph | `lib/ralph/cmd/sync.sh` | Extend `ralph sync` to detect mkCity and scaffold |
| Docs convention | `docs/` | Established by scaffolding on first run |

## Success Criteria

- [x] `mkCity` evaluates with minimal config (`services.api.package = myApp`)
  [verify](tests/city/unit.nix::city-mkcity-eval)
- [x] Generated `city.toml` is valid and references the wrapix provider script
  [verify](tests/city/unit.nix::city-city-toml), [verify](tests/city/unit.nix::city-config-validate)
- [x] Provider script handles all gc provider methods
  [verify](tests/city/unit.nix::city-shell-syntax), [verify](tests/city/unit.nix::city-provider-worker)
- [x] Ephemeral workers use git worktrees at `.wrapix/worktree/gc-<bead-id>`
  [verify](tests/city/integration.nix::Phase 1 worker worktree)
- [x] Persistent roles (scout, reviewer) start with tmux as PID 1
  [verify](tests/city/integration.nix::Phase 1 scout/reviewer start)
- [x] gc convergence detects worker completion and triggers reviewer gate
  [verify](tests/city/integration.nix::Phase 1 reviewer approval)
- [x] Secrets are injected at runtime, never baked into images
  [verify](tests/city/unit.nix::city-secrets)
- [ ] `ralph run` still works standalone without gc
- [x] NixOS module generates systemd units and podman network
  [verify](tests/city/unit.nix::city-nixos-module)
- [ ] Crash recovery: gc container restarts, reconciles orphaned containers
- [ ] `ralph sync` scaffolds missing docs files and creates review beads
- [x] Service packages are built into OCI images via `dockerTools.buildLayeredImage`
  [verify](tests/city/unit.nix::city-service-images)
- [ ] Cooldown pacing delays task dispatch by configured duration
- [ ] Reviewer enforces `docs/style-guidelines.md` rules
  [judge]
- [x] Provider script is clean, minimal shell with no Go dependencies
  [judge]
- [x] Agent abstraction allows future provider swaps without architectural changes
  [judge]
- [ ] P0 beads bypass cooldown and are dispatched immediately
- [x] Merge uses fast-forward only; rebase + prek on divergence
  [verify](tests/city/integration.nix::Phase 1 post-gate merge), [verify](tests/city/integration.nix::Phase 2 merge conflict)
- [x] Post-gate order sends notifications via `wrapix-notify` for director events
  [verify](tests/city/integration.nix::Phase 1 deploy bead)
- [ ] Scout pauses bead creation when queue cap is reached
- [x] Scout detects errors via log pattern regex matching
  [verify](tests/city/unit.nix::city-scout-parse-rules), [verify](tests/city/unit.nix::city-scout-scan)
- [x] Reviewer gate reads commit range from bead metadata
  [verify](tests/city/unit.nix::city-gate-functional)
- [ ] Scout polling uses gc orders for scheduling
- [ ] Worker→reviewer retry uses gc convergence with max 2 iterations
- [x] Role behavior defined as gc formulas, overridable by consumers
  [verify](tests/city/unit.nix::city-formulas)
- [x] Post-gate handles escalation path (non-approved convergence)
  [verify](tests/city/integration.nix::Phase 3 escalation)
- [x] Custom scale_check avoids gc's 30s timeout under dolt contention
  [verify](tests/city/unit.nix::city-config-validate)

## Out of Scope

- Web UI / dashboard — the director interacts via CLI only (`gc`, `bd`, `ralph`)
- Multi-machine cities — one city per host; architecture supports future
  multi-host via podman remote but not implemented in v1
- Non-Nix consumers — `mkCity` requires Nix
- Custom agent providers — claude only at launch; Codex/Gemini are future work
- The Wasteland — federated cities / trust networks
- macOS production cities — dev only, Linux for production
- Token tracking / budget enforcement — rely on backpressure + cooldown
- Service builds from source — services defined by Nix package
- Gas City upstream contributions — provider is `exec:` script, not a Go PR
