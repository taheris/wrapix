# Debug profile for wrapix providing tmux pane management
#
# Provides MCP tools for AI-assisted debugging:
# - tmux_create_pane, tmux_send_keys, tmux_capture_pane, etc.
#
# Usage in profiles.nix:
#   debug = tmuxProfile.debug;
#   rust-debug = deriveProfile profiles.rust tmuxProfile.debug;
{ pkgs }:

let
  tmuxDebugMcp = import ./mcp-server.nix { inherit pkgs; };

in
{
  # Debug profile with tmux MCP server
  debug = {
    name = "debug";

    packages = [
      pkgs.tmux
      tmuxDebugMcp
    ];

    mcp = {
      servers.tmux-debug = {
        command = "tmux-debug-mcp";
      };
    };

    env = { };
    mounts = [ ];
  };

  # Helper to create audited debug profile
  # Usage: mkAuditedDebug "/workspace/.debug-audit.log"
  mkAuditedDebug = auditPath: {
    name = "debug-audited";

    packages = [
      pkgs.tmux
      tmuxDebugMcp
    ];

    mcp = {
      servers.tmux-debug = {
        command = "tmux-debug-mcp";
        env = {
          TMUX_DEBUG_AUDIT = auditPath;
        };
      };
    };

    env = { };
    mounts = [ ];
  };
}
