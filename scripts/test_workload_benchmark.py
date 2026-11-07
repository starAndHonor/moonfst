#!/usr/bin/env python3
"""Frozen UTF-8 wire vectors, corruption rejection and benchmark validation."""
import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from scripts import prepare_workload as workload
from scripts import workload_benchmark as runner

TINY = bytes.fromhex(
    "4d465354573030310400000006000000030000000200000000000000e69c88"
    "0400000007000000000000006d6f6f6e030000000b00000000000000626974"
    "060000000d00000000000000e69c88e58594060000001100000000000000e4b8ade69687"
    "040000001300000000000000f09f9982"
)


def payload():
    expected = workload.reference(TINY, "shuffled")
    result = {key: expected[key] for key in (
        "n", "total", "order", "query_seed", "order_hash", "dataset_hash", "b_hash", "union_hash", "input_key_bytes",
    )}
    result.update(schema=1, measurement_revision=runner.MEASUREMENT_REVISION,
                  engine="moonbit", mode="timing", fst_bytes=123, samples=2, warmups=1)
    result["metrics"] = []
    for name in workload.METRICS:
        checksum, count = ["123", 4] if name == "build" else expected["expected"][name]
        result["metrics"].append(dict(name=name, checksum=checksum, result_count=count, samples_us=[2.0, 3.0]))
    return result, expected


