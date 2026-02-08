#!/usr/bin/env bash
# Judge rubrics for beads.md success criteria

test_sync_in_container() {
  judge_files "lib/ralph/cmd/sync.sh"
  judge_criterion "bd sync works correctly in the container environment, synchronizing issue state between local and remote"
}
