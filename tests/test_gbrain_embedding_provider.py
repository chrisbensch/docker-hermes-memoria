from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "validate_gbrain_embedding_provider",
    ROOT / "scripts" / "validate-gbrain-embedding-provider.py",
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EmbeddingProviderValidationTests(unittest.TestCase):
    def test_url_appends_embeddings(self) -> None:
        self.assertEqual(
            MODULE.embeddings_url("http://embedding.example:8000/v1/"),
            "http://embedding.example:8000/v1/embeddings",
        )

    def test_url_rejects_non_http_scheme(self) -> None:
        with self.assertRaisesRegex(ValueError, "absolute"):
            MODULE.embeddings_url("file:///tmp/provider")

    def test_response_accepts_expected_numeric_vector(self) -> None:
        MODULE.validate_response({"data": [{"embedding": [0.1, 2, -3.5]}]}, 3)

    def test_response_rejects_wrong_dimension(self) -> None:
        with self.assertRaisesRegex(ValueError, "expected 3, got 2"):
            MODULE.validate_response({"data": [{"embedding": [0.1, 0.2]}]}, 3)

    def test_response_rejects_malformed_body(self) -> None:
        with self.assertRaisesRegex(ValueError, r"data\[0\]"):
            MODULE.validate_response({"error": "no model"}, 3)


if __name__ == "__main__":
    unittest.main()
