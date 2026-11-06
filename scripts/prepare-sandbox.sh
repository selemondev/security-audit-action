#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_OUTPUT:?}" "${RUNNER_TEMP:?}" "${GITHUB_WORKSPACE:?}"
tool_cache="${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}"
deps_dir="$RUNNER_TEMP/security-audit-deps"
target_source="$RUNNER_TEMP/security-audit-target"

unavailable() {
  echo "::warning title=security-audit::No sandbox: $1. The audit reads source only and cannot confirm findings that need execution."
  printf 'available=false\nreason=%s\n' "$1" >>"$GITHUB_OUTPUT"
  exit 0
}

[[ "$(uname -s)" == "Linux" ]] || unavailable "the runner is not Linux"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && -n "${VERSION_ID:-}" ]] || unavailable "the runner is not Ubuntu"
command -v docker >/dev/null || unavailable "Docker is not installed"
docker info >/dev/null 2>&1 || unavailable "the Docker daemon is not reachable"
sudo -n true 2>/dev/null || unavailable "passwordless sudo is unavailable for the size-limited scratch disk"
command -v python3 >/dev/null || unavailable "python3 is not installed"
command -v timeout >/dev/null || unavailable "timeout is not installed"

image="ubuntu:$VERSION_ID"
docker pull --quiet "$image" >/dev/null || unavailable "docker pull $image failed"

sandbox_path="$deps_dir/venv/bin:$deps_dir/npm-global/bin"
IFS=: read -ra entries <<<"$PATH"
for entry in "${entries[@]}"; do
  case "$entry" in
    /usr/* | /bin | /sbin | "$tool_cache"/*) sandbox_path+=":$entry" ;;
  esac
done

rm -rf "$deps_dir" "$target_source"
mkdir -p "$deps_dir" "$target_source"
git -C "$GITHUB_WORKSPACE" ls-files -z --cached \
  | tar --create --file=- --directory="$GITHUB_WORKSPACE" --no-recursion --ignore-failed-read --null --files-from=- \
  | tar --extract --directory="$target_source" --file=-

{
  echo "available=true"
  echo "image=$image"
  echo "path=$sandbox_path"
  echo "deps-dir=$deps_dir"
  echo "tool-cache=$tool_cache"
  echo "target-source=$target_source"
} >>"$GITHUB_OUTPUT"
echo "Sandbox image: $image"
