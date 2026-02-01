# Debug profile for wrapix providing tmux pane management
#
# Provides MCP tools for AI-assisted debugging:
# - tmux_create_pane, tmux_send_keys, tmux_capture_pane, etc.
#
# Usage in profiles.nix:
#   debug = tmuxProfile.debug;
#   rust-debug = deriveProfile profiles.rust tmuxProfile.debug;
#
# Spec: specs/tmux-mcp.md
{ pkgs }:

let
  tmuxDebugMcp = import ./mcp-server.nix { inherit pkgs; };

in
{
  # Debug profile with tmux MCP server
  # This profile extension provides debugging capabilities via tmux.
  # Compose with other profiles: deriveProfile profiles.rust debug
  debug = {
    name = "debug";

    packages = with pkgs; [
      tmux
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

  # Debug profile with audit logging enabled
  # Set TMUX_DEBUG_AUDIT to log all pane operations for review.
  # See specs/tmux-mcp.md "Auditing" section for log format.
  debug-audited = auditPath: {
    name = "debug-audited";

    packages = with pkgs; [
      tmux
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

  # Helper to create audited debug profile (alias for compatibility)
  # Usage: mkAuditedDebug "/workspace/.debug-audit.log"
  mkAuditedDebug = auditPath: {
    name = "debug-audited";

    packages = with pkgs; [
      tmux
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

  # Example rust-debug profile composition
  # Demonstrates how to compose debug with language profiles.
  # In practice, use deriveProfile in profiles.nix for full base package support.
  rust-debug = {
    name = "rust-debug";

    packages = with pkgs; [
      # Rust packages
      gcc
      openssl
      openssl.dev
      pkg-config
      postgresql.lib
      rustup
      # Debug packages
      tmux
      tmuxDebugMcp
    ];

    mcp = {
      servers.tmux-debug = {
        command = "tmux-debug-mcp";
      };
    };

    env = {
      CARGO_HOME = "/workspace/.cargo";
      LIBRARY_PATH = "${pkgs.postgresql.lib}/lib";
      OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";
      OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
      RUSTUP_HOME = "/workspace/.rustup";
    };

    mounts = [
      {
        source = "~/.cargo/registry";
        dest = "~/.cargo/registry";
        mode = "ro";
        optional = true;
      }
      {
        source = "~/.cargo/git";
        dest = "~/.cargo/git";
        mode = "ro";
        optional = true;
      }
    ];
  };
}
