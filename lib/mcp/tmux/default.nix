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
#   - mkServerConfig: Create MCP server configuration for opt-in mechanism
#
# Spec: specs/tmux-mcp.md
{ pkgs }:

let
  package = import ./mcp-server.nix { inherit pkgs; };

  # Debug profile with tmux MCP server
  # This profile extension provides debugging capabilities via tmux.
  # Compose with other profiles: deriveProfile profiles.rust debug
  debug = {
    name = "debug";

    packages = with pkgs; [
      tmux
      package
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
      package
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
      package
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
      package
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

  # Create MCP server configuration for opt-in mechanism
  # Used by mkSandbox when tmux-debug is requested via the mcp parameter
  # See specs/tmux-mcp.md "MCP Opt-in" section
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

in
{
  inherit package;

  # Direct exports for convenience
  inherit
    debug
    rust-debug
    debug-audited
    mkAuditedDebug
    mkServerConfig
    ;

  # Expose all profiles for composition
  profiles = {
    inherit
      debug
      rust-debug
      debug-audited
      mkAuditedDebug
      ;
  };
}
