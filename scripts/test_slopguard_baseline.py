#!/usr/bin/env python3
"""Hermetic checks for the weighted-CRAP baseline joiner."""

import csv
import importlib.util
import tempfile
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "slopguard_baseline", ROOT / "scripts" / "slopguard_baseline.py"
)
baseline = importlib.util.module_from_spec(SPEC)
sys.modules["slopguard_baseline"] = baseline
SPEC.loader.exec_module(baseline)


def method(file, name, line=10, end=40, cyc=19, cog=41, kind="function"):
    return baseline.Method(
        file=file,
        line=line,
        end_line=end,
        qualified_name=name,
        kind=kind,
        cyclomatic=cyc,
        cognitive=cog,
    )


def complexity(methods):
    return {
        "sourceRoot": "/repo",
        "methods": [
            {
                "file": item.file,
                "line": item.line,
                "endLine": item.end_line,
                "qualifiedName": item.qualified_name,
                "kind": item.kind,
                "complexity": item.cyclomatic,
                "cognitiveComplexity": item.cognitive,
            }
            for item in methods
        ],
    }


class FormulaTests(unittest.TestCase):
    def test_uncovered_paywall_score_matches_the_september_report(self):
        self.assertAlmostEqual(baseline.crap_score(19, 41, 0), 806.9105714739, places=6)

    def test_full_coverage_collapses_to_the_weight(self):
        weight = (19 * 41) ** 0.5
        self.assertAlmostEqual(baseline.crap_score(19, 41, 100), weight, places=6)

    def test_zero_cognitive_complexity_scores_zero(self):
        self.assertEqual(baseline.crap_score(12, 0, 0), 0)


class ArtifactProvenanceTests(unittest.TestCase):
    def test_mixed_revisions_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("complexity.json", "coverage.json")]
            for index, path in enumerate(paths):
                path.write_text("{}")
                baseline.attest_artifact(path, str(index) * 40)
            with self.assertRaisesRegex(ValueError, "same source revision"):
                baseline.artifact_revision(paths)

    def test_modified_export_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "coverage.json"
            path.write_text("{}")
            baseline.attest_artifact(path, "a" * 40)
            path.write_text('{"changed":true}')
            with self.assertRaisesRegex(ValueError, "changed after collection"):
                baseline.artifact_revision([path])

    def test_unattested_export_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "coverage.json"
            path.write_text("{}")
            with self.assertRaisesRegex(ValueError, "missing provenance"):
                baseline.artifact_revision([path])

    def test_report_uses_collection_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("complexity.json", "coverage.json")]
            for path in paths:
                path.write_text("{}")
                baseline.attest_artifact(path, "a" * 40)
            self.assertEqual(baseline.artifact_revision(paths), "a" * 40)


