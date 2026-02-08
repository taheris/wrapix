# tmux-debug-mcp: MCP server for tmux pane management
#
# Provides tools for AI-assisted debugging within wrapix sandboxes:
# - tmux_create_pane: Spawn panes running commands
# - tmux_send_keys: Send keystrokes to panes
# - tmux_capture_pane: Capture pane output
# - tmux_kill_pane: Terminate panes
# - tmux_list_panes: List active panes
#
# Usage: nix build .#tmux-debug-mcp
{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "tmux-debug-mcp";
  version = "0.1.0";
  src = ./tmux-debug-mcp;

  cargoLock = {
    lockFile = ./tmux-debug-mcp/Cargo.lock;
  };

  # Prevent cargo from creating /homeless-shelter/.cargo/ when building
  # without Nix sandbox (e.g., inside containers where sandbox = false)
  env.HOME = "/tmp";

  # tmux is required at runtime for pane management
  buildInputs = [ pkgs.tmux ];

  # Propagate tmux so it's available in PATH when package is installed
  propagatedBuildInputs = [ pkgs.tmux ];

  # Run tests during build
  doCheck = true;

  meta = {
    description = "MCP server providing tmux pane management for AI-assisted debugging";
    mainProgram = "tmux-debug-mcp";
  };
}
