import os
import signal
import sys
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "src" / "fixit-common.sh"
AI_HELPER = ROOT / "src" / "fixit-ai.py"
SHELLS = [path for name in ("bash", "zsh") if (path := shutil.which(name))]

SPEC = spec_from_file_location("fixit_ai_timeout_test", AI_HELPER)
AI_MODULE = module_from_spec(SPEC)
SPEC.loader.exec_module(AI_MODULE)


class TimeoutTests(unittest.TestCase):
    def test_interruption_cleans_up_provider(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as directory:
                pidfile = Path(directory) / "pid"
                child = "import os,time,pathlib; pathlib.Path(" + repr(str(pidfile)) + ").write_text(str(os.getpid())); time.sleep(60)"
                process = subprocess.Popen([sys.executable, str(ROOT / "src/fixit-ai.py"), "timeout", "30", sys.executable, "-c", child], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 5
                    while not pidfile.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(pidfile.exists())
                    process.send_signal(sig)
                    process.communicate(timeout=5)
                    self.assertNotEqual(process.returncode, 0)
                    self.assertFalse(self.process_exists(int(pidfile.read_text())))
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()

    def test_function_only_provider_is_not_ready(self):
        for shell in SHELLS:
            result = self.invoke(shell, "opencode() { :; }; PATH=/usr/bin:/bin; FX_PROVIDER=opencode; _fx_ai_ready")
            self.assertNotEqual(result.returncode, 0)

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
                    "_fx_timeout 3 "
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

    def test_non_finite_timeouts_are_rejected_before_spawn(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            marker = Path(tmp) / "spawned"
            child = f"touch {shlex.quote(str(marker))}"
            for value in ("nan", "inf", "-inf"):
                with self.subTest(value=value):
                    result = subprocess.run(
                        [sys.executable, str(AI_HELPER), "timeout", value, "sh", "-c", child],
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=5,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("invalid timeout", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
                    self.assertFalse(marker.exists())

    def test_supervisor_exception_attempts_child_cleanup(self):
        process = mock.Mock()
        process.communicate.side_effect = RuntimeError("communicate failed")
        process.poll.return_value = None
        with mock.patch.object(AI_MODULE.subprocess, "Popen", return_value=process), mock.patch.object(
            AI_MODULE, "_stop_process", return_value=(b"", b"")
        ) as stop_process:
            with self.assertRaisesRegex(RuntimeError, "communicate failed"):
                AI_MODULE.run_with_timeout(1, ["provider"])
        stop_process.assert_called_once_with(process)

    def test_termination_signals_are_forwarded_and_descendants_reaped(self):
        signals = (signal.SIGTERM, signal.SIGHUP)
        for sent_signal in signals:
            with self.subTest(signal=sent_signal), tempfile.TemporaryDirectory(dir="/tmp") as tmp:
                tmpdir = Path(tmp)
                pidfile = tmpdir / "child.pid"
                child = tmpdir / "child.sh"
                child.write_text(
                    "#!/bin/sh\n"
                    "trap '' TERM HUP\n"
                    "printf '%s\\n' \"$$\" >\"$1\"\n"
                    "while :; do sleep 1; done\n"
                )
                child.chmod(0o755)
                supervisor = subprocess.Popen(
                    [
                        sys.executable,
                        str(AI_HELPER),
                        "timeout",
                        "30",
                        str(child),
                        str(pidfile),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and not pidfile.exists():
                    time.sleep(0.02)
                self.assertTrue(pidfile.exists())
                child_pid = int(pidfile.read_text().strip())
                os.kill(supervisor.pid, sent_signal)
                supervisor.communicate(timeout=5)
                self.assertEqual(supervisor.returncode, 128 + sent_signal)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline and self.process_exists(child_pid):
                    time.sleep(0.05)
                self.assertFalse(
                    self.process_exists(child_pid),
                    f"child {child_pid} survived signal {sent_signal}",
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
