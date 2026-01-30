# tmux-debug-mcp module entry point
#
# MCP server providing tmux pane management for AI-assisted debugging
# within wrapix sandboxes.
#
# Exports:
#   - package: The tmux-debug-mcp binary
#   - profiles: Debug profiles for wrapix
#     - debug: Basic debug profile with tmux MCP
#     - mkAuditedDebug: Create debug profile with audit logging
{ pkgs }:

let
  package = import ./mcp-server.nix { inherit pkgs; };
  profiles = import ./profile.nix { inherit pkgs; };

in
{
  inherit package;
  inherit (profiles) debug mkAuditedDebug;

  # Expose all profiles for composition
  profiles = {
    inherit (profiles) debug mkAuditedDebug;
  };
}
