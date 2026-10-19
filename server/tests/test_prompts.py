from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace as N
import unittest

from tests.helpers import ROOT  # noqa: F401 - sets sys.path
from xcreen_server import prompts

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class PromptTests(unittest.TestCase):
    """Golden files were produced by the 1.x Swift XCreenPrompts: the port is byte-identical."""

    def test_manual_prompt_matches_swift(self):
        self.assertEqual(prompts.manual("Q?"), (FIXTURES / "prompt_manual.txt").read_text())

    def test_batch_prompt_matches_swift(self):
        t = datetime.fromtimestamp(1_760_000_000, timezone.utc)
        text = prompts.batch("batch-1", [N(id="image-1", timestamp=t)],
                             [N(id="ocr-1", timestamp=t, text="hello   world\n x", app="com.app"), N(id="ocr-2", timestamp=t, text="hello world x", app="com.app")],
                             t, t + timedelta(seconds=300))
        self.assertEqual(text, (FIXTURES / "prompt_batch.txt").read_text())

    def test_batch_prompt_bounds_ocr_previews(self):
        t = datetime.now(timezone.utc)
        ocr = [N(id=f"ocr-{i}", timestamp=t, text="x" * 1000 + str(i), app="a" * 200) for i in range(40)]
        text = prompts.batch("batch-2", [N(id="image-1", timestamp=t)], ocr, t, t)
        self.assertIn("16 more not listed", text)
        self.assertNotIn("x" * 241, text)
        self.assertLess(len(text.encode()), 32_000)


if __name__ == "__main__":
    unittest.main()
