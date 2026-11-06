#!/usr/bin/env bash
set -euo pipefail

: "${RUN_DIR:?}"
agents_root="$RUN_DIR/agents"
[[ -d "$agents_root" ]] || exit 0
real_root="$(cd "$agents_root" && pwd -P)"

if command -v docker >/dev/null; then
  docker ps --all --filter label=security-audit.scratch --format '{{.ID}} {{.Label "security-audit.scratch"}}' 2>/dev/null \
    | while read -r id scratch; do
      if [[ "$scratch" == "$real_root"/* ]]; then docker rm --force "$id" >/dev/null 2>&1 || true; fi
    done
fi

find "$real_root" -mindepth 2 -maxdepth 2 -type d -name scratch -exec chmod -R u+rwX {} + -exec rm -rf {} + || true
leftover="$(find "$real_root" -mindepth 2 -maxdepth 2 -type d -name scratch -print -quit)"
if [[ -n "$leftover" ]]; then
  echo "::error title=security-audit::Could not delete sandbox scratch $leftover."
  exit 1
fi
