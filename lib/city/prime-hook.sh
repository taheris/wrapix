#!/usr/bin/env bash
# wrapix-prime-hook — emit role prompt for Claude Code SessionStart/PreCompact.
# Reads from the city-config derivation staged at $WRAPIX_CITY_DIR.
set -euo pipefail
exec cat "${WRAPIX_CITY_DIR:?WRAPIX_CITY_DIR not set}/prompts/${GC_AGENT:?GC_AGENT not set}.md"
