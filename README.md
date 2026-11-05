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

A push that only deletes files skips the audit. A push to a new branch audits the commits since it left the default branch.

The latest successful full audit is cached and passed to later runs as a prior run, so each run checks what changed and the gaps the last one left.

## Results

- **Check status:** fails when a confirmed finding is at or above `fail-on`, or when the audit ends without a valid `findings.json`.
- **Annotations:** each confirmed finding appears on its file and line; findings that need validation appear as notices.
- **Job summary:** a findings table, the Copilot usage and `REPORT.md`.
- **Artifact:** `security-audit-<run>` holds `findings.json`, `REPORT.md`, `FINDINGS-DETAIL.md`, `NEEDS-VALIDATION.md`, the coverage ledger and the Copilot session log, kept for 30 days.

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
| `github-token` | `github.token` | Token with the `copilot-requests` permission. A fine-grained personal access token with the **Copilot Requests** permission also works. |

## Outputs

| Output | Value |
| --- | --- |
| `mode` | `diff`, `full` or `skipped` |
| `confirmed` | Number of confirmed findings |
| `failing` | Number of confirmed findings at or above `fail-on` |
| `highest-severity` | Highest confirmed severity, or `none` |
| `report-dir` | Directory with the run's report files |

## Limits

- The audit reads source only. The runner has no sandbox for the repository's own code, so the skill never builds, tests or runs it, and leads that need execution stay `needs_validation`.
- The Copilot agent runs without the repository's agent instruction files, without GitHub's built-in MCP servers and without the GitHub token in its shell. URL access is never pre-approved, so the unattended run denies it.
- A run that reaches its AI credit cap stops before writing `findings.json` and fails the check. A higher cap or a smaller push fixes it.
