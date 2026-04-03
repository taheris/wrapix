#!/usr/bin/env bash
# Scout error detection and queue management helper.
#
# Called by the scout formula during patrol iterations.
# Scans podman logs for error patterns, deduplicates against existing beads,
# and enforces the maxBeads queue cap.
#
# Usage: scout.sh <command> [args]
# Commands: parse-rules, scan, create-beads, check-cap, housekeeping,
#           housekeeping-stale, housekeeping-orphans, housekeeping-worktrees
# Environment variables:
#   GC_CITY_NAME     — city name (for container filtering)
#   SCOUT_MAX_BEADS  — bead cap (default: 10)
#   SCOUT_ERRORS_DIR — directory to accumulate scan results (default: /tmp/scout-errors)
set -euo pipefail

SCOUT_MAX_BEADS="${SCOUT_MAX_BEADS:-10}"
SCOUT_ERRORS_DIR="${SCOUT_ERRORS_DIR:-/tmp/scout-errors}"

# Default patterns (used when docs/orchestration.md has no Scout Rules section)
DEFAULT_IMMEDIATE='FATAL|PANIC|panic:'
DEFAULT_BATCHED='ERROR|Exception'
DEFAULT_IGNORE=''

# ---------------------------------------------------------------------------
# Pattern parsing
# ---------------------------------------------------------------------------

