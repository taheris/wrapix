#!/usr/bin/env bash
# Judge rubrics for tmux-mcp.md success criteria

test_context_isolation() {
  judge_files "lib/mcp/tmux/mcp-server.nix" "lib/mcp/tmux/tmux-debug-mcp/src/main.rs"
  judge_criterion "Main session has zero token overhead from debug panes; debug subagent context is approximately 1.5k tokens (tool definitions only)"
}
