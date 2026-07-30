#!/usr/bin/env node
// Circuit MCP server — exposes Circuit's code-grading engine over MCP stdio.
//
// Backed by the Node modules directly (../lib/report.js, ../lib/analyze.js), NOT by
// Circuit's HTTP server. The HTTP server is pinned to a single repo at process start;
// calling the modules lets every tool call target a different tree. Nothing here binds
// or contacts a port, so :8923 (the hands-off live instance) is untouched.
//
// Both tools are READ-ONLY:
//   - sarifPath is hard-forced to null; a caller-supplied write path is refused.
//   - No file is created, modified or deleted by either tool.
// Neither tool is gated, because neither has a side effect to gate.
//
// The work is CPU-bound and fully synchronous (fs.readFileSync + parsing), so the
// server serializes calls: concurrency 1, generous per-call timeout.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { createServer, ToolError, emptyResult } from "./mcp-kit.mjs";
import { meetsMinGrade, GRADE_ORDER } from "../lib/report.js";
import { analyzeRepo } from "../lib/analyze.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, "..");

// Analyses of a large tree can run for minutes. 10 minutes is deliberately generous;
// the handler is synchronous, so this is a ceiling on the reported call, not a preemption.
const ANALYSIS_TIMEOUT_MS = 600_000;

// ---------------------------------------------------------------------------
// Concurrency cap = 1
// ---------------------------------------------------------------------------
// analyzeRepo() walks the tree and parses every file synchronously. Running two at
// once buys nothing (one blocks the other on the event loop) and doubles peak RSS.
// Every call is queued behind the previous one and reports how long it waited.

const CONCURRENCY_LIMIT = 1;

let chain = Promise.resolve();
let inFlight = 0;
let queued = 0;
let maxObservedInFlight = 0;

function serialize(label, fn) {
  queued++;
  const enqueuedAt = Date.now();
  const run = chain.then(async () => {
    queued--;
    inFlight++;
    if (inFlight > maxObservedInFlight) maxObservedInFlight = inFlight;
    const inFlightDuringCall = inFlight;
    const queuedBehind = queued;
    const waitedMs = Date.now() - enqueuedAt;
    const startedAt = Date.now();
    try {
      const value = await fn();
      return {
        value,
        waitedMs,
        tookMs: Date.now() - startedAt,
        inFlightDuringCall,
        queuedBehind,
        maxObservedInFlight,
      };
    } finally {
      inFlight--;
    }
  });
  // Keep the chain alive even when this call rejects, so one failure cannot wedge the lane.
  chain = run.then(
    () => undefined,
    () => undefined
  );
  return run;
}

/** Observable proof that the cap held: in_flight must never exceed the limit. */
function laneReport(lane) {
  return {
    limit: CONCURRENCY_LIMIT,
    in_flight_during_this_call: lane.inFlightDuringCall,
    queued_behind_this_call: lane.queuedBehind,
    max_in_flight_observed_since_start: lane.maxObservedInFlight,
  };
}

// ---------------------------------------------------------------------------
// Input handling
// ---------------------------------------------------------------------------

/** Refuse any caller-supplied output path. Circuit's MCP surface never writes. */
const WRITE_PATH_KEYS = ["sarif_path", "sarifPath", "sarif", "out", "output", "output_path", "outPath", "write_to"];

function refuseWritePaths(args) {
  for (const key of WRITE_PATH_KEYS) {
    if (args && Object.prototype.hasOwnProperty.call(args, key) && args[key] !== undefined && args[key] !== null) {
      throw new ToolError(
        `"${key}" is not accepted. This Circuit MCP surface is read-only: SARIF output is forced off (sarifPath=null) ` +
          `and no tool here will write to a caller-supplied path. Use Circuit's CLI if you need a SARIF file on disk.`,
        { code: "WRITE_PATH_REFUSED", details: { rejected_argument: key } }
      );
    }
  }
}

