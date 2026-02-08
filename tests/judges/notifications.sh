#!/usr/bin/env bash
# Judge rubrics for notifications.md success criteria

test_focus_suppression() {
  judge_files "lib/notify/daemon.nix"
  judge_criterion "No notification is sent when the terminal window is focused (focus-aware suppression is implemented)"
}

test_concurrent_connections() {
  judge_files "lib/notify/daemon.nix"
  judge_criterion "Daemon handles multiple simultaneous client connections without blocking or dropping messages"
}
