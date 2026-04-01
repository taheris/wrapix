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
- One city per project; services are defined within the city
- `mkSandbox` remains the foundational primitive, unchanged
- `mkCity` uses `mkSandbox` internally for agent container images
- `mkCity` generates `city.toml`, the provider script, and container images at
  Nix build time — these are deterministic outputs in the Nix store

### Deployment Model

- `gc-control` runs in a container with the podman socket mounted (sibling
  container pattern)
- `gc-control` has no direct host access beyond the podman socket and workspace
  mount
- All containers (services, agents) share a podman network per city
- Service containers are built from Nix packages via `dockerTools.buildLayeredImage`
- NixOS module generates systemd units, a podman network
  (`wrapix-<city-name>`), and invokes `mkCity` to produce `city.toml` and
  container images

### Roles

Four roles in the ops loop:

| Role | Job | Lifetime | Workspace Access | Podman Socket |
|------|-----|----------|-----------------|---------------|
| **Scout** | Watches service containers, detects errors, creates beads | Persistent | Read-only | Read-only (logs, inspect) |
| **Worker** | Picks up a bead, investigates, writes the fix | Ephemeral (per bead) | Read-write (own worktree) | None |
| **Reviewer** | Reviews every worker's output before merge, enforces style guidelines | Persistent | Read-only | None |
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

- Scout runs on a polling interval (configurable, default 5 minutes)
- Hybrid event trigger: a lightweight shell process watches `podman events`
  for critical lifecycle events (die, oom, restart) and wakes the scout
  immediately
- Scout deduplicates — if a bead exists for the same error pattern, it appends
  rather than creating a new one
- Workers run in isolated git worktrees with clean state per bead (see
  Session Lifecycle for details)
- Container exit is the completion event — no polling for task completion
- Reviewer enforces `docs/style-guidelines.md` mechanically; flags anything
  outside documented rules for director review via `bd human`
- Rejection: reviewer reopens the bead with review notes, a new worker picks
  it up. If rejected twice for the same bead, director is notified
- After reviewer approval, deploy is gated by risk tier (see Deploy section)

### Deploy

- Default: all deploys require director approval via `bd human`
- Consumer can opt into auto-deploy for low-risk changes by defining an
  `## Auto-deploy` section in `docs/orchestration.md`
- Deploy means: the director (or CI) runs `nix build` on the host to produce
  updated service images, then gc-control restarts the affected containers
  with the new image (`podman stop && podman rm && podman run`). gc-control
  does not run Nix builds itself. Rolling restarts and database migrations
  are out of scope for v1.
- Reviewer classifies risk based on the auto-deploy rules

### Build-to-Ops Transition

- No automatic escalation from ops to build mode, ever
- The system surfaces patterns for the director to interpret:
  - Worker observations: "this is a patch, the real fix needs restructuring"
    (flagged via `bd human`)
  - Reviewer observations: "third patch to this module this week"
    (flagged via `bd human`)
  - Periodic digest: hot spots, fix counts, rejection rates (mechanism TBD —
    may be a gc subcommand or a scheduled bead summary)
- Director decides when to initiate `ralph plan` for a spec-driven redesign
- During a build: creating a spec bead implicitly holds the affected area.
  The spec bead's description should name the modules/files under redesign.
  The reviewer checks for active spec beads and rejects worker fixes that
  touch held areas. When the spec bead closes, the hold lifts automatically.
- Build complete to ops: automatic — scout watches new code, no explicit handoff

### Context Hierarchy

| File | Shared | Pinned | Purpose |
|------|--------|--------|---------|
| `docs/README.md` | git | Always (baked into role prompts) | Project overview, terminology |
| `docs/architecture.md` | git | On demand (referenced by role prompts when needed) | System design |
| `docs/orchestration.md` | git | On demand (loaded by ops role prompts at session start) | Ops config, deploy commands, role rules |
| `docs/style-guidelines.md` | git | On demand (loaded by reviewer prompt at session start) | Code standards the reviewer enforces |
| `.wrapix/orchestration.md` | local | On demand (loaded by ops role prompts at session start) | Dynamic/temporal overrides |

