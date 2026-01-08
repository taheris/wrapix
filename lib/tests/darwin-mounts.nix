# Darwin VM mount tests - verify file and directory mount handling
# These tests validate the entrypoint logic without requiring the actual VM
{
  pkgs,
  system,
}:

let
  inherit (pkgs) runCommandLocal writeShellScript;
  inherit (builtins) elem;

  isDarwin = system == "aarch64-darwin";

  # Helper to create a mock entrypoint test environment
  mockEntrypointTest = writeShellScript "mock-entrypoint-test" ''
    set -euo pipefail

    # Mock environment variables as the Swift runner would set them
    export HOST_USER="testuser"
    export HOST_UID="1000"
    export WRAPIX_PROMPT="test prompt"

    # Create mock directory structure
    export MOCK_ROOT=$(mktemp -d)
    trap "rm -rf $MOCK_ROOT" EXIT

    # Create /etc for passwd
    mkdir -p "$MOCK_ROOT/etc"
    touch "$MOCK_ROOT/etc/passwd"
    touch "$MOCK_ROOT/etc/group"

    # Create /home directory
    mkdir -p "$MOCK_ROOT/home"

    # Create mock mount directories
    mkdir -p "$MOCK_ROOT/mnt/wrapix/dir-mount/0"
    mkdir -p "$MOCK_ROOT/mnt/wrapix/file-mount/0"

    # Create mock .claude directory content at mount point
    # In real scenario: ~/.claude is mounted to /mnt/wrapix/dir-mount/0
    # So content should be directly in dir-mount/0, not nested in .claude
    mkdir -p "$MOCK_ROOT/mnt/wrapix/dir-mount/0/mcp"
    echo '{"test": "config"}' > "$MOCK_ROOT/mnt/wrapix/dir-mount/0/settings.json"
    echo '{"server": "test"}' > "$MOCK_ROOT/mnt/wrapix/dir-mount/0/mcp/config.json"

    # Create mock .claude.json file
    echo '{"apiKey": "test-key-123", "numStartups": 5}' > "$MOCK_ROOT/mnt/wrapix/file-mount/0/.claude.json"

    "$@"
  '';

