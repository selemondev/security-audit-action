#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?}" "${GITHUB_ACTION_PATH:?}" "${DEPS_DIR:?}" "${SANDBOX_IMAGE:?}" "${SANDBOX_PATH:?}"
install_command="${INSTALL_COMMAND:-auto}"
tool_cache="${SANDBOX_TOOL_CACHE:-/opt/hostedtoolcache}"
timeout_s=900

if [[ "$install_command" == none ]]; then
  echo "Dependency install disabled."
  exit 0
fi

mkdir -p "$DEPS_DIR/home"
mounts=(
  --volume /usr:/usr:ro
  --volume /etc/ld.so.cache:/etc/ld.so.cache:ro
  --volume /etc/ssl:/etc/ssl:ro
  --volume "$GITHUB_ACTION_PATH/scripts:/security-audit-scripts:ro"
  --volume "$GITHUB_WORKSPACE:$GITHUB_WORKSPACE:rw"
  --volume "$DEPS_DIR:$DEPS_DIR:rw"
)
if [[ -d "$GITHUB_WORKSPACE/.git" ]]; then
  mounts+=(--mount "type=tmpfs,destination=$GITHUB_WORKSPACE/.git")
fi
for dir in /etc/alternatives "$tool_cache"; do
  if [[ -d "$dir" ]]; then mounts+=(--volume "$dir:$dir:ro"); fi
done

name="security-audit-install-$$-$RANDOM"
status=0
timeout --kill-after=10 "$((timeout_s + 60))" \
  docker run --rm --init --name "$name" \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --cpus 2 \
  --memory 4g --memory-swap 4g \
  --pids-limit 1024 \
  --user "$(id -u):$(id -g)" \
  --workdir "$GITHUB_WORKSPACE" \
  "${mounts[@]}" \
  --env "PATH=$SANDBOX_PATH" \
  --env "HOME=$DEPS_DIR/home" \
  --env "TARGET=$GITHUB_WORKSPACE" \
  --env "DEPS_DIR=$DEPS_DIR" \
  --env "INSTALL_COMMAND=$install_command" \
  --env "XDG_CACHE_HOME=$DEPS_DIR/home/.cache" \
  --env "npm_config_cache=$DEPS_DIR/home/.npm" \
  --env "COREPACK_HOME=$DEPS_DIR/corepack" \
  --env "COREPACK_ENABLE_DOWNLOAD_PROMPT=0" \
  --env "GOMODCACHE=$DEPS_DIR/gomod" \
  --env "GOPATH=$DEPS_DIR/go" \
  --env "GOTOOLCHAIN=local" \
  --env "LANG=C.UTF-8" \
  --env "CI=true" \
  "$SANDBOX_IMAGE" \
  /usr/bin/timeout --kill-after=10 "$timeout_s" bash /security-audit-scripts/install-deps-container.sh </dev/null || status=$?
docker rm --force "$name" >/dev/null 2>&1 || true
if [[ "$status" -ne 0 ]]; then
  echo "::warning title=security-audit::The dependency install container exited with $status; the audit continues with the dependencies that installed."
fi

changed="$(git -C "$GITHUB_WORKSPACE" diff --name-only)"
if [[ -n "$changed" ]]; then
  echo "::warning title=security-audit::The dependency install changed tracked files; they were restored before the audit: $(tr '\n' ' ' <<<"$changed")"
  git -C "$GITHUB_WORKSPACE" checkout --quiet -- .
fi
