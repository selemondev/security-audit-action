import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { annotation, evaluate, location } from "../scripts/report.mjs";

const reportScript = fileURLToPath(new URL("../scripts/report.mjs", import.meta.url));
const skillDir = process.env.SKILL_DIR;

function confirmed(severity, fingerprint = `finding-${severity}`) {
  return {
    verdict: "confirmed",
    fingerprint,
    title: `Missing ownership check (${severity})`,
    description: "An attacker can reach an operation without the intended ownership check.",
    root_cause: "handle omits the ownership check before changing the object.",
    intended_behavior: "Only the object's owner can change it.",
    trace: [
      { kind: "entrypoint", file: "src/handler.ts", line: 10, scope: "handle", description: "Attacker data enters." },
      { kind: "sink", file: "src/store.ts", line: 30, scope: "save", description: "The object changes." },
    ],
    evidence: [{ file: "src/handler.ts", line: 10, description: "No ownership check." }],
    conditions: [],
    execution: {
      attacker_perspective: "An unprivileged remote user with their own account.",
      payloads: ["An object identifier owned by another user."],
      instructions: ["Submit the identifier through the public operation."],
      observed_result: "The other user's object changes.",
    },
    remediation: { strategy: "Check ownership before the state change." },
    severity: {
      likelihood: { score: severity, reason: "The operation is directly reachable." },
      impact: { score: severity, reason: "The attacker changes one protected object." },
      overall_severity: severity,
    },
    confidence: { score: "high", reason: "The source path was traced." },
  };
}

const needsValidation = {
  verdict: "needs_validation",
  fingerprint: "parser-size",
  title: "Unchecked parsed size",
  description: "A parsed size may reach an allocation without a limit.",
  claimed_root_cause: "parse_size may pass an unbounded value to allocate.",
  trace: [{ kind: "entrypoint", file: "src/parse.ts", line: 4, scope: "parse", description: "Size is read." }],
  evidence: [{ file: "src/parse.ts", line: 4, description: "No upper bound." }],
  blockers: ["The generated parser source is absent from this checkout."],
  validation_plan: {
    local: "Generate the parser and submit the smallest input that exceeds the documented limit.",
    deployment: "In an approved test deployment, confirm the request reaches the parser.",
  },
};

test("fail-on high fails high and critical findings only", () => {
  const result = evaluate([confirmed("medium"), confirmed("critical"), confirmed("high"), needsValidation], "high");
  assert.deepEqual(
    result.failing.map((item) => item.severity),
    ["critical", "high"],
  );
  assert.equal(result.confirmed.length, 3);
  assert.equal(result.needsValidation.length, 1);
  assert.equal(result.highest, "critical");
});

test("fail-on none never fails and no findings report none", () => {
  assert.equal(evaluate([confirmed("critical")], "none").failing.length, 0);
  assert.equal(evaluate([needsValidation], "low").highest, "none");
});

test("an unknown fail-on value is rejected", () => {
  assert.throws(() => evaluate([], "severe"), /fail-on must be one of/);
});

test("location points at the sink step", () => {
  assert.deepEqual(location(confirmed("high")), { file: "src/store.ts", line: 30 });
  assert.deepEqual(location(needsValidation), { file: "src/parse.ts", line: 4 });
});

test("annotations escape workflow command delimiters", () => {
  const line = annotation(
    "error",
    { title: "a,b:c", description: "line1\nline2 100%", trace: [{ kind: "sink", file: "/w/src/x.ts", line: 3 }] },
    "/w",
  );
  assert.equal(line, "::error file=src/x.ts,line=3,title=a%2Cb%3Ac::line1%0Aline2 100%25");
});

function runReport(findings, failOn, { ledger = [] } = {}) {
  assert.ok(skillDir, "SKILL_DIR must point at the security-audit skill directory");
  const dir = mkdtempSync(path.join(os.tmpdir(), "security-audit-report-"));
  try {
    if (findings !== undefined) writeFileSync(path.join(dir, "findings.json"), JSON.stringify(findings));
    if (ledger !== undefined) writeFileSync(path.join(dir, "coverage-ledger.json"), JSON.stringify(ledger));
    writeFileSync(path.join(dir, "run-metadata.json"), JSON.stringify({ run_status: "complete" }));
    writeFileSync(path.join(dir, "REPORT.md"), "# Report\n");
    writeFileSync(path.join(dir, "summary.md"), "");
    writeFileSync(path.join(dir, "output.txt"), "");
    const result = spawnSync(process.execPath, [reportScript], {
      encoding: "utf8",
      env: {
        PATH: process.env.PATH,
        RUN_DIR: dir,
        SKILL_DIR: skillDir,
        FAIL_ON: failOn,
        MODE: "diff",
        BASE_SHA: "0123456789abcdef",
        GITHUB_WORKSPACE: dir,
        GITHUB_STEP_SUMMARY: path.join(dir, "summary.md"),
        GITHUB_OUTPUT: path.join(dir, "output.txt"),
      },
    });
    return {
      status: result.status,
      stdout: result.stdout,
      summary: readFileSync(path.join(dir, "summary.md"), "utf8"),
      output: readFileSync(path.join(dir, "output.txt"), "utf8"),
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("a confirmed high finding fails the check with an error annotation", () => {
  const run = runReport([confirmed("high"), needsValidation], "high");
  assert.equal(run.status, 1, run.stdout);
  assert.match(run.stdout, /::error file=src\/store.ts,line=30,title=\[high\] Missing ownership check/);
  assert.match(run.stdout, /::notice file=src\/parse.ts,line=4,title=\[needs validation\]/);
  assert.match(run.output, /^confirmed=1$/m);
  assert.match(run.output, /^failing=1$/m);
  assert.match(run.output, /^highest-severity=high$/m);
  assert.match(run.summary, /\| high \| Missing ownership check \(high\) \| src\/store.ts:30 \|/);
});

test("findings below fail-on pass the check as warnings", () => {
  const run = runReport([confirmed("high")], "critical");
  assert.equal(run.status, 0, run.stdout);
  assert.match(run.stdout, /::warning file=src\/store.ts/);
  assert.match(run.output, /^failing=0$/m);
});

test("a missing findings.json fails the check", () => {
  const run = runReport(undefined, "high");
  assert.equal(run.status, 1);
  assert.match(run.stdout, /::error title=Security audit did not finish::The audit did not write/);
});

test("a findings.json that breaks the schema fails the check", () => {
  const broken = confirmed("high");
  delete broken.severity;
  const run = runReport([broken], "none");
  assert.equal(run.status, 1);
  assert.match(run.stdout, /findings.json failed validation/);
});
