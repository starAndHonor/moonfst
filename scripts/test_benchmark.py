#!/usr/bin/env python3
"""Protocol and reporting checks; never builds or runs either benchmark."""
from __future__ import annotations

import contextlib
import copy
import csv
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "moonfst_benchmark", Path(__file__).with_name("benchmark.py")
)
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)

METRICS = (
    "build", "lookup_hit", "lookup_miss", "stream_owned", "prefix_owned", "union_owned",
)

# Frozen protocol vectors, calculated separately from benchmark.reference.
# Fields: A FNV, A SHA256, B FNV, input key bytes, hit sum, prefix FNV,
# prefix count, union FNV. The n=2 vectors also match the Rust runner's
# independently specified raw-key golden tests.
GOLDENS = {
    (2, "shared"): (
        "13146377713594168491",
        "b0cb4c53896c0172b89f9afe1f86ceb722dfae4a79bb3a7c95935e7769439f37",
        "13549158798438833740", 56, "6949403057",
        "13146377713594168491", 2, "14634150698178146485",
    ),
    (2, "random"): (
        "10656632618923367303",
        "b84d42fa5a91f5689316ae4db0be9e4bc39008c98a606f54a6a85c6c214f5de9",
        "18296799878126613654", 32, "6949403057",
        "14695981039346656037", 0, "7451948023877761687",
    ),
    (100, "shared"): (
        "6898778106240362035",
        "8f0f780b870ff4110a8f36124bfde82e09ac6063abdceab9e575eadfd47ddbd4",
        "17719556050537169533", 2800, "21471693571190",
        "6351386585959601598", 64, "6544550469668722375",
    ),
    (100, "random"): (
        "18120280097955669974",
        "42d46f4bfb1f0f71546110eafb54a89e13361b2b205b0477d9ea0b16c7d9da63",
        "15431115656552904552", 1600, "21471693571190",
        "2541738757377381211", 16, "6119437038547274327",
    ),
}