- `ralph sync` always scaffolds missing docs files for any project:
  `docs/README.md` (project overview), `docs/architecture.md` (system design),
  `docs/style-guidelines.md` (code standards). These are useful with or
  without Gas City.
- When `ralph sync` detects `mkCity` in the flake, it additionally scaffolds
  `docs/orchestration.md` from the built city config with placeholder sections
  for deploy commands, scout rules, and auto-deploy criteria.
- All scaffolded files are created as beads flagged for director review via
  `bd human`
- Director reviews and approves scaffolded files before running `gc start`
- The gc-control entrypoint checks for unresolved init beads before starting
  the reconciliation loop. If any exist, it prints a warning listing the
  pending reviews and exits.
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
| `RunLive` | `podman exec sh -c` |

**Ephemeral workers** — no tmux, container exit signals completion:

| gc method | Provider action |
|-----------|----------------|
| `Start` | `podman run -d` with task command as entrypoint |
| `Stop` | `podman stop && podman rm` |
| `IsRunning` | `podman inspect --format '{{.State.Running}}'` |
| `Peek` | `podman logs --tail` |
| `Interrupt` / `SendKeys` / `Nudge` | No-op (worker runs to completion or is stopped) |
| `Attach` / `GetLastActivity` / `ClearScrollback` / `RunLive` | No-op |

**Shared across both modes:**

| gc method | Provider action |
|-----------|----------------|
| `ListRunning` | `podman ps --filter label=gc-city=<name>` |
| `SetMeta/GetMeta/RemoveMeta` | Container labels via `podman inspect` |
| `CopyTo` | `podman cp` |
| `ProcessAlive` | Persistent: `podman exec pgrep`. Ephemeral: delegates to `IsRunning` |
| `Capabilities` | `{ CanDetectAttachment: true, CanDetectActivity: true }` |

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
- gc-control creates git worktree: `git worktree add .wrapix/worktree/gc-<bead-id> -b gc-<bead-id>`
- Worker container mounts the worktree as its workspace
- Worker commits to the branch, then exits
- Container exit event (via `podman events`) signals completion
- gc-control checks branch for commits, sends to reviewer
- After merge or rejection: `git worktree remove .wrapix/worktree/gc-<bead-id>`

**Crash recovery:**
- gc-control is a systemd service with `Restart=always`
- On restart: scan `podman ps --filter label=gc-city=<name>` for running containers
- Reconcile against beads state (desired vs actual)
- Orphaned workers (no matching in-progress bead): stop and remove
- Workers that finished (commits on branch, bead still open): send to reviewer
- Stale worktrees in `.wrapix/worktree/gc-*`: clean up orphans

### Beads Sync

Two modes depending on execution path:

| Mode | Beads access | Sync mechanism |
|------|-------------|----------------|
| `ralph run` (standalone) | Container has bd + dolt, does its own pull/push | Existing behavior, unchanged |
| `gc start` (orchestrated) | gc-control owns beads exclusively | Workers have no bd/dolt access |

In gc mode, gc-control passes the bead ID, task description, and relevant
context to the worker via environment variables and a mounted task file at
container start. The task file contains the bead description, acceptance
criteria, and any reviewer notes from prior attempts. The worker reads these,
executes the task using `wrapix-agent`, commits results to its worktree
branch, and exits. gc-control reads bead state and updates it based on the
container exit code and branch contents. No dolt sync between containers.

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
prompt construction and output capture. One place to swap,
all roles benefit. Future agent providers require only a new entry in the
agent registry and the corresponding package in the Nix closure.

### Secrets

