# MCP Server Registry
#
# Maps server names to their definitions. Each server exports:
#   - name: Server identifier (string)
#   - package: Nix package for the MCP server binary
#   - mkServerConfig: Function to generate server config from user options
#
# Usage:
#   mcpRegistry = import ./mcp { inherit pkgs; };
#   serverDef = mcpRegistry.tmux-debug;
#   config = serverDef.mkServerConfig { audit = "/path/to/audit.log"; };
#
# This registry is used by mkSandbox to look up enabled MCP servers
# and merge their packages and configs.
#
# Spec: specs/tmux-mcp.md
{ pkgs }:

{
  # tmux-debug: MCP server for tmux pane management
  # Provides tools for AI-assisted debugging (create_pane, send_keys, capture_pane, etc.)
  tmux-debug = import ./tmux { inherit pkgs; };
}
