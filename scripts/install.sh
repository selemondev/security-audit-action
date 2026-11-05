#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_OUTPUT:?}" "${RUNNER_TEMP:?}" "${SKILL_REF:?}"
copilot_version="${COPILOT_VERSION:-latest}"

source_dir="$RUNNER_TEMP/security-audit-skill-src"
skill_dir="$HOME/.copilot/skills/security-audit"

rm -rf "$source_dir" "$skill_dir"
git init --quiet "$source_dir"
git -C "$source_dir" fetch --quiet --depth 1 https://github.com/cloudflare/security-audit-skill "$SKILL_REF"
git -C "$source_dir" checkout --quiet FETCH_HEAD
mkdir -p "$(dirname "$skill_dir")"
cp -R "$source_dir/skills/security-audit" "$skill_dir"
echo "security-audit skill at $(git -C "$source_dir" rev-parse HEAD)"

npm install --global --no-fund --no-audit "@github/copilot@$copilot_version"
copilot --version

printf 'skill-dir=%s\n' "$skill_dir" >>"$GITHUB_OUTPUT"