def golden_case(n=100, shape="shared"):
    a_hash, sha256, b_hash, key_bytes, hit_sum, prefix_hash, prefix_n, union_hash = GOLDENS[n, shape]
    return {
        "shape": shape, "n": n, "seed": 12648430,
        "dataset_hash": a_hash, "dataset_sha256": sha256,
        "b_hash": b_hash, "input_key_bytes": key_bytes,
        "expected": {
            "lookup_hit": [hit_sum, n],
            "lookup_miss": ["0", 0],
            "stream_owned": [a_hash, n],
            "prefix_owned": [prefix_hash, prefix_n],
            "union_owned": [union_hash, 3 * n // 2],
        },
    }


def valid_payload(expected=None, engine="moonbit", times=(10.0, 20.0, 30.0), size=1234):
    expected = golden_case() if expected is None else expected
    metrics = []
    for name in METRICS:
        checksum, count = (
            (str(size), expected["n"]) if name == "build" else expected["expected"][name]
        )
        metrics.append({
            "name": name, "checksum": checksum, "result_count": count,
            "samples_us": list(times),
        })
    return {
        "schema": 1, "engine": engine, "shape": expected["shape"],
        "n": expected["n"], "seed": 12648430,
        "samples": len(times), "warmups": 1,
        "dataset_hash": expected["dataset_hash"],
        "input_key_bytes": expected["input_key_bytes"],
        "fst_bytes": size, "metrics": metrics,
    }


def summary_fixture(n=100, shape="shared"):
    expected = golden_case(n, shape)
    runs = []
    for round_index, (moon_times, rust_times) in enumerate(
        (((10, 40), (2, 6)), ((20, 30), (4, 8))), start=1
    ):
        for engine, times, size in (
            ("moonbit", moon_times, 1234), ("rust", rust_times, 789),
        ):
            runs.append({
                "round": round_index,
                "payload": valid_payload(expected, engine, times, size),
            })
    return {
        "datasets": [expected], "runs": runs,
        "finished_at": "2026-11-06T00:00:00+00:00",
        "config": {"rounds": 2, "samples": 2, "warmups": 1},
        "environment": {
            "cpu_model": "test CPU", "selected_cpu": 0, "platform": "test OS",
            "moon": "test MoonBit", "rustc": "test Rust",
        },
    }


class ReferenceTests(unittest.TestCase):
    def test_fixed_protocol_vectors_for_both_sizes_and_shapes(self):
        for n, shape in GOLDENS:
            with self.subTest(n=n, shape=shape):
                self.assertEqual(benchmark.reference(n, shape), golden_case(n, shape))

    def test_record_wire_preserves_raw_bytes_and_full_u64(self):
        self.assertEqual(
            benchmark.record_bytes((b"\x00\xff", 0x0102030405060708)),
            bytes.fromhex("00ff020000000807060504030201"),
        )
        self.assertEqual(
            benchmark.record_bytes((b"", (1 << 64) - 1)),
            b"\x00" * 4 + b"\xff" * 8,
        )


class ValidationTests(unittest.TestCase):
    def validate(self, payload, expected=None, engine="moonbit"):
        benchmark.validate(payload, golden_case() if expected is None else expected, engine, 3, 1)

    def test_accepts_distinct_build_sizes_and_zero_output_prefix(self):
        for n, shape in GOLDENS:
            expected = golden_case(n, shape)
            for engine, size in (("moonbit", 1234), ("rust", 789)):
                with self.subTest(n=n, shape=shape, engine=engine):
                    self.validate(valid_payload(expected, engine, size=size), expected, engine)

    def test_rejects_wrong_dataset_configuration_or_engine(self):
        wrong_values = {
            "schema": 2, "engine": "rust", "shape": "random", "n": 102,
            "seed": 1, "samples": 2, "warmups": 2,
            "dataset_hash": "6898778106240362036", "input_key_bytes": 2801,
        }
        for field, wrong in wrong_values.items():
            payload = valid_payload()
            payload[field] = wrong
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate(payload)

    def test_rejects_json_type_coercions(self):
        for field, wrong in (
            ("schema", True), ("n", 100.0), ("seed", "12648430"),
            ("samples", 3.0), ("warmups", True), ("input_key_bytes", 2800.0),
            ("dataset_hash", 6898778106240362035), ("fst_bytes", True),
            ("fst_bytes", 0), ("fst_bytes", -1), ("fst_bytes", 1234.0),
        ):
            payload = valid_payload()
            payload[field] = wrong
            with self.subTest(field=field, wrong=wrong), self.assertRaises(ValueError):
                self.validate(payload)

    def test_rejects_missing_duplicate_or_reordered_metrics(self):
        for mutation in ("missing", "duplicate", "reordered", "unknown"):
            payload = valid_payload()
            if mutation == "missing":
                payload["metrics"].pop()
            elif mutation == "duplicate":
                payload["metrics"][-1] = copy.deepcopy(payload["metrics"][0])
            elif mutation == "reordered":
                payload["metrics"].reverse()
            else:
                payload["metrics"][-1]["name"] = "unrecognized"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.validate(payload)

    def test_rejects_malformed_containers_and_missing_metric_fields(self):
        malformed = [None, [], "not an object"]
        for metrics in (None, {}, "metrics", [None], ["build"]):
            payload = valid_payload()
            payload["metrics"] = metrics
            malformed.append(payload)
        payload = valid_payload()
        del payload["metrics"]
        malformed.append(payload)
        for field in ("name", "checksum", "result_count", "samples_us"):
            payload = valid_payload()
            del payload["metrics"][0][field]
            malformed.append(payload)
        for index, payload in enumerate(malformed):
            with self.subTest(case=index), self.assertRaises(ValueError):
                self.validate(payload)

    def test_rejects_bad_checksum_or_count_for_every_operation(self):
        for index, name in enumerate(METRICS):
            for field in ("checksum", "result_count"):
                payload = valid_payload()
                metric = payload["metrics"][index]
                metric[field] = str(int(metric[field]) + 1) if field == "checksum" else metric[field] + 1
                with self.subTest(name=name, field=field), self.assertRaises(ValueError):
                    self.validate(payload)
            for field, value in (("checksum", 1234), ("result_count", 100.0), ("result_count", True)):
                payload = valid_payload()
                payload["metrics"][index][field] = value
                with self.subTest(name=name, field=field, value=value), self.assertRaises(ValueError):
                    self.validate(payload)

    def test_rejects_nonfinite_nonpositive_and_non_numeric_timings(self):
        for invalid in (float("nan"), float("inf"), -float("inf"), 0, -0.0, -1, True, "1", None):
            payload = valid_payload()
            payload["metrics"][0]["samples_us"][1] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                self.validate(payload)
        for times in ([], [1], [1, 2, 3, 4], None, "123"):
            payload = valid_payload()
            payload["metrics"][0]["samples_us"] = times
            with self.subTest(times=times), self.assertRaises(ValueError):
                self.validate(payload)


class SummaryTests(unittest.TestCase):
    def test_interpolated_statistics_and_single_sample(self):
        stats = benchmark.statistics_us([40, 10, 30, 20])
        self.assertEqual(stats, {
            "sample_count": 4, "median_us": 25, "p25_us": 17.5,
            "p75_us": 32.5, "p95_us": 38.5, "min_us": 10, "max_us": 40,
        })
        singleton = benchmark.statistics_us([42])
        self.assertEqual(singleton["sample_count"], 1)
        self.assertTrue(all(value == 42 for key, value in singleton.items() if key != "sample_count"))

    def test_pooled_samples_ratio_and_throughput_work_units(self):
        rows = benchmark.summarize(summary_fixture())
        self.assertEqual([row["metric"] for row in rows], list(METRICS))
        for row in rows:
            with self.subTest(metric=row["metric"]):
                moon, rust = row["moonbit"], row["rust"]
                self.assertEqual(moon["sample_count"], 4)
                self.assertEqual(moon["median_us"], 25)
                self.assertEqual(rust["median_us"], 5)
                self.assertAlmostEqual(rust["p95_us"], 7.7)
                self.assertEqual(row["moonbit_over_rust"], 5)
                units = 64 if row["metric"] == "prefix_owned" else 150 if row["metric"] == "union_owned" else 100
                self.assertEqual(moon["work_units"], units)
                self.assertEqual(rust["work_units"], units)
                self.assertEqual(moon["units_per_second"], units * 40000)
                self.assertEqual(rust["units_per_second"], units * 200000)
                self.assertEqual(moon["fst_bytes"], 1234)
                self.assertEqual(rust["fst_bytes"], 789)
        miss = next(row for row in rows if row["metric"] == "lookup_miss")
        self.assertEqual(miss["moonbit"]["result_count"], 0)
        self.assertEqual(miss["moonbit"]["units_per_second"], 4000000)

    def test_empty_prefix_output_has_zero_record_throughput(self):
        rows = benchmark.summarize(summary_fixture(2, "random"))
        prefix = next(row for row in rows if row["metric"] == "prefix_owned")
        for engine in ("moonbit", "rust"):
            self.assertEqual(prefix[engine]["work_units"], 0)
            self.assertEqual(prefix[engine]["units_per_second"], 0)

    def test_rejects_changing_file_size_across_rounds(self):
        raw = summary_fixture()
        raw["runs"][2]["payload"]["fst_bytes"] += 1
        with self.assertRaisesRegex(ValueError, "nondeterministic FST length"):
            benchmark.summarize(raw)

    def test_reports_csv_per_second_and_markdown_milliseconds(self):
        raw = summary_fixture()
        rows = benchmark.summarize(raw)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            benchmark.report(output, raw, rows)
            with (output / "summary.csv").open(newline="") as handle:
                csv_rows = list(csv.DictReader(handle))
            self.assertEqual(len(csv_rows), 12)
            miss = next(row for row in csv_rows if row["metric"] == "lookup_miss" and row["engine"] == "moonbit")
            self.assertEqual(int(miss["work_units"]), 100)
            self.assertEqual(int(miss["result_count"]), 0)
            self.assertEqual(float(miss["median_us"]), 25)
            self.assertEqual(float(miss["units_per_second"]), 4000000)
            self.assertEqual(float(miss["moonbit_over_rust"]), 5)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["schema"], 1)
            self.assertEqual(summary["rows"], rows)
            report = (output / "REPORT.md").read_text()
            self.assertIn("MoonBit ms（P25–P75）", report)
            self.assertIn("| shared | 100 | lookup_hit | 0.025 ", report)


