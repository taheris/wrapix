# tmux-mcp tests - verify MCP server builds and tests pass
{
  pkgs,
  system,
  src,
}:

let
  inherit (pkgs) bash runCommandLocal rustPlatform;

  cratePath = ../lib/mcp/tmux/tmux-debug-mcp;

  # Build the tmux-debug-mcp package using rustPlatform
  # This properly handles cargo dependency fetching in the nix sandbox
  tmuxDebugMcp = rustPlatform.buildRustPackage {
    pname = "tmux-debug-mcp";
    version = "0.1.0";
    src = cratePath;

    cargoLock = {
      lockFile = ../lib/mcp/tmux/tmux-debug-mcp/Cargo.lock;
    };

    # Run tests as part of the build
    doCheck = true;

    meta = {
      description = "MCP server providing tmux pane management for AI-assisted debugging";
    };
  };

in
{
  # Build the tmux-debug-mcp Rust crate and run unit tests
  # Uses rustPlatform.buildRustPackage for proper offline cargo builds
  tmux-mcp-unit-tests = runCommandLocal "tmux-mcp-unit-tests" { } ''
    echo "Verifying tmux-debug-mcp builds and tests pass..."
    # The package build with doCheck=true already ran tests
    test -x ${tmuxDebugMcp}/bin/tmux-debug-mcp
    echo "tmux-debug-mcp binary exists and tests passed"
    mkdir $out
  '';

  # Verify integration test shell scripts have valid syntax
  tmux-mcp-integration-syntax =
    runCommandLocal "tmux-mcp-integration-syntax"
      {
        nativeBuildInputs = [
          bash
          pkgs.shellcheck
        ];
      }
      ''
        echo "Checking integration test script syntax..."

        E2E_DIR="${src}/tests/tmux-mcp/e2e"

        if [ -d "$E2E_DIR" ]; then
          # Check bash syntax
          for script in "$E2E_DIR"/*.sh; do
            if [ -f "$script" ]; then
              echo "Checking syntax: $(basename "$script")"
              bash -n "$script"
            fi
          done

          # Run shellcheck on scripts
          echo "Running shellcheck on E2E scripts..."
          find "$E2E_DIR" -name '*.sh' -exec shellcheck -x --exclude=SC1091 {} +
          echo "All integration test scripts pass syntax checks"
        else
          echo "No E2E test directory found at $E2E_DIR, skipping"
        fi

        mkdir $out
      '';

  # Verify the Rust crate builds (this is the actual build artifact)
  tmux-mcp-builds = runCommandLocal "tmux-mcp-builds" { } ''
    echo "Verifying tmux-debug-mcp builds..."
    test -x ${tmuxDebugMcp}/bin/tmux-debug-mcp
    echo "tmux-debug-mcp compiles successfully"
    mkdir $out
  '';
}
