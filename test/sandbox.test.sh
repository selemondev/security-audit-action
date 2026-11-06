#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?}"
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d "$RUNNER_TEMP/sandbox-test.XXXXXX")"
failures=0

pass() { echo "ok - $1"; }
fail() {
  echo "not ok - $1"
  failures=$((failures + 1))
}
expect_status() {
  local want="$1" name="$2" got=0
  shift 2
  "$@" >"$work/out" 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then pass "$name"; else
    fail "$name (exit $got, wanted $want)"
    cat "$work/out"
  fi
}
expect_failure() {
  local name="$1" got=0
  shift
  "$@" >"$work/out" 2>&1 || got=$?
  if grep -q "Error response from daemon" "$work/out"; then
    fail "$name (the container did not start)"
    cat "$work/out"
  elif [[ "$got" -ne 0 ]]; then pass "$name"; else
    fail "$name (exit 0)"
    cat "$work/out"
  fi
}

target="$work/target"
cp -R "$repo/test/fixtures/npm-app" "$target"
git -C "$target" init --quiet
git -C "$target" -c user.name=t -c user.email=t@example.com add .
git -C "$target" -c user.name=t -c user.email=t@example.com commit --quiet -m fixture
git -C "$target" config http.https://github.com/.extraheader "AUTHORIZATION: basic c2VjcmV0"
git init --quiet "$target/lib"
git -C "$target/lib" config http.https://github.com/.extraheader "AUTHORIZATION: basic c2VjcmV0"
echo '{"token":"secret"}' >"$target/gha-creds-test.json"

export GITHUB_OUTPUT="$work/prepare-output" GITHUB_WORKSPACE="$target"
"$repo/scripts/prepare-sandbox.sh"
output() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT"; }
if [[ "$(output available)" != true ]]; then
  echo "prepare-sandbox reported no sandbox: $(output reason)"
  exit 1
fi
export SANDBOX_IMAGE SANDBOX_PATH SANDBOX_DEPS_DIR SANDBOX_TOOL_CACHE SANDBOX_TARGET_SOURCE
SANDBOX_IMAGE="$(output image)"
SANDBOX_PATH="$(output path)"
SANDBOX_DEPS_DIR="$(output deps-dir)"
SANDBOX_TOOL_CACHE="$(output tool-cache)"
SANDBOX_TARGET_SOURCE="$(output target-source)"

export SECRET_PROBE=leaked
GITHUB_ACTION_PATH="$repo" DEPS_DIR="$SANDBOX_DEPS_DIR" "$repo/scripts/install-deps.sh"

probe="$SANDBOX_TARGET_SOURCE/install-probe.json"
if [[ -f "$SANDBOX_TARGET_SOURCE/node_modules/ms/package.json" ]]; then pass "install-deps installs the lockfile"; else fail "install-deps installs the lockfile"; fi
if [[ -f "$probe" ]]; then
  if grep -q SECRET_PROBE "$probe"; then fail "install env excludes host variables"; else pass "install env excludes host variables"; fi
  if grep -q '"credentials":\[\]' "$probe"; then pass "install sees no .git or credential files"; else
    fail "install sees no .git or credential files"
    cat "$probe"
  fi
else
  fail "postinstall ran inside the install container"
fi
if [[ ! -e "$target/node_modules" && ! -e "$target/install-probe.json" && "$(cat "$target/tracked.txt")" == original ]]; then
  pass "checked-out repository unchanged by install"
else
  fail "checked-out repository unchanged by install"
fi

run_dir="$work/run"
export SANDBOX_TARGET="$target" SANDBOX_AGENTS_ROOT="$run_dir/agents"
mkdir -p "$SANDBOX_AGENTS_ROOT"
sudo -n mount -t tmpfs -o "size=600m,mode=0755,uid=$(id -u),gid=$(id -g)" security-audit-scratch "$SANDBOX_AGENTS_ROOT"
scratch="$SANDBOX_AGENTS_ROOT/probe/scratch"
mkdir -p "$scratch"
sandbox=("$repo/scripts/sandbox-run.sh" --scratch "$scratch" --timeout 60 --)

