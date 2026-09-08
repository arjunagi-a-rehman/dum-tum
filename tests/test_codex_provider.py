import os
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "src" / "fixit-common.sh"
SHELLS = [path for name in ("bash", "zsh") if (path := shutil.which(name))]
FAKE_CODEX = """#!/bin/sh
if [ "$1" = exec ] && [ "$2" = --help ]; then
  printf 'help\\n' >>"$FX_TEST_CODEX_HELP_COUNT"
  printf '%s\\n' "$FX_TEST_CODEX_HELP"
  exit 0
fi

printf 'exec\\n' >>"$FX_TEST_CODEX_EXEC_COUNT"
output_file=
output_option=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output-last-message)
      output_option=$1
      shift
      output_file=$1
      ;;
  esac
  shift
done
if [ -n "$output_file" ]; then
  printf '%s\\n' "$output_option" >>"$FX_TEST_CODEX_ARGS"
else
  printf 'stdout\\n' >>"$FX_TEST_CODEX_ARGS"
fi

case "$FX_TEST_CODEX_MODE" in
  success)
    if [ -n "$output_file" ]; then
      printf 'git status\\n' >"$output_file"
    else
      printf 'git status\\n'
    fi
    ;;
  failure)
    printf 'provider failed\\n' >&2
    exit 17
    ;;
  timeout)
    printf 'provider still running\\n' >&2
    sleep 30
    ;;
esac
"""


class CodexProviderTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(dir="/tmp")
        self.tmpdir = Path(self.tempdir.name)
        self.bindir = self.tmpdir / "bin"
        self.bindir.mkdir()
        codex = self.bindir / "codex"
        codex.write_text(FAKE_CODEX)
        codex.chmod(0o755)
        self.help_count = self.tmpdir / "help.count"
        self.exec_count = self.tmpdir / "exec.count"
        self.args = self.tmpdir / "args"

    def tearDown(self):
        self.tempdir.cleanup()

    def run_codex(self, shell, help_text, mode="success", calls=1, timeout=8):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bindir}{os.pathsep}{env['PATH']}",
                "FX_AI_TIMEOUT": "0.2" if mode == "timeout" else "5",
                "FX_TEST_CODEX_ARGS": str(self.args),
                "FX_TEST_CODEX_EXEC_COUNT": str(self.exec_count),
                "FX_TEST_CODEX_HELP": help_text,
                "FX_TEST_CODEX_HELP_COUNT": str(self.help_count),
                "FX_TEST_CODEX_MODE": mode,
            }
        )
        invocation = "; ".join(
            f"_fx_ai_codex request-{index}" for index in range(calls)
        )
        script = (
            f"source {shlex.quote(str(COMMON))}; "
            "unset _FX_CODEX_OUTPUT_FILE_OPTION; "
            f"{invocation}"
        )
        return subprocess.run(
            [shell, "-c", script],
            cwd=self.tmpdir,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )

    def count(self, path):
        return len(path.read_text().splitlines()) if path.exists() else 0

    def test_supported_help_uses_output_file_shape_and_caches_detection(self):
        supported_options = (
            ("--output-last-message <FILE>", "--output-last-message"),
            ("-o <FILE>", "-o"),
        )
        for shell in SHELLS:
            for help_text, expected_option in supported_options:
                with self.subTest(shell=shell, option=expected_option):
                    result = self.run_codex(shell, help_text, calls=2)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "git status\ngit status\n")
                    self.assertEqual(self.count(self.help_count), 1)
                    self.assertEqual(self.count(self.exec_count), 2)
                    self.assertEqual(
                        self.args.read_text().splitlines(),
                        [expected_option, expected_option],
                    )
                    self.reset_logs()

    def test_unsupported_help_uses_stdout_shape_and_caches_detection(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = self.run_codex(shell, "Usage: codex exec", calls=2)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "git status\ngit status\n")
                self.assertEqual(self.count(self.help_count), 1)
                self.assertEqual(self.count(self.exec_count), 2)
                self.assertEqual(
                    self.args.read_text().splitlines(), ["stdout", "stdout"]
                )
                self.reset_logs()

    def test_nonzero_failure_is_not_retried(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = self.run_codex(
                    shell,
                    "-o, --output-last-message <FILE>",
                    mode="failure",
                )
                self.assertEqual(result.returncode, 17)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "provider failed\n")
                self.assertEqual(self.count(self.help_count), 1)
                self.assertEqual(self.count(self.exec_count), 1)
                self.reset_logs()

    def test_timeout_is_not_retried(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                started = time.monotonic()
                result = self.run_codex(
                    shell,
                    "-o, --output-last-message <FILE>",
                    mode="timeout",
                )
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 124)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "provider still running\n")
                self.assertEqual(self.count(self.help_count), 1)
                self.assertEqual(self.count(self.exec_count), 1)
                self.assertLess(elapsed, 4)
                self.reset_logs()

    def reset_logs(self):
        for path in (self.help_count, self.exec_count, self.args):
            if path.exists():
                path.unlink()


if __name__ == "__main__":
    unittest.main()
