# Project Specifications

An ordered list of specs and project terminology.

| Spec | Code | Beads | Purpose |
|------|------|-------|---------|
| [beads.md](./beads.md) | [`.beads/`](../.beads/) | — | Issue tracking with dependency support |
| [image-builder.md](./image-builder.md) | [`lib/sandbox/image.nix`](../lib/sandbox/image.nix) | — | Nix-based OCI image creation |
| [linux-builder.md](./linux-builder.md) | [`lib/builder/default.nix`](../lib/builder/default.nix) | wx-ope | Remote Nix builds for macOS |
| [notifications.md](./notifications.md) | [`lib/notify/`](../lib/notify/) | wx-q6x | Desktop notifications with focus suppression |
| [pre-commit.md](./pre-commit.md) | [`.pre-commit-config.yaml`](../.pre-commit-config.yaml), [`lib/ralph/cmd/run.sh`](../lib/ralph/cmd/run.sh) | wx-t6rh | Git hooks and ralph run integration |
| [profiles.md](./profiles.md) | [`lib/sandbox/profiles.nix`](../lib/sandbox/profiles.nix) | wx-zna0 | Pre-configured development environments |
| [ralph-tests.md](./ralph-tests.md) | [`tests/ralph/`](../tests/ralph/) | wx-hfp | Integration tests for ralph workflow |
| [ralph-workflow.md](./ralph-workflow.md) | [`lib/ralph/`](../lib/ralph/) | wx-zay1 | Spec-driven AI orchestration |
| [sandbox.md](./sandbox.md) | [`lib/sandbox/default.nix`](../lib/sandbox/default.nix) | — | Platform-agnostic container isolation |
| [security-review.md](./security-review.md) | — | wx-eok | Security tradeoffs and mitigations |
| [live-specs.md](./live-specs.md) | [`lib/ralph/cmd/spec.sh`](../lib/ralph/cmd/spec.sh) | wx-a13n | Queryable, verifiable, observable specifications |
| [tmux-mcp.md](./tmux-mcp.md) | [`lib/mcp/tmux/`](../lib/mcp/tmux/) | wx-4f3g | AI-assisted debugging via tmux panes |
| [playwright-mcp.md](./playwright-mcp.md) | [`lib/mcp/playwright/`](../lib/mcp/playwright/) | wx-9mvh | Browser automation for frontend development |
| ~~[orchestration.md](./orchestration.md)~~ | — | ~~wx-fqkv~~ | *Superseded by gas-city.md and ralph-workflow.md* |
| [gas-city.md](./gas-city.md) | [`lib/city/`](../lib/city/) | wx-ijfv | Multi-agent orchestration via Gas City integration |
