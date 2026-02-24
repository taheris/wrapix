#!/usr/bin/env bash
# Judge rubrics for beads.md success criteria

test_sync_in_container() {
  judge_files "lib/sandbox/linux/entrypoint.sh" "lib/sandbox/darwin/entrypoint.sh"
  judge_criterion "bd dolt pull/push works correctly in the container environment, synchronizing issue state between local and remote"
}
