"""Server against the real installed Hermes; no inference.

Opt-in: set XCREEN_HERMES_ROOT (and optionally XCREEN_HERMES_PYTHON). It uses your real
HERMES_HOME and creates one hidden session titled "xCreen". A synthetic HERMES_HOME is not
used on purpose: Hermes treats it as a fresh install and starts rebuilding its apps.
"""
import os
import sys
import unittest

from tests.helpers import TempDirTestCase, run
from xcreen_server.service import XCreenService


class InstalledHermesTests(TempDirTestCase):
    def test_bundled_runtime_connects_reads_models_history_and_visibility(self):
        root = os.environ.get("XCREEN_HERMES_ROOT")
        if not root:
            self.skipTest("set XCREEN_HERMES_ROOT to installed Hermes")
        python = os.environ.get("XCREEN_HERMES_PYTHON", sys.executable)
        config = self.config()
        config.hermes_python, config.hermes_root = python, root

        async def scenario():
            service = XCreenService(config, encoder=None)
            await service.start(connect=False)
            try:
                await service.connection("connect")
                status = service.status()
                self.assertTrue(status["hermes"]["connected"], status["hermes"]["error"])
                self.assertTrue(status["hermes"]["session"])
                models = await service.models()
                self.assertIsInstance(models["routes"], list)
                history = await service.history(None)
                self.assertIn("messages", history)
                self.assertIs(service.status()["session_visible_confirmed"], False)
                await service.connection("reconnect")  # resumes the stored session
                self.assertEqual(service.status()["hermes"]["session"], status["hermes"]["session"])
            finally:
                await service.stop()

        run(scenario(), timeout=120)


if __name__ == "__main__":
    unittest.main()