class AttributionTests(unittest.TestCase):
    def test_app_totals_exclude_dependency_targets(self):
        files, totals = baseline.parse_xccov({"targets": [
            {"name": "ML Browser.app", "coveredLines": 3, "executableLines": 10},
            {"name": "ConfigCat", "coveredLines": 100, "executableLines": 100},
            {"name": "NativeModelConverter", "coveredLines": 20, "executableLines": 20},
        ]}, "app")
        self.assertEqual((totals.covered, totals.executable), (3, 10))

    def test_generated_runner_and_dependencies_are_not_production_sources(self):
        self.assertTrue(baseline.is_test_source(
            "/repo/.build/out/Intermediates/Tests-p.build/DerivedSources/test_entry_point.swift"
        ))
        self.assertTrue(baseline.is_test_source(
            "/repo/.build/checkouts/argument-parser/Sources/ArgumentParser/Parser.swift"
        ))

    def test_function_match_ignores_a_higher_file_coverage(self):
        files, _ = baseline.parse_xccov({
            "targets": [{
                "name": "ML Browser.app",
                "coveredLines": 90,
                "executableLines": 100,
                "files": [{
                    "path": "/repo/ios/PaywallView.swift",
                    "coveredLines": 90,
                    "executableLines": 100,
                    "functions": [{
                        "name": "body.get",
                        "lineNumber": 12,
                        "executableLines": 10,
                        "coveredLines": 0,
                        "lineCoverage": 0,
                    }],
                }],
            }],
        }, "app")
        item = method("ios/PaywallView.swift", "PaywallView.body.get", line=10, end=40)
        baseline.attribute_method(item, baseline.CoverageIndex(files), Path("/repo"))
        self.assertEqual(item.provenance, "measured-zero")
        self.assertEqual(item.coverage_percent, 0)
        self.assertAlmostEqual(item.weighted_crap, 806.9105714739, places=6)

    def test_file_without_a_function_in_range_is_not_scored(self):
        files, _ = baseline.parse_xccov({
            "targets": [{
                "name": "ML Browser.app",
                "coveredLines": 9,
                "executableLines": 10,
                "files": [{
                    "path": "/repo/ios/PaywallView.swift",
                    "coveredLines": 9,
                    "executableLines": 10,
                    "functions": [{
                        "name": "other()",
                        "lineNumber": 80,
                        "executableLines": 2,
                        "coveredLines": 2,
                        "lineCoverage": 1,
                    }],
                }],
            }],
        }, "app")
        item = method("ios/PaywallView.swift", "PaywallView.body.get")
        baseline.attribute_method(item, baseline.CoverageIndex(files), Path("/repo"))
        self.assertEqual(item.provenance, "file-fallback")
        self.assertIsNone(item.weighted_crap)

    def test_absent_file_is_missing_rather_than_zero(self):
        item = method("ios/MLBrowser/iOS/State/DataController.swift", "DataController.handleStoreLoadError(_:description:)")
        baseline.attribute_method(item, baseline.CoverageIndex([]), Path("/repo"))
        self.assertEqual(item.provenance, "missing")
        self.assertIsNone(item.weighted_crap)

    def test_project_tool_executable_is_excluded_not_measured_zero(self):
        item = method(
            "Tools/Sources/ProjectTool/ToolsConfiguration.swift",
            "ToolsManager.installTool(name:spec:)",
        )
        baseline.attribute_method(item, baseline.CoverageIndex([]), Path("/repo"))
        self.assertEqual(item.provenance, "excluded")
        self.assertEqual(
            item.exclusion_reason,
            "ProjectTool executable not in ProjectToolCore tests",
        )
        self.assertIsNone(item.coverage_percent)
        self.assertIsNone(item.weighted_crap)

    def test_cli_main_and_script_paths_are_excluded(self):
        cli = method(
            "Sources/NativeModelConverterCLI/main.swift",
            "NativeModelConverterCLI.main()",
        )
        script = method(
            "scripts/xcstrings-to-strings.swift",
            "convert(inputPath:outputPath:)",
        )
        index = baseline.CoverageIndex([])
        baseline.attribute_method(cli, index, Path("/repo"))
        baseline.attribute_method(script, index, Path("/repo"))
        self.assertEqual(cli.provenance, "excluded")
        self.assertEqual(cli.exclusion_reason, "CLI main")
        self.assertEqual(script.provenance, "excluded")
        self.assertEqual(script.exclusion_reason, "script")

    def test_same_filename_in_another_directory_is_ambiguous(self):
        files = [baseline.FileCoverage(
            path="/other/main.swift",
            executable=4,
            covered=0,
            functions=(baseline.FunctionCoverage(1, 4, 0, 0, "app"),),
            suite="app",
        )]
        item = method("ios/Helpers/main.swift", "main()", line=1, end=20, cyc=4, cog=4)
        baseline.attribute_method(item, baseline.CoverageIndex(files), Path("/repo"))
        self.assertEqual(item.provenance, "ambiguous")

    def test_suffix_match_accepts_a_shared_directory(self):
        files = [baseline.FileCoverage(
            path="/ci/checkout/ios/State/DataController.swift",
            executable=10,
            covered=5,
            functions=(baseline.FunctionCoverage(12, 8, 4, 50, "app"),),
            suite="app",
        )]
        item = method("ios/State/DataController.swift", "DataController.handleStoreLoadError(_:description:)", line=10, end=40, cyc=4, cog=4)
        baseline.attribute_method(item, baseline.CoverageIndex(files), Path("/repo"))
        self.assertEqual(item.provenance, "function-match")
        self.assertEqual(item.coverage_percent, 50)

    def test_partial_parent_directory_suffix_does_not_match(self):
        file = baseline.FileCoverage(
            path="/ci/OtherState/Foo.swift", executable=10, covered=10,
            functions=(baseline.FunctionCoverage(10, 10, 10, 100, "app"),),
            suite="app",
        )
        item = method("State/Foo.swift", "Foo.bar()")
        baseline.attribute_method(item, baseline.CoverageIndex([file]), Path("/repo"))
        self.assertEqual(item.provenance, "ambiguous")
        self.assertIsNone(item.weighted_crap)

    def test_test_bundle_zero_does_not_count_as_measured(self):
        files, totals = baseline.parse_xccov({
            "targets": [{
                "name": "NativeModelConverterTests",
                "coveredLines": 0,
                "executableLines": 100,
                "files": [{
                    "path": "/repo/Sources/NativeModelConverter/NativeModelCoreMLEmitter.swift",
                    "coveredLines": 0,
                    "executableLines": 100,
                    "functions": [{
                        "name": "makeModel",
                        "lineNumber": 12,
                        "executableLines": 20,
                        "coveredLines": 0,
                        "lineCoverage": 0,
                    }],
                }],
            }],
        }, "app")
        self.assertEqual(files, [])
        self.assertEqual(totals.executable, 0)
        item = method(
            "Sources/NativeModelConverter/NativeModelCoreMLEmitter.swift",
            "NativeModelCoreMLEmitter.makeModel(input:context:)",
        )
        baseline.attribute_method(item, baseline.CoverageIndex(files), Path("/repo"))
        self.assertEqual(item.provenance, "missing")

    def test_two_suites_keep_the_higher_function_coverage(self):
        low = baseline.FileCoverage(
            path="/repo/Sources/Foo.swift",
            executable=10,
            covered=1,
            functions=(baseline.FunctionCoverage(10, 10, 1, 10, "app"),),
            suite="app",
        )
        high = baseline.FileCoverage(
            path="/repo/Sources/Foo.swift",
            executable=10,
            covered=8,
            functions=(baseline.FunctionCoverage(10, 10, 8, 80, "converter"),),
            suite="converter",
        )
        item = method("Sources/Foo.swift", "Foo.bar()", line=10, end=30, cyc=4, cog=4)
        baseline.attribute_method(item, baseline.CoverageIndex([low, high]), Path("/repo"))
        self.assertEqual(item.coverage_percent, 80)
        self.assertEqual(item.coverage_suite, "converter")

    def test_same_line_closure_is_ambiguous_instead_of_taking_maximum(self):
        file = baseline.FileCoverage(
            path="/repo/Sources/Foo.swift", executable=10, covered=10,
            functions=(
                baseline.FunctionCoverage(10, 10, 0, 0, "app", "Foo.bar()"),
                baseline.FunctionCoverage(10, 1, 1, 100, "app", "closure in Foo.bar()"),
            ), suite="app",
        )
        item = method("Sources/Foo.swift", "Foo.bar()")
        baseline.attribute_method(item, baseline.CoverageIndex([file]), Path("/repo"))
        self.assertEqual(item.provenance, "ambiguous")
        self.assertIsNone(item.weighted_crap)

    def test_llvm_regions_and_test_paths(self):
        files, totals = baseline.parse_llvm_cov({
            "data": [{
                "files": [
                    {
                        "filename": "/repo/Sources/Foo.swift",
                        "summary": {"lines": {"count": 4, "covered": 2}},
                    },
                    {
                        "filename": "/repo/Tests/FooTests/FooTests.swift",
                        "summary": {"lines": {"count": 20, "covered": 20}},
                    },
                ],
                "functions": [
                    {
                        "name": "Foo.bar()",
                        "filenames": ["/repo/Sources/Foo.swift"],
                        "regions": [[10, 1, 12, 2, 3, 0, 0, 0], [12, 1, 14, 1, 0, 0, 0, 0]],
                    },
                    {
                        "name": "test()",
                        "filenames": ["/repo/Tests/FooTests/FooTests.swift"],
                        "regions": [[1, 1, 4, 1, 1, 0, 0, 0]],
                    },
                ],
            }],
        }, "converter")
        self.assertEqual(len(files), 1)
        self.assertEqual(totals.executable, 4)
        self.assertEqual(totals.covered, 2)
        function = files[0].functions[0]
        self.assertEqual(function.line, 10)
        self.assertEqual(function.executable, 4)
        self.assertEqual(function.covered, 3)
        self.assertEqual(function.percent, 75)


