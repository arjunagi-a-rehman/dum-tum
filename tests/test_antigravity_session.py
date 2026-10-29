import json
import os
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from test_shell_interactive import ShellSession


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "src" / "fixit-ai.py"
COMMON = ROOT / "src" / "fixit-common.sh"
SHELLS = [path for name in ("bash", "zsh") if (path := shutil.which(name))]

FAKE_AGY = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import time

control = Path(os.environ["FX_TEST_AGY_CONTROL"])
with open(os.environ["FX_TEST_AGY_LAUNCHES"], "a") as log:
    log.write(json.dumps({"pid": os.getpid(), "args": sys.argv[1:]}) + "\n")
if (control / "no-read").exists():
    print(json.dumps({"event": "init", "init": {}}), flush=True)
    time.sleep(30)
for index, line in enumerate(sys.stdin):
    request = json.loads(line)
    if (control / "fail").exists():
        if index == 0:
            print(json.dumps({"event": "init", "init": {}}), flush=True)
        print("provider failed", file=sys.stderr, flush=True)
        raise SystemExit(17)
    if (control / "timeout").exists():
        if index == 0:
            print(json.dumps({"event": "init", "init": {}}), flush=True)
        print("provider still running", file=sys.stderr, flush=True)
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        (control / "descendant.pid").write_text(str(child.pid))
        time.sleep(30)
    if index == 0:
        print(json.dumps({"event": "init", "init": {}}), flush=True)
    if (control / "diagnostics").exists():
        print("\x1b[8mconcealed", file=sys.stderr, flush=True)
    if (control / "slow").exists():
        (control / "turn-started").write_text(str(os.getpid()))
        time.sleep(30)
    response = "ls -la" if index == 0 else "pwd"
    with open(os.environ["FX_TEST_AGY_TURNS"], "a") as log:
        log.write(json.dumps({"pid": os.getpid(), "response": response}) + "\n")
    print(json.dumps({"event": "result", "result": {"status": "SUCCESS", "response": response}}), flush=True)
    if index == 0 and (control / "exit-after-first").exists():
        raise SystemExit(0)
