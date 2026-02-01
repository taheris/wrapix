# tmux-debug MCP server definition
#
# Server providing tmux pane management for AI-assisted debugging
# within wrapix sandboxes.
#
# Exports:
#   - name: Server identifier ("tmux-debug")
#   - package: The tmux-debug-mcp binary
#   - mkServerConfig: Function to generate server config from user options
#
# Config options:
#   - audit: Path to audit log file (optional)
#   - auditFull: Path to directory for full capture logging (optional)
#
# Spec: specs/tmux-mcp.md
{ pkgs }:

{
  name = "tmux-debug";

  package = import ./mcp-server.nix { inherit pkgs; };

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
}
