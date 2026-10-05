import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AgentProviderRefusalTest(unittest.TestCase):
    def test_agent_providers_never_launch_even_with_cached_sandbox_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "invoked"
            for binary in ("codex", "agy"):
                path = Path(tmp) / binary
                path.write_text("#!/bin/sh\nprintf called > \"$REVIEW_MARKER\"\n")
                path.chmod(0o755)
            env = os.environ.copy()
            env.update(PATH=tmp + os.pathsep + env["PATH"], REVIEW_MARKER=str(marker))
            for shell in (shutil.which("bash"), shutil.which("zsh")):
                for provider in ("codex", "antigravity"):
                    for entry in (f"_fx_ai_{provider} task", "_fx_ai_resolve task"):
                        with self.subTest(shell=shell, provider=provider, entry=entry):
                            command = (f"source {shlex.quote(str(ROOT / 'src/fixit-common.sh'))}; "
                                       f"FX_PROVIDER={provider}; _FX_CODEX_CONFINEMENT_SUPPORTED=1; "
                                       f"_FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED=1; {entry}")
                            result = subprocess.run([shell, "-c", command], env=env, text=True,
                                                    capture_output=True, timeout=5)
                            self.assertEqual(result.returncode, 126, result.stderr)
                            self.assertFalse(marker.exists())
                            self.assertIn("cannot prove read-only/no-tools support", result.stderr)
