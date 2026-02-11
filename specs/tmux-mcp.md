# tmux-mcp

MCP server providing tmux pane management for AI-assisted debugging within wrapix sandboxes.

## Problem Statement

AI agents lack the ability to debug applications the way humans do — running a server with debug logging in one terminal while sending test requests from another, watching logs scroll, and iterating. The single-command Bash tool doesn't support this parallel observation pattern.

## Overview

An MCP server providing tmux pane management tools, running inside wrapix sandboxes. AI agents spawn panes, send commands, and capture output to diagnose issues interactively.

**Key design decisions:**

- MCP server runs inside wrapix container (sandbox is the security boundary)
- Invoked via Task subagent to keep main session context lean (~0 tokens normally, ~1.5k when debugging)
- Open command policy — no restrictions beyond sandbox isolation
- Optional audit logging for review and debugging-the-debugger

## Use Cases

1. **Interactive debugging** — Spawn server with debug logging, send requests, analyze logs in real-time
2. **Test debugging** — Run failing tests in one pane while tailing logs in another
3. **Multi-service debugging** — Set up server, database client, and test runner across panes
4. **Reproduction workflows** — Systematically trigger and observe bugs

## MCP Tools

| Tool | Parameters | Description |
|------|------------|-------------|
| `tmux_create_pane` | `command: string`, `name?: string` | Create a new pane running the given command. Returns pane ID. |
| `tmux_send_keys` | `pane_id: string`, `keys: string` | Send keystrokes to a pane (for interactive input or commands). |
| `tmux_capture_pane` | `pane_id: string`, `lines?: number` | Capture recent output from a pane. Default 100 lines. |
| `tmux_kill_pane` | `pane_id: string` | Terminate a pane and its process. |
| `tmux_list_panes` | — | List all active panes with their IDs, names, status, and running commands. |

### Tool Definitions

```json
{
  "name": "tmux_create_pane",
  "description": "Create a new tmux pane running a command. Use for spawning servers, test runners, or interactive shells. Returns a pane ID for subsequent operations.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "command": {
        "type": "string",
        "description": "Command to run in the pane (e.g., 'RUST_LOG=debug cargo run')"
      },
      "name": {
        "type": "string",
        "description": "Optional human-readable name for the pane"
      }
    },
    "required": ["command"]
  }
}
```

```json
{
  "name": "tmux_send_keys",
  "description": "Send keystrokes to a tmux pane. Use for interactive input, running additional commands, or sending signals (e.g., Ctrl-C as '^C').",
  "inputSchema": {
    "type": "object",
    "properties": {
      "pane_id": {
        "type": "string",
        "description": "Target pane ID from tmux_create_pane or tmux_list_panes"
      },
      "keys": {
        "type": "string",
        "description": "Keystrokes to send. Use '^C' for Ctrl-C, 'Enter' for newline."
      }
    },
    "required": ["pane_id", "keys"]
  }
}
```

```json
{
  "name": "tmux_capture_pane",
  "description": "Capture recent output from a tmux pane. Use to read logs, command output, or error messages. Works on both running and exited panes.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "pane_id": {
        "type": "string",
        "description": "Target pane ID"
      },
      "lines": {
        "type": "number",
        "description": "Number of lines to capture (default: 100, max: 1000)"
      }
    },
    "required": ["pane_id"]
  }
}
```

```json
{
  "name": "tmux_kill_pane",
  "description": "Terminate a tmux pane and its running process. Use for cleanup after debugging.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "pane_id": {
        "type": "string",
        "description": "Target pane ID"
      }
    },
    "required": ["pane_id"]
  }
}
```

```json
{
  "name": "tmux_list_panes",
  "description": "List all active tmux panes with their IDs, names, status (running/exited), and running commands.",
  "inputSchema": {
    "type": "object",
    "properties": {}
  }
}
```

### Error Handling

Tool errors use MCP's standard `isError: true` response with plain text messages:

```json
{
  "content": [{"type": "text", "text": "Pane 'debug-1' not found. Use tmux_list_panes to see active panes."}],
  "isError": true
}
```

Error messages are descriptive and may include hints for recovery. No structured error codes — the AI consumer understands natural language.

### Pane Lifecycle

Panes remain visible after their process exits to preserve diagnostic information:

- Tmux configured with `remain-on-exit on` so windows stay after process dies
- `tmux_list_panes` shows panes with `status: "running"` or `status: "exited"`
- `tmux_capture_pane` on exited pane returns final output (crash logs, stack traces)
- `tmux_kill_pane` explicitly removes the pane from both tmux and internal state

This matches human debugging workflow: you want to see what a process printed before it died.

## Invocation Model

### Subagent Isolation

The debug MCP is **not** registered in the main session. Instead:

1. Main session identifies need for debugging
2. Main session spawns a Task subagent with the debug profile
3. Debug subagent has tmux tools in context (~1.5k tokens)
4. Subagent performs debugging, captures findings
5. Subagent returns summary to main session
6. Main session continues with lean context

