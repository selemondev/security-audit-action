import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

export const SEVERITIES = ["informational", "low", "medium", "high", "critical"];
const SUMMARY_LIMIT = 900_000;

export function severityRank(severity) {
  return SEVERITIES.indexOf(severity);
}

export function failThreshold(failOn) {
  if (failOn === "none") return Number.POSITIVE_INFINITY;
  const rank = severityRank(failOn);
  if (rank < 0) {
    throw new Error(`fail-on must be one of ${[...SEVERITIES, "none"].join(", ")}, got "${failOn}"`);
  }
  return rank;
}

export function location(record) {
  const trace = Array.isArray(record.trace) ? record.trace : [];
  const point =
    trace.find((step) => step.kind === "sink") ?? trace[0] ?? (Array.isArray(record.evidence) ? record.evidence[0] : undefined);
  return point ? { file: point.file, line: point.line } : undefined;
}

export function evaluate(findings, failOn) {
  const threshold = failThreshold(failOn);
  const confirmed = findings
    .filter((record) => record.verdict === "confirmed")
    .map((record) => ({ record, severity: record.severity.overall_severity }))
    .sort((a, b) => severityRank(b.severity) - severityRank(a.severity));
  const failing = confirmed.filter((item) => severityRank(item.severity) >= threshold);
  return {
    confirmed,
    failing,
    needsValidation: findings.filter((record) => record.verdict === "needs_validation"),
    rejected: findings.filter((record) => record.verdict === "rejected"),
    highest: confirmed[0]?.severity ?? "none",
  };
}

function escapeData(value) {
  return String(value).replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
}

function escapeProperty(value) {
  return escapeData(value).replace(/:/g, "%3A").replace(/,/g, "%2C");
}

export function annotation(level, record, workspace) {
  const where = location(record);
  const properties = [`title=${escapeProperty(record.title)}`];
  if (where?.file) {
    const file = path.isAbsolute(where.file) ? path.relative(workspace, where.file) : where.file;
    properties.unshift(`file=${escapeProperty(file)}`, `line=${escapeProperty(where.line ?? 1)}`);
  }
  return `::${level} ${properties.join(",")}::${escapeData(record.description)}`;
}

function markdownCell(value) {
  return String(value).replace(/\|/g, "\\|").replace(/\r?\n/g, " ");
}

function readJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function runValidator(skillDir, script, file) {
  try {
    execFileSync(process.execPath, [path.join(skillDir, script), file], { stdio: "pipe", encoding: "utf8" });
    return undefined;
  } catch (error) {
    return `${error.stdout ?? ""}${error.stderr ?? ""}`.trim() || error.message;
  }
}

function setOutput(name, value) {
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
}

function main() {
  const runDir = process.env.RUN_DIR;
  const skillDir = process.env.SKILL_DIR;
  const failOn = process.env.FAIL_ON ?? "high";
  const workspace = process.env.GITHUB_WORKSPACE ?? process.cwd();
  const summaryFile = process.env.GITHUB_STEP_SUMMARY;
  const summary = [];
  const errors = [];

  failThreshold(failOn);

  const findingsFile = path.join(runDir, "findings.json");
  const ledgerFile = path.join(runDir, "coverage-ledger.json");
  const metadataFile = path.join(runDir, "run-metadata.json");
  const reportFile = path.join(runDir, "REPORT.md");

  const metadata = existsSync(metadataFile) ? readJson(metadataFile) : undefined;
  const scope =
    process.env.MODE === "diff"
      ? `diff audit from \`${(process.env.BASE_SHA ?? "").slice(0, 12)}\``
      : "full audit";
  summary.push("## Security audit", "", `Copilot ran a ${scope} with Cloudflare's security-audit skill.`, "");

  if (metadata && metadata.run_status !== "complete") {
    const reason = metadata.incomplete_reason ? ` (${metadata.incomplete_reason})` : "";
    console.log(`::warning title=Security audit incomplete::run_status is ${metadata.run_status}${reason}`);
    summary.push(`**Run status:** ${metadata.run_status}${reason}`, "");
  }

  if (!existsSync(findingsFile)) {
    errors.push(`The audit did not write ${findingsFile}. Check the Copilot session log in the artifact.`);
  } else {
    const findingsError = runValidator(skillDir, "validate-findings.cjs", findingsFile);
    if (findingsError) errors.push(`findings.json failed validation:\n${findingsError}`);
  }
  if (existsSync(ledgerFile)) {
    const ledgerError = runValidator(skillDir, "validate-coverage-ledger.cjs", ledgerFile);
    if (ledgerError) errors.push(`coverage-ledger.json failed validation:\n${ledgerError}`);
  } else {
    errors.push(`The audit did not write ${ledgerFile}.`);
  }

  let result;
  if (errors.length === 0) {
    result = evaluate(readJson(findingsFile), failOn);
    for (const { record, severity } of result.confirmed) {
      const level = severityRank(severity) >= failThreshold(failOn) ? "error" : "warning";
      console.log(annotation(level, { ...record, title: `[${severity}] ${record.title}` }, workspace));
    }
    for (const record of result.needsValidation) {
      console.log(annotation("notice", { ...record, title: `[needs validation] ${record.title}` }, workspace));
    }

    summary.push(
      `| Confirmed | Fails the check (${failOn}+) | Needs validation | Rejected |`,
      "| --- | --- | --- | --- |",
      `| ${result.confirmed.length} | ${result.failing.length} | ${result.needsValidation.length} | ${result.rejected.length} |`,
      "",
    );
    if (result.confirmed.length > 0) {
      summary.push("| Severity | Finding | Location |", "| --- | --- | --- |");
      for (const { record, severity } of result.confirmed) {
        const where = location(record);
        summary.push(
          `| ${severity} | ${markdownCell(record.title)} | ${where ? markdownCell(`${where.file}:${where.line}`) : ""} |`,
        );
      }
      summary.push("");
    }

    setOutput("confirmed", result.confirmed.length);
    setOutput("failing", result.failing.length);
    setOutput("highest-severity", result.highest);
  } else {
    for (const error of errors) console.log(`::error title=Security audit did not finish::${escapeData(error)}`);
    summary.push("**The audit did not produce a valid report.**", "", ...errors.map((error) => `- ${markdownCell(error)}`), "");
  }

  if (process.env.USAGE_FILE && existsSync(process.env.USAGE_FILE)) {
    summary.push("<details><summary>Copilot usage</summary>", "", "```json", readFileSync(process.env.USAGE_FILE, "utf8").trim(), "```", "</details>", "");
  }
  if (existsSync(reportFile)) {
    const report = readFileSync(reportFile, "utf8");
    const used = summary.join("\n").length;
    const room = SUMMARY_LIMIT - used;
    summary.push(
      "<details><summary>REPORT.md</summary>",
      "",
      report.length > room ? `${report.slice(0, room)}\n\n_Truncated. The full report is in the workflow artifact._` : report,
      "",
      "</details>",
    );
  }
  if (summaryFile) appendFileSync(summaryFile, `${summary.join("\n")}\n`);

  if (errors.length > 0) process.exit(1);
  if (result.failing.length > 0) {
    console.log(
      `::error title=Security audit::${result.failing.length} confirmed finding(s) at or above ${failOn}. Highest: ${result.highest}.`,
    );
    process.exit(1);
  }
  console.log(`Confirmed findings: ${result.confirmed.length}. None at or above ${failOn}.`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
