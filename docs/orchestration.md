# Orchestration

Ops config for the wrapix dogfooding city. This repo runs its own Gas City
(`wrapix.mkCity { name = "wx"; ... }` in `flake.nix`) for bead-driven work
but defines no service containers - the Scout's log-watching role is inactive
until services are added; only housekeeping applies.

## Deploy Commands

"Deploy" for this repo means the Judge pushing merged commits to the GitHub
mirror from inside its container via `git push`. This is handled automatically
by the Judge after merge using `secrets.deployKey` - no manual step required.
There are no service containers to restart, migrate, or roll.

## Scout Rules

Error patterns the Scout watches for in service container logs. These patterns
are defined and spec-compliant but **currently inactive** because no services
are configured in `flake.nix`. They will take effect automatically when
services are added.

### Immediate (P0 bead)

```
FATAL|PANIC|panic:
```

### Batched (collected over one poll cycle)

```
ERROR|Exception
```

### Ignore

```
# Add patterns for known noise
```

## Auto-deploy

<!--
  Intentionally empty: all merges require human approval. The Judge gate and
  convergence pipeline are still being hardened (see unchecked success criteria
  in specs/gas-city.md). Revisit once the Worker -> Judge -> merge flow has
  run cleanly in production for a reasonable period.
-->