expect_status 0 "target dependencies load read-only" "${sandbox[@]}" node -e "require('$target/node_modules/ms')"
# shellcheck disable=SC2016
expect_status 0 "host variables are absent" "${sandbox[@]}" sh -c '[ -z "${SECRET_PROBE:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]'
expect_status 0 ".git and untracked credentials are absent" "${sandbox[@]}" sh -c "[ ! -e '$target/.git' ] && [ ! -e '$target/lib/.git/config' ] && [ ! -e '$target/gha-creds-test.json' ]"
expect_failure "target is read-only" "${sandbox[@]}" touch "$target/written"
expect_failure "toolchain is read-only" "${sandbox[@]}" touch /usr/written
expect_failure "root filesystem is read-only" "${sandbox[@]}" touch /written
expect_failure "external network is blocked" "${sandbox[@]}" node -e "fetch('https://registry.npmjs.org/').then(() => process.exit(0), () => process.exit(3))"
expect_status 0 "loopback works" "${sandbox[@]}" node -e "
const http = require('node:http');
const server = http.createServer((req, res) => res.end('pong')).listen(0, '127.0.0.1', async () => {
  const body = await (await fetch('http://127.0.0.1:' + server.address().port)).text();
  server.close();
  process.exit(body === 'pong' ? 0 : 1);
});"
expect_failure "per-file size limit" "${sandbox[@]}" dd if=/dev/zero of=big bs=1M count=300 status=none
rm -f "$scratch/big"
expect_status 0 "scratch disk fills to its cap" "${sandbox[@]}" sh -c 'dd if=/dev/zero of=fill1 bs=1M count=230 status=none && dd if=/dev/zero of=fill2 bs=1M count=230 status=none'
expect_failure "scratch disk limit" "${sandbox[@]}" dd if=/dev/zero of=fill3 bs=1M count=230 status=none
rm -f "$scratch"/fill*

start=$SECONDS
expect_status 124 "wall-clock timeout" "$repo/scripts/sandbox-run.sh" --scratch "$scratch" --timeout 2 -- sleep 60
if ((SECONDS - start < 30)); then pass "timeout returns promptly"; else fail "timeout returns promptly ($((SECONDS - start)) s)"; fi

expect_failure "scratch outside agents root is refused" "$repo/scripts/sandbox-run.sh" --scratch "$work" -- true
ln -s "$scratch" "$SANDBOX_AGENTS_ROOT/link"
expect_failure "symlinked scratch is refused" "$repo/scripts/sandbox-run.sh" --scratch "$SANDBOX_AGENTS_ROOT/link" -- true

expect_status 0 "scratch is writable" "${sandbox[@]}" sh -c 'echo evidence > out.txt'
"$repo/scripts/sandbox-run.sh" --scratch "$scratch" --timeout 60 -- sleep 30 &
runner_pid=$!
for _ in $(seq 1 30); do
  if [[ -n "$(docker ps --quiet --filter "label=security-audit.scratch=$scratch")" ]]; then break; fi
  sleep 1
done
expect_failure "promotion waits for the sandbox to exit" "$repo/scripts/sandbox-promote.py" --agent probe --max-total 100 out.txt:100
docker ps --quiet --filter "label=security-audit.scratch=$scratch" | xargs -r docker rm --force >/dev/null
wait "$runner_pid" || true
expect_status 0 "promotion copies evidence" "$repo/scripts/sandbox-promote.py" --agent probe --max-total 100 out.txt:100
if [[ "$(cat "$SANDBOX_AGENTS_ROOT/probe/artifacts/out.txt" 2>/dev/null)" == evidence ]]; then pass "promoted bytes match"; else fail "promoted bytes match"; fi

victim="$work/victim"
echo keep >"$victim"
chmod 0400 "$victim"
expect_status 0 "target code can lock its scratch" "${sandbox[@]}" sh -c "mkdir -p deep && ln -s /proc/self/environ deep/env && ln -s '$victim' leak && chmod 0555 deep ."
expect_status 0 "discard removes a locked scratch" env RUN_DIR="$run_dir" "$repo/scripts/discard-scratch.sh"
if [[ ! -e "$scratch" && -f "$SANDBOX_AGENTS_ROOT/probe/artifacts/out.txt" ]]; then pass "discard keeps artifacts and removes scratch"; else fail "discard keeps artifacts and removes scratch"; fi
if [[ "$(stat -c %a "$victim")" == 400 && "$(cat "$victim")" == keep ]]; then pass "discard does not follow symlinks"; else fail "discard does not follow symlinks"; fi

sudo -n umount "$SANDBOX_AGENTS_ROOT"
echo "$failures failures"
[[ "$failures" -eq 0 ]]
