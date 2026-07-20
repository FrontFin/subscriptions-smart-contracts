#!/usr/bin/env bash
# Build the test-environment program, then run the LiteSVM tests against it.
set -euo pipefail
cd "$(dirname "$0")"

scripts/build.sh test
cargo test -p subscription-controller "$@"
