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

let
  tmuxModule = import ./tmux { inherit pkgs; };

in
{
  # tmux-debug: MCP server for tmux pane management
  # Provides tools for AI-assisted debugging (create_pane, send_keys, capture_pane, etc.)
  tmux-debug = {
    name = "tmux-debug";

    # The MCP server package
    package = tmuxModule.package;

    # Generate server configuration from user options
    # Options:
    #   audit: Path to audit log file (optional)
    #   auditFull: Path to directory for full capture logs (optional)
    mkServerConfig =
      {
        audit ? null,
        auditFull ? null,
      }:
      {
        command = "tmux-debug-mcp";
        env =
          { }
          // (if audit != null then { TMUX_DEBUG_AUDIT = audit; } else { })
          // (if auditFull != null then { TMUX_DEBUG_AUDIT_FULL = auditFull; } else { });
      };
  };
}
