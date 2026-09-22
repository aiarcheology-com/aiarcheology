#!/usr/bin/env python3
"""Join a SlopGuard complexity report with scoped coverage and freeze a cohort.

SlopGuard 0.1.0 falls back from a function match to file coverage, and it
reports 0% when a file is absent. This joiner keeps those cases out of the
score. A method is ranked only when a coverage function's first line falls
inside its SwiftSyntax span. Missing, ambiguous, and file-level matches are
listed separately.

Several suites combine by the highest function coverage percent. That is not a
line-level union: disjoint partial coverage is under-counted, never
double-counted.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


ANALYZER_PIN = "70245e434a271d6ce95a62976d67f7a14f9f298c"
COHORT_FRACTION = 0.15
WARNING_THRESHOLD = 30.0
REVIEW_TARGET = 7.0

NAMED_HOTSPOTS = {
    (
        "ios/MLBrowser/iOS/State/DataController.swift",
        "DataController.handleStoreLoadError(_:description:)",
    ): "persistence-store-recovery",
    (
        "ios/MLBrowser/iOS/State/FindingRepository.swift",
        "FindingRepository.restore(_:)",
    ): "finding-restore",
    (
        "ios/MLBrowser/iOS/State/Downloader.swift",
        "Downloader.reconnectBackgroundSession()",
    ): "background-download-reconnect",
}


@dataclass(frozen=True)
class FunctionCoverage:
    line: int
    executable: int
    covered: int
    percent: float
    suite: str


@dataclass(frozen=True)
class FileCoverage:
    path: str
    executable: int
    covered: int
    functions: tuple[FunctionCoverage, ...]
    suite: str


@dataclass
class Method:
    file: str
    line: int
    end_line: int
    qualified_name: str
    kind: str
    cyclomatic: int
    cognitive: int
    provenance: str = "missing"
    match_quality: str = ""
    coverage_percent: float | None = None
    coverage_suite: str = ""
    weighted_crap: float | None = None
    exclusion_reason: str = ""

    @property
    def identity(self) -> tuple[str, str]:
        return (self.file, self.qualified_name)

    @property
    def area(self) -> str:
        return area_for(self.file)


@dataclass
class SuiteTotals:
    suite: str
    covered: int = 0
    executable: int = 0

    @property
    def percent(self) -> float | None:
        if self.executable <= 0:
            return None
        return 100.0 * self.covered / self.executable


def crap_score(cyclomatic: int, cognitive: int, coverage_percent: float) -> float:
    """Weighted CRAP. Zero cognitive complexity scores 0 even when uncovered."""
    weight = math.sqrt(max(0, cyclomatic) * max(0, cognitive))
    uncovered = 1.0 - max(0.0, min(100.0, coverage_percent)) / 100.0
    return weight * weight * uncovered * uncovered * uncovered + weight


def area_for(path: str) -> str:
    if path.startswith("Sources/"):
        return "Sources"
    if path.startswith("Tools/"):
        return "Tools"
    if path.startswith("scripts/"):
        return "scripts"
    if path.startswith("ios/") and "/UI/" in path:
        return "SwiftUI"
    if path.startswith("ios/"):
        return "ios"
    return "other"


def exclusion_reason_for(path: str) -> str | None:
    """Programs absent from the app/converter/tools coverage products.

    These are not scored as 0%. Reconciliation records them as `excluded` with
    a required reason instead of leaving a fake measured-zero hotspot.
    """
    if path.startswith("scripts/"):
        return "script"
    if path.startswith("Tools/Sources/ProjectTool/"):
        return "ProjectTool executable not in ProjectToolCore tests"
    if path.startswith((
        "Sources/NativeModelConverterCLI/",
        "Sources/NativeModelEvaluatorCLI/",
        "Sources/ADAFDetectorParityRunner/",
    )):
        return "CLI main"
    return None


def is_production_xccov_target(name: str) -> bool:
    lowered = name.lower()
    if lowered.endswith(".xctest") or "tests" in lowered:
        return False
    if "harmonize" in lowered or lowered == "sentry":
        return False
    return True


def is_test_source(path: str) -> bool:
    parts = Path(path).parts
    if any(part.endswith("Tests") or part.endswith("Specs") for part in parts):
        return True
    name = Path(path).name
    return name.endswith("Tests.swift") or name.endswith("Spec.swift") or name.endswith("Specs.swift")


def shared_suffix_length(left: str, right: str) -> int:
    count = 0
    for a, b in zip(reversed(left), reversed(right)):
        if a != b:
            break
        count += 1
    return count


def _function_from_regions(function: dict, suite: str) -> FunctionCoverage | None:
    lines: dict[int, int] = {}
    for region in function.get("regions") or []:
        if len(region) < 5:
            continue
        start_line = int(region[0])
        end_line = int(region[2])
        end_column = int(region[3])
        count = int(region[4])
        last = end_line if end_column > 1 else end_line - 1
        if last < start_line:
            last = start_line
        for line in range(start_line, last + 1):
            lines[line] = max(lines.get(line, 0), count)
    if not lines:
        return None
    covered = sum(1 for count in lines.values() if count > 0)
    executable = len(lines)
    return FunctionCoverage(
        line=min(lines),
        executable=executable,
        covered=covered,
        percent=100.0 * covered / executable,
        suite=suite,
    )


def parse_xccov(document: dict, suite: str) -> tuple[list[FileCoverage], SuiteTotals]:
    files: list[FileCoverage] = []
    totals = SuiteTotals(suite=suite)
    for target in document.get("targets") or []:
        name = target.get("name") or ""
        if not is_production_xccov_target(name):
            continue
        totals.covered += int(target.get("coveredLines") or 0)
        totals.executable += int(target.get("executableLines") or 0)
        for raw in target.get("files") or []:
            functions = []
            for function in raw.get("functions") or []:
                executable = int(function.get("executableLines") or 0)
                covered = int(function.get("coveredLines") or 0)
                if "lineCoverage" in function and function["lineCoverage"] is not None:
                    percent = float(function["lineCoverage"]) * 100.0
                elif executable:
                    percent = 100.0 * covered / executable
                else:
                    percent = 0.0
                functions.append(FunctionCoverage(
                    line=int(function["lineNumber"]),
                    executable=executable,
                    covered=covered,
                    percent=percent,
                    suite=suite,
                ))
            files.append(FileCoverage(
                path=raw["path"],
                executable=int(raw.get("executableLines") or 0),
                covered=int(raw.get("coveredLines") or 0),
                functions=tuple(functions),
                suite=suite,
            ))
    return files, totals


def parse_llvm_cov(document: dict, suite: str) -> tuple[list[FileCoverage], SuiteTotals]:
    """Read llvm-cov JSON export schema 3, where functions live beside files."""
    totals = SuiteTotals(suite=suite)
    functions_by_path: dict[str, list[FunctionCoverage]] = defaultdict(list)
    files: list[FileCoverage] = []
    for chunk in document.get("data") or []:
        for function in chunk.get("functions") or []:
            filenames = function.get("filenames") or []
            if not filenames or is_test_source(filenames[0]):
                continue
            parsed = _function_from_regions(function, suite)
            if parsed is not None:
                functions_by_path[filenames[0]].append(parsed)
        for raw in chunk.get("files") or []:
            path = raw["filename"]
            if is_test_source(path):
                continue
            line_summary = (raw.get("summary") or {}).get("lines") or {}
            executable = int(line_summary.get("count") or 0)
            covered = int(line_summary.get("covered") or 0)
            totals.executable += executable
            totals.covered += covered
            own_functions = []
            for function in raw.get("functions") or []:
                parsed = _function_from_regions(function, suite)
                if parsed is not None:
                    own_functions.append(parsed)
            files.append(FileCoverage(
                path=path,
                executable=executable,
                covered=covered,
                functions=tuple(own_functions or functions_by_path.get(path, [])),
                suite=suite,
            ))
    return files, totals


class CoverageIndex:
    def __init__(self, files: list[FileCoverage]):
        self.by_path: dict[str, list[FileCoverage]] = defaultdict(list)
        self.by_basename: dict[str, list[FileCoverage]] = defaultdict(list)
        for file in files:
            normalized = str(Path(file.path))
            self.by_path[normalized].append(file)
            self.by_basename[Path(normalized).name].append(file)

    def lookup(self, absolute_path: str) -> tuple[str, list[FileCoverage]]:
        normalized = str(Path(absolute_path))
        direct = self.by_path.get(normalized)
        if direct:
            return "absolute", direct
        basename = Path(normalized).name
        candidates = self.by_basename.get(basename) or []
        if not candidates:
            return "missing", []
        scored: list[tuple[int, FileCoverage]] = []
        for candidate in candidates:
            overlap = shared_suffix_length(normalized, str(Path(candidate.path)))
            # A shared "/File.swift" is not a path match: every absolute path
            # has that slash. Require at least one parent-directory character.
            if overlap > len(basename) + 1:
                scored.append((overlap, candidate))
        if not scored:
            return "ambiguous", []
        best = max(item[0] for item in scored)
        winners = [item[1] for item in scored if item[0] == best]
        paths = {str(Path(item.path)) for item in winners}
        if len(paths) != 1:
            return "ambiguous", []
        return "suffix", winners


def _best_function(
    files: list[FileCoverage], start: int, end: int
) -> tuple[str, FunctionCoverage | None]:
    in_range: list[FunctionCoverage] = []
    for file in files:
        for function in file.functions:
            if start <= function.line <= end:
                in_range.append(function)
    if not in_range:
        return "file-fallback", None
    closest = min(abs(function.line - start) for function in in_range)
    nearest = [function for function in in_range if abs(function.line - start) == closest]
    # Two different first-lines at the same distance are an ambiguous closure match.
    if len({function.line for function in nearest}) > 1:
        return "ambiguous", None
    return "function-match", max(nearest, key=lambda function: function.percent)


def _mark_unscored(method: Method, provenance: str, *, reason: str = "") -> None:
    method.provenance = provenance
    method.match_quality = ""
    method.coverage_percent = None
    method.coverage_suite = ""
    method.weighted_crap = None
    method.exclusion_reason = reason


def attribute_method(method: Method, index: CoverageIndex, source_root: Path) -> None:
    absolute = str(source_root / method.file)
    quality, files = index.lookup(absolute)
    if quality in {"missing", "ambiguous"} or not files:
        reason = exclusion_reason_for(method.file)
        if reason is not None:
            _mark_unscored(method, "excluded", reason=reason)
            return
        _mark_unscored(
            method,
            quality if quality in {"missing", "ambiguous"} else "missing",
        )
        return
    provenance, function = _best_function(files, method.line, method.end_line)
    method.match_quality = quality
    if provenance != "function-match" or function is None:
        reason = exclusion_reason_for(method.file)
        if reason is not None:
            _mark_unscored(method, "excluded", reason=reason)
            return
        method.provenance = provenance
        method.coverage_percent = None
        method.weighted_crap = None
        method.exclusion_reason = ""
        return
    method.provenance = "measured-zero" if function.percent <= 0 else "function-match"
    method.coverage_percent = function.percent
    method.coverage_suite = function.suite
    method.weighted_crap = crap_score(method.cyclomatic, method.cognitive, function.percent)
    method.exclusion_reason = ""


def load_methods(report: dict) -> list[Method]:
    methods = []
    for raw in report["methods"]:
        methods.append(Method(
            file=raw["file"],
            line=int(raw["line"]),
            end_line=int(raw["endLine"]),
            qualified_name=raw["qualifiedName"],
            kind=raw.get("kind") or "",
            cyclomatic=int(raw["complexity"]),
            cognitive=int(raw["cognitiveComplexity"]),
        ))
    return methods


def select_cohort(methods: list[Method], fraction: float = COHORT_FRACTION) -> list[Method]:
    """Worst `fraction` of all analyzed methods, drawn only from scored methods."""
    count = int(round(len(methods) * fraction))
    scored = [method for method in methods if method.weighted_crap is not None]
    scored.sort(key=lambda method: (
        -method.weighted_crap,
        method.file,
        method.line,
        method.qualified_name,
    ))
    return scored[:count]


def percentile(sorted_values: list[float], percent: float) -> float | None:
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = (len(sorted_values) - 1) * (percent / 100.0)
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return sorted_values[low]
    weight = rank - low
    return sorted_values[low] * (1.0 - weight) + sorted_values[high] * weight


def cluster_for(method: Method) -> str | None:
    named = NAMED_HOTSPOTS.get(method.identity)
    if named:
        return named
    if method.weighted_crap is None or method.weighted_crap <= WARNING_THRESHOLD:
        return None
    path = method.file
    if "/UI/Subscription/" in path:
        return "swiftui-subscription"
    if "/UI/SettingsView/" in path:
        return "swiftui-settings"
    if "/UI/Findings/" in path:
        return "swiftui-findings"
    if "/UI/FileImporter/" in path or "/UI/Catalog/" in path:
        return "swiftui-import-and-catalog"
    if method.area == "SwiftUI":
        return "swiftui-other"
    if path.endswith("NativeModelCoreMLEmitter.swift"):
        return "converter-emission"
    if path.endswith("ONNXModelReader.swift"):
        return "converter-onnx-lowering"
    if path.startswith("Sources/"):
        return "converter-other"
    if path.startswith("Tools/"):
        return "tooling"
    name = method.qualified_name
    if "Downloader.recoverOrphanedDownloads" in name:
        return "background-download-reconnect"
    if "FindingRepository.undoInParent" in name:
        return "finding-restore"
    if name.startswith("Detector.") or name.startswith("DetectionEngine."):
        return "detection"
    if name.startswith("MapLocationProbe."):
        return "map-location-probe"
    if "SentryCrashReportingService." in name:
        return "crash-reporting"
    if "StoreKitSubscriptionProvider.purchase" in name:
        return "storekit-purchase"
    if name.startswith("UITestLaunchConfiguration.") or "runSentryThrottleSmokeTestIfEnabled" in name:
        return "debug-launch-helpers"
    return "app-logic"


def triage_label(method: Method) -> tuple[str, str]:
    if method.provenance == "excluded":
        reason = method.exclusion_reason or "not linked into a tested coverage product"
        return (
            "measurement",
            f"excluded ({reason}); not scored and not treated as measured-zero",
        )
    if method.provenance in {"missing", "ambiguous", "file-fallback"}:
        return (
            "measurement",
            f"{method.provenance} coverage; excluded from the ranked score",
        )
    cluster = cluster_for(method)
    if cluster:
        rationale = f"actionable cluster {cluster}"
        if method.area == "SwiftUI":
            rationale += (
                "; unit-suite coverage does not establish the UI journey"
            )
        if method.identity in NAMED_HOTSPOTS:
            rationale += "; named user-data hotspot"
        return "actionable", rationale
    if method.weighted_crap is not None and method.weighted_crap <= WARNING_THRESHOLD:
        return (
            "acceptable",
            "function-matched and at or under the warning threshold of 30; "
            "kept in the frozen tail for comparison, not scheduled as a refactor",
        )
    return "measurement", method.provenance


def load_initial_cohort(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def reconcile(initial_rows: list[dict[str, str]], methods: list[Method], cohort: list[Method]) -> list[dict[str, str]]:
    by_identity = {method.identity: method for method in methods}
    cohort_ids = {method.identity for method in cohort}
    initial_ids = set()
    rows = []
    for initial in initial_rows:
        identity = (initial["file"], initial["function"])
        initial_ids.add(identity)
        current = by_identity.get(identity)
        if current is None:
            status = "removed"
        elif current.provenance == "excluded":
            status = "excluded"
        elif current.weighted_crap is None:
            status = "unmeasured"
        elif identity in cohort_ids:
            status = "stayed"
        else:
            status = "left-cohort"
        rows.append({
            "file": identity[0],
            "function": identity[1],
            "initial_line": initial.get("line", ""),
            "initial_weighted_crap": initial.get("weighted_crap", ""),
            "initial_evidence": initial.get("coverage_evidence", ""),
            "corrected_line": "" if current is None else str(current.line),
            "corrected_weighted_crap": "" if current is None or current.weighted_crap is None else format_number(current.weighted_crap),
            "corrected_provenance": "" if current is None else current.provenance,
            "exclusion_reason": "" if current is None else current.exclusion_reason,
            "status": status,
        })
    for method in cohort:
        if method.identity in initial_ids:
            continue
        rows.append({
            "file": method.file,
            "function": method.qualified_name,
            "initial_line": "",
            "initial_weighted_crap": "",
            "initial_evidence": "",
            "corrected_line": str(method.line),
            "corrected_weighted_crap": format_number(method.weighted_crap or 0),
            "corrected_provenance": method.provenance,
            "exclusion_reason": method.exclusion_reason,
            "status": "entered",
        })
    return rows


def format_number(value: float) -> str:
    return f"{value:.6f}".rstrip("0").rstrip(".")


def summarize(
    methods: list[Method],
    cohort: list[Method],
    totals: list[SuiteTotals],
    reconciliation: list[dict[str, str]],
) -> dict:
    scored = sorted(
        (method.weighted_crap for method in methods if method.weighted_crap is not None)
    )
    above = lambda threshold: sum(1 for value in scored if value > threshold)
    zero_cognitive = sum(
        1 for method in methods
        if method.weighted_crap is not None and method.cognitive == 0
    )
    provenance_counts: dict[str, int] = defaultdict(int)
    for method in methods:
        provenance_counts[method.provenance] += 1
    triage_counts: dict[str, int] = defaultdict(int)
    cluster_counts: dict[str, int] = defaultdict(int)
    for method in cohort:
        label, _ = triage_label(method)
        triage_counts[label] += 1
        cluster = cluster_for(method)
        if cluster and label == "actionable":
            cluster_counts[cluster] += 1
    status_counts: dict[str, int] = defaultdict(int)
    for row in reconciliation:
        status_counts[row["status"]] += 1
    return {
        "analyzed_methods": len(methods),
        "scored_methods": len(scored),
        "cohort_size": len(cohort),
        "cohort_cutoff": None if not cohort else cohort[-1].weighted_crap,
        "median": percentile(scored, 50),
        "p90": percentile(scored, 90),
        "p95": percentile(scored, 95),
        "max": scored[-1] if scored else None,
        "above_7": above(REVIEW_TARGET),
        "above_30": above(WARNING_THRESHOLD),
        "zero_cognitive": zero_cognitive,
        "provenance": dict(provenance_counts),
        "triage": dict(triage_counts),
        "clusters": dict(cluster_counts),
        "reconciliation": dict(status_counts),
        "production_coverage": [
            {
                "suite": item.suite,
                "covered": item.covered,
                "executable": item.executable,
                "percent": item.percent,
            }
            for item in totals
        ],
    }


def _write_csv(path: Path, rows: list[dict], fieldnames: list[str]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_outputs(
    out: Path,
    methods: list[Method],
    cohort: list[Method],
    reconciliation: list[dict[str, str]],
    summary: dict,
    metadata: dict,
) -> None:
    out.mkdir(parents=True, exist_ok=True)
    cohort_rows = []
    triage_rows = []
    for rank, method in enumerate(cohort, start=1):
        label, rationale = triage_label(method)
        cohort_rows.append({
            "rank": rank,
            "area": method.area,
            "file": method.file,
            "line": method.line,
            "function": method.qualified_name,
            "kind": method.kind,
            "weighted_crap": format_number(method.weighted_crap or 0),
            "cyclomatic": method.cyclomatic,
            "cognitive": method.cognitive,
            "coverage_percent": format_number(method.coverage_percent or 0),
            "provenance": method.provenance,
            "coverage_suite": method.coverage_suite,
            "triage": label,
            "cluster": cluster_for(method) or "",
        })
        triage_rows.append({
            "file": method.file,
            "line": method.line,
            "function": method.qualified_name,
            "triage": label,
            "cluster": cluster_for(method) or "",
            "rationale": rationale,
        })
    unmeasured = [
        {
            "file": method.file,
            "line": method.line,
            "function": method.qualified_name,
            "area": method.area,
            "cyclomatic": method.cyclomatic,
            "cognitive": method.cognitive,
            "provenance": method.provenance,
        }
        for method in methods
        if method.weighted_crap is None and method.provenance != "excluded"
    ]
    unmeasured.sort(key=lambda row: (-row["cyclomatic"] * max(row["cognitive"], 1), row["file"], row["line"], row["function"]))
    excluded = [
        {
            "file": method.file,
            "line": method.line,
            "function": method.qualified_name,
            "area": method.area,
            "cyclomatic": method.cyclomatic,
            "cognitive": method.cognitive,
            "provenance": method.provenance,
            "exclusion_reason": method.exclusion_reason,
        }
        for method in methods
        if method.provenance == "excluded"
    ]
    excluded.sort(key=lambda row: (-row["cyclomatic"] * max(row["cognitive"], 1), row["file"], row["line"], row["function"]))
    _write_csv(out / "cohort.csv", cohort_rows, list(cohort_rows[0]) if cohort_rows else [
        "rank", "area", "file", "line", "function", "kind", "weighted_crap",
        "cyclomatic", "cognitive", "coverage_percent", "provenance",
        "coverage_suite", "triage", "cluster",
    ])
    _write_csv(out / "triage.csv", triage_rows, [
        "file", "line", "function", "triage", "cluster", "rationale",
    ])
    _write_csv(out / "unmeasured.csv", unmeasured, [
        "file", "line", "function", "area", "cyclomatic", "cognitive", "provenance",
    ])
    _write_csv(out / "excluded.csv", excluded, [
        "file", "line", "function", "area", "cyclomatic", "cognitive", "provenance",
        "exclusion_reason",
    ])
    if reconciliation:
        _write_csv(out / "reconciliation.csv", reconciliation, list(reconciliation[0]))
    payload = {"metadata": metadata, "summary": summary}
    (out / "summary.json").write_text(json.dumps(payload, indent=2) + "\n")
    (out / "summary.md").write_text(render_markdown(payload) + "\n")


def run_lines(runs: list[dict]) -> list[str]:
    if not runs:
        return []
    lines = ["## Collection", ""]
    for run in runs:
        result = run.get("result", "")
        detail = run.get("detail", "")
        lines.append(f"- {run.get('suite', 'suite')}: {result} {detail}".rstrip())
    lines.append("")
    return lines


def render_markdown(payload: dict) -> str:
    meta = payload["metadata"]
    summary = payload["summary"]
    coverage_lines = []
    for item in summary["production_coverage"]:
        percent = "n/a" if item["percent"] is None else f"{item['percent']:.2f}%"
        coverage_lines.append(
            f"- {item['suite']}: {percent} "
            f"({item['covered']} / {item['executable']} executable lines, production files only)"
        )
    cutoff = summary["cohort_cutoff"]
    cutoff_text = "n/a" if cutoff is None else format_number(cutoff)
    def stat(name: str) -> str:
        value = summary[name]
        return "n/a" if value is None else format_number(value)
    return "\n".join([
        "# Weighted-CRAP baseline",
        "",
        f"Analyzer: slopguard-swift {meta.get('tool_version', '0.1.0')} at `{meta.get('analyzer_revision', ANALYZER_PIN)}`.",
        f"Source revision: `{meta.get('source_revision', 'unknown')}`.",
        "Regenerate with `./scripts/slopguard-baseline.sh report`.",
        "",
        *run_lines(meta.get("runs") or []),
        "## How a method is scored",
        "",
        "Weighted CRAP uses `W = sqrt(cyclomatic × cognitive)` and "
        "`W² × (1 − coverage)³ + W`. Coverage is a percentage from a function whose "
        "first line lies inside the method span. The closest such function wins. "
        "File-level fallback, a missing file, and an ambiguous path or closure match "
        "do not receive a score. Zero cognitive complexity scores 0.",
        "",
        "Suites combine by the highest function coverage percent, not a line-level union. "
        "The app figure counts the application product only. Converter and tool figures "
        "omit test sources. SwiftUI getters measured here are unit-suite coverage, not "
        "a UI journey.",
        "",
        "The converter suite is the root package test with ONNX fixtures and the Apple "
        "reference models. `ADAFCheckpointDirectoryTests` is not part of that command. "
        "The tool suite is `swift test --package-path Tools`, which builds "
        "`ProjectToolCoreTests`.",
        "",
        "Programs that are not linked into those tested products — CLI mains under "
        "`Sources/*CLI*` / parity runners, the `ProjectTool` executable (not "
        "`ProjectToolCore`), and `scripts/` — are classified `excluded` with an explicit "
        "reason. They are not scored as coverage 0%, do not enter the cohort as "
        "measured-zero hotspots, and appear in reconciliation as `excluded` rather than "
        "`unmeasured` or a silent drop.",
        "",
        "## Production coverage",
        "",
        *coverage_lines,
        "",
        "## Scored population",
        "",
        f"- Analyzed methods: {summary['analyzed_methods']}",
        f"- Function-matched methods: {summary['scored_methods']}",
        f"- Provenance counts: {json.dumps(summary['provenance'], sort_keys=True)}",
        f"- Median / p90 / p95 / max: {stat('median')} / {stat('p90')} / {stat('p95')} / {stat('max')}",
        f"- Methods above 7: {summary['above_7']}",
        f"- Methods above 30: {summary['above_30']}",
        f"- Scored methods with zero cognitive complexity: {summary['zero_cognitive']} "
        "(their weighted CRAP is 0, which pulls the median down)",
        "",
        "Missing, ambiguous, and file-fallback methods stay in the provenance counts. "
        "They are not folded into the median or the threshold counts.",
        "",
        "## Frozen cohort",
        "",
        f"Worst 15% of analyzed methods ({summary['cohort_size']}), taken only from "
        f"function-matched scores. Cutoff: {cutoff_text}. Ties break by file, line, "
        "and qualified name. Identities are in `cohort.csv`.",
        "",
        f"Triage of that cohort: {json.dumps(summary['triage'], sort_keys=True)}.",
        f"Actionable clusters: {json.dumps(summary['clusters'], sort_keys=True)}.",
        "",
        "## Reconciliation with the 2026-09-13 list",
        "",
        "The September 13 list scored absent coverage as 0% and reused one app-test bundle. "
        f"Identity match is file plus qualified name. Status counts: "
        f"{json.dumps(summary['reconciliation'], sort_keys=True)}.",
        "",
        "`stayed` is still in the frozen cohort. `left-cohort` is function-matched and "
        "now outside it. `excluded` is an explicit non-product coverage gap with a "
        "reason. `unmeasured` has no function match and is not excluded, so it is not "
        "given a fake zero. `entered` is new to the cohort. `removed` is no longer in "
        "the complexity report.",
        "",
    ])


def build(
    complexity: dict,
    coverage_files: list[FileCoverage],
    totals: list[SuiteTotals],
    initial_rows: list[dict[str, str]] | None,
) -> tuple[list[Method], list[Method], list[dict[str, str]], dict]:
    source_root = Path(complexity.get("sourceRoot") or ".")
    methods = load_methods(complexity)
    index = CoverageIndex(coverage_files)
    for method in methods:
        attribute_method(method, index, source_root)
    cohort = select_cohort(methods)
    reconciliation = reconcile(initial_rows, methods, cohort) if initial_rows is not None else []
    summary = summarize(methods, cohort, totals, reconciliation)
    return methods, cohort, reconciliation, summary


def _load_coverage(path: Path, kind: str, suite: str) -> tuple[list[FileCoverage], SuiteTotals]:
    document = json.loads(path.read_text())
    if kind == "xccov":
        return parse_xccov(document, suite)
    if kind == "llvm":
        return parse_llvm_cov(document, suite)
    raise SystemExit(f"unknown coverage kind {kind}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--complexity", required=True, type=Path)
    parser.add_argument("--initial", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--xccov", action="append", default=[], nargs=2, metavar=("SUITE", "PATH"))
    parser.add_argument("--llvm-cov", action="append", default=[], nargs=2, metavar=("SUITE", "PATH"))
    parser.add_argument("--source-revision", default="unknown")
    parser.add_argument("--analyzer-revision", default=ANALYZER_PIN)
    parser.add_argument("--tool-version", default="0.1.0")
    parser.add_argument("--runs", type=Path)
    parser.add_argument("--require-suite", action="append", default=[])
    args = parser.parse_args(argv)

    files: list[FileCoverage] = []
    totals: list[SuiteTotals] = []
    present = set()
    for suite, raw_path in args.xccov:
        parsed, total = _load_coverage(Path(raw_path), "xccov", suite)
        files.extend(parsed)
        totals.append(total)
        present.add(suite)
    for suite, raw_path in args.llvm_cov:
        parsed, total = _load_coverage(Path(raw_path), "llvm", suite)
        files.extend(parsed)
        totals.append(total)
        present.add(suite)
    missing = [suite for suite in args.require_suite if suite not in present]
    if missing:
        raise SystemExit(f"missing required coverage suites: {', '.join(missing)}")

    complexity = json.loads(args.complexity.read_text())
    initial = load_initial_cohort(args.initial) if args.initial else None
    methods, cohort, reconciliation, summary = build(complexity, files, totals, initial)
    metadata = {
        "source_revision": args.source_revision,
        "analyzer_revision": args.analyzer_revision,
        "tool_version": args.tool_version,
    }
    if args.runs:
        metadata["runs"] = json.loads(args.runs.read_text())
    write_outputs(
        args.out,
        methods,
        cohort,
        reconciliation,
        summary,
        metadata,
    )
    print(
        f"scored {summary['scored_methods']} of {summary['analyzed_methods']} methods; "
        f"cohort {summary['cohort_size']}; above 30: {summary['above_30']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
