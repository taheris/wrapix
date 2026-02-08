#!/usr/bin/env bash
# Judge rubrics for ralph-workflow.md success criteria

test_plan_update_writes_new_requirements() {
  judge_files "lib/ralph/cmd/plan.sh"
  judge_criterion "ralph plan -u writes NEW requirements to state/<label>.md rather than modifying the main spec"
}

test_plan_update_hidden() {
  judge_files "lib/ralph/cmd/plan.sh"
  judge_criterion "ralph plan -u -h updates a hidden spec in state/ directory"
}

test_plan_runs_in_container() {
  judge_files "lib/ralph/cmd/plan.sh"
  judge_criterion "ralph plan runs Claude in a wrapix container using the base profile"
}

test_todo_update_reads_new_requirements() {
  judge_files "lib/ralph/cmd/todo.sh"
  judge_criterion "In update mode, ralph todo reads NEW requirements from state/<label>.md"
}

test_todo_update_creates_only_new() {
  judge_files "lib/ralph/cmd/todo.sh"
  judge_criterion "In update mode, ralph todo creates tasks ONLY for new requirements, not duplicating existing ones"
}

test_todo_update_merges_state() {
  judge_files "lib/ralph/cmd/todo.sh"
  judge_criterion "In update mode, ralph todo merges state/<label>.md into specs/<label>.md after creating tasks"
}

test_todo_update_deletes_state() {
  judge_files "lib/ralph/cmd/todo.sh"
  judge_criterion "In update mode, ralph todo deletes state/<label>.md after successful merge into the main spec"
}

test_todo_runs_in_container() {
  judge_files "lib/ralph/cmd/todo.sh"
  judge_criterion "ralph todo runs Claude in a wrapix container using the base profile"
}

test_tune_interactive() {
  judge_files "lib/ralph/cmd/tune.sh"
  judge_criterion "ralph tune in interactive mode identifies the correct template to edit and allows making changes"
}

test_tune_integration() {
  judge_files "lib/ralph/cmd/tune.sh"
  judge_criterion "ralph tune in integration mode ingests a diff and interviews the user about changes"
}
