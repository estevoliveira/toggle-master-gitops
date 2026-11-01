import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fase4_smoke", ROOT / "scripts/fase4-smoke.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
REMOTE = {"__name__": "smoke_contract_test"}
exec(compile(MODULE.REMOTE_CODE, "remote-smoke", "exec"), REMOTE)


class FakeAPI:
    def __init__(self, mode="success"):
        self.mode = mode
        self.calls = []
        self.flag = None
        self.rule = None

    def __call__(self, base, path, method, key, expected, payload):
        service = base.split("//", 1)[1].split(".", 1)[0]
        self.calls.append((service, path, method))
        if method == "DELETE":
            if self.mode == "cleanup_failure" and service == "targeting-service":
                raise REMOTE["SmokeFailure"]("DELETE: HTTP 500")
            return b""
        if service == "auth-service":
            return b"{}"
        if service == "flag-service":
            if method == "POST":
                if self.mode == "conflict":
                    raise REMOTE["SmokeFailure"]("POST /flags: HTTP 409")
                self.flag = payload
            return json.dumps(self.flag).encode()
        if service == "targeting-service":
            if method == "POST":
                self.rule = payload
            return json.dumps(self.rule).encode()
        from urllib.parse import parse_qs, urlsplit
        query = parse_qs(urlsplit(path).query)
        return json.dumps({"flag_name": query["flag_name"][0], "user_id": query["user_id"][0],
                           "result": self.mode != "wrong_decision"}).encode()


class FakeDynamoDB:
    def __init__(self, mode="success"):
        self.mode = mode
        self.calls = []

    def scan(self, **options):
        self.calls.append(options.copy())
        if self.mode == "missing":
            return {"Items": []}
        if self.mode == "access_denied":
            error = RuntimeError("private provider message must not be printed")
            error.response = {"Error": {"Code": "AccessDeniedException"}}
            raise error
        if self.mode == "pagination" and len(self.calls) == 1:
            return {"Items": [], "LastEvaluatedKey": {"event_id": {"S": "previous-page"}}}
        values = options["ExpressionAttributeValues"]
        item = {"event_id": {"S": "test-event"}, "user_id": values[":u"],
                "flag_name": values[":f"], "result": {"BOOL": True}}
        if self.mode == "unrelated":
            item["user_id"] = {"S": "another-user"}
        return {"Items": [item]}


class SmokeContracts(unittest.TestCase):
    def run_case(self, api_mode="success", dynamo_mode="success"):
        api, dynamo = FakeAPI(api_mode), FakeDynamoDB(dynamo_mode)
        output = io.StringIO()
        with patch.dict(os.environ, {"AWS_REGION": "us-east-1", "AWS_DYNAMODB_TABLE": "test-events"}):
            with contextlib.redirect_stderr(output):
                result = REMOTE["run_flow"]({"namespace": "toggle-master", "api_key": "test-key-not-a-real-secret"},
                                            api=api, dynamodb=dynamo, sleep=lambda _: None)
        self.assertNotIn("test-key-not-a-real-secret", output.getvalue() + json.dumps(result))
        return result, api, dynamo

    def test_success_correlates_event_and_cleans_only_its_fixtures(self):
        result, api, dynamo = self.run_case()
        self.assertTrue(result["ok"])
        deletes = [(service, path) for service, path, method in api.calls if method == "DELETE"]
        self.assertEqual(deletes, [("targeting-service", "/rules/" + result["flag_name"]),
                                  ("flag-service", "/flags/" + result["flag_name"])])
        self.assertEqual(dynamo.calls[0]["ExpressionAttributeValues"][":u"]["S"], result["user_id"])

    def test_conflict_never_deletes_a_resource_it_did_not_create(self):
        result, api, dynamo = self.run_case(api_mode="conflict")
        self.assertFalse(result["ok"])
        self.assertFalse(any(method == "DELETE" for _, _, method in api.calls))
        self.assertEqual(dynamo.calls, [])

    def test_wrong_evaluation_cleans_fixtures_without_claiming_async_success(self):
        result, api, dynamo = self.run_case(api_mode="wrong_decision")
        self.assertFalse(result["ok"])
        self.assertEqual(sum(method == "DELETE" for _, _, method in api.calls), 2)
        self.assertEqual(dynamo.calls, [])

    def test_missing_or_unrelated_event_cannot_pass(self):
        for mode in ("missing", "unrelated"):
            with self.subTest(mode=mode):
                result, api, dynamo = self.run_case(dynamo_mode=mode)
                self.assertFalse(result["ok"])
                self.assertEqual(len(dynamo.calls), 12)
                self.assertEqual(sum(method == "DELETE" for _, _, method in api.calls), 2)

    def test_scan_pagination_is_followed(self):
        result, _, dynamo = self.run_case(dynamo_mode="pagination")
        self.assertTrue(result["ok"])
        self.assertEqual(dynamo.calls[1]["ExclusiveStartKey"], {"event_id": {"S": "previous-page"}})

    def test_scan_permission_error_is_reported_without_provider_message(self):
        result, _, _ = self.run_case(dynamo_mode="access_denied")
        self.assertFalse(result["ok"])
        self.assertIn("AccessDeniedException", result["error"])
        self.assertNotIn("private provider message", json.dumps(result))

    def test_cleanup_failure_prevents_a_clean_success(self):
        result, api, _ = self.run_case(api_mode="cleanup_failure")
        self.assertFalse(result["ok"])
        self.assertEqual(len(result["cleanup_errors"]), 1)
        self.assertIn(("flag-service", "/flags/" + result["flag_name"], "DELETE"), api.calls)


if __name__ == "__main__":
    unittest.main()
