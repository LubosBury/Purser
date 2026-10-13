import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)


def load_tool(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = load_tool("audit_report", "audit-report.py")


def compact(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def chain(specs):
    """Synthetic export lines in the K3 ChainLine format: refs and payload are JSON objects encoded as strings.
    The prevHash linkage is valid; the hash values themselves are arbitrary."""
    lines, previous = [], "0" * 64
    for index, (kind, refs, payload) in enumerate(specs, 1):
        digest = f"{index:064x}"
        lines.append(compact({
            "actor": "owner@example.invalid", "hash": digest, "payload": compact(payload), "prevHash": previous,
            "refs": compact(refs), "seq": index, "ts": "2026-10-09T10:00:00.000Z", "type": kind,
        }))
        previous = digest
    return lines


PLAN = {"plan": "plan-1"}
DELETE_PATH = "/v1/subscriptionIntroductoryOffers/intro-1"
POST_PATH = "/v1/subscriptionIntroductoryOffers"


def item(seq):
    return {**PLAN, "seq": str(seq), "cell": "I|sub-1|CZE|UPFRONT"}


# Executor order (M2): itemStateChanged + httpSent in one transaction, itemStateChanged + httpReceived in the next.
# After a successful write the Executor stores status null (or omits it) and outcome "ok".
CLEAN = [
    ("planCreated", PLAN, {"items": 2}),
    ("itemStateChanged", item(1), {"from": "pending", "to": "inFlight"}),
    ("httpSent", item(1), {"attempt": 1, "method": "DELETE", "naturalKey": "I-|intro-1", "op": "DELETE",
                           "path": DELETE_PATH}),
    ("itemStateChanged", item(1), {"from": "inFlight", "to": "done"}),
    ("httpReceived", item(1), {"method": "DELETE", "outcome": "ok", "path": DELETE_PATH}),
    ("itemStateChanged", item(2), {"from": "pending", "to": "inFlight"}),
    ("httpSent", item(2), {"attempt": 1, "method": "POST", "naturalKey": "I+|sub-1|CZE", "op": "POST",
                           "path": POST_PATH}),
    ("itemStateChanged", item(2), {"ascId": "intro-2", "from": "inFlight", "to": "done"}),
    ("httpReceived", item(2), {"ascId": "intro-2", "method": "POST", "outcome": "ok", "path": POST_PATH,
                               "status": None}),
]


class AuditReportTests(unittest.TestCase):
    def test_clean_export_passes_and_summarises_the_plan(self):
        code, text = tool.run(chain(CLEAN), plan="plan-1")
        self.assertEqual(code, 0, text)
        self.assertIn("plan plan-1: sent DELETE=1 POST=1; received ok=2", text)
        self.assertIn("problems: 0", text)
        self.assertIn("warnings: 0", text)

    def test_failed_write_is_counted_by_its_status(self):
        specs = CLEAN[:3] + [
            ("itemStateChanged", item(1), {"from": "inFlight", "to": "failed"}),
            ("httpReceived", item(1), {"error": {"status": 409}, "method": "DELETE", "outcome": "error",
                                       "path": DELETE_PATH, "status": 409}),
        ]
        code, text = tool.run(chain(specs), plan="plan-1")
        self.assertEqual(code, 0, text)
        self.assertIn("plan plan-1: sent DELETE=1; received 409=1", text)

    def test_broken_link_fails(self):
        lines = chain(CLEAN)
        event = json.loads(lines[2])
        event["prevHash"] = "f" * 64
        lines[2] = compact(event)
        code, text = tool.run(lines)
        self.assertEqual(code, 1)
        self.assertIn("prevHash does not match", text)

    def test_bearer_token_fails(self):
        specs = CLEAN + [("httpSent", item(3), {"method": "POST", "note": "Bearer abc", "path": "/v1/x"}),
                         ("httpReceived", item(3), {"method": "POST", "outcome": "ok", "path": "/v1/x"})]
        code, text = tool.run(chain(specs))
        self.assertEqual(code, 1)
        self.assertIn("forbidden pattern", text)

    def test_authorization_key_inside_payload_fails(self):
        specs = CLEAN + [("httpSent", item(3), {"Authorization": "x", "method": "POST", "path": "/v1/x"}),
                         ("httpReceived", item(3), {"method": "POST", "outcome": "ok", "path": "/v1/x"})]
        code, text = tool.run(chain(specs))
        self.assertEqual(code, 1)
        self.assertIn("forbidden pattern", text)

    def test_received_without_sent_fails(self):
        specs = [("httpReceived", item(1), {"method": "POST", "outcome": "ok", "path": POST_PATH})]
        code, text = tool.run(chain(specs))
        self.assertEqual(code, 1)
        self.assertIn("httpReceived without an earlier httpSent", text)

    def test_request_events_without_method_or_path_fail(self):
        specs = [("httpSent", item(1), {"path": "/v1/x"}),
                 ("httpReceived", item(1), {"method": "POST", "outcome": "ok"})]
        code, text = tool.run(chain(specs))
        self.assertEqual(code, 1)
        self.assertIn("httpSent without method", text)
        self.assertIn("httpReceived without path", text)

    def test_sent_without_received_is_only_a_warning(self):
        specs = CLEAN + [("httpSent", item(3), {"method": "POST", "path": "/v1/x"})]
        code, text = tool.run(chain(specs))
        self.assertEqual(code, 0, text)
        self.assertIn("warnings: 1", text)

    def test_plan_filter_limits_warnings_to_the_plan(self):
        other = {"plan": "plan-drill", "seq": "7", "cell": "R|sub-9|USA|UPFRONT"}
        specs = CLEAN + [("httpSent", other, {"method": "POST", "path": "/v1/subscriptionPrices"})]
        code, text = tool.run(chain(specs), plan="plan-1")
        self.assertEqual(code, 0, text)
        self.assertIn("warnings: 0", text)
        self.assertIn("warnings outside plan plan-1: 1", text)
        code, text = tool.run(chain(specs))
        self.assertIn("warnings: 1", text)
        self.assertIn("seq 10: httpSent without httpReceived (plan plan-drill)", text)

    def test_approved_probe_requests_pair_by_method_and_path(self):
        probe = {"probe": "p1", "subscription": "sub-1", "territory": "SVN"}
        patch_path = "/v1/subscriptionIntroductoryOffers/i1"
        specs = [
            ("httpSent", probe, {"method": "PATCH", "path": patch_path, "spike": "S4b"}),
            ("httpReceived", probe, {"ascId": "i1", "effect": "ended", "method": "PATCH", "outcome": "ok",
                                     "path": patch_path, "spike": "S4b", "status": None}),
            ("httpSent", probe, {"method": "POST", "path": POST_PATH, "spike": "S4b"}),
            ("httpReceived", probe, {"error": "ENTITY_ERROR | Conflict", "method": "POST", "outcome": "http",
                                     "path": POST_PATH, "spike": "S4b", "status": 409}),
        ]
        code, text = tool.run(chain(specs))
        self.assertEqual(code, 0, text)
        self.assertIn("probe p1: sent PATCH=1 POST=1; received 409=1 ok=1", text)

    def test_spike_probe_requests_are_grouped_by_spike(self):
        spike = {"spike": "S7", "step": "S7-A-2"}
        path = "/v1/subscriptionPromotionalOffers/promo-1"
        specs = [
            ("httpSent", spike, {"body": "{}", "method": "PATCH", "path": path, "query": ""}),
            ("httpReceived", spike, {"body": "{}", "method": "PATCH", "path": path, "status": 200}),
        ]
        code, text = tool.run(chain(specs))
        self.assertEqual(code, 0, text)
        self.assertIn("spike S7: sent PATCH=1; received 200=1", text)

    def test_lines_outside_the_k3_format_are_unreadable(self):
        base = {"actor": "a", "hash": "1" * 64, "prevHash": "0" * 64, "seq": 1,
                "ts": "2026-10-09T10:00:00.000Z", "type": "signIn"}
        payload_json_key = compact({**base, "payloadJSON": "{}", "refs": "{}"})
        refs_object = compact({**base, "payload": "{}", "refs": {}})
        for line in (payload_json_key, refs_object):
            with self.assertRaises(tool.AuditReportError):
                tool.run([line])
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "old.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                f.write(payload_json_key + "\n")
            self.assertEqual(tool.main([path]), 2)

    def test_missing_file_returns_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(tool.main([os.path.join(tmp, "missing.jsonl")]), 2)


if __name__ == "__main__":
    unittest.main()