class LLVMFunctionCoverageTests(unittest.TestCase):
    def test_unexecuted_nested_branch_overrides_the_enclosing_region(self):
        # Real Swift coverage layout for CoreMLProtobufStreamingEncoder.varint:
        # the function ran, but the while body on lines 154-156 never did.
        result = baseline._function_from_regions({"regions": [
            [150, 54, 159, 3, 10, 0, 0, 0],
            [153, 9, 153, 26, 10, 0, 0, 0],
            [153, 27, 156, 4, 0, 0, 0, 0],
            [156, 4, 158, 14, 10, 0, 0, 0],
        ]}, "converter")
        self.assertEqual(result.executable, 10)
        self.assertEqual(result.covered, 8)
        self.assertEqual(result.percent, 80)

    def test_regions_from_an_expansion_file_do_not_cover_the_main_file(self):
        result = baseline._function_from_regions({"regions": [
            [10, 1, 12, 2, 0, 0, 0, 0],
            [10, 1, 12, 2, 4, 1, 0, 0],
        ]}, "converter")
        self.assertEqual(result.covered, 0)

    def test_skipped_region_is_not_an_executable_line(self):
        result = baseline._function_from_regions({"regions": [
            [10, 1, 15, 2, 1, 0, 0, 0],
            [12, 1, 14, 1, 0, 0, 0, 2],
        ]}, "converter")
        self.assertEqual(result.executable, 3)
        self.assertEqual(result.covered, 3)