- Secrets are never baked into images — always injected at runtime
- `secrets.claude` is required — city fails to start if not set
- String starting with `/` = file path (works with sops-nix, agenix, or plain files)
- Any other string = host environment variable name
- gc-control receives secrets from the host and passes them to agent containers

```nix
secrets.claude = "ANTHROPIC_API_KEY";                          # env var (no leading /)
secrets.claude = config.sops.secrets.claude-api-key.path;      # file (returns /run/secrets/...)
secrets.deployKey = config.sops.secrets.deploy-key.path;       # optional
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
- Reactive backpressure (automatic): when any agent hits a rate limit,
  gc-control pauses dispatching until the window resets

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

Layered testing integrated with prek stages:

| Layer | What | prek stage | Automated |
|-------|------|-----------|-----------|
| 1. Nix evaluation | `mkCity` evaluates, `city.toml` valid, images build | `pre-commit` | Always |
| 2. Provider script | Mock podman, verify command translation | `pre-commit` | Always |
| 3. Container lifecycle | Images start, entrypoints work, tmux runs | `pre-commit` | Always |
| 4+5. Integration + VM | Full ops loop in NixOS VM test | `manual` | On demand |

```yaml
# .pre-commit-config.yaml
- id: gc-fast
  stages: [pre-commit]
  entry: nix build .#checks.x86_64-linux.gc-fast

- id: gc-full
  stages: [pre-push]
  entry: nix flake check

- id: gc-integration
  stages: [manual]
  entry: nix build .#checks.x86_64-linux.gc-integration
