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


class TimeoutTests(unittest.TestCase):
    def invoke(self, shell, command, input_text=None, timeout=8):
        script = f"source {shlex.quote(str(COMMON))}; {command}"
        return subprocess.run(
            [shell, "-c", script],
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )

    def test_success_forwards_stdin_stdout_and_stderr(self):
        child = (
            "IFS= read -r line; "
            "printf 'out:%s\\n' \"$line\"; "
            "printf 'err:%s\\n' \"$line\" >&2"
        )
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = self.invoke(
                    shell,
                    f"_fx_timeout 5 sh -c {shlex.quote(child)}",
                    input_text="hello stdin\n",
                )
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "out:hello stdin\n")
                self.assertEqual(result.stderr, "err:hello stdin\n")

    def test_nonzero_status_and_diagnostics_are_preserved(self):
        child = "printf 'partial output\\n'; printf 'provider failed\\n' >&2; exit 7"
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = self.invoke(
                    shell, f"_fx_timeout 5 sh -c {shlex.quote(child)}"
                )
                self.assertEqual(result.returncode, 7)
                self.assertEqual(result.stdout, "partial output\n")
                self.assertEqual(result.stderr, "provider failed\n")

    def test_timeout_returns_124_and_preserves_partial_output(self):
        child = "printf 'partial output\\n'; printf 'still running\\n' >&2; sleep 30"
        for shell in SHELLS:
            with self.subTest(shell=shell):
                started = time.monotonic()
                result = self.invoke(
                    shell, f"_fx_timeout 0.2 sh -c {shlex.quote(child)}"
                )
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 124)
                self.assertEqual(result.stdout, "partial output\n")
                self.assertEqual(result.stderr, "still running\n")
                self.assertLess(elapsed, 4)

    def test_timeout_kills_nested_descendants(self):
        for shell in SHELLS:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(dir="/tmp") as tmp:
                tmpdir = Path(tmp)
                pidfile = tmpdir / "descendant.pid"
                descendant = tmpdir / "descendant.sh"
                parent = tmpdir / "parent.sh"
                descendant.write_text(
                    "#!/bin/sh\n"
                    "trap '' TERM\n"
                    "printf '%s\\n' \"$$\" >\"$1\"\n"
                    "sleep 30\n"
                )
                parent.write_text(
                    "#!/bin/sh\n"
                    f"sh {shlex.quote(str(descendant))} \"$1\" &\n"
                    "while [ ! -s \"$1\" ]; do sleep 0.01; done\n"
                    "wait\n"
                )
                descendant.chmod(0o755)
                parent.chmod(0o755)

                result = self.invoke(
                    shell,
                    "_fx_timeout 1 "
                    f"{shlex.quote(str(parent))} {shlex.quote(str(pidfile))}",
                )
                self.assertEqual(result.returncode, 124, result.stderr)
                self.assertTrue(
                    pidfile.exists(),
                    f"stdout={result.stdout!r} stderr={result.stderr!r} "
                    f"parent={parent.read_text()!r} descendant={descendant.read_text()!r}",
                )
                pid = int(pidfile.read_text().strip())

                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and self.process_exists(pid):
                    time.sleep(0.05)
                self.assertFalse(
                    self.process_exists(pid), f"descendant process {pid} survived timeout"
                )

    @staticmethod
    def process_exists(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
        return bool(state.stdout.strip()) and not state.stdout.lstrip().startswith("Z")


if __name__ == "__main__":
    unittest.main()
