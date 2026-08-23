import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "collector"))

from family_finance_collector.config import load_config
from family_finance_collector.rules import MailEnvelope, classify


class CollectorRuleTests(unittest.TestCase):
    def _config(self):
        return {
            "version": 1,
            "sources": [
                {
                    "household_label": "fictional_household",
                    "source_key": "gmail_finance",
                    "source_type": "gmail",
                    "display_label": "Fictional mailbox",
                    "authority_level": "reconciling",
                    "cadence_seconds": 900,
                    "freshness_sla_seconds": 3600,
                    "gmail": {
                        "initial_query": "newer_than:30d",
                        "rules": [
                            {
                                "rule_id": "receipt",
                                "observation_type": "purchase_receipt",
                                "authority_level": "supplemental",
                                "from_regex": "(?i)receipt@example\\.test$",
                                "subject_regex": "(?i)order",
                                "amount_regex": "(?P<amount>[0-9][0-9,]*)\\s*KRW",
                                "currency": "KRW"
                            }
                        ]
                    }
                }
            ]
        }

    def test_match_extracts_amount_without_persisting_raw_mail_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "collector.json"
            path.write_text(json.dumps(self._config()), encoding="utf-8")
            source = load_config(path).sources[0]
        envelope = MailEnvelope(
            message_id="message-123",
            internal_date_ms=1_700_000_000_000,
            sender="Fictional Store <receipt@example.test>",
            subject="Your order is complete",
            snippet="Private product name total 12,345 KRW paid successfully",
        )
        observations = classify(envelope, source.gmail.rules)
        self.assertEqual(len(observations), 1)
        obs = observations[0]
        self.assertEqual(str(obs.amount), "12345")
        self.assertEqual(obs.currency, "KRW")
        self.assertEqual(obs.normalized_payload["sender_domain"], "example.test")
        serialized = json.dumps(obs.normalized_payload)
        self.assertNotIn("Private product name", serialized)
        self.assertNotIn("Your order is complete", serialized)
        self.assertNotIn("message-123", serialized)
        self.assertEqual(len(obs.external_event_hash), 64)

    def test_unmatched_message_creates_no_observation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "collector.json"
            path.write_text(json.dumps(self._config()), encoding="utf-8")
            source = load_config(path).sources[0]
        envelope = MailEnvelope(
            message_id="unmatched",
            internal_date_ms=1_700_000_000_000,
            sender="newsletter@example.test",
            subject="Order tips",
            snippet="12,345 KRW",
        )
        self.assertEqual(classify(envelope, source.gmail.rules), [])

    def test_invalid_rule_without_matcher_is_rejected(self):
        raw = self._config()
        raw["sources"][0]["gmail"]["rules"][0].pop("from_regex")
        raw["sources"][0]["gmail"]["rules"][0].pop("subject_regex")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "collector.json"
            path.write_text(json.dumps(raw), encoding="utf-8")
            with self.assertRaises(ValueError):
                load_config(path)


if __name__ == "__main__":
    unittest.main()
