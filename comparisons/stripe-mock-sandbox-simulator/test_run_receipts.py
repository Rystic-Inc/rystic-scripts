"""Tests for run_receipts.py's request masking.  Run: python3 -m unittest test_run_receipts"""
import unittest

from run_receipts import Client, mask


class Mask(unittest.TestCase):
    def test_masks_object_ids_in_paths(self):
        self.assertEqual(mask("GET /v1/charges/ch_1ExampleChargeId"), "GET /v1/charges/ch_…")
        self.assertEqual(mask("GET /v1/balance_transactions/txn_1ExampleBalanceTxn"),
                         "GET /v1/balance_transactions/txn_…")
        self.assertEqual(mask("GET /v1/payment_intents/pi_3AbC"), "GET /v1/payment_intents/pi_…")

    def test_masks_object_ids_in_query_strings(self):
        self.assertEqual(mask("GET /v1/charges?customer=cus_1ExampleCustomer&limit=10"),
                         "GET /v1/charges?customer=cus_…&limit=10")
        self.assertEqual(mask("GET /v1/events?limit=100&starting_after=evt_1AbC"),
                         "GET /v1/events?limit=100&starting_after=evt_…")

    def test_keeps_resource_names_and_the_never_created_id(self):
        for path in ("POST /v1/payment_intents", "GET /v1/balance_transactions", "GET /v1/customers/cus_doesnotexist"):
            self.assertEqual(mask(path), path)


class Unreachable(unittest.TestCase):
    def test_a_server_that_does_not_answer_is_status_0(self):
        client = Client("http://127.0.0.1:1", "sk_test_...")
        self.assertEqual(client.call("GET", "/v1/customers"), (0, None))


if __name__ == "__main__":
    unittest.main()