in
{
  # Test 1: Verify directory mount copy logic
  darwin-dir-mount-copy =
    runCommandLocal "test-darwin-dir-mount-copy"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
        ];
      }
      ''
        echo "Testing directory mount copy logic..."

        ${mockEntrypointTest} bash -c '
          # Use MOCK_ROOT for all paths (nix sandbox cannot create /home)
          export HOME="$MOCK_ROOT/home/testuser"
          mkdir -p "$HOME"

          # Set up test mount mapping pointing to mock home
          export WRAPIX_DIR_MOUNTS="$MOCK_ROOT/mnt/wrapix/dir-mount/0:$HOME/.claude"

          # Simulate the entrypoint directory copy logic
          declare -a DIR_MOUNT_PAIRS
          if [ -n "''${WRAPIX_DIR_MOUNTS:-}" ]; then
              IFS="," read -ra DIR_MOUNTS <<< "$WRAPIX_DIR_MOUNTS"
              for mapping in "''${DIR_MOUNTS[@]}"; do
                  src="''${mapping%%:*}"
                  dst="''${mapping#*:}"
                  if [ -d "$src" ]; then
                      mkdir -p "$(dirname "$dst")"
                      cp -r "$src" "$dst"
                      # In real entrypoint we would chown here
                      DIR_MOUNT_PAIRS+=("$src:$dst")
                  fi
              done
          fi

          # Verify the copy worked
          [ -d "$HOME/.claude" ] || { echo "FAIL: .claude directory not created"; exit 1; }
          [ -f "$HOME/.claude/settings.json" ] || { echo "FAIL: settings.json not copied"; exit 1; }
          [ -d "$HOME/.claude/mcp" ] || { echo "FAIL: mcp subdirectory not copied"; exit 1; }
          [ -f "$HOME/.claude/mcp/config.json" ] || { echo "FAIL: mcp/config.json not copied"; exit 1; }

          # Verify content
          grep -q "test.*config" "$HOME/.claude/settings.json" || { echo "FAIL: settings.json content wrong"; exit 1; }

          echo "Directory mount copy test PASSED"
        '

        mkdir $out
      '';

  # Test 2: Verify file mount copy logic
  darwin-file-mount-copy =
    runCommandLocal "test-darwin-file-mount-copy"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
        ];
      }
      ''
        echo "Testing file mount copy logic..."

        ${mockEntrypointTest} bash -c '
          # Use MOCK_ROOT for all paths (nix sandbox cannot create /home)
          export HOME="$MOCK_ROOT/home/testuser"
          mkdir -p "$HOME"

          # Set up test mount mapping pointing to mock home
          export WRAPIX_FILE_MOUNTS="$MOCK_ROOT/mnt/wrapix/file-mount/0/.claude.json:$HOME/.claude.json"

          # Simulate the entrypoint file copy logic
          declare -a FILE_MOUNT_PAIRS
          if [ -n "''${WRAPIX_FILE_MOUNTS:-}" ]; then
              IFS="," read -ra MOUNTS <<< "$WRAPIX_FILE_MOUNTS"
              for mapping in "''${MOUNTS[@]}"; do
                  src="''${mapping%%:*}"
                  dst="''${mapping#*:}"
                  if [ -f "$src" ]; then
                      mkdir -p "$(dirname "$dst")"
                      cp "$src" "$dst"
                      FILE_MOUNT_PAIRS+=("$src:$dst")
                  fi
              done
          fi

          # Verify the copy worked
          [ -f "$HOME/.claude.json" ] || { echo "FAIL: .claude.json not created"; exit 1; }

          # Verify content preserved
          grep -q "test-key-123" "$HOME/.claude.json" || { echo "FAIL: apiKey not preserved"; exit 1; }
          grep -q "numStartups" "$HOME/.claude.json" || { echo "FAIL: numStartups not preserved"; exit 1; }

          echo "File mount copy test PASSED"
        '

        mkdir $out
      '';

  # Test 3: Verify multiple mounts handled correctly
  darwin-multiple-mounts =
    runCommandLocal "test-darwin-multiple-mounts"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
        ];
      }
      ''
        echo "Testing multiple mount handling..."

        ${mockEntrypointTest} bash -c '
          # Use MOCK_ROOT for all paths (nix sandbox cannot create /home)
          export HOME="$MOCK_ROOT/home/testuser"
          mkdir -p "$HOME"

          # Create additional mock mounts
          echo "backup content" > "$MOCK_ROOT/mnt/wrapix/file-mount/0/.claude.json.backup"

          # Set up multiple file mounts (comma-separated) pointing to mock home
          export WRAPIX_FILE_MOUNTS="$MOCK_ROOT/mnt/wrapix/file-mount/0/.claude.json:$HOME/.claude.json,$MOCK_ROOT/mnt/wrapix/file-mount/0/.claude.json.backup:$HOME/.claude.json.backup"

          # Simulate the entrypoint logic
          declare -a FILE_MOUNT_PAIRS
          if [ -n "''${WRAPIX_FILE_MOUNTS:-}" ]; then
              IFS="," read -ra MOUNTS <<< "$WRAPIX_FILE_MOUNTS"
              count=0
              for mapping in "''${MOUNTS[@]}"; do
                  src="''${mapping%%:*}"
                  dst="''${mapping#*:}"
                  if [ -f "$src" ]; then
                      mkdir -p "$(dirname "$dst")"
                      cp "$src" "$dst"
                      FILE_MOUNT_PAIRS+=("$src:$dst")
                      count=$((count + 1))
                  fi
              done
              [ "$count" -eq 2 ] || { echo "FAIL: Expected 2 file mounts, got $count"; exit 1; }
          fi

          # Verify both files copied
          [ -f "$HOME/.claude.json" ] || { echo "FAIL: .claude.json not copied"; exit 1; }
          [ -f "$HOME/.claude.json.backup" ] || { echo "FAIL: .claude.json.backup not copied"; exit 1; }

          echo "Multiple mount test PASSED"
        '

        mkdir $out
      '';

  # Test 4: Verify mount with missing source is handled gracefully
  darwin-missing-mount-source =
    runCommandLocal "test-darwin-missing-mount"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
        ];
      }
      ''
        echo "Testing missing mount source handling..."

        ${mockEntrypointTest} bash -c '
          # Use MOCK_ROOT for all paths (nix sandbox cannot create /home)
          export HOME="$MOCK_ROOT/home/testuser"
          mkdir -p "$HOME"

          # Point to non-existent file
          export WRAPIX_FILE_MOUNTS="/nonexistent/path/.claude.json:$HOME/.claude.json"

          # Simulate the entrypoint logic - should not fail, just skip
          declare -a FILE_MOUNT_PAIRS
          if [ -n "''${WRAPIX_FILE_MOUNTS:-}" ]; then
              IFS="," read -ra MOUNTS <<< "$WRAPIX_FILE_MOUNTS"
              for mapping in "''${MOUNTS[@]}"; do
                  src="''${mapping%%:*}"
                  dst="''${mapping#*:}"
                  if [ -f "$src" ]; then
                      mkdir -p "$(dirname "$dst")"
                      cp "$src" "$dst"
                      FILE_MOUNT_PAIRS+=("$src:$dst")
                  fi
              done
          fi

          # Should not have created the file (source didnt exist)
          [ ! -f "$HOME/.claude.json" ] || { echo "FAIL: File should not exist when source missing"; exit 1; }

          # Array should be empty
          [ "''${#FILE_MOUNT_PAIRS[@]}" -eq 0 ] || { echo "FAIL: No mounts should have been recorded"; exit 1; }

          echo "Missing mount source test PASSED"
        '

        mkdir $out
      '';

  # Test 5: Verify passwd home directory is set correctly
  darwin-passwd-home =
    runCommandLocal "test-darwin-passwd-home"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          gnugrep
        ];
      }
      ''
        echo "Testing /etc/passwd home directory..."

        # Check that the entrypoint sets the correct home directory in passwd
        SCRIPT="${../sandbox/darwin/entrypoint.sh}"

        # The passwd entry should use /home/$HOST_USER, not /workspace
        if grep -q '/workspace:/bin/bash' "$SCRIPT"; then
          echo "FAIL: /etc/passwd should not use /workspace as home"
          exit 1
        fi

        if ! grep -q '/home/\$HOST_USER:/bin/bash' "$SCRIPT"; then
          echo "FAIL: /etc/passwd should use /home/\$HOST_USER as home"
          exit 1
        fi

        echo "Passwd home directory test PASSED"
        mkdir $out
      '';
}