'''


class AntigravitySessionTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(dir="/tmp")
        self.tmpdir = Path(self.tempdir.name)
        self.control = self.tmpdir / "control"
        self.control.mkdir()
        self.launches = self.tmpdir / "launches.jsonl"
        self.turns = self.tmpdir / "turns.jsonl"
        self.bindir = self.tmpdir / "bin"
        self.bindir.mkdir()
        self.agy = self.bindir / "agy"
        self.agy.write_text(FAKE_AGY)
        self.agy.chmod(0o755)
        self.sessions = []
        self.env = os.environ.copy()
        self.env.update({
            "FX_TEST_AGY_CONTROL": str(self.control),
            "FX_TEST_AGY_LAUNCHES": str(self.launches),
            "FX_TEST_AGY_TURNS": str(self.turns),
            "PATH": f"{self.bindir}{os.pathsep}{self.env['PATH']}",
        })

    def tearDown(self):
        for session in self.sessions:
            if session.exists():
                subprocess.run(
                    [sys.executable, str(HELPER), "antigravity-stop", str(session)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=8,
                    check=False,
                )
        self.tempdir.cleanup()

    def session(self):
        path = Path(tempfile.mkdtemp(prefix="fixit-agy.", dir=self.tmpdir))
        self.sessions.append(path)
        return path

    def request_command(self, session, timeout, owner=None):
        return [
            sys.executable,
            str(HELPER),
            "antigravity-request",
            str(session),
            str(owner or os.getpid()),
            timeout,
            str(self.agy),
            "--sandbox",
        ]

    def start_request(self, session, timeout="15", owner=None, body=None):
        process = subprocess.Popen(
            self.request_command(session, timeout, owner),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            text=True,
        )
        process.stdin.write(body or json.dumps({"event": "user", "message": {"content": "test"}}))
        process.stdin.close()
        return process

    def request(self, session, timeout="15", owner=None, env=None, body=None):
        return subprocess.run(
            self.request_command(session, timeout, owner),
            input=body or json.dumps({"event": "user", "message": {"content": "test"}}),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env or self.env,
            timeout=25,
            check=False,
        )

    def stop(self, session):
        return subprocess.run(
            [sys.executable, str(HELPER), "antigravity-stop", str(session)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env,
            timeout=8,
            check=False,
        )

    def records(self, path):
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def wait_for_removal(self, path):
        deadline = time.monotonic() + 6
        while path.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(path.exists(), f"{path} was not removed")

    @staticmethod
    def process_exists(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        state = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(pid)],
            capture_output=True,
            text=True,
            check=False,
        )
        return bool(state.stdout.strip()) and not state.stdout.lstrip().startswith("Z")

    def test_requests_reuse_one_provider_and_stop_cleans_up(self):
        session = self.session()
        first = self.request(session)
        second = self.request(session)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("ls -la", first.stdout)
        self.assertIn("pwd", second.stdout)
        launches = self.records(self.launches)
        turns = self.records(self.turns)
        self.assertEqual(len(launches), 1)
        self.assertEqual([turn["pid"] for turn in turns], [launches[0]["pid"]] * 2)
        stopped = self.stop(session)
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        self.assertFalse(session.exists())
        deadline = time.monotonic() + 2
        while self.process_exists(launches[0]["pid"]) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(self.process_exists(launches[0]["pid"]))

    def test_sessions_are_isolated(self):
        first_session = self.session()
        second_session = self.session()
        self.assertEqual(self.request(first_session).returncode, 0)
        self.assertEqual(self.request(second_session).returncode, 0)
        launches = self.records(self.launches)
        self.assertEqual(len(launches), 2)
        self.assertNotEqual(launches[0]["pid"], launches[1]["pid"])

    def test_timeout_kills_descendants_and_next_request_recovers(self):
        session = self.session()
        warmed_up = self.request(session)
        self.assertEqual(warmed_up.returncode, 0, warmed_up.stderr)
        (self.control / "timeout").touch()
        started = time.monotonic()
        timed_out = self.request(session, timeout="0.2")
        self.assertEqual(timed_out.returncode, 124, timed_out.stderr)
        self.assertEqual(timed_out.stdout, "")
        self.assertIn("provider still running", timed_out.stderr)
        self.assertLess(time.monotonic() - started, 5)
        first_pid = self.records(self.launches)[0]["pid"]
        descendant_pid = int((self.control / "descendant.pid").read_text())
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and (
            self.process_exists(first_pid) or self.process_exists(descendant_pid)
        ):
            time.sleep(0.05)
        self.assertFalse(self.process_exists(first_pid))
        self.assertFalse(self.process_exists(descendant_pid))
        (self.control / "timeout").unlink()
        recovered = self.request(session)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertIn("ls -la", recovered.stdout)
        self.assertEqual(len(self.records(self.launches)), 2)

    def test_failure_is_not_parsed_and_preserves_status(self):
        session = self.session()
        (self.control / "fail").touch()
        failed = self.request(session)
        self.assertEqual(failed.returncode, 17, failed.stderr)
        self.assertEqual(failed.stdout, "")
        self.assertIn("provider failed", failed.stderr)
        (self.control / "fail").unlink()
        recovered = self.request(session)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(len(self.records(self.launches)), 2)

    def test_owner_exit_cleans_up_worker(self):
        session = self.session()
        owner = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            result = self.request(session, owner=owner.pid)
            self.assertEqual(result.returncode, 0, result.stderr)
            provider_pid = self.records(self.launches)[0]["pid"]
            owner.terminate()
            owner.wait(timeout=2)
            self.wait_for_removal(session)
            self.assertFalse(self.process_exists(provider_pid))
        finally:
            if owner.poll() is None:
                owner.kill()
                owner.wait()

    def test_idle_timeout_cleans_up_worker(self):
        session = self.session()
        env = self.env.copy()
        env["FX_AGY_IDLE_TIMEOUT"] = "0.2"
        result = self.request(session, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.wait_for_removal(session)

    def test_shell_reuses_session_and_restarts_for_model_change(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.launches.unlink(missing_ok=True)
                self.turns.unlink(missing_ok=True)
                script = f"""
                    source {shlex.quote(str(COMMON))}
                    _FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED=1
                    FX_MODEL=first-model
                    _fx_ai_antigravity first >/dev/null || exit
                    _fx_ai_antigravity second >/dev/null || exit
                    FX_MODEL=second-model
                    _fx_ai_antigravity third >/dev/null || exit
                    _fx_antigravity_stop
                """
                result = subprocess.run(
                    [shell, "-c", script],
                    cwd=self.tmpdir,
                    env=self.env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=25,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                launches = self.records(self.launches)
                turns = self.records(self.turns)
                self.assertEqual(len(launches), 2)
                self.assertEqual(len(turns), 3)
                self.assertEqual(turns[0]["pid"], turns[1]["pid"])
                self.assertNotEqual(turns[1]["pid"], turns[2]["pid"])
                self.assertIn("first-model", launches[0]["args"])
                self.assertIn("second-model", launches[1]["args"])

    def test_shell_unload_cleans_up_session(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                adapter = ROOT / "src" / ("fixit.zsh" if "zsh" in shell else "fixit.bash")
                marker = self.control / "shell-session"
                marker.unlink(missing_ok=True)
                script = f"""
                    source {shlex.quote(str(adapter))}
                    _FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED=1
                    _fx_ai_antigravity test >/dev/null || exit
                    printf '%s' "$_FX_AGY_SESSION_DIR" > {shlex.quote(str(marker))}
                    dum_tum_unload
                """
                result = subprocess.run(
                    [shell, "-c", script],
                    cwd=self.tmpdir,
                    env=self.env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=25,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                session = Path(marker.read_text())
                self.assertFalse(session.exists())

    def test_timeout_covers_provider_stdin_writes(self):
        session = self.session()
        (self.control / "no-read").touch()
        body = json.dumps({"event": "user", "message": {"content": "x" * 200000}})
        started = time.monotonic()
        result = self.request(session, timeout="2", body=body)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(time.monotonic() - started, 8)
        provider_pid = self.records(self.launches)[0]["pid"]
        deadline = time.monotonic() + 2
        while self.process_exists(provider_pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(self.process_exists(provider_pid))
        (self.control / "no-read").unlink()
        recovered = self.request(session)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(len(self.records(self.launches)), 2)

    def test_interrupt_cancels_provider_and_worker_recovers(self):
        session = self.session()
        (self.control / "slow").touch()
        active = self.start_request(session)
        marker = self.control / "turn-started"
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(marker.exists(), active.stderr.read() if active.poll() is not None else "")
            provider_pid = int(marker.read_text())
            active.send_signal(signal.SIGINT)
            self.assertEqual(active.wait(timeout=5), 130)
        finally:
            if active.poll() is None:
                active.kill()
            active.wait()
            active.stdout.close()
            active.stderr.close()
        deadline = time.monotonic() + 2
        while self.process_exists(provider_pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(self.process_exists(provider_pid))
        (self.control / "slow").unlink()
        recovered = self.request(session)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(len(self.records(self.launches)), 2)

    def test_disconnected_stop_client_still_stops_worker(self):
        session = self.session()
        warmed_up = self.request(session)
        self.assertEqual(warmed_up.returncode, 0, warmed_up.stderr)
        (self.control / "slow").touch()
        active = self.start_request(session, timeout="0.2")
        marker = self.control / "turn-started"
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(marker.exists())
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.connect(str(session / "session.sock"))
            client.sendall(b'{"stop": true}\n')
            client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            client.close()
            self.assertEqual(active.wait(timeout=5), 124)
        finally:
            if active.poll() is None:
                active.kill()
            active.wait()
            active.stdout.close()
            active.stderr.close()
        self.wait_for_removal(session)

    def test_idle_provider_exit_restarts_before_next_request(self):
        session = self.session()
        (self.control / "exit-after-first").touch()
        first = self.request(session)
        self.assertEqual(first.returncode, 0, first.stderr)
        provider_pid = self.records(self.launches)[0]["pid"]
        deadline = time.monotonic() + 2
        while self.process_exists(provider_pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(self.process_exists(provider_pid))
        second = self.request(session)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("ls -la", second.stdout)
        self.assertEqual(len(self.records(self.launches)), 2)

    def test_provider_diagnostics_are_sanitized(self):
        session = self.session()
        (self.control / "diagnostics").touch()
        result = self.request(session)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("\x1b", result.stderr)
        self.assertIn("\\x1b[8mconcealed", result.stderr)

    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_bash_command_not_found_reuses_parent_session(self):
        bash = shutil.which("bash")
        version = subprocess.check_output([bash, "-c", "printf %s ${BASH_VERSINFO[0]}"], text=True)
        if int(version) < 4:
            self.skipTest("command_not_found_handle requires Bash 4+")
        marker = self.control / "bash-session"
        shell = ShellSession([bash, "--noprofile", "--norc", "-i"], self.tmpdir)
        try:
            shell.command(
                f"export FX_TEST_AGY_CONTROL={shlex.quote(str(self.control))} "
                f"FX_TEST_AGY_LAUNCHES={shlex.quote(str(self.launches))} "
                f"FX_TEST_AGY_TURNS={shlex.quote(str(self.turns))}; "
                f"PATH={shlex.quote(str(self.bindir))}:$PATH; export PATH; "
                f"source {shlex.quote(str(ROOT / 'src' / 'fixit.bash'))}; "
                "_FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED=1; FX_PROVIDER=antigravity"
            )
            shell.command("_fx_confirm_ai_send() { return 0; }; _fx_confirm_run() { return 0; }")
            output = shell.command("dumtumunknown first")
            output += shell.command("dumtumunknown second")
            shell.command(f"printf '%s' \"$_FX_AGY_SESSION_DIR\" > {shlex.quote(str(marker))}")
            shell.command("dum_tum_unload")
        finally:
            shell.close()
        launches = self.records(self.launches)
        turns = self.records(self.turns)
        self.assertEqual(len(launches), 1, output)
        self.assertEqual(len(turns), 2)
        self.assertEqual(turns[0]["pid"], turns[1]["pid"])
        self.assertTrue(marker.read_text())
        self.assertFalse(Path(marker.read_text()).exists())


if __name__ == "__main__":
    unittest.main()