```

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
| `gc` | Orchestration | `gc start`, `gc stop`, `gc status` |
| `bd` | Work tracking | `bd ready`, `bd human`, `bd close` |
| `ralph` | Spec workflow + setup | `ralph plan`, `ralph todo`, `ralph run` (fallback), `ralph sync` (city setup) |

## Affected Files/Modules

| Area | Files | Change |
|------|-------|--------|
| Nix API | `lib/city/default.nix` (new) | `mkCity` function |
| Provider | `lib/city/provider.sh` (new) | Shell script for `exec:<script>` |
| NixOS module | `modules/city.nix` (new) | `services.wrapix.cities` |
| Agent wrapper | `lib/city/agent.sh` (new) | `wrapix-agent` CLI abstraction |
| Flake | `flake.nix` | Add gc dependency, expose mkCity |
| Sandbox | `lib/sandbox/default.nix` | No changes (mkCity uses mkSandbox) |
| Ralph | `lib/ralph/cmd/sync.sh` | Extend `ralph sync` to detect mkCity and scaffold |
| Docs convention | `docs/` | Established by scaffolding on first run |

## Success Criteria

- [ ] `mkCity` evaluates with minimal config (`services.api.package = myApp`)
  [verify](tests/gas-city-test.sh::test_mkcity_minimal_eval)
- [ ] Generated `city.toml` is valid and references the wrapix provider script
  [verify](tests/gas-city-test.sh::test_city_toml_valid)
- [ ] Provider script handles all 19 gc provider methods
  [verify](tests/gas-city-test.sh::test_provider_methods)
- [ ] Ephemeral workers use git worktrees at `.wrapix/worktree/gc-<bead-id>`
  [verify](tests/gas-city-test.sh::test_worker_worktree)
- [ ] Persistent roles (scout, reviewer) start with tmux as PID 1
  [verify](tests/gas-city-test.sh::test_persistent_role_tmux)
- [ ] Container exit events trigger gc-control reconciliation (no polling)
  [verify](tests/gas-city-test.sh::test_exit_event_trigger)
- [ ] Secrets are injected at runtime, never baked into images
  [verify](tests/gas-city-test.sh::test_secrets_runtime_only)
- [ ] `ralph run` still works standalone without gc
  [verify](tests/gas-city-test.sh::test_ralph_standalone)
- [ ] NixOS module generates systemd units and podman network
  [verify](tests/gas-city-test.sh::test_nixos_module)
- [ ] Crash recovery: gc-control restarts, reconciles orphaned containers
  [verify](tests/gas-city-test.sh::test_crash_recovery)
- [ ] `ralph sync` scaffolds missing docs files and creates review beads
  [verify](tests/gas-city-test.sh::test_docs_scaffolding)
- [ ] Service packages are built into OCI images via `dockerTools.buildLayeredImage`
  [verify](tests/gas-city-test.sh::test_service_image_build)
- [ ] Cooldown pacing delays task dispatch by configured duration
  [verify](tests/gas-city-test.sh::test_cooldown_pacing)
- [ ] Reviewer enforces `docs/style-guidelines.md` rules
  [judge](tests/judges/gas-city.sh::test_reviewer_enforcement)
- [ ] Provider script is clean, minimal shell with no Go dependencies
  [judge](tests/judges/gas-city.sh::test_provider_simplicity)
- [ ] Agent abstraction allows future provider swaps without architectural changes
  [judge](tests/judges/gas-city.sh::test_agent_abstraction)

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

## Implementation Notes

> This section is automatically stripped when the spec is finalized.

### Docs Restructuring

This spec introduces a `docs/` convention that conflicts with the current repo
layout. As part of implementation:

- Move `specs/architecture.md` to `docs/architecture.md` — it describes the
  system as-is (descriptive), not a feature to build (prescriptive)
- Move the Terminology Index from `specs/README.md` to `docs/README.md`
- Slim `specs/README.md` to just the spec table (links to spec files, code, beads)
- This applies to wrapix itself and becomes the convention for consumers

### Flake Integration

Gas City must be added as a flake input (pinned in `flake.lock`). Both `bd` and
`gc` should be exposed through `legacyPackages.lib` and `packages` so consumers
reuse the exact versions pinned by wrapix rather than managing their own:

```nix
# flake.nix inputs
gascity = {
  url = "github:gastownhall/gascity";
  # follows if applicable
};
```

Expose in outputs:
- `packages.${system}.gc` — the Gas City binary
- `packages.${system}.beads` — already exposed
- `legacyPackages.lib.mkCity` — the new API function

Consumers then do:
```nix
inputs.wrapix.packages.${system}.gc   # pinned gc binary
inputs.wrapix.packages.${system}.beads  # pinned bd binary
inputs.wrapix.legacyPackages.${system}.lib.mkCity { ... }
```

This follows the existing pattern where `beads` is already built from the pinned
input and exposed as `packages.beads`.

### Provider Research

The Gas City provider interface has 19 methods. Key findings from research:

- Many methods are best-effort — returning nil/empty is valid for conformance
- The `exec:<script>` provider pattern is designed for external delegation
- The subprocess provider is the simplest reference implementation
- `AcceptStartupDialogs` helper in `runtime/dialog.go` is reusable
- Gas City's conformance test suite (`runtimetest.RunProviderTests`) can
  validate the provider

### Worktree Concerns

Git worktrees have known edge cases with submodules, nested repos, and lock
files. The implementation should:

- Test worktree creation/cleanup in CI
- Handle `git worktree prune` during crash recovery
- Document any submodule limitations

### Overlay Filesystem Issues

Overlayfs was considered as an alternative to worktrees for worker isolation
but was not selected due to prior unspecified issues. If worktrees prove
problematic, revisit overlayfs or podman volume copies.

### Existing tmux Infrastructure

The tmux MCP server (`lib/mcp/tmux/`) already has pane management, send-keys,
and capture-pane implemented in Rust. The provider script delegates to tmux
directly via `podman exec` rather than going through the MCP server, but the
MCP server's test patterns may be useful reference.

### Rate Limit Backpressure

The reactive backpressure implementation needs to detect rate limit errors
from the agent CLI output. Claude Code returns specific error messages when
rate limited. The scout or gc-control needs to parse these from `podman logs`
or the agent's exit code. Exact detection patterns should be determined
during implementation.
