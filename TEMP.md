# Gas City Audit — COMPLETE

All fixes applied, all tests passing (22/22 shell, 12/12 Nix).

## Fixes Applied

1. **provider.sh** — worker_start() now creates task file from bead description/acceptance/reviewer notes, mounts it, sets WRAPIX_PROMPT_FILE
2. **modules/city.nix** — startScript now passes GC_AGENT_IMAGE and GC_PODMAN_NETWORK env vars
3. **AGENTS.md** (+ CLAUDE.md symlink) — Updated refs: `docs/architecture.md`, `docs/README.md`
4. **specs/README.md** — Removed "and project terminology" from header
5. **docs/style-guidelines.md** — Populated with enforceable rules (SH-, NX-, DOC-, GIT-, TST- prefixed)
6. **docs/architecture.md** — Updated with Gas City section, source layout, context hierarchy
7. **README.md** — Added Gas City section with quick start, NixOS module, and full options

## Tests Rewritten
- `tests/gas-city-test.sh` — 22 functional tests (was grep-based)
- `tests/gc.nix` — 12 Nix checks (Layer 2-3 rewritten to functional)