class CohortTests(unittest.TestCase):
    def test_frozen_cohort_keeps_unmeasured_members_and_does_not_rerank(self):
        existing = method("A.swift", "a()", cyc=2, cog=2)
        new_hotspot = method("B.swift", "b()", cyc=20, cog=20)
        new_hotspot.weighted_crap = 420
        rows = [{"file": "A.swift", "function": "a()", "line": "10", "kind": "function",
                 "cyclomatic": "2", "cognitive": "2"}]
        selected = baseline.frozen_cohort([existing, new_hotspot], rows)
        self.assertEqual(selected, [existing])
        self.assertIsNone(selected[0].weighted_crap)
        with tempfile.TemporaryDirectory() as directory:
            baseline.write_outputs(
                Path(directory), [existing, new_hotspot], selected, [],
                baseline.summarize([existing, new_hotspot], selected, [], []),
                {"cohort_selection": "frozen"},
            )
            with (Path(directory) / "cohort.csv").open() as handle:
                output = list(csv.DictReader(handle))
            self.assertEqual(output[0]["weighted_crap"], "")
            self.assertEqual(output[0]["coverage_percent"], "")

    def test_exact_fifteen_percent_breaks_ties_by_file_line_and_name(self):
        methods = []
        for index in range(10):
            item = method(f"F{index:02d}.swift", f"fn{index}()", cyc=2, cog=2)
            item.provenance = "function-match"
            item.coverage_percent = 0
            item.weighted_crap = 6
            methods.append(item)
        # 15% of 10 rounds to 2. Equal scores take the earliest file names.
        selected = baseline.select_cohort(methods)
        self.assertEqual(len(selected), 2)
        self.assertEqual([item.file for item in selected], ["F00.swift", "F01.swift"])

    def test_unscored_methods_do_not_fill_the_cohort(self):
        scored = method("A.swift", "a()", cyc=2, cog=2)
        scored.weighted_crap = 10
        scored.provenance = "function-match"
        methods = [scored]
        for index in range(7):
            missing = method(f"M{index}.swift", f"m{index}()", cyc=20, cog=20)
            missing.provenance = "missing"
            methods.append(missing)
        selected = baseline.select_cohort(methods)
        self.assertEqual(selected, [scored])

    def test_excluded_identity_is_not_measured_zero_or_cohort_hotspot(self):
        methods = []
        for index in range(10):
            item = method(f"F{index:02d}.swift", f"fn{index}()", cyc=2, cog=2)
            item.provenance = "function-match"
            item.coverage_percent = 50
            item.weighted_crap = 3
            methods.append(item)
        excluded = method(
            "Tools/Sources/ProjectTool/ToolsConfiguration.swift",
            "ToolsManager.installTool(name:spec:)",
            cyc=15,
            cog=26,
        )
        baseline.attribute_method(excluded, baseline.CoverageIndex([]), Path("/repo"))
        self.assertEqual(excluded.provenance, "excluded")
        self.assertIsNone(excluded.weighted_crap)
        self.assertNotEqual(excluded.provenance, "measured-zero")
        methods.append(excluded)
        selected = baseline.select_cohort(methods)
        self.assertEqual(len(selected), 2)
        self.assertNotIn(excluded, selected)
        summary = baseline.summarize(methods, selected, [], [])
        self.assertEqual(summary["provenance"]["excluded"], 1)
        self.assertEqual(summary["scored_methods"], 10)
        self.assertNotIn(excluded.identity, {method.identity for method in selected})

    def test_threshold_counts_ignore_unmeasured_methods(self):
        scored = method("A.swift", "a()")
        scored.weighted_crap = 40
        scored.provenance = "measured-zero"
        scored.coverage_percent = 0
        missing = method("B.swift", "b()")
        missing.provenance = "missing"
        summary = baseline.summarize([scored, missing], [scored], [], [])
        self.assertEqual(summary["above_30"], 1)
        self.assertEqual(summary["scored_methods"], 1)
        self.assertEqual(summary["provenance"]["missing"], 1)

    def test_orphan_download_recovery_joins_the_download_cluster(self):
        item = method(
            "ios/MLBrowser/iOS/State/Downloader.swift",
            "Downloader.recoverOrphanedDownloads(activeTaskIds:)",
            cyc=8,
            cog=8,
        )
        item.provenance = "measured-zero"
        item.coverage_percent = 0
        item.weighted_crap = 40
        self.assertEqual(baseline.cluster_for(item), "background-download-reconnect")

    def test_named_hotspot_stays_actionable_under_the_warning_threshold(self):
        item = method(
            "ios/MLBrowser/iOS/State/Downloader.swift",
            "Downloader.reconnectBackgroundSession()",
            cyc=3,
            cog=3,
        )
        item.provenance = "function-match"
        item.coverage_percent = 90
        item.weighted_crap = 4
        label, rationale = baseline.triage_label(item)
        self.assertEqual(label, "actionable")
        self.assertIn("named user-data hotspot", rationale)

    def test_reconciliation_records_left_unmeasured_and_entered(self):
        stayed = method("A.swift", "a()")
        stayed.line = 3
        stayed.weighted_crap = 40
        stayed.provenance = "function-match"
        left = method("B.swift", "b()")
        left.weighted_crap = 1
        left.provenance = "function-match"
        missing = method("C.swift", "c()")
        missing.provenance = "missing"
        entered = method("D.swift", "d()")
        entered.weighted_crap = 50
        entered.provenance = "function-match"
        methods = [stayed, left, missing, entered]
        cohort = [entered, stayed]
        rows = baseline.reconcile([
            {"file": "A.swift", "function": "a()", "line": "1", "weighted_crap": "10", "coverage_evidence": "function present"},
            {"file": "B.swift", "function": "b()", "line": "2", "weighted_crap": "9", "coverage_evidence": "function present"},
            {"file": "C.swift", "function": "c()", "line": "3", "weighted_crap": "8", "coverage_evidence": "file absent; coverage unknown"},
            {"file": "E.swift", "function": "e()", "line": "4", "weighted_crap": "7", "coverage_evidence": "function present"},
        ], methods, cohort)
        status = { (row["file"], row["function"]): row["status"] for row in rows }
        self.assertEqual(status[("A.swift", "a()")], "stayed")
        self.assertEqual(status[("B.swift", "b()")], "left-cohort")
        self.assertEqual(status[("C.swift", "c()")], "unmeasured")
        self.assertEqual(status[("E.swift", "e()")], "removed")
        self.assertEqual(status[("D.swift", "d()")], "entered")

    def test_reconciliation_records_excluded_instead_of_unmeasured_or_zero(self):
        excluded = method(
            "Tools/Sources/ProjectTool/ToolsConfiguration.swift",
            "ToolsManager.installTool(name:spec:)",
        )
        baseline.attribute_method(excluded, baseline.CoverageIndex([]), Path("/repo"))
        rows = baseline.reconcile([
            {
                "file": excluded.file,
                "function": excluded.qualified_name,
                "line": "212",
                "weighted_crap": "409",
                "coverage_evidence": "file absent; coverage unknown",
            },
        ], [excluded], [])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "excluded")
        self.assertEqual(rows[0]["corrected_provenance"], "excluded")
        self.assertEqual(
            rows[0]["exclusion_reason"],
            "ProjectTool executable not in ProjectToolCore tests",
        )
        self.assertEqual(rows[0]["corrected_weighted_crap"], "")


class ReportTextTests(unittest.TestCase):
    def test_summary_states_the_measurement_limits(self):
        text = baseline.render_markdown({
            "metadata": {
                "tool_version": "0.1.0",
                "analyzer_revision": baseline.ANALYZER_PIN,
                "source_revision": "abc",
            },
            "summary": {
                "analyzed_methods": 1,
                "scored_methods": 1,
                "cohort_size": 1,
                "cohort_cutoff": 4,
                "median": 4,
                "p90": 4,
                "p95": 4,
                "max": 4,
                "above_7": 0,
                "above_30": 0,
                "zero_cognitive": 0,
                "provenance": {"function-match": 1},
                "triage": {"acceptable": 1},
                "clusters": {},
                "reconciliation": {},
                "production_coverage": [
                    {"suite": "app", "covered": 1, "executable": 2, "percent": 50},
                ],
            },
        })
        self.assertIn("File-level fallback", text)
        self.assertIn("not a line-level union", text)
        self.assertIn("not a UI journey", text)
        self.assertIn("Zero cognitive complexity", text)
        self.assertIn("classified `excluded`", text)
        self.assertIn(baseline.ANALYZER_PIN, text)


if __name__ == "__main__":
    unittest.main()
