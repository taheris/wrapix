#!/usr/bin/env bash
# Stage a gc home directory that isolates gc from the host's .beads/.
#
# gc writes dolt.auto-start: false and dolt-server.port to .beads/,
# which corrupts the host's beads config.  It ignores BEADS_DIR.
#
# Fix: create .gc/home/ with its own .beads/ containing config copies
# and the city's dolt port (not the host's).  gc discovers .beads/ by
# walking up from cwd, so running gc from .gc/home/ (or setting
# GC_CITY=.gc/home) makes all gc writes go there instead.
#
# The .beads/ in gc home has:
#   - config.yaml    — copy from host, plus dolt.auto-start: false
#   - metadata.json  — copy from host
#   - issues.jsonl   — copy from host (if present)
#   - dolt-server.port — city dolt port (so gc connects to the container)
#   - NO dolt/ dir   — prevents gc's dolt pack from starting a duplicate
#
# Environment:
#   GC_WORKSPACE  — workspace root (required)
#   GC_DOLT_PORT  — city dolt port (default: 3306)
#
# Output: prints the gc home path; caller should export GC_CITY to it.
set -euo pipefail

: "${GC_WORKSPACE:?stage-gc-home.sh requires GC_WORKSPACE}"
DOLT_PORT="${GC_DOLT_PORT:-3306}"

GC_HOME="${GC_WORKSPACE}/.gc/home"
rm -rf "$GC_HOME"
mkdir -p "$GC_HOME/.beads" "$GC_HOME/.gc"

# Copy beads config files
for f in config.yaml metadata.json issues.jsonl; do
  [ -f "${GC_WORKSPACE}/.beads/$f" ] && cp "${GC_WORKSPACE}/.beads/$f" "$GC_HOME/.beads/"
done

# Disable dolt auto-start (gc should use the city's dolt container)
# and record the city dolt port so gc's internal bd calls connect there.
if ! grep -q '^dolt\.auto-start:' "$GC_HOME/.beads/config.yaml" 2>/dev/null; then
  echo "dolt.auto-start: false" >> "$GC_HOME/.beads/config.yaml"
fi
echo "$DOLT_PORT" > "$GC_HOME/.beads/dolt-server.port"

# City config and .gc subdirectories
cp -f "${GC_WORKSPACE}/city.toml" "$GC_HOME/" 2>/dev/null || true
for d in formulas scripts prompts; do
  [ -d "${GC_WORKSPACE}/.gc/$d" ] && ln -sfn "${GC_WORKSPACE}/.gc/$d" "$GC_HOME/.gc/$d"
done

# gc needs these writable dirs
mkdir -p "$GC_HOME/.gc/cache" "$GC_HOME/.gc/system" "$GC_HOME/.gc/runtime"
touch "$GC_HOME/.gc/events.jsonl"

# bd requires a git repo at the working directory root.  Without this,
# gc's bd subprocess calls fail with "cannot determine repository root".
if [[ ! -d "$GC_HOME/.git" ]]; then
  git init -q "$GC_HOME"
fi

echo "$GC_HOME"