### MCP Opt-in

Debugging is enabled per-sandbox via the `mcp` parameter, not via dedicated profiles:

```nix
# Enable tmux-debug with defaults
mkSandbox {
  profile = profiles.rust;
  mcp = {
    tmux-debug = { };
  };
}

# Enable with auditing
mkSandbox {
  profile = profiles.rust;
  mcp = {
    tmux-debug = { audit = "/workspace/.debug-audit.log"; };
  };
}

# Full capture logging
mkSandbox {
  profile = profiles.rust;
  mcp = {
    tmux-debug = {
      audit = "/workspace/.debug-audit.log";
      auditFull = "/workspace/.debug-audit/";
    };
  };
}
```

This eliminates profile proliferation — consumers add MCP servers to existing profiles rather than creating debug variants.

### Example Flow

```
User: "Debug why POST /api/users returns 500"

Main session:
  -> Spawns debug subagent: "Investigate 500 error on POST /api/users"

Debug subagent:
  -> tmux_create_pane("RUST_LOG=debug cargo run", name="server")
  -> tmux_create_pane("bash", name="client")
  -> [waits for server startup]
  -> tmux_send_keys(client, "curl -X POST localhost:3000/api/users -d '{...}'")
  -> tmux_capture_pane(server, lines=200)
  -> [analyzes stack trace, reads relevant code]
  -> tmux_kill_pane(server)
  -> tmux_kill_pane(client)
  -> Returns: "The 500 is caused by a missing database migration.
              The users table lacks the 'email' column.
              Fix: Run the pending migration."

Main session:
  -> Receives findings, proceeds with fix
```

## Auditing

Optional logging of all pane activity for review.

### Configuration

Enabled via environment variable:

```bash
TMUX_DEBUG_AUDIT=/workspace/.debug-audit.log
```

Or in the `mcp` parameter (see MCP Opt-in section above).

### Log Format

JSON Lines format for easy parsing:

```json
{"ts": "2026-01-30T10:15:32Z", "tool": "create_pane", "pane_id": "debug-1", "command": "RUST_LOG=debug cargo run", "name": "server"}
{"ts": "2026-01-30T10:15:45Z", "tool": "send_keys", "pane_id": "debug-2", "keys": "curl -X POST localhost:3000/api/users"}
{"ts": "2026-01-30T10:15:46Z", "tool": "capture_pane", "pane_id": "debug-1", "lines": 200, "output_bytes": 4523}
{"ts": "2026-01-30T10:16:02Z", "tool": "kill_pane", "pane_id": "debug-1"}
```

Output content is logged by byte count only (not full content) to avoid log bloat. Full captures can be written to separate files if needed:

```bash
TMUX_DEBUG_AUDIT_FULL=/workspace/.debug-audit/
# Creates: .debug-audit/debug-1-capture-001.txt, etc.
```

## Security Model

### Sandbox as Trust Boundary

- The MCP server runs inside the wrapix container
- All pane commands execute within sandbox isolation
- No additional command restrictions — same trust model as Bash tool
- Filesystem access limited to `/workspace` (wrapix constraint)
- Network access per wrapix profile configuration

### No Privilege Escalation

- MCP server runs as the same unprivileged user as Claude Code
- Tmux session is user-local, no system-wide visibility
- Pane processes inherit sandbox constraints

## Integration

### Module Location

```
lib/
  mcp/
    default.nix              # MCP registry: { tmux-debug = import ./tmux; }
    tmux/
      default.nix            # Server definition: { name, package, mkServerConfig }
      mcp-server.nix         # MCP server Rust package
  sandbox/
    default.nix              # mkSandbox accepts `mcp` parameter
    profiles.nix             # Base profiles (rust, python, base) - no debug variants
```

### MCP Server Implementation

A Rust binary implementing the MCP protocol:

```
tmux-debug-mcp/
  Cargo.toml
  src/
    main.rs          # MCP server entry point
    mcp.rs           # MCP protocol handling (JSON-RPC over stdio)
    tmux.rs          # Tmux command execution
    panes.rs         # Pane state management
    audit.rs         # Optional audit logging
```

### Dependencies

- `serde`, `serde_json` — MCP protocol serialization
- `tokio` — Async runtime for MCP server
- Standard library for process spawning (tmux commands)

### Tmux Session Management

The MCP server manages a single tmux session named `debug-{pid}`:

```bash
# Create session (on first pane creation)
tmux new-session -d -s debug-12345 -x 200 -y 50

# Configure remain-on-exit for pane lifecycle
tmux set-option -t debug-12345 remain-on-exit on

# Create pane
tmux new-window -t debug-12345 -n "server"

# Send keys
tmux send-keys -t debug-12345:server "cargo run" Enter

# Capture output
tmux capture-pane -t debug-12345:server -p -S -100

# Kill pane
tmux kill-window -t debug-12345:server

# Cleanup (on MCP server shutdown)
tmux kill-session -t debug-12345
```

