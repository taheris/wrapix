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

# Build jq filter for stream-json output based on config
# Usage: build_stream_filter "$config_json"
# Returns: jq filter string for processing claude stream-json output
build_stream_filter() {
  local config="$1"

  # Extract output config with defaults
  local responses tool_names tool_inputs tool_results thinking stats
  local max_tool_input max_tool_result

  # Note: jq's // operator treats false as null, so we use explicit null checks
  # to properly handle explicit false values vs missing keys
  responses=$(echo "$config" | jq -r 'if .output.responses == null then true else .output.responses end')
  tool_names=$(echo "$config" | jq -r 'if .output."tool-names" == null then true else .output."tool-names" end')
  tool_inputs=$(echo "$config" | jq -r 'if .output."tool-inputs" == null then true else .output."tool-inputs" end')
  tool_results=$(echo "$config" | jq -r 'if .output."tool-results" == null then true else .output."tool-results" end')
  thinking=$(echo "$config" | jq -r 'if .output.thinking == null then true else .output.thinking end')
  stats=$(echo "$config" | jq -r 'if .output.stats == null then true else .output.stats end')
  max_tool_input=$(echo "$config" | jq -r '.output."max-tool-input" // 200')
  max_tool_result=$(echo "$config" | jq -r '.output."max-tool-result" // 500')

  # Extract prefix config with defaults
  local prefix_response prefix_tool_result prefix_tool_error
  local prefix_thinking_start prefix_thinking_end prefix_stats_header prefix_stats_line
  prefix_response=$(echo "$config" | jq -r '.output.prefixes.response // "[response] "')
  prefix_tool_result=$(echo "$config" | jq -r '.output.prefixes."tool-result" // "[result] "')
  prefix_tool_error=$(echo "$config" | jq -r '.output.prefixes."tool-error" // "[ERROR] "')
  prefix_thinking_start=$(echo "$config" | jq -r '.output.prefixes."thinking-start" // "<thinking>\n"')
  prefix_thinking_end=$(echo "$config" | jq -r '.output.prefixes."thinking-end" // "\n</thinking>"')
  prefix_stats_header=$(echo "$config" | jq -r '.output.prefixes."stats-header" // "\n--- Stats ---\n"')
  prefix_stats_line=$(echo "$config" | jq -r '.output.prefixes."stats-line" // ""')

  debug "Output config: responses=$responses tool_names=$tool_names tool_inputs=$tool_inputs tool_results=$tool_results thinking=$thinking stats=$stats"
  debug "Prefixes: response='$prefix_response' tool_result='$prefix_tool_result' tool_error='$prefix_tool_error'"

  # Build the jq filter dynamically
  # We use a different approach: check message type first, then process content types
  local filter='
# Helper function for truncation
def truncate(n): if n == 0 then . elif (. | length) > n then .[0:n] + "..." else . end;

# Process assistant messages - extract text and thinking from content array
if .type == "assistant" and .message.content then
  .message.content[] |
'

  # Build content type checks within assistant message processing
  local content_checks=""

  if [ "$responses" = "true" ]; then
    content_checks+="
  if .type == \"text\" then \"$prefix_response\" + (.text // empty)"
  fi

  if [ "$thinking" = "true" ]; then
    if [ -n "$content_checks" ]; then
      content_checks+="
  elif .type == \"thinking\" then \"$prefix_thinking_start\" + .thinking + \"$prefix_thinking_end\""
    else
      content_checks+="
  if .type == \"thinking\" then \"$prefix_thinking_start\" + .thinking + \"$prefix_thinking_end\""
    fi
  fi

  # Add tool use inside assistant message content (names and/or inputs)
  if [ "$tool_names" = "true" ] || [ "$tool_inputs" = "true" ]; then
    if [ -n "$content_checks" ]; then
      if [ "$tool_inputs" = "true" ]; then
        content_checks+="
  elif .type == \"tool_use\" then \"[\" + .name + \"] \" + ((.input // {}) | tostring | truncate($max_tool_input))"
      else
        content_checks+='
  elif .type == "tool_use" then "[" + .name + "]"'
      fi
    else
      if [ "$tool_inputs" = "true" ]; then
        content_checks+="
  if .type == \"tool_use\" then \"[\" + .name + \"] \" + ((.input // {}) | tostring | truncate($max_tool_input))"
      else
        content_checks+='
  if .type == "tool_use" then "[" + .name + "]"'
      fi
    fi
  fi

  # Close content type checks or provide default
  if [ -n "$content_checks" ]; then
    filter+="$content_checks"'
  else empty end'
  else
    filter+='empty'
  fi

  # Add tool results
  if [ "$tool_results" = "true" ]; then
    filter+="

# Show tool results
elif .type == \"user\" and .message.content then
  .message.content[] |
  if .type == \"tool_result\" then
    if .is_error == true then
      \"$prefix_tool_error\" + ((.content // \"unknown error\") | tostring | truncate($max_tool_result))
    else
      \"$prefix_tool_result\" + ((.content // \"\") | tostring | truncate($max_tool_result))
    end
  else
    empty
  end"
  fi

  # Add stats output
  if [ "$stats" = "true" ]; then
    filter+="

# Show final stats
elif .type == \"result\" then
  \"$prefix_stats_header\" +
  \"${prefix_stats_line}Cost: \$\" + ((.cost_usd // 0) | tostring) + \"\n\" +
  \"${prefix_stats_line}Input tokens: \" + ((.usage.input_tokens // 0) | tostring) + \"\n\" +
  \"${prefix_stats_line}Output tokens: \" + ((.usage.output_tokens // 0) | tostring) + \"\n\" +
  \"${prefix_stats_line}Duration: \" + ((.duration_ms // 0) / 1000 | tostring) + \"s\""
  fi

  # Close the if chain
  filter+='

else
  empty
end'

  echo "$filter"
}