class CommandLineTests(unittest.TestCase):
    def test_valid_small_and_maximum_runner_configuration(self):
        args = benchmark.parse_args([
            "--sizes", "2", "100", "--shapes", "random", "shared",
            "--samples", "1", "--warmups", "0", "--rounds", "1", "--no-affinity",
        ])
        self.assertEqual(args.sizes, [2, 100])
        self.assertEqual(args.shapes, ["random", "shared"])
        upper = benchmark.parse_args([
            "--sizes", "1431655764", "--samples", "2147483647", "--warmups", "0",
        ])
        self.assertEqual(upper.samples, 2147483647)

    def test_rejects_illegal_cli_before_build_or_execution(self):
        invalid = (
            ["--sizes", "0"], ["--sizes", "1"], ["--sizes", "3"],
            ["--sizes", "1431655766"], ["--sizes", "2", "2"],
            ["--shapes", "shared", "shared"], ["--shapes", "other"],
            ["--samples", "0"], ["--warmups", "-1"], ["--rounds", "0"],
            ["--samples", "2147483648"], ["--warmups", "2147483648"],
            ["--samples", "2147483647", "--warmups", "1"],
            ["--cpu", "0", "--no-affinity"], ["--sizes", "not-a-number"],
        )
        for argv in invalid:
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    benchmark.parse_args(argv)
                self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