## Client Configuration

Projects consuming wrapix debugging enable MCP servers via the `mcp` parameter:

```nix
# In client project's flake.nix
{
  devShells.debug = wrapix.mkSandbox {
    profile = wrapix.profiles.rust;
    mcp = {
      tmux-debug = {
        audit = "/workspace/.debug-audit.log";
      };
    };
  };
}
```

## Testing

### Unit Tests (Rust)

Located in `lib/mcp/tmux/src/` as standard Rust `#[test]` modules:

| Module | Tests |
|--------|-------|
| `mcp.rs` | JSON-RPC parsing, tool request/response serialization, error formatting |
| `panes.rs` | Pane state tracking, ID generation, status transitions (running → exited) |
| `audit.rs` | Log entry formatting, byte counting, file rotation |

Run with `cargo test` in the `tmux-debug-mcp` crate.

### Integration Tests

Located in `tests/tmux-mcp/`:

| Test | Description |
|------|-------------|
| `test_create_pane.sh` | Create pane, verify tmux window exists, verify returned pane ID |
| `test_send_keys.sh` | Create pane with shell, send `echo hello`, capture output, verify "hello" present |
| `test_capture_pane.sh` | Create pane running `seq 1 200`, capture with various line counts, verify content |
| `test_kill_pane.sh` | Create pane, kill it, verify tmux window gone, verify list_panes excludes it |
| `test_list_panes.sh` | Create multiple panes, verify list returns all with correct names and IDs |
| `test_exited_pane.sh` | Create pane with `echo done && exit`, wait for exit, verify status="exited", capture final output |
| `test_error_handling.sh` | Send keys to nonexistent pane, verify isError response with descriptive message |
| `test_audit_log.sh` | Enable audit logging, run operations, verify JSON Lines output format |
| `test_cleanup_on_exit.sh` | Start MCP server, create panes, kill server, verify tmux session cleaned up |

Tests spawn the MCP server, send JSON-RPC requests over stdio, and verify responses. Requires tmux installed.

### End-to-End Tests (Sandbox)

Located in `tests/tmux-mcp/e2e/`:

| Test | Description |
|------|-------------|
| `test_sandbox_debug_profile.sh` | Build wrapix image with MCP opt-in, verify tmux and MCP server present |
| `test_mcp_in_sandbox.sh` | Run MCP server inside sandbox, create pane, send keys, capture output |
| `test_profile_composition.sh` | Build rust profile with MCP opt-in, verify both rust toolchain and debug tools available |
| `test_filesystem_isolation.sh` | Verify pane commands can only access `/workspace` |

These tests use `nix build` to create sandbox images and `podman run` to execute inside containers.

### Running Tests

```bash
# Unit tests
nix develop -c cargo test -p tmux-debug-mcp

# Integration tests (requires tmux)
nix develop -c ./tests/tmux-mcp/run-integration.sh

# E2E tests (requires podman)
nix develop -c ./tests/tmux-mcp/run-e2e.sh

# All tests
nix flake check
```

## Success Criteria

- [ ] Pane lifecycle works: Create, list, kill panes successfully
  [verify:wrapix](../tests/tmux-mcp/test_create_pane.sh)
- [ ] I/O works: Send keys and capture output accurately
  [verify:wrapix](../tests/tmux-mcp/test_send_keys.sh)
- [ ] Exited pane visibility: Exited panes show status and allow final output capture
  [verify:wrapix](../tests/tmux-mcp/test_exited_pane.sh)
- [ ] Context isolation: Main session has 0 token overhead; debug subagent ~1.5k
  [judge](../tests/judges/tmux-mcp.sh#test_context_isolation)
- [ ] Sandbox contained: All pane commands run within wrapix isolation
  [verify:wrapix](../tests/tmux-mcp/e2e/test_filesystem_isolation.sh)
- [ ] Audit works: When enabled, all operations logged correctly
  [verify:wrapix](../tests/tmux-mcp/test_audit_log.sh)
- [ ] Cleanup: Panes and session terminated on MCP server exit
  [verify:wrapix](../tests/tmux-mcp/test_cleanup_on_exit.sh)
- [ ] MCP integration: MCP servers integrate cleanly with any profile via `mcp` parameter
  [verify:wrapix](../tests/tmux-mcp/e2e/test_profile_composition.sh)
- [ ] Tests pass: All unit, integration, and e2e tests pass
  [verify:wrapix](../tests/tmux-mcp/run-integration.sh)

## Out of Scope

- **GUI/TUI for pane viewing** — AI reads pane content via capture, no visual interface needed
- **Pane layout management** — Simple window-per-pane model, no splits or tiling
- **Cross-container debugging** — Single sandbox scope; multi-container orchestration is future work
- **Breakpoint/stepping integration** — This is terminal-level debugging, not debugger integration (gdb/lldb)
- **Persistent sessions** — Tmux session is ephemeral, tied to MCP server lifetime
