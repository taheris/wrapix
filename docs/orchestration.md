# Orchestration

## Deploy Commands

Describe how to deploy changes (e.g., `nix build`, `podman restart`).

## Scout Rules

Error patterns the scout watches for in service container logs.

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

<!-- Define criteria for changes that can be deployed without director approval -->
<!-- Remove this section or leave empty to require director approval for all deploys -->
