#!/usr/bin/env bash
# Build the program for an environment, injecting that env's program id
# (puller keys are NOT baked in — they live in the on-chain Config). The
# committed source always carries the TEST values (scripts/envs/test.env) —
# deployable-env values exist only in the env files and the built artifacts:
#
#   test  → target/deploy/subscription_controller.so         (what tests load)
#   local → target/deploy-local/subscription_controller.so
#   dev   → target/deploy-dev/subscription_controller.so
#   prod  → target/deploy-prod/subscription_controller.so
#
# Usage: scripts/build.sh <test|local|dev|prod> [program-id]
#   program-id — override for a first deploy, before the env has a pinned
#                PROGRAM_ID (deploy.sh passes the freshly minted id).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_env.sh

ENV="${1:?usage: scripts/build.sh <test|local|dev|prod> [program-id]}"
ENV_FILE=$(env_file "$ENV")
if [[ -n "${2:-}" ]]; then
  PROGRAM_ID="$2"
else
  PROGRAM_ID=$(env_program_id "$ENV")
fi

# Whatever happens, leave the committed source on the test values.
restore_test() { python3 scripts/apply_env.py scripts/envs/test.env >/dev/null; }
trap restore_test EXIT

python3 scripts/apply_env.py "$ENV_FILE" "$PROGRAM_ID"
cargo build-sbf --manifest-path programs/subscription-controller/Cargo.toml

if [[ "$ENV" != "test" ]]; then
  mkdir -p "target/deploy-$ENV"
  cp target/deploy/subscription_controller.so "target/deploy-$ENV/"
  # Rebuild target/deploy/ from the test source so the test artifact never
  # silently carries a deployable env's constants.
  restore_test
  cargo build-sbf --manifest-path programs/subscription-controller/Cargo.toml
  echo "built target/deploy-$ENV/subscription_controller.so  (program id $PROGRAM_ID)"
else
  echo "built target/deploy/subscription_controller.so  (program id $PROGRAM_ID)"
fi
