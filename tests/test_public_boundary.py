import tempfile
import unittest
from pathlib import Path

import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import check_public_boundary as scanner  # noqa: E402


class PublicBoundaryScannerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel: str, content: str = "safe") -> Path:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def findings(self, terms=None):
        return scanner.scan(self.root, terms=terms or [])

    def test_safe_source_passes(self):
        self.write("src/example.py", "print('synthetic example')")
        self.assertEqual([], self.findings())

    def test_real_env_file_is_blocked(self):
        self.write(".env", "DB_PASSWORD=example")
        self.assertTrue(any(rel == ".env" for rel, _ in self.findings()))

    def test_env_example_is_allowed(self):
        self.write(".env.example", "DB_PASSWORD=change-me")
        self.assertEqual([], self.findings())

    def test_financial_export_outside_synthetic_path_is_blocked(self):
        self.write("data/card-export.csv", "date,amount\n2026-01-01,100")
        self.assertTrue(any(rel == "data/card-export.csv" for rel, _ in self.findings()))

    def test_synthetic_export_is_allowed(self):
        self.write("examples/synthetic/card-export.csv", "date,amount\n2026-01-01,100")
        self.assertEqual([], self.findings())

    def test_private_data_top_level_directory_is_blocked(self):
        self.write("private-data/notes.md", "private")
        self.assertTrue(any(rel == "private-data/notes.md" for rel, _ in self.findings()))

    def test_rrn_shape_is_blocked(self):
        rrn_like = "900101-" + "1" + "234567"
        self.write("docs/example.md", rrn_like)
        self.assertTrue(any("resident-registration" in reason for _, reason in self.findings()))

    def test_private_key_material_is_blocked(self):
        key_marker = "-----BEGIN " + "PRIVATE KEY-----\nnot-a-real-key"
        self.write("docs/key.md", key_marker)
        self.assertTrue(any("private-key" in reason for _, reason in self.findings()))

    def test_runtime_denylist_blocks_exact_household_term_without_embedding_it_in_rules(self):
        private_term = "PRIVATE_" + "HOUSEHOLD_TERM_FOR_TEST"
        self.write("docs/post.md", f"value={private_term}")
        findings = self.findings([private_term])
        self.assertTrue(any("denylist match fingerprint=" in reason for _, reason in findings))
        self.assertFalse(any(private_term in reason for _, reason in findings))


if __name__ == "__main__":
    unittest.main()
