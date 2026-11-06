# Copilot security audit

A GitHub Action that runs Cloudflare's [security-audit skill](https://github.com/cloudflare/security-audit-skill) with GitHub Copilot CLI on every push and fails the check when it confirms a high or critical vulnerability.

## Setup

1. Copy [`examples/security-audit.yml`](examples/security-audit.yml) to `.github/workflows/security-audit.yml` in the repository to audit.
2. Push the file.

The workflow signs in to Copilot with the job's `GITHUB_TOKEN`; no secret is needed. In a personal repository, usage counts against the owner's Copilot plan. In an organization repository, an owner enables **Allow use of Copilot CLI billed to the organization** under the organization's Copilot policies.

## What runs when

| Event | Audit | Skill profile | Default AI credit cap |
| --- | --- | --- | --- |
| `push` | Files changed since the previous push | `quick`, scoped to the diff | 300 (3 USD) |
| `schedule` (Mondays 03:17 UTC) | Whole repository | `standard` | 2000 (20 USD) |
| `workflow_dispatch` | Whole repository | `standard` | 2000 (20 USD) |

On a small Express app, a sandboxed diff audit of a three-file push used 131 AI credits (1.31 USD) in 7 minutes, and a full audit used 184 AI credits (1.84 USD) in 10 minutes.

A push that only deletes files skips the audit. A push to a new branch audits the commits since it left the default branch.

Push runs report on the pushed commit, and their checks also appear on pull requests from branches in the same repository. Pull requests from forks are not audited.

The latest successful full audit is cached and passed to later runs as a prior run, so each run checks what changed and the gaps the last one left.

## Results

- **Check status:** fails when a confirmed finding is at or above `fail-on`, or when the audit ends without a valid `findings.json`.
- **Annotations:** each confirmed finding appears on its file and line; findings that need validation appear as notices.
- **Job summary:** a findings table, the Copilot usage and `REPORT.md`.
- **Artifact:** `security-audit-<run>` holds `findings.json`, `REPORT.md`, `FINDINGS-DETAIL.md`, `NEEDS-VALIDATION.md`, the coverage ledger, the Copilot session log and the evidence files in `agents/<id>/artifacts/`, kept for 30 days.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `mode` | `auto` | `auto`, `diff` or `full`. `auto` audits the diff on pushes and the whole repository on `schedule` and `workflow_dispatch`. |
| `fail-on` | `high` | Lowest confirmed severity that fails the check: `critical`, `high`, `medium`, `low`, `informational` or `none`. |
| `model` | Copilot default | Copilot model ID from `copilot --model`. |
| `reasoning-effort` | `high` | `low`, `medium`, `high`, `xhigh` or `max`. |
| `diff-max-ai-credits` | `300` | AI credit cap for a diff audit. |
| `full-max-ai-credits` | `2000` | AI credit cap for a full audit. |
| `skill-ref` | pinned commit | Commit of `cloudflare/security-audit-skill` to run. |
| `copilot-version` | `latest` | `@github/copilot` npm version. |
| `sandbox` | `true` | `true` runs target code in a Docker sandbox for findings that need execution; `false` reads source only. |
| `install-command` | `auto` | `auto` installs dependencies from the root lockfile: `pnpm-lock.yaml`, `yarn.lock`, `bun.lock` or `bun.lockb`, `package-lock.json` or `npm-shrinkwrap.json`, `requirements.txt` or `go.mod`. `none` skips the install. Any other value is the install command, run in the install container. |
| `github-token` | `github.token` | Token with the `copilot-requests` permission. A fine-grained personal access token with the **Copilot Requests** permission also works. |

## Outputs

| Output | Value |
| --- | --- |
| `mode` | `diff`, `full` or `skipped` |
| `confirmed` | Number of confirmed findings |
| `failing` | Number of confirmed findings at or above `fail-on` |
| `highest-severity` | Highest confirmed severity, or `none` |
| `report-dir` | Directory with the run's report files |

## Sandbox

Before the audit, the action copies the repository's tracked files, without `.git`, to a separate directory and installs dependencies there. The install runs in a container with network access and the dependencies' install scripts, without the job's tokens, environment or home directory. The install container gets 2 CPUs, 4 GB of memory, 1024 processes, 1 GB per file and 15 minutes. The checked-out repository stays unchanged.

The Copilot agent runs target code only through the `sandbox-run` command, a fresh Docker container for each command:

| Resource | Limit |
| --- | --- |
| Network | None except loopback |
| Environment | Empty |
| Files | Copy of the repository's tracked files with installed dependencies, and the toolchain, read-only; writes only to the agent's scratch directory |
| CPU | 2 CPUs |
| Memory | 1 GB by default, 4 GB max |
| Processes | 256 |
| File size | 256 MiB per file |
| Open files | 1024 |
| Scratch disk | 2 GB, shared by all agents |
| Time | 120 s per command by default, 600 s max |

The `sandbox-promote` command copies evidence files out of scratch into the report after the container exits, following the skill's artifact promotion procedure. Scratch directories are deleted before the report is uploaded or cached; a scratch directory that cannot be deleted is left out of the upload and stops the cache save.

The sandbox needs an Ubuntu runner with Docker and passwordless sudo; GitHub-hosted `ubuntu-*` runners have both. On other runners the audit reads source only and logs a warning.

## Limits

- The sandbox binds target code, not the Copilot agent. The agent itself has a shell on the runner, and the prompt, not the operating system, keeps it from running target code outside `sandbox-run`. That shell has no GitHub or Copilot tokens.
- Dependency install scripts run with network access, as in any CI install. `install-command: none` turns the install off, and the sandbox then runs without the target's dependencies.
- The Copilot agent runs without the repository's agent instruction files, without GitHub's built-in MCP servers and without the GitHub token in its shell. URL access is never pre-approved, so the unattended run denies it.
- A run that reaches its AI credit cap stops before writing `findings.json` and fails the check. A higher cap or a smaller push fixes it.