# Run claude with stream-json output and configurable display
# Usage: run_claude_stream "$prompt_var_name" "$log_file" "$config_json"
# The prompt must be exported as an environment variable before calling
run_claude_stream() {
  local prompt_var="$1"
  local log_file="$2"
  local config="$3"

  local jq_filter
  jq_filter=$(build_stream_filter "$config")

  debug "Running claude with stream-json output to $log_file"

  # Run claude with stream-json, tee to log, and filter with jq
  # The prompt variable is passed via environment
  claude --dangerously-skip-permissions --print --output-format stream-json --verbose "${!prompt_var}" 2>&1 \
    | tee "$log_file" \
    | jq --unbuffered -r "$jq_filter" 2>/dev/null || true
}

# Validate template has required placeholders, reset from source if corrupted
# Usage: validate_template "$local_path" "$source_path" "$template_name"
# Returns: 0 if valid or repaired, 1 if repair failed
validate_template() {
  local local_path="$1"
  local source_path="$2"
  local template_name="${3:-template}"

  if [ ! -f "$local_path" ]; then
    warn "$template_name not found at $local_path"
    return 1
  fi

  # Check for required placeholder - if {{LABEL}} is missing, template is corrupted
  if ! grep -q '{{LABEL}}' "$local_path" 2>/dev/null; then
    warn "$template_name is missing {{LABEL}} placeholder - resetting from source"

    if [ ! -f "$source_path" ]; then
      warn "Source template not found at $source_path - cannot repair"
      return 1
    fi

    # Backup corrupted file before overwriting
    cp "$local_path" "${local_path}.bak"
    debug "Backed up corrupted $template_name to ${local_path}.bak"

    cp "$source_path" "$local_path"
    debug "$template_name reset from $source_path"
  fi

  return 0
}

# Run claude interactively with an initial prompt
# Usage: run_claude_interactive "$prompt_var_name"
# Opens an interactive Claude console with the prompt as initial context
run_claude_interactive() {
  local prompt_var="$1"

  debug "Running claude interactively"

  # Run claude without --print to open interactive console
  # The prompt is passed as the initial message
  claude --dangerously-skip-permissions "${!prompt_var}"
}

# Resolve partial markers {{> partial-name}} in template content
# Usage: resolve_partials "$content" "$partial_dir"
# Returns: content with partials resolved
resolve_partials() {
  local content="$1"
  local partial_dir="$2"

  if [ -z "$partial_dir" ] || [ ! -d "$partial_dir" ]; then
    debug "Partial directory not available, returning content unchanged"
    echo "$content"
    return 0
  fi

  # Find all partial references {{> partial-name}}
  local refs
  refs=$(echo "$content" | grep -oE '\{\{> [a-z-]+\}\}' | sed 's/{{> //;s/}}//' | sort -u || true)

  if [ -z "$refs" ]; then
    debug "No partial references found"
    echo "$content"
    return 0
  fi

  # Resolve each partial
  local result="$content"
  for ref in $refs; do
    local partial_path="$partial_dir/${ref}.md"
    if [ -f "$partial_path" ]; then
      local partial_content
      partial_content=$(cat "$partial_path")
      # Use awk for safe substitution of multi-line content
      result=$(echo "$result" | awk -v marker="{{> $ref}}" -v replacement="$partial_content" '{
        idx = index($0, marker)
        if (idx > 0) {
          before = substr($0, 1, idx - 1)
          after = substr($0, idx + length(marker))
          print before replacement after
        } else {
          print
        }
      }')
      debug "Resolved partial: $ref"
    else
      warn "Partial not found: $partial_path"
    fi
  done

  echo "$result"
}