# Parse Scout Rules from docs/orchestration.md.
# Outputs three files in SCOUT_ERRORS_DIR: immediate.pat, batched.pat, ignore.pat
# Each file contains one regex pattern (pipe-separated alternatives).
parse_rules() {
  local doc="${1:-}"
  mkdir -p "$SCOUT_ERRORS_DIR"

  if [[ -z "$doc" ]] || [[ ! -f "$doc" ]]; then
    echo "$DEFAULT_IMMEDIATE" > "$SCOUT_ERRORS_DIR/immediate.pat"
    echo "$DEFAULT_BATCHED" > "$SCOUT_ERRORS_DIR/batched.pat"
    echo "$DEFAULT_IGNORE" > "$SCOUT_ERRORS_DIR/ignore.pat"
    return 0
  fi

  local section="" in_code=false
  local immediate="" batched="" ignore=""

  while IFS= read -r line; do
    # Detect section headers under ## Scout Rules
    if [[ "$line" =~ ^###[[:space:]]+Immediate ]]; then
      section="immediate"
      in_code=false
      continue
    elif [[ "$line" =~ ^###[[:space:]]+Batched ]]; then
      section="batched"
      in_code=false
      continue
    elif [[ "$line" =~ ^###[[:space:]]+Ignore ]]; then
      section="ignore"
      in_code=false
      continue
    elif [[ "$line" =~ ^##[[:space:]] ]] && [[ ! "$line" =~ ^###  ]]; then
      # New top-level section — stop parsing Scout Rules
      if [[ "$section" != "" ]]; then
        break
      fi
      if [[ "$line" =~ ^##[[:space:]]+Scout[[:space:]]+Rules ]]; then
        section="start"
        continue
      fi
      continue
    fi

    # Track code fence state
    if [[ "$line" =~ ^\`\`\` ]]; then
      if $in_code; then
        in_code=false
      else
        in_code=true
      fi
      continue
    fi

    # Collect pattern lines inside code fences
    if $in_code && [[ -n "$section" ]] && [[ "$section" != "start" ]]; then
      # Skip comment lines
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      # Skip empty lines
      [[ -z "${line// /}" ]] && continue

      case "$section" in
        immediate) immediate="$line" ;;
        batched)   batched="$line" ;;
        ignore)    ignore="$line" ;;
      esac
    fi
  done < "$doc"

  # Write patterns (fall back to defaults if empty)
  echo "${immediate:-$DEFAULT_IMMEDIATE}" > "$SCOUT_ERRORS_DIR/immediate.pat"
  echo "${batched:-$DEFAULT_BATCHED}" > "$SCOUT_ERRORS_DIR/batched.pat"
  echo "${ignore:-$DEFAULT_IGNORE}" > "$SCOUT_ERRORS_DIR/ignore.pat"
}

# ---------------------------------------------------------------------------
# Log scanning
# ---------------------------------------------------------------------------

# Scan a single container's logs for error patterns.
# Writes results to SCOUT_ERRORS_DIR/<container>/{immediate,batched}.log
scan() {
  local container="${1:?scan requires container name}"
  local since="${2:-5m}"
  # Strip --since= prefix if present
  since="${since#--since=}"

  mkdir -p "$SCOUT_ERRORS_DIR/$container"

  # Load patterns
  local pat_immediate pat_batched pat_ignore
  pat_immediate="$(cat "$SCOUT_ERRORS_DIR/immediate.pat" 2>/dev/null || echo "$DEFAULT_IMMEDIATE")"
  pat_batched="$(cat "$SCOUT_ERRORS_DIR/batched.pat" 2>/dev/null || echo "$DEFAULT_BATCHED")"
  pat_ignore="$(cat "$SCOUT_ERRORS_DIR/ignore.pat" 2>/dev/null || echo "$DEFAULT_IGNORE")"

  # Pull logs
  local logs
  logs="$(podman logs --since "$since" --tail 1000 "$container" 2>&1)" || logs=""

  local immediate_file="$SCOUT_ERRORS_DIR/$container/immediate.log"
  local batched_file="$SCOUT_ERRORS_DIR/$container/batched.log"
  : > "$immediate_file"
  : > "$batched_file"

  if [[ -z "$logs" ]]; then
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Check ignore patterns first
    if [[ -n "$pat_ignore" ]] && echo "$line" | grep -qE "$pat_ignore" 2>/dev/null; then
      continue
    fi

    # Check immediate patterns
    if echo "$line" | grep -qE "$pat_immediate"; then
      echo "$line" >> "$immediate_file"
      continue
    fi

    # Check batched patterns
    if echo "$line" | grep -qE "$pat_batched"; then
      echo "$line" >> "$batched_file"
      continue
    fi
  done <<< "$logs"
}

# ---------------------------------------------------------------------------
# Bead deduplication and creation
# ---------------------------------------------------------------------------

# Check if a bead already exists for a given error pattern.
# Returns: bead ID if found, empty string if not.
find_existing_bead() {
  local pattern="$1"
  local container="$2"

  # Search open/in-progress beads for matching title
  local beads
  beads="$(bd list --status=open --status=in_progress --json --limit=0 2>/dev/null)" || beads="[]"

  # Match on pattern and container in title
  local bead_id
  bead_id="$(echo "$beads" | jq -r \
    --arg pat "$pattern" \
    --arg ctr "$container" \
    '[.[] | select(.title | (contains($pat) and contains($ctr)))] | first // empty | .id' \
    2>/dev/null)" || bead_id=""

  echo "$bead_id"
}

# Get current count of open/in-progress beads.
open_bead_count() {
  local count
  count="$(bd list --status=open --status=in_progress --json --limit=0 2>/dev/null | jq 'length' 2>/dev/null)" || count="0"
  echo "$count"
}

# Check if bead cap is reached. Prints "true" or "false".
check_cap() {
  local count
  count="$(open_bead_count)"
  if [[ "$count" -ge "$SCOUT_MAX_BEADS" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Notify director that bead cap is reached.
notify_cap_reached() {
  wrapix-notify "Gas City" "Scout paused: ${SCOUT_MAX_BEADS} open beads reached" 2>/dev/null || true
}

# Extract the dominant error pattern from a log line for grouping.
# Returns the first matching token from the pattern regex.
extract_pattern_key() {
  local line="$1"
  local pat="$2"

  # Split the pipe-separated pattern and find which alternative matched
  local IFS='|'
  local alternatives
  read -ra alternatives <<< "$pat"
  for alt in "${alternatives[@]}"; do
    if echo "$line" | grep -qE "$alt" 2>/dev/null; then
      echo "$alt"
      return
    fi
  done
  echo "unknown"
}

# Create beads for all accumulated scan results.
# Handles deduplication, grouping, and cap enforcement.
create_beads() {
  local created=0

  # Process each container's results
  for container_dir in "$SCOUT_ERRORS_DIR"/*/; do
    [[ -d "$container_dir" ]] || continue
    local container
    container="$(basename "$container_dir")"

    local pat_immediate pat_batched
    pat_immediate="$(cat "$SCOUT_ERRORS_DIR/immediate.pat" 2>/dev/null || echo "$DEFAULT_IMMEDIATE")"
    pat_batched="$(cat "$SCOUT_ERRORS_DIR/batched.pat" 2>/dev/null || echo "$DEFAULT_BATCHED")"

    # --- Immediate errors (P0) ---
    if [[ -s "$container_dir/immediate.log" ]]; then
      # Group by pattern key
      declare -A immediate_groups
      while IFS= read -r line; do
        local key
        key="$(extract_pattern_key "$line" "$pat_immediate")"
        if [[ -z "${immediate_groups[$key]+x}" ]]; then
          immediate_groups[$key]="$line"
        else
          immediate_groups[$key]+=$'\n'"$line"
        fi
      done < "$container_dir/immediate.log"

      for key in "${!immediate_groups[@]}"; do
        # Check cap before each creation
        if [[ "$(check_cap)" == "true" ]]; then
          notify_cap_reached
          return "$created"
        fi

        local existing
        existing="$(find_existing_bead "$key" "$container")"
        if [[ -n "$existing" ]]; then
          # Append to existing bead
          bd update "$existing" --notes "$(date -u +%FT%TZ): additional occurrence in $container" 2>/dev/null || true
        else
          local details="${immediate_groups[$key]}"
          local line_count
          line_count="$(echo "$details" | wc -l)"
          bd create \
            --title="FATAL: $key in $container" \
            --description="Immediate error pattern detected in $container logs.

Pattern: $key
Occurrences: $line_count

Sample:
$(echo "$details" | head -5)" \
            --type=bug --priority=0 2>/dev/null || true
          created=$((created + 1))
        fi
      done
      unset immediate_groups
    fi

    # --- Batched errors (P2) ---
    if [[ -s "$container_dir/batched.log" ]]; then
      declare -A batched_groups
      while IFS= read -r line; do
        local key
        key="$(extract_pattern_key "$line" "$pat_batched")"
        if [[ -z "${batched_groups[$key]+x}" ]]; then
          batched_groups[$key]="$line"
        else
          batched_groups[$key]+=$'\n'"$line"
        fi
      done < "$container_dir/batched.log"

      for key in "${!batched_groups[@]}"; do
        # Check cap before each creation
        if [[ "$(check_cap)" == "true" ]]; then
          notify_cap_reached
          return "$created"
        fi

        local existing
        existing="$(find_existing_bead "$key" "$container")"
        if [[ -n "$existing" ]]; then
          bd update "$existing" --notes "$(date -u +%FT%TZ): additional occurrence in $container" 2>/dev/null || true
        else
          local details="${batched_groups[$key]}"
          local line_count
          line_count="$(echo "$details" | wc -l)"
          bd create \
            --title="Error: $key in $container" \
            --description="Batched error pattern detected in $container logs.

Pattern: $key
Occurrences: $line_count

Sample:
$(echo "$details" | head -5)" \
            --type=bug --priority=2 2>/dev/null || true
          created=$((created + 1))
        fi
      done
      unset batched_groups
    fi
  done

  echo "$created"
}

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

GC_CITY_NAME="${GC_CITY_NAME:-}"
GC_WORKSPACE="${GC_WORKSPACE:-.}"

# Run all housekeeping tasks: stale beads, orphaned workers, worktree cleanup.
housekeeping() {
  housekeeping_stale_beads
  housekeeping_orphaned_workers
  housekeeping_worktree_cleanup
}

# Flag stale beads for human review.
housekeeping_stale_beads() {
  local stale
  stale="$(bd stale --json 2>/dev/null)" || stale="[]"

  local ids
  ids="$(echo "$stale" | jq -r '.[].id' 2>/dev/null)" || ids=""

  for id in $ids; do
    [[ -z "$id" ]] && continue
    bd label add "$id" human 2>/dev/null || true
    bd update "$id" --notes "$(date -u +%FT%TZ): flagged stale by scout housekeeping" 2>/dev/null || true
  done
}

# Detect and stop orphaned worker containers (no matching in-progress bead).
housekeeping_orphaned_workers() {
  [[ -z "$GC_CITY_NAME" ]] && return 0

  local workers
  workers="$(podman ps --filter "label=gc-city=$GC_CITY_NAME" \
    --filter "label=gc-role=worker" \
    --format '{{.Names}}' 2>/dev/null)" || workers=""

  [[ -z "$workers" ]] && return 0

  local in_progress
  in_progress="$(bd list --status=in_progress --json --limit=0 2>/dev/null | jq -r '.[].id' 2>/dev/null)" || in_progress=""

  while IFS= read -r container; do
    [[ -z "$container" ]] && continue

    # Extract bead ID from container labels
    local bead_id
    bead_id="$(podman inspect --format '{{index .Config.Labels "gc-bead"}}' "$container" 2>/dev/null)" || bead_id=""

    [[ -z "$bead_id" ]] && continue

    # Check if bead is in the in-progress list
    if ! echo "$in_progress" | grep -qF "$bead_id"; then
      podman stop "$container" 2>/dev/null || true
      podman rm "$container" 2>/dev/null || true
      wrapix-notify "Gas City" "Scout housekeeping: stopped orphaned worker $container (bead $bead_id not in_progress)" 2>/dev/null || true
    fi
  done <<< "$workers"
}

# Remove stale worktrees with no matching running worker or active bead.
housekeeping_worktree_cleanup() {
  local worktree_dir="$GC_WORKSPACE/.wrapix/worktree"
  [[ -d "$worktree_dir" ]] || return 0

  for wt in "$worktree_dir"/gc-*; do
    [[ -d "$wt" ]] || continue

    local bead_id="${wt##*gc-}"

    # Check if a worker container exists for this bead
    if podman ps --filter "label=gc-bead=$bead_id" --format '{{.Names}}' 2>/dev/null | grep -q .; then
      continue
    fi

    # Check the bead is not in_progress (avoid cleaning active worktrees)
    local status
    status="$(bd show "$bead_id" --json 2>/dev/null | jq -r 'if type == "array" then .[0].status else .status end // "unknown"' 2>/dev/null)" || status="unknown"

    if [[ "$status" != "in_progress" ]]; then
      rm -rf "$wt"
      git -C "$GC_WORKSPACE" worktree prune 2>/dev/null || true
    fi
  done
}

# Clean up scan results from a previous cycle.
clean() {
  rm -rf "$SCOUT_ERRORS_DIR"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

cmd="${1:-}"
shift || true

case "$cmd" in
  parse-rules)
    parse_rules "$@"
    ;;
  scan)
    scan "$@"
    ;;
  create-beads)
    create_beads
    ;;
  check-cap)
    check_cap
    ;;
  notify-cap)
    notify_cap_reached
    ;;
  housekeeping)
    housekeeping
    ;;
  housekeeping-stale)
    housekeeping_stale_beads
    ;;
  housekeeping-orphans)
    housekeeping_orphaned_workers
    ;;
  housekeeping-worktrees)
    housekeeping_worktree_cleanup
    ;;
  clean)
    clean
    ;;
  open-count)
    open_bead_count
    ;;
  *)
    echo "Usage: scout.sh {parse-rules|scan|create-beads|check-cap|notify-cap|housekeeping|clean|open-count}" >&2
    exit 1
    ;;
esac
