#!/usr/bin/env bash
set -euo pipefail

: "${RUN_DIR:?}"

if command -v docker >/dev/null; then
  containers="$(docker ps --all --quiet --filter label=security-audit.scratch 2>/dev/null || true)"
  if [[ -n "$containers" ]]; then
    # shellcheck disable=SC2086
    docker rm --force $containers >/dev/null
  fi
fi

if [[ -d "$RUN_DIR/agents" ]]; then
  find "$RUN_DIR/agents" -mindepth 2 -maxdepth 2 -name scratch -exec rm -rf {} +
fi
