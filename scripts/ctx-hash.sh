#!/usr/bin/env bash
# Hash the build recipe into 12 hex chars for the state-gate key.
# Usage: ctx-hash.sh [extra-file...]
#
# The signalk-server-images reference gates ONLY on the upstream source, so
# a Dockerfile change never rebuilds until upstream moves (its AGENTS.md
# documents that as a live gotcha). Here the recipe hash is part of every
# state key: recipe change -> key moves -> next run rebuilds. Both
# build-latest.yml and build-master.yml call this script so their shared
# file list cannot drift apart; each passes ITS OWN workflow file as the
# extra arg — without that, a push touching only the workflow file would
# trigger a run whose gate still computed an unchanged key (changed=false),
# and the cron could never self-heal it either.
set -euo pipefail
extras=("$@")
cd "$(dirname "$0")/.."
cat Dockerfile entrypoint.sh \
    .github/actions/build-and-push-arch/action.yml \
    .github/workflows/_build.yml \
    ${extras[@]+"${extras[@]}"} \
  | sha256sum | cut -c1-12
