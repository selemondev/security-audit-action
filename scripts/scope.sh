#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_OUTPUT:?}" "${RUNNER_TEMP:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"
input_mode="${INPUT_MODE:-auto}"
event_name="${EVENT_NAME:-}"
before_sha="${BEFORE_SHA:-}"
pr_base_sha="${PR_BASE_SHA:-}"
default_branch="${DEFAULT_BRANCH:-}"
empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904

repo_name="${GITHUB_REPOSITORY#*/}"
runs_root="$RUNNER_TEMP/security-audit-runs/$repo_name"
run_dir="$runs_root/run-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}"
log_dir="$RUNNER_TEMP/security-audit-logs"
changed_files="$log_dir/changed-files.txt"
mkdir -p "$log_dir"

emit() { printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; }

is_commit() { [[ -n "$1" ]] && git cat-file -e "$1^{commit}" 2>/dev/null; }

case "$input_mode" in
  auto)
    case "$event_name" in
      schedule | workflow_dispatch) mode="full" ;;
      *) mode="diff" ;;
    esac
    ;;
  diff | full) mode="$input_mode" ;;
  *)
    echo "::error title=security-audit::mode must be auto, diff or full, got '$input_mode'"
    exit 1
    ;;
esac

if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
  echo "::error title=security-audit::The checkout is shallow. Set fetch-depth: 0 on actions/checkout."
  exit 1
fi

head_sha="$(git rev-parse HEAD)"
base=""

if [[ "$mode" == "diff" ]]; then
  if is_commit "$pr_base_sha"; then
    base="$pr_base_sha"
  elif [[ "$before_sha" =~ ^0+$ ]] || ! is_commit "$before_sha"; then
    if [[ -n "$default_branch" ]] && is_commit "origin/$default_branch" \
      && [[ "$(git rev-parse "origin/$default_branch")" != "$head_sha" ]]; then
      base="$(git merge-base HEAD "origin/$default_branch")"
    elif is_commit HEAD^; then
      base="$(git rev-parse HEAD^)"
    else
      base="$empty_tree"
    fi
  else
    base="$before_sha"
  fi

  git diff --name-only --diff-filter=ACMRT "$base" HEAD >"$changed_files"
  count="$(grep -c . "$changed_files" || true)"
  if [[ "$count" -eq 0 ]]; then
    echo "No added or modified files between ${base:0:12} and ${head_sha:0:12}; skipping the audit."
    {
      echo "## Security audit"
      echo
      echo "Skipped: no added or modified files between \`${base:0:12}\` and \`${head_sha:0:12}\`."
    } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
    emit mode skipped
    exit 0
  fi
  echo "Diff audit of $count files: ${base:0:12}..${head_sha:0:12}"
else
  : >"$changed_files"
  echo "Full audit of ${head_sha:0:12}"
fi

emit mode "$mode"
emit base "$base"
emit changed-files "$changed_files"
emit runs-root "$runs_root"
emit run-dir "$run_dir"
emit log-dir "$log_dir"
