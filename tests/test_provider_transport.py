import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "src" / "fixit-common.sh"
SHELLS = [path for name in ("bash", "zsh") if (path := shutil.which(name))]
PROVIDERS = {
    "openrouter": ("_fx_ai_openrouter test", '{"choices":[{"message":{"content":"ls -la"}}]}'),
    "openai": ("_fx_ai_openai test", '{"choices":[{"message":{"content":"ls -la"}}]}'),
    "anthropic": ("_fx_ai_anthropic test", '{"content":[{"type":"text","text":"ls -la"}]}'),
    "gemini": ("_fx_ai_gemini test", '{"candidates":[{"content":{"parts":[{"text":"ls -la"}]}}]}'),
}


class ProviderTransportTests(unittest.TestCase):
    def test_http_nonzero_and_timeout_payloads_are_never_parsed(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            for shell in SHELLS:
                for provider, (command, payload) in PROVIDERS.items():
                    for status in (17, 124):
                        with self.subTest(shell=shell, provider=provider, status=status):
                            script = (
                                f"source {shlex.quote(str(COMMON))}; "
                                "_fx_ai_http() { "
                                f"printf '%s\\n' {shlex.quote(payload)}; "
                                "printf 'transport failed\\n' >&2; "
                                f"return {status}; "
                                "}; "
                                f"{command}"
                            )
                            env = os.environ.copy()
                            env.update(
                                {
                                    "OPENROUTER_API_KEY": "test-router-key",
                                    "OPENAI_API_KEY": "test-openai-key",
                                    "ANTHROPIC_API_KEY": "test-anthropic-key",
                                    "GEMINI_API_KEY": "test-gemini-key",
                                }
                            )
                            result = subprocess.run(
                                [shell, "-c", script],
                                cwd=tmp,
                                env=env,
                                text=True,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                timeout=8,
                                check=False,
                            )
                            self.assertEqual(result.returncode, status)
                            self.assertEqual(result.stdout, "")
                            self.assertEqual(result.stderr, "transport failed\n")


if __name__ == "__main__":
    unittest.main()
