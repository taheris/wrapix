#!/usr/bin/env bash
# Shared helper functions for ralph scripts
# Source this file: source "$(dirname "$0")/lib.sh"

# Debug mode: set RALPH_DEBUG=1 to see verbose output
RALPH_DEBUG="${RALPH_DEBUG:-0}"

# Colors for output (disabled if not a tty)
if [ -t 2 ]; then
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m' # No Color
else
  RED=''
  YELLOW=''
  CYAN=''
  NC=''
fi

# Debug log - only prints when RALPH_DEBUG=1
debug() {
  if [ "$RALPH_DEBUG" = "1" ]; then
    echo -e "${CYAN}[DEBUG]${NC} $*" >&2
  fi
}

# Warning - prints but doesn't exit
warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

# Error - prints and exits
error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

# Validate JSON string is valid
# Usage: validate_json "$json_string" "description"
validate_json() {
  local json="$1"
  local desc="${2:-JSON}"

  if [ -z "$json" ]; then
    warn "$desc is empty"
    return 1
  fi

  if ! echo "$json" | jq empty 2>/dev/null; then
    warn "$desc is not valid JSON: ${json:0:100}..."
    return 1
  fi

  debug "$desc is valid JSON"
  return 0
}

# Validate JSON is an array with at least one element
# Usage: validate_json_array "$json_string" "description"
validate_json_array() {
  local json="$1"
  local desc="${2:-JSON}"

  if ! validate_json "$json" "$desc"; then
    return 1
  fi

  local array_length
  array_length=$(echo "$json" | jq 'if type == "array" then length else -1 end')

  if [ "$array_length" = "-1" ]; then
    warn "$desc is not an array"
    return 1
  fi

  if [ "$array_length" = "0" ]; then
    debug "$desc is an empty array"
    return 1
  fi

  debug "$desc is an array with $array_length element(s)"
  return 0
}

# Extract field from JSON array's first element with validation
# Usage: json_array_field "$json" "field_name" "description"
# Returns: field value or empty string, warns if missing
json_array_field() {
  local json="$1"
  local field="$2"
  local desc="${3:-field}"

  # Extract clean JSON first (handles bd warnings in output)
  json=$(extract_json "$json")

  if ! validate_json_array "$json" "JSON for $desc"; then
    echo ""
    return 1
  fi

  local value
  value=$(echo "$json" | jq -r ".[0].$field // empty")

  if [ -z "$value" ]; then
    debug "$desc.$field is empty or missing"
    echo ""
    return 0
  fi

  debug "$desc.$field = ${value:0:50}..."
  echo "$value"
}

# Run a bd command with error capture
# Usage: bd_run "command description" bd list --label foo
# Returns: command output, warns on failure
bd_run() {
  local desc="$1"
  shift

  debug "Running: bd $*"

  local output
  local exit_code

  output=$("$@" 2>&1) && exit_code=0 || exit_code=$?

  if [ $exit_code -ne 0 ]; then
    warn "$desc failed (exit $exit_code): ${output:0:200}"
    echo ""
    return $exit_code
  fi

  debug "$desc succeeded"
  echo "$output"
}

# Check required variable is set
# Usage: require_var "VAR_NAME" "$VAR_VALUE" "description"
require_var() {
  local name="$1"
  local value="$2"
  local desc="${3:-$name}"

  if [ -z "$value" ]; then
    error "$desc ($name) is required but empty"
  fi

  debug "$name is set: ${value:0:50}..."
}

# Check required file exists
# Usage: require_file "$path" "description"
require_file() {
  local path="$1"
  local desc="${2:-file}"

  if [ ! -f "$path" ]; then
    error "$desc not found: $path"
  fi

  debug "$desc exists: $path"
}

# Parse bd list JSON output and extract issue IDs
# Usage: bd_list_ids "$json_output"
# Returns: space-separated list of IDs
bd_list_ids() {
  local json="$1"

  if ! validate_json_array "$json" "bd list output"; then
    echo ""
    return 1
  fi

  echo "$json" | jq -r '.[].id'
}

# Get first issue ID from bd list JSON output
# Usage: bd_list_first_id "$json_output"
bd_list_first_id() {
  local json="$1"

  # Extract clean JSON from potentially mixed output
  json=$(extract_json "$json")

  if ! validate_json_array "$json" "bd list output"; then
    echo ""
    return 1
  fi

  echo "$json" | jq -r '.[0].id // empty'
}

# Extract JSON array or object from mixed output
# bd commands sometimes emit warnings before JSON; this extracts just the JSON
# Usage: extract_json "$mixed_output"
extract_json() {
  local input="$1"

  # Try to find JSON array starting with [
  local array_json
  array_json=$(echo "$input" | sed -n '/^\[/,/^\]/p')
  if [ -n "$array_json" ] && echo "$array_json" | jq empty 2>/dev/null; then
    echo "$array_json"
    return 0
  fi

  # Try to find JSON object starting with {
  local object_json
  object_json=$(echo "$input" | sed -n '/^{/,/^}/p')
  if [ -n "$object_json" ] && echo "$object_json" | jq empty 2>/dev/null; then
    echo "$object_json"
    return 0
  fi

  # If the whole thing is valid JSON, return it
  if echo "$input" | jq empty 2>/dev/null; then
    echo "$input"
    return 0
  fi

  # Last resort: grep for lines that look like JSON and try to parse
  local maybe_json
  maybe_json=$(echo "$input" | grep -E '^\s*[\[\{]' | head -1)
  if [ -n "$maybe_json" ]; then
    # Try to extract from that point to end
    local from_json
    from_json=$(echo "$input" | sed -n "/^${maybe_json:0:1}/,\$p")
    if echo "$from_json" | jq empty 2>/dev/null; then
      echo "$from_json"
      return 0
    fi
  fi

  warn "Could not extract JSON from output: ${input:0:100}..."
  echo "$input"
  return 1
}

# Strip "## Implementation Notes" section from markdown content
# This section provides transient context during ralph ready but shouldn't persist in permanent docs
# Usage: strip_implementation_notes "$markdown_content"
# Returns: markdown with Implementation Notes section removed
strip_implementation_notes() {
  local content="$1"

  # Use awk to remove the ## Implementation Notes section
  # Removes from "## Implementation Notes" to the next ## heading or end of file
  echo "$content" | awk '
    /^## Implementation Notes/ { skip = 1; next }
    /^## / && skip { skip = 0 }
    !skip { print }
  '
}
