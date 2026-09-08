import json
import os
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROMPT = "__DUM_TUM_TEST__> "


class ShellSession:
    def __init__(self, argv, cwd):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            env = os.environ.copy()
            env.update({"PS1": PROMPT, "PROMPT": PROMPT, "TERM": "xterm"})
            os.execvpe(argv[0], argv, env)
        self.buffer = b""
        time.sleep(0.1)
        self.send(f"PS1='{PROMPT}'; PROMPT='{PROMPT}'\r")
        self.read_until(PROMPT)

    def send(self, value):
        if isinstance(value, str):
            value = value.encode()
        os.write(self.fd, value)

    def read_until(self, needle, timeout=8):
        if isinstance(needle, str):
            needle = needle.encode()
        deadline = time.monotonic() + timeout
        while needle not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                text = self.buffer.decode(errors="replace")
                raise AssertionError(f"timed out waiting for {needle!r}; output: {text!r}")
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 4096)
            except OSError as exc:
                raise AssertionError(f"shell exited while waiting for {needle!r}") from exc
            if not chunk:
                raise AssertionError(f"shell exited while waiting for {needle!r}")
            self.buffer += chunk
        end = self.buffer.index(needle) + len(needle)
        found = self.buffer[:end]
        self.buffer = self.buffer[end:]
        return found.decode(errors="replace")

    def command(self, command):
        self.send(command + "\r")
        return self.read_until_idle(PROMPT)

    def read_until_idle(self, needle, idle=0.15):
        output = self.read_until(needle)
        if self.buffer:
            output += self.buffer.decode(errors="replace")
            self.buffer = b""
        while True:
            ready, _, _ = select.select([self.fd], [], [], idle)
            if not ready:
                return output
            try:
                chunk = os.read(self.fd, 4096)
            except OSError:
                return output
            if not chunk:
                return output
            output += chunk.decode(errors="replace")

    def close(self):
        if getattr(self, "pid", None) is None:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(self.pid, sig)
            except (ProcessLookupError, PermissionError):
                break
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                try:
                    waited, _ = os.waitpid(self.pid, os.WNOHANG)
                except ChildProcessError:
                    waited = self.pid
                if waited == self.pid:
                    break
                time.sleep(0.01)
            if waited == self.pid:
                break
        try:
            os.close(self.fd)
        except OSError:
            pass
        self.pid = None


class InteractiveAdapterTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.shell = None

    def tearDown(self):
        if self.shell is not None:
            self.shell.close()
        self.tempdir.cleanup()

    def start(self, argv, adapter):
        self.shell = ShellSession(argv, self.tempdir.name)
        self.shell.command(f"source '{ROOT / 'src' / adapter}'")
        self.shell.command("_fx_ai_ready() { return 0; }")
        self.shell.command("_fx_ai() { printf '%s\\n' \"$FX_TEST_SUGGESTION\"; }")

    def set_suggestion(self, command):
        escaped = command.replace("'", "'\\''")
        self.shell.command(f"FX_TEST_SUGGESTION='{escaped}'")

    def prompt_for_suggestion(self):
        self.shell.send("check package version\r")
        return self.shell.read_until("[Enter] run  [e] edit  [n] cancel")

    def exercise_confirmation_flow(self, test_edit):
        run_marker = Path(self.tempdir.name) / "ran"
        self.set_suggestion(f"touch {run_marker}")
        self.prompt_for_suggestion()
        self.shell.send("\n")
        output = self.shell.read_until_idle(PROMPT)
        self.assertTrue(run_marker.exists(), output)
        self.assertIn(f"touch {run_marker}", output)

        cancel_marker = Path(self.tempdir.name) / "cancelled"
        self.set_suggestion(f"touch {cancel_marker}")
        self.prompt_for_suggestion()
        self.shell.send("n\r")
        self.shell.read_until_idle(PROMPT)
        self.assertFalse(cancel_marker.exists())

        if test_edit:
            edit_marker = Path(self.tempdir.name) / "unedited"
            changed_marker = Path(self.tempdir.name) / "edited"
            self.set_suggestion(f"touch {edit_marker}")
            self.prompt_for_suggestion()
            self.shell.send("e")
            self.shell.read_until_idle(PROMPT)
            self.assertFalse(edit_marker.exists())
            self.shell.send(f"\x15touch {changed_marker}\r")
            self.shell.read_until_idle(PROMPT)
            self.assertTrue(changed_marker.exists())
            self.assertFalse(edit_marker.exists())

        output = self.shell.command("printf DUM_TUM_PLAIN_COMMAND")
        self.assertIn("DUM_TUM_PLAIN_COMMAND", output)

    def exercise_argv_confirmation(self):
        executable = Path(self.tempdir.name) / "fxargvprobe"
        log_path = Path(self.tempdir.name) / "argv.json"
        semicolon_marker = Path(self.tempdir.name) / "semicolon-injected"
        substitution_marker = Path(self.tempdir.name) / "substitution-injected"
        executable.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['FX_ARGV_LOG'], 'w', encoding='utf-8') as fh:\n"
            "    json.dump(sys.argv[1:], fh)\n",
            encoding="utf-8",
        )
        executable.chmod(0o755)
        self.shell.command(
            f"PATH='{self.tempdir.name}':$PATH; export PATH; "
            f"FX_ARGV_LOG='{log_path}'; export FX_ARGV_LOG; "
            "_fx_all_commands() { printf '%s\\n' fxargvprobe; }"
        )

        arguments = [
            "space value",
            f"literal; touch {semicolon_marker}",
            f"$(touch {substitution_marker})",
            "*",
            "",
            "single'quote",
            'double"quote',
            "back\\slash",
        ]

        def quote(value):
            return "'" + value.replace("'", "'\\''") + "'"

        self.shell.send("_fx_handle_not_found fxargvprobx " + " ".join(map(quote, arguments)) + "\r")
        output = self.shell.read_until("[Enter] run  [e] edit  [n] cancel")
        self.assertIn("fxargvprobe", output)
        self.shell.send("\n")
        output += self.shell.read_until_idle(PROMPT)
        self.assertTrue(log_path.exists(), output)
        self.assertEqual(arguments, json.loads(log_path.read_text(encoding="utf-8")))
        self.assertFalse(semicolon_marker.exists(), output)
        self.assertFalse(substitution_marker.exists(), output)

        log_path.unlink()
        self.shell.command(
            "alias fxargvalias=fxargvprobe; "
            "_fx_all_commands() { printf '%s\\n' fxargvalias; }"
        )
        self.shell.send("_fx_handle_not_found fxargvaliax " + " ".join(map(quote, arguments)) + "\r")
        output = self.shell.read_until("[Enter] run  [e] edit  [n] cancel")
        self.assertIn("fxargvalias", output)
        self.shell.send("\n")
        output += self.shell.read_until_idle(PROMPT)
        self.assertTrue(log_path.exists(), output)
        self.assertEqual(arguments, json.loads(log_path.read_text(encoding="utf-8")))
        self.assertFalse(semicolon_marker.exists(), output)
        self.assertFalse(substitution_marker.exists(), output)

    @unittest.skipUnless(shutil.which("zsh"), "zsh is not installed")
    def test_zsh_confirmation_flow(self):
        self.start([shutil.which("zsh"), "-f"], "fixit.zsh")
        self.exercise_confirmation_flow(test_edit=False)
        marker = Path(self.tempdir.name) / "zsh_edit_deferred"
        command = (
            "read() { key=e; return 0; }; "
            "_FX_ZLE_CONFIRM=1; _FX_ZLE_ACCEPT=0; _FX_ZLE_CMD=''; "
            f"_fx_confirm_run 'touch {marker}'; "
            "printf 'ZSH_EDIT_STATE=%s:%s\\n' \"$_FX_ZLE_ACCEPT\" \"$_FX_ZLE_CMD\"; "
            "unfunction read; unset _FX_ZLE_CONFIRM _FX_ZLE_ACCEPT _FX_ZLE_CMD"
        )
        output = self.shell.command(command)
        self.assertIn(f"ZSH_EDIT_STATE=0:touch {marker}", output)
        self.assertFalse(marker.exists())

    @unittest.skipUnless(shutil.which("zsh"), "zsh is not installed")
    def test_zsh_argv_confirmation_preserves_arguments(self):
        self.start([shutil.which("zsh"), "-f"], "fixit.zsh")
        self.exercise_argv_confirmation()

    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_bash_confirmation_flow(self):
        bash = shutil.which("bash")
        version = subprocess.check_output([bash, "-c", "printf %s \"${BASH_VERSINFO[0]}\""]).decode()
        if int(version) < 4:
            self.skipTest("Bash 4+ is required for the Enter hook")
        self.start([bash, "--noprofile", "--norc", "-i"], "fixit.bash")
        self.exercise_confirmation_flow(test_edit=True)

    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_bash_argv_confirmation_preserves_arguments(self):
        bash = shutil.which("bash")
        self.start([bash, "--noprofile", "--norc", "-i"], "fixit.bash")
        self.exercise_argv_confirmation()


if __name__ == "__main__":
    unittest.main()
