#!/usr/bin/env bash
set -euo pipefail

wrix_prepare_mcp_manifest() {
  local available_manifest="/etc/wrix/mcp-available.json"
  local selected_manifest="/tmp/wrix-mcp-manifest.json"
  local selection="${WRIX_MCP:-all}"
  local audit="${WRIX_MCP_TMUX_AUDIT:-}"
  local audit_full="${WRIX_MCP_TMUX_AUDIT_FULL:-}"

  if [[ ! -f "$available_manifest" ]]; then
    unset WRIX_MCP_MANIFEST
    return 0
  fi

  if ! jq \
    --arg selection "$selection" \
    --arg audit "$audit" \
    --arg auditFull "$audit_full" \
    '
      def selected_names:
        $selection
        | split(",")
        | map(gsub("^\\s+|\\s+$"; ""))
        | map(select(length > 0))
        | unique;
      def with_runtime_overrides:
        map(
          if .name == "tmux" then
            .env = (
              .env
              + (if $audit == "" then {} else { TMUX_DEBUG_AUDIT: $audit } end)
              + (if $auditFull == "" then {} else { TMUX_DEBUG_AUDIT_FULL: $auditFull } end)
            )
          else
            .
          end
        );
      .servers as $available
      | if .runtime_selection then
          (if $selection == "all" then [$available[].name] else selected_names end) as $selected
          | ([$available[].name]) as $availableNames
          | ($selected - $availableNames) as $unknown
          | if $unknown != [] then
              error("WRIX_MCP selects unknown servers: " + ($unknown | join(", ")))
            else
              {
                schema: 1,
                servers: ($available | map(select(.name as $name | $selected | index($name))) | with_runtime_overrides)
              }
            end
        else
          { schema: 1, servers: ($available | with_runtime_overrides) }
        end
    ' \
    "$available_manifest" >"$selected_manifest"; then
    printf 'Error: failed to select MCP servers from %s\n' "$available_manifest" >&2
    rm -f "$selected_manifest"
    return 1
  fi

  chmod 0600 "$selected_manifest"
  export WRIX_MCP_MANIFEST="$selected_manifest"
}