/** Resolve a caller-supplied root into a real, existing directory or throw the real reason. */
function resolveRoot(root) {
  if (typeof root !== "string" || !root.trim()) {
    throw new ToolError(`"root" must be a non-empty path to a directory to analyze. Received: ${JSON.stringify(root)}`, {
      code: "ROOT_INVALID",
    });
  }
  let candidate = root.trim();
  if (candidate === "~") candidate = os.homedir();
  else if (candidate.startsWith("~/")) candidate = path.join(os.homedir(), candidate.slice(2));
  // A relative root would be resolved against this process's cwd, which is chosen by whichever
  // client spawned the server — the same argument would then grade different trees in different
  // clients, and the resolved path of an unrelated directory would surface in the error text.
  // The schema already promises "absolute (or ~-relative)"; enforce it instead of guessing.
  if (!path.isAbsolute(candidate)) {
    throw new ToolError(
      `"root" must be an absolute path, or start with "~/". Received a relative path: ${JSON.stringify(root)}. ` +
        `A relative path would be resolved against this server process's working directory, which the caller does not control.`,
      { code: "ROOT_NOT_ABSOLUTE" }
    );
  }
  const abs = path.resolve(candidate);
  let st;
  try {
    st = fs.statSync(abs);
  } catch (err) {
    throw new ToolError(`Cannot analyze "${abs}": ${err?.code || err?.message || "stat failed"}.`, {
      code: "ROOT_UNREADABLE",
      details: { resolved_root: abs },
    });
  }
  if (!st.isDirectory()) {
    throw new ToolError(`"${abs}" is not a directory. Circuit grades a directory tree, not a single file.`, {
      code: "ROOT_NOT_A_DIRECTORY",
      details: { resolved_root: abs },
    });
  }
  return abs;
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

const gradeRepo = {
  name: "circuit__grade_repo",
  description:
    "Grade a directory tree with Circuit's analyzer and return the repo letter grade, weighted score and stats " +
    "(file count, LOC, edges, broken edges, cycles, grade histogram, language mix, parse errors, skipped files). " +
    "Optionally pass min_grade to also get a pass/fail against a threshold. Read-only: never writes SARIF or any other file.",
  inputSchema: {
    type: "object",
    properties: {
      root: {
        type: "string",
        description: "Absolute (or ~-relative) path to the directory tree to grade.",
      },
      min_grade: {
        type: "string",
        enum: GRADE_ORDER,
        description:
          "Optional threshold. When set, the result includes pass (true/false) and the exit code Circuit's CI check would use. " +
          "A tree with no gradeable source never satisfies a threshold.",
      },
    },
    required: ["root"],
  },
  timeoutMs: ANALYSIS_TIMEOUT_MS,
  async handler(args) {
    refuseWritePaths(args);
    const abs = resolveRoot(args.root);
    const minGrade = args.min_grade ?? null;

    // This is lib/report.js runCheck() minus its SARIF branch — which is dead here anyway,
    // because sarifPath is forced null (see refuseWritePaths()). Calling analyzeRepo directly
    // is what makes `truncated` reachable: runCheck drops that flag, so grading a tree larger
    // than the walker's file cap would otherwise report a grade over a PARTIAL view of the repo
    // with nothing in the payload saying so. Equivalence with runCheck verified across 28
    // (tree x min_grade) combinations: identical empty/grade/score/pass/exitCode/stats.
    const lane = await serialize("grade_repo", () => analyzeRepo(abs));
    const graph = lane.value;
    const pass = minGrade != null ? meetsMinGrade(graph.stats.grade, minGrade) : null;
    const check = {
      empty: graph.stats.empty,
      grade: graph.stats.grade,
      score: graph.stats.score,
      pass,
      exitCode: minGrade != null && !pass ? 1 : 0,
      stats: graph.stats,
    };
    const truncated = graph.truncated === true;

    const meta = {
      tool: "circuit__grade_repo",
      root: abs,
      analysis_ms: lane.tookMs,
      queue_wait_ms: lane.waitedMs,
      concurrency: laneReport(lane),
      sarif: "disabled (sarifPath forced to null; this surface never writes files)",
      // A grade computed over part of a tree must never look like a grade over all of it.
      walk_truncated: truncated,
      ...(truncated
        ? {
            partial_view_warning:
              `This tree has more source files than Circuit's walker will read, so ${graph.stats.files} files were graded ` +
              `and the rest were dropped before analysis. The grade, score and every stat below describe ONLY the files that ` +
              `were read — they are not the grade of the whole tree, and any pass/exit_code below is a pass over a partial view.`,
          }
        : {}),
    };

    if (check.empty) {
      // Circuit reports grade=null for a tree with no gradeable source. That is a real,
      // verified zero — not a failure and not an A+.
      return emptyResult({
        what: "gradeable source files",
        source: `Circuit analyzer over ${abs}`,
        reason:
          "the analyzer walked the tree successfully but found no source file it can grade, so score and grade are null (not zero, not A+)",
        checked: abs,
        ...meta,
        grade: null,
        score: null,
        min_grade: minGrade,
        pass: check.pass,
        exit_code: check.exitCode,
        stats: check.stats,
      });
    }

    return {
      ok: true,
      status: "ok",
      ...meta,
      grade: check.grade,
      score: check.score,
      min_grade: minGrade,
      pass: check.pass,
      exit_code: check.exitCode,
      stats: check.stats,
    };
  },
};

const getGraph = {
  name: "circuit__get_graph",
  description:
    "Return Circuit's dependency graph for a directory tree: nodes (one per source file, with grade, score, LOC, " +
    "fan-in/fan-out, churn, cycle membership and findings) and links (import edges, including broken ones). " +
    "Nodes come back worst-graded first so a truncated view still shows the problems. Read-only.",
  inputSchema: {
    type: "object",
    properties: {
      root: {
        type: "string",
        description: "Absolute (or ~-relative) path to the directory tree to analyze.",
      },
      max_nodes: {
        type: "integer",
        description: "Maximum nodes to return, worst grade first. Default 100. Use 0 for no cap.",
      },
      max_links: {
        type: "integer",
        description: "Maximum links to return, broken edges first. Default 200. Use 0 for no cap.",
      },
      include_findings: {
        type: "boolean",
        description: "Include each node's per-finding detail (dimension, severity, points, message, line). Default true.",
      },
    },
    required: ["root"],
  },
  timeoutMs: ANALYSIS_TIMEOUT_MS,
  async handler(args) {
    refuseWritePaths(args);
    const abs = resolveRoot(args.root);
    const maxNodes = Number.isInteger(args.max_nodes) ? args.max_nodes : 100;
    const maxLinks = Number.isInteger(args.max_links) ? args.max_links : 200;
    const includeFindings = args.include_findings !== false;
    if (maxNodes < 0 || maxLinks < 0) {
      throw new ToolError("max_nodes and max_links must be >= 0 (0 means no cap).", { code: "LIMIT_NEGATIVE" });
    }

    const lane = await serialize("get_graph", () => analyzeRepo(abs));
    const graph = lane.value;

    const meta = {
      tool: "circuit__get_graph",
      root: graph.root,
      name: graph.name,
      analysis_ms: lane.tookMs,
      analyzer_ms: graph.tookMs,
      queue_wait_ms: lane.waitedMs,
      concurrency: laneReport(lane),
      walk_truncated: graph.truncated === true,
    };

    const allNodes = graph.nodes ?? [];
    const allLinks = graph.links ?? [];

    if (graph.stats?.empty) {
      return emptyResult({
        what: "graded graph nodes",
        source: `Circuit analyzer over ${graph.root}`,
        reason:
          "the analyzer walked the tree successfully but found no source file it can grade, so the graph has no real nodes and the repo grade is null",
        checked: graph.root,
        ...meta,
        stats: graph.stats,
        node_count: allNodes.length,
        link_count: allLinks.length,
      });
    }

    // Worst first: lowest score, missing/phantom nodes (score 0) surface immediately.
    const rankedNodes = [...allNodes].sort((a, b) => (a.score ?? 0) - (b.score ?? 0) || String(a.id).localeCompare(String(b.id)));
    const nodes = (maxNodes === 0 ? rankedNodes : rankedNodes.slice(0, maxNodes)).map((n) => {
      const out = {
        id: n.id,
        lang: n.lang,
        grade: n.grade,
        score: n.score,
        loc: n.loc,
        lines: n.lines,
        fanIn: n.fanIn,
        fanOut: n.fanOut,
        churn: n.churn,
        inCycle: n.inCycle,
        missing: n.missing,
        dimensions: n.dimensions,
        findingCount: (n.findings ?? []).length,
      };
      if (includeFindings) out.findings = n.findings ?? [];
      return out;
    });

    // Broken edges first: they are what a caller is usually hunting for.
    const rankedLinks = [...allLinks].sort((a, b) => Number(b.broken === true) - Number(a.broken === true));
    const links = (maxLinks === 0 ? rankedLinks : rankedLinks.slice(0, maxLinks)).map((l) => ({
      source: l.source,
      target: l.target,
      kind: l.kind,
      count: l.count,
      broken: l.broken === true,
      ...(l.ruleViolation ? { ruleViolation: true } : {}),
    }));

    return {
      ok: true,
      status: "ok",
      ...meta,
      stats: graph.stats,
      node_count: allNodes.length,
      link_count: allLinks.length,
      nodes_returned: nodes.length,
      links_returned: links.length,
      nodes_truncated: nodes.length < allNodes.length,
      links_truncated: links.length < allLinks.length,
      node_order: "worst score first",
      link_order: "broken edges first",
      nodes,
      links,
    };
  },
};

// ---------------------------------------------------------------------------

createServer({
  name: "circuit",
  version: "1.0.0",
  tools: [gradeRepo, getGraph],
  timeoutMs: ANALYSIS_TIMEOUT_MS,
  instructions:
    "Circuit grades a codebase and maps its wiring. Both tools take a `root` directory and are read-only — " +
    "they never write SARIF or any other file, and they never bind a port. Analysis is CPU-bound and runs one " +
    "call at a time; a large tree can take a while. Default repo for this server: " +
    REPO_ROOT +
    " (pass it explicitly as `root`).",
});
