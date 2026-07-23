#!/usr/bin/env bash
set -euo pipefail

jq -e '.initial_prompt == "consumer field" and .repin == true' "${WRIX_SPAWN_CONFIG:?}" >/dev/null
: >"${WRIX_TEST_RUNTIME_STATE:?}/consumer-ran"