class CorpusTests(unittest.TestCase):
    def test_duplicate_and_real_frequencies(self):
        entries, duplicates = workload.parse_dictionary("月 2 n\n中文 17 n\n月 2 n\n".encode())
        self.assertEqual(entries, [("中文".encode(), 17), ("月".encode(), 2)])
        self.assertEqual(duplicates, 1)
        for invalid in ("月 2 n\n月 3 n", "月 -1 n", "月 18446744073709551616 n", "月 2"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                workload.parse_dictionary(invalid.encode())

    def test_cache_digest_is_required_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"dict.txt"
            path.write_bytes(b"wrong corpus")
            with patch("urllib.request.urlopen") as network, self.assertRaises(ValueError):
                workload.fetch_dictionary(path)
            network.assert_not_called()

    def test_json_output_name_cannot_overwrite_binary_with_sidecar(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"workload.json"
            entries = [(b"a", 1), (b"b", 2), (b"c", 3)]
            with patch.object(workload, "fetch_dictionary", return_value=(entries, {})):
                workload.prepare(2, Path(directory)/"unused", path)
            self.assertEqual(workload.decode_workload(path.read_bytes())[0], 2)
            self.assertEqual(json.loads(Path(str(path)+".json").read_text())["n"], 2)

    def test_wire_unicode_boundaries_and_full_values(self):
        n, entries = workload.decode_workload(TINY)
        self.assertEqual(n, 4)
        self.assertEqual(entries, [("月".encode(), 2), (b"moon", 7), (b"bit", 11),
                                   ("月兔".encode(), 13), ("中文".encode(), 17), ("🙂".encode(), 19)])
        changed = bytearray(TINY)
        struct.pack_into("<Q", changed, 20, (1 << 64)-1)
        self.assertEqual(workload.decode_workload(changed)[1][0][1], (1 << 64)-1)

    def test_wire_rejects_corrupt_lengths_headers_duplicates_and_trailing_bytes(self):
        bad_length = bytearray(TINY)
        struct.pack_into("<I", bad_length, 16, 0xFFFFFFFF)
        bad_size = bytearray(TINY)
        struct.pack_into("<I", bad_size, 8, 3)
        _, entries = workload.decode_workload(TINY)
        entries[-1] = entries[0]
        duplicate = TINY[:16] + b"".join(struct.pack("<IQ", len(k), v)+k for k, v in entries)
        for raw in (b"", TINY[:15], b"X"+TINY[1:], TINY[:-1], TINY+b"x", bad_length, bad_size, duplicate):
            with self.subTest(raw=bytes(raw[:20])), self.assertRaises(ValueError):
                workload.decode_workload(raw)

    def test_frozen_query_order_and_mixed_result(self):
        self.assertEqual(workload.shuffled_indices(4, 0x12345678), [2, 1, 0, 3])
        expected = workload.reference(TINY, "shuffled")
        self.assertEqual(expected["dataset_hash"], "897339413234894094")
        self.assertEqual(expected["union_hash"], "15913185213158097098")
        self.assertEqual(expected["order_hash"], "13806630394080953814")
        self.assertEqual(expected["expected"]["lookup_mixed"], ["13", 2])
        self.assertEqual(workload.reference(TINY, "sorted")["expected"]["lookup_mixed"], ["13", 2])
        self.assertNotEqual(expected["order_hash"], expected["dataset_hash"])
        for order, seed in (("invalid", 0), ("shuffled", -1), ("shuffled", 1 << 32)):
            with self.assertRaises(ValueError):
                workload.reference(TINY, order, seed)


class ProtocolTests(unittest.TestCase):
    def test_report_cannot_relabel_legacy_measurements(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            with self.assertRaises(ValueError):
                runner.report(destination, {"config": {}})
            self.assertEqual(list(destination.iterdir()), [])

    def test_valid_payload_and_query_order_failure(self):
        value, expected = payload()
        runner.validate_timing(value, expected, "moonbit", 2, 1)
        for key, wrong in (("order_hash", expected["dataset_hash"]), ("mode", "memory-build"),
                           ("measurement_revision", 1),
                           ("query_seed", 1), ("total", 4), ("fst_bytes", True), ("n", 4.0)):
            bad = copy.deepcopy(value)
            bad[key] = wrong
            with self.subTest(key=key), self.assertRaises(ValueError):
                runner.validate_timing(bad, expected, "moonbit", 2, 1)
        legacy = copy.deepcopy(value)
        del legacy["measurement_revision"]
        with self.assertRaises(ValueError):
            runner.validate_timing(legacy, expected, "moonbit", 2, 1)

    def test_each_operation_result_and_timing_must_validate(self):
        value, expected = payload()
        for index in range(len(workload.METRICS)):
            for key, wrong in (("checksum", "999"), ("result_count", 999), ("samples_us", [float("nan"), 1]),
                               ("samples_us", [0, 1]), ("samples_us", [1]), ("samples_us", [True, 1])):
                bad = copy.deepcopy(value)
                bad["metrics"][index][key] = wrong
                with self.subTest(index=index, key=key), self.assertRaises(ValueError):
                    runner.validate_timing(bad, expected, "moonbit", 2, 1)

    def test_metrics_are_complete_and_not_duplicated(self):
        value, expected = payload()
        for metrics in (None, {}, [], value["metrics"][:-1], value["metrics"][::-1],
                        value["metrics"][:-1]+value["metrics"][:1]):
            value["metrics"] = metrics
            with self.assertRaises(ValueError):
                runner.validate_timing(value, expected, "moonbit", 2, 1)

    def test_memory_identity_checksum_and_monotonic_peak(self):
        _, expected = payload()
        for mode in runner.MEMORY_MODES:
            value = dict(schema=1, measurement_revision=runner.MEASUREMENT_REVISION,
                         engine="moonbit", mode=mode, n=4, memory_source="proc-self-status",
                         checksum=expected["union_hash"] if mode == "memory-union" else expected["dataset_hash"],
                         result_count=6 if mode == "memory-union" else 4,
                         fst_bytes=0 if mode == "memory-baseline" else 123,
                         baseline_rss_kib=100, after_rss_kib=120, peak_rss_kib=125, baseline_peak_rss_kib=110,
                         validation_after_rss_kib=130, validation_peak_rss_kib=135)
            runner.validate_memory(value, expected, "moonbit", mode, 123)
            for key, wrong in (("checksum", "0"), ("result_count", True), ("baseline_rss_kib", 0),
                               ("measurement_revision", 1),
                               ("peak_rss_kib", 109), ("after_rss_kib", -1)):
                bad = dict(value, **{key: wrong})
                with self.subTest(mode=mode, key=key), self.assertRaises(ValueError):
                    runner.validate_memory(bad, expected, "moonbit", mode, 123)


if __name__ == "__main__":
    unittest.main()
