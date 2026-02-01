# tmux-debug-mcp module entry point
#
# MCP server providing tmux pane management for AI-assisted debugging
# within wrapix sandboxes.
#
# Exports:
#   - package: The tmux-debug-mcp binary
#   - profiles: Debug profiles for wrapix
#     - debug: Basic debug profile with tmux MCP
#     - debug-audited: Function to create audited debug profile
#     - rust-debug: Example rust + debug composition
#     - mkAuditedDebug: Create debug profile with audit logging (alias)
#
# Spec: specs/tmux-mcp.md
{ pkgs }:

let
  package = import ./mcp-server.nix { inherit pkgs; };
  profileDefs = import ./profile.nix { inherit pkgs; };

in
{
  inherit package;

  # Direct exports for convenience
  inherit (profileDefs)
    debug
    rust-debug
    debug-audited
    mkAuditedDebug
    ;

  # Expose all profiles for composition
  profiles = {
    inherit (profileDefs)
      debug
      rust-debug
      debug-audited
      mkAuditedDebug
      ;
  };
}
