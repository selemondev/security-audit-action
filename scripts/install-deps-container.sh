#!/usr/bin/env bash
set -uo pipefail

: "${TARGET:?}" "${DEPS_DIR:?}"
install_command="${INSTALL_COMMAND:-auto}"
cd "$TARGET" || exit 1

failed=0
run() {
  echo "+ $*"
  if ! "$@"; then
    echo "::warning title=security-audit::'$*' failed; the audit continues with the dependencies that installed."
    failed=1
  fi
}

if [[ "$install_command" != auto ]]; then
  run bash -c "$install_command"
  exit 0
fi

ran=0
if [[ -f pnpm-lock.yaml ]]; then
  run corepack pnpm install --frozen-lockfile
  ran=1
elif [[ -f yarn.lock ]]; then
  if [[ -f .yarnrc.yml ]]; then run corepack yarn install --immutable; else run corepack yarn install --frozen-lockfile; fi
  ran=1
elif [[ -f bun.lock || -f bun.lockb ]]; then
  run npm install --global --prefix "$DEPS_DIR/npm-global" --no-fund --no-audit bun
  run bun install --frozen-lockfile
  ran=1
elif [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
  run npm ci --no-fund --no-audit
  ran=1
fi

if [[ -f requirements.txt ]]; then
  run python3 -m venv "$DEPS_DIR/venv"
  run "$DEPS_DIR/venv/bin/pip" install --quiet --requirement requirements.txt
  ran=1
fi

if [[ -f go.mod ]]; then
  run go mod download
  ran=1
fi

if [[ "$ran" -eq 0 ]]; then
  echo "No lockfile found at the repository root; nothing to install."
elif [[ "$failed" -eq 0 ]]; then
  echo "Dependencies installed."
fi
exit 0
