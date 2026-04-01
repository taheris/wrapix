# Style Guidelines

Rules the reviewer enforces mechanically. Every rejection must cite a rule by ID.
Rules not listed here cannot be used to reject — flag unlisted concerns for
the director via `bd human` instead.

## Shell (SH-)

- **SH-1** — Every script must start with `set -euo pipefail`
- **SH-2** — All variable expansions must be quoted: `"$var"`, not `$var`
  (exception: intentional word-splitting with a comment explaining why)
- **SH-3** — Use `[[ ]]` for conditionals, not `[ ]`
- **SH-4** — Use `$(command)` for substitution, not backticks
- **SH-5** — Functions use `local` for all variables except intentional exports

## Nix (NX-)

- **NX-1** — Use `inherit` to pull names from enclosing scope; do not repeat `x = x`
- **NX-2** — Files must pass `nix fmt` (nixfmt-rfc-style) with no diff
- **NX-3** — Keep derivations pure — no `builtins.fetchurl` without a hash,
  no `builtins.currentSystem`
- **NX-4** — Attrset arguments use `{ a, b, ... }:` destructuring, not `args: args.a`

## Documentation (DOC-)

- **DOC-1** — New specs go in `specs/` and must be added to `specs/README.md`
- **DOC-2** — Architecture references point to `docs/architecture.md`, not `specs/`
- **DOC-3** — Terminology references point to `docs/README.md`, not `specs/README.md`

## Git (GIT-)

- **GIT-1** — Commit messages are imperative mood, max 72 chars for the subject line
- **GIT-2** — No secrets, credentials, or API keys in committed files
- **GIT-3** — Hidden specs (`.wrapix/ralph/state/`) must never be copied into `specs/`

## Testing (TST-)

- **TST-1** — Tests must execute the code under test, not grep for strings in source
- **TST-2** — Mock external dependencies (podman, network), not internal logic
- **TST-3** — Each test function tests one behavior and has a descriptive name
