#!/bin/sh
# Renders the README's screenshots into docs/: the menu, the history window in dark and light, and the output of
# `subsmash -a`, for sample accounts.
set -eu

cd "$(dirname "$0")/.."
docs="$(cd .. && pwd)/docs"
cli_output="$(mktemp)"
trap 'rm -f "$cli_output"' EXIT

(cd ../cli && bun scripts/sample-output.ts) >"$cli_output"
mkdir -p "$docs"
SUBSMASHER_SCREENSHOTS="$docs" SUBSMASHER_CLI_OUTPUT="$cli_output" swift test --filter Screenshots
