"""The signed runtime must remain unchanged even without launch-time -B."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class GatewayPackagingTests(unittest.TestCase):
    def test_gateway_imports_do_not_write_bytecode(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            resources = work / "Resources"
            runtime = resources / "runtime"
            runtime.mkdir(parents=True)
            for name in ("__init__.py", "xcreen_gateway.py"):
                shutil.copyfile(root / "runtime" / name, runtime / name)
            (runtime / "xcreen_tools.py").write_text(
                "import sys\nassert sys.dont_write_bytecode\n"
                "class EvidenceReader:\n def __init__(self, root): pass\n"
                "class VaultDailyWriter: pass\n"
                "def register_xcreen_tools(*args): pass\n"
            )
            hermes = work / "hermes"
            (hermes / "tui_gateway").mkdir(parents=True)
            (hermes / "hermes_bootstrap.py").write_text("import sys\nassert sys.dont_write_bytecode\n")
            (hermes / "tui_gateway" / "__init__.py").write_text("")
            (hermes / "tui_gateway" / "entry.py").write_text("def main(): pass\n")
            env = dict(os.environ, HERMES_HOME=str(hermes))
            env.pop("PYTHONDONTWRITEBYTECODE", None)
            env.pop("PYTHONPYCACHEPREFIX", None)
            result = subprocess.run(
                [sys.executable, str(runtime / "xcreen_gateway.py"),
                 "--hermes-root", str(hermes), "--evidence-root", str(work)],
                env=env, capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(resources.rglob("__pycache__")), [])
            self.assertEqual(list(resources.rglob("*.pyc")), [])


if __name__ == "__main__":
    unittest.main()
