#!/usr/bin/env bash
set -euo pipefail

: "${SANDBOX_TARGET:?}" "${SANDBOX_AGENTS_ROOT:?}" "${SANDBOX_IMAGE:?}" "${SANDBOX_PATH:?}"
deps_dir="${SANDBOX_DEPS_DIR:-}"
tool_cache="${SANDBOX_TOOL_CACHE:-/opt/hostedtoolcache}"
max_timeout=600

usage() {
  cat >&2 <<'EOF'
usage: sandbox-run --scratch DIR [--timeout SECONDS] [--memory SIZE] -- COMMAND [ARG...]

Runs COMMAND in a Docker container with no network (loopback only), an empty
environment, the target and toolchain read-only, writes allowed only in DIR,
and limits of 2 CPUs, --memory (default 1g), 256 processes, 256 MiB per file,
1024 open files and --timeout seconds of wall clock (default 120, max 600).
DIR must be <output-dir>/agents/<agent-id>/scratch.
EOF
  exit 2
}

die() {
  echo "sandbox-run: $*" >&2
  exit 2
}

scratch=""
timeout_s=120
memory=1g
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch) scratch="${2:-}"; shift 2 ;;
    --timeout) timeout_s="${2:-}"; shift 2 ;;
    --memory) memory="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -h | --help) usage ;;
    *) die "unknown option $1" ;;
  esac
done
[[ $# -gt 0 ]] || usage
if ! [[ "$timeout_s" =~ ^[0-9]{1,4}$ ]] || ((10#$timeout_s < 1 || 10#$timeout_s > max_timeout)); then
  die "--timeout must be 1-$max_timeout seconds"
fi
timeout_s=$((10#$timeout_s))
[[ "$memory" =~ ^([0-9]{1,5})([mg])$ ]] || die "--memory must look like 512m or 2g"
memory_mib=$((10#${BASH_REMATCH[1]}))
if [[ "${BASH_REMATCH[2]}" == g ]]; then memory_mib=$((memory_mib * 1024)); fi
if ((memory_mib < 64 || memory_mib > 4096)); then die "--memory must be between 64m and 4g"; fi
memory="${memory_mib}m"

[[ "$scratch" == /* ]] || die "--scratch must be an absolute path"
[[ -d "$scratch" && ! -L "$scratch" ]] || die "--scratch $scratch is not a real directory"
agents_root="$(cd "$SANDBOX_AGENTS_ROOT" && pwd -P)"
real_scratch="$(cd "$scratch" && pwd -P)"
[[ "$real_scratch" == "${scratch%/}" ]] || die "--scratch must not contain symlinks"
agent_id="${real_scratch#"$agents_root"/}"
agent_id="${agent_id%/scratch}"
[[ "$real_scratch" == "$agents_root/$agent_id/scratch" && "$agent_id" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] \
  || die "--scratch must be $agents_root/<agent-id>/scratch"
for dir in "$real_scratch/.home" "$real_scratch/.tmp"; do
  [[ ! -L "$dir" ]] || die "$dir is a symlink"
  [[ -d "$dir" ]] || mkdir "$dir"
done

mounts=(
  --volume /usr:/usr:ro
  --volume /etc/ld.so.cache:/etc/ld.so.cache:ro
  --volume "$SANDBOX_TARGET:$SANDBOX_TARGET:ro"
  --volume "$real_scratch:$real_scratch:rw"
)
if [[ -d "$SANDBOX_TARGET/.git" ]]; then
  mounts+=(--mount "type=tmpfs,destination=$SANDBOX_TARGET/.git,tmpfs-size=1m,tmpfs-mode=0555")
fi
for dir in /etc/alternatives "$tool_cache" "$deps_dir"; do
  if [[ -n "$dir" && -d "$dir" ]]; then mounts+=(--volume "$dir:$dir:ro"); fi
done

env_args=(
  --env "PATH=$SANDBOX_PATH"
  --env "HOME=$real_scratch/.home"
  --env "TMPDIR=$real_scratch/.tmp"
  --env "XDG_CACHE_HOME=$real_scratch/.home/.cache"
  --env "npm_config_cache=$real_scratch/.home/.npm"
  --env "npm_config_offline=true"
  --env "PIP_NO_INDEX=1"
  --env "PYTHONDONTWRITEBYTECODE=1"
  --env "GOCACHE=$real_scratch/.home/.cache/go-build"
  --env "GOPROXY=off"
  --env "GOTOOLCHAIN=local"
  --env "GOFLAGS=-mod=mod"
  --env "LANG=C.UTF-8"
  --env "CI=true"
)
if [[ -n "$deps_dir" && -d "$deps_dir/gomod" ]]; then env_args+=(--env "GOMODCACHE=$deps_dir/gomod"); fi
if [[ -n "$deps_dir" && -d "$deps_dir/venv" ]]; then env_args+=(--env "VIRTUAL_ENV=$deps_dir/venv"); fi

name="security-audit-sandbox-$agent_id-$$-$RANDOM"
status=0
timeout --kill-after=10 "$((timeout_s + 30))" \
  docker run --rm --init --name "$name" \
  --label "security-audit.scratch=$real_scratch" \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --cpus 2 \
  --memory "$memory" --memory-swap "$memory" \
  --pids-limit 256 \
  --ulimit fsize=268435456:268435456 \
  --ulimit nofile=1024:1024 \
  --ulimit core=0 \
  --user "$(id -u):$(id -g)" \
  --workdir "$real_scratch" \
  "${mounts[@]}" \
  "${env_args[@]}" \
  "$SANDBOX_IMAGE" \
  /usr/bin/timeout --kill-after=5 "$timeout_s" "$@" </dev/null || status=$?
docker rm --force "$name" >/dev/null 2>&1 || true
exit "$status"
