"""Tests for compare_payments.py.  Run: python3 -m unittest test_compare_payments"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

from compare_payments import compare, compare_step, load, same, table

HERE = os.path.dirname(os.path.abspath(__file__))


def fixture(name):
    return load(os.path.join(HERE, "testdata", name))


class ComparePayments(unittest.TestCase):
    def merged(self, *servers):
        return compare(fixture("stripe.json"), [fixture(s) for s in servers])

    def test_match_ignores_timing_requests_and_masked_ids(self):
        m = self.merged("match.json")
        self.assertEqual(m["agrees_with_stripe"], {"same_server": 3})
        for n in ("1", "2", "3"):
            self.assertEqual(m["per_step"][n]["same_server"]["verdict"], "match")

    def test_field_mismatch_names_each_differing_field(self):
        m = self.merged("mismatch.json")
        self.assertEqual(m["agrees_with_stripe"], {"field_mismatch": 1})
        step2 = m["per_step"]["2"]["field_mismatch"]
        self.assertEqual(step2["verdict"], "differs")
        self.assertEqual(step2["fields"], ["bt.fee"])
        step3 = m["per_step"]["3"]["field_mismatch"]
        self.assertEqual(step3["fields"], ["event_types.charge.updated"])

    def test_missing_step_is_not_a_match(self):
        m = self.merged("missing.json")
        self.assertEqual(m["per_step"]["3"]["missing_step"]["verdict"], "missing")
        self.assertEqual(m["agrees_with_stripe"], {"missing_step": 2})

    def test_error_where_stripe_succeeded(self):
        m = self.merged("error.json")
        step1 = m["per_step"]["1"]["error_server"]
        self.assertEqual(step1["verdict"], "differs")
        self.assertEqual(step1["fields"], ["error.type", "status"])
        self.assertEqual(step1["note"], "error where Stripe succeeded")
        self.assertEqual(m["agrees_with_stripe"], {"error_server": 2})

    def test_several_servers_and_table(self):
        m = self.merged("match.json", "mismatch.json", "missing.json", "error.json")
        self.assertEqual(list(m["servers"]), ["stripe", "same_server", "field_mismatch", "missing_step", "error_server"])
        text = table(m)
        self.assertIn("agrees with Stripe", text)
        self.assertIn("3/3", text)
        self.assertIn("missing", text)

    def test_duplicate_labels_get_distinct_keys(self):
        m = self.merged("match.json", "match.json")
        self.assertEqual(list(m["agrees_with_stripe"]), ["same_server", "same_server_2"])

    def test_receipts_results_use_calls(self):
        m = compare(fixture("receipts-stripe.json"), [fixture("receipts-server.json")])
        self.assertIn("per_call", m)
        self.assertEqual(m["per_call"]["1"]["receipts_server"]["fields"], ["email"])
        self.assertEqual(m["agrees_with_stripe"], {"receipts_server": 1})

    def test_cli_writes_merged_json(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "merged.json")
            run = subprocess.run([sys.executable, os.path.join(HERE, "compare_payments.py"),
                                  os.path.join(HERE, "testdata", "stripe.json"),
                                  os.path.join(HERE, "testdata", "mismatch.json"), "--out", out],
                                 capture_output=True, text=True, check=True)
            self.assertIn("Field Mismatch", run.stdout)
            with open(out) as f:
                self.assertEqual(json.load(f)["agrees_with_stripe"], {"field_mismatch": 1})

    def test_cli_stamps_the_run(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "merged.json")
            subprocess.run([sys.executable, os.path.join(HERE, "compare_payments.py"),
                            os.path.join(HERE, "testdata", "stripe.json"),
                            os.path.join(HERE, "testdata", "match.json"), "--out", out,
                            "--meta", "date=2026-10-18", "--meta", "sandbox=new, empty=before the run"],
                           capture_output=True, text=True, check=True)
            with open(out) as f:
                merged = json.load(f)
            self.assertEqual(merged["run"], {"date": "2026-10-18", "sandbox": "new, empty=before the run"})
            self.assertEqual(list(merged)[0], "run")

    def test_cli_refuses_a_meta_without_a_value(self):
        run = subprocess.run([sys.executable, os.path.join(HERE, "compare_payments.py"),
                              os.path.join(HERE, "testdata", "stripe.json"),
                              os.path.join(HERE, "testdata", "match.json"), "--meta", "date"],
                             capture_output=True, text=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("KEY=VALUE", run.stderr)


class CompareStep(unittest.TestCase):
    def verdict(self, want, got):
        return compare_step({"result": want}, {"result": got})

    def test_empty_dict_is_not_an_absent_field(self):
        self.assertEqual(self.verdict({}, {})["verdict"], "match")
        self.assertEqual(self.verdict({"a": {}}, {})["fields"], ["a"])
        self.assertEqual(self.verdict({"a": {}}, {"a": None})["fields"], ["a"])
        self.assertEqual(self.verdict({"status": 400, "error": {}}, {"status": 400})["fields"], ["error"])

    def test_unreachable_server_is_an_error(self):
        v = self.verdict({"status": 200}, {"status": 0})
        self.assertEqual(v["note"], "error where Stripe succeeded")

    def test_only_masked_object_ids_match_any_id(self):
        self.assertTrue(same("ch_\u2026", "ch_3AbC"))
        self.assertFalse(same("ch_\u2026", "pi_3AbC"))
        self.assertFalse(same("resource_\u2026", "resource_missing"))
        self.assertFalse(same("ch_a", "ch_b"))

    def test_runs_of_different_scripts_are_refused(self):
        with self.assertRaises(ValueError):
            compare(fixture("stripe.json"), [fixture("receipts-server.json")])


if __name__ == "__main__":
    unittest.main()
