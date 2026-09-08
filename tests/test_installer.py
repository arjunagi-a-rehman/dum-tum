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
INSTALLER = ROOT / "install.sh"
PROVIDER_KEYS = (
    "OPENROUTER_API_KEY",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
)


class InstallerKeyHandlingTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.base = Path(self.tempdir.name)
        self.home = self.base / "home"
        self.home.mkdir()

    def tearDown(self):
        self.tempdir.cleanup()

    def env(self, **values):
        env = os.environ.copy()
        for name in (*PROVIDER_KEYS, "FX_PROVIDER", "FX_MODEL", "FX_VARIANT"):
            env.pop(name, None)
        env.update({
            "HOME": str(self.home),
            "FIXIT_HOME": str(self.base / "install"),
            "PATH": "/usr/bin:/bin",
            "SHELL": shutil.which("zsh") or "/bin/zsh",
        })
        env.update(values)
        return env

    def run_installer(self, *args, env=None):
        command = [
            "/bin/bash",
            str(INSTALLER),
            "--yes",
            "--skip-deps",
            "--skip-ai-test",
            "--shell",
            "zsh",
            *args,
        ]
        return subprocess.run(
            command,
            cwd=ROOT,
            env=env or self.env(),
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )

    def test_explicit_provider_uses_only_its_key_in_multi_key_environment(self):
        result = self.run_installer(
            "--provider",
            "openai",
            env=self.env(
                OPENROUTER_API_KEY="router-only-value",
                OPENAI_API_KEY="openai-only-value",
            ),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        config = (self.home / ".zshrc").read_text()
        self.assertIn('export FX_PROVIDER="openai"', config)
        self.assertIn('export OPENAI_API_KEY="openai-only-value"', config)
        self.assertNotIn("router-only-value", config)

    def test_implicit_multi_provider_keys_are_rejected_as_ambiguous(self):
        result = self.run_installer(
            env=self.env(
                OPENROUTER_API_KEY="router-only-value",
                OPENAI_API_KEY="openai-only-value",
            )
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Multiple provider API keys are set", result.stderr)
        self.assertFalse((self.home / ".zshrc").exists())

    def test_gemini_environment_aliases_are_one_provider(self):
        result = self.run_installer(
            env=self.env(
                GEMINI_API_KEY="preferred-gemini-value",
                GOOGLE_API_KEY="fallback-google-value",
            )
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        config = (self.home / ".zshrc").read_text()
        self.assertIn('export FX_PROVIDER="gemini"', config)
        self.assertIn('export GEMINI_API_KEY="preferred-gemini-value"', config)
        self.assertNotIn("fallback-google-value", config)

    def test_loading_new_provider_clears_stale_provider_key(self):
        installer_functions = self.base / "installer-functions.sh"
        source = INSTALLER.read_text()
        self.assertTrue(source.endswith("\nmain\n"))
        installer_functions.write_text(source[:-5])
        script = f"""
source {installer_functions}
API_KEY=old-openai-secret
API_KEY_PROVIDER=openai
unset ANTHROPIC_API_KEY
load_key_for_provider anthropic
printf '%s|%s' "$API_KEY" "$API_KEY_PROVIDER"
"""
        result = subprocess.run(
            ["/bin/bash", "-c", script],
            cwd=ROOT,
            env=self.env(),
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "|")

    def test_key_option_is_rejected_without_echoing_its_value(self):
        marker = "argv-secret-sentinel"
        result = subprocess.run(
            ["/bin/bash", str(INSTALLER), f"--key={marker}"],
            cwd=ROOT,
            env=self.env(),
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("--key option is not supported", result.stderr)
        self.assertNotIn(marker, result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which("node"), "node is required for the npm entrypoint")
    def test_npm_entrypoint_does_not_forward_key_to_bash(self):
        fake_bin = self.base / "fake-bin"
        fake_bin.mkdir()
        marker_file = self.base / "bash-called"
        fake_bash = fake_bin / "bash"
        fake_bash.write_text("#!/bin/sh\ntouch \"$DUM_TUM_BASH_CALLED\"\n")
        fake_bash.chmod(0o755)
        marker = "node-argv-secret-sentinel"
        env = self.env(
            PATH=f"{fake_bin}:/usr/bin:/bin",
            DUM_TUM_BASH_CALLED=str(marker_file),
        )
        result = subprocess.run(
            [shutil.which("node"), str(ROOT / "bin" / "dum-tum.js"), f"--key={marker}"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertFalse(marker_file.exists())
        self.assertNotIn(marker, result.stdout + result.stderr)

    def test_smoke_test_keeps_key_out_of_child_arguments(self):
        fake_bin = self.base / "smoke-bin"
        fake_bin.mkdir()
        arg_log = self.base / "child-args"
        env_log = self.base / "child-env"
        fake_bash = fake_bin / "bash"
        fake_bash.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$@\" > \"$DUM_TUM_ARG_LOG\"\n"
            "printf 'openai=%s\\nopenrouter=%s\\n' \"${OPENAI_API_KEY-unset}\" "
            "\"${OPENROUTER_API_KEY-unset}\" > \"$DUM_TUM_ENV_LOG\"\n"
            "printf 'ls -la\\n'\n"
        )
        fake_bash.chmod(0o755)
        marker = "smoke-secret-sentinel"
        env = self.env(
            PATH=f"{fake_bin}:/usr/bin:/bin",
            SHELL="/bin/bash",
            OPENAI_API_KEY=marker,
            OPENROUTER_API_KEY="unrelated-router-secret",
            DUM_TUM_ARG_LOG=str(arg_log),
            DUM_TUM_ENV_LOG=str(env_log),
        )
        result = subprocess.run(
            [
                "/bin/bash",
                str(INSTALLER),
                "--yes",
                "--skip-deps",
                "--provider",
                "openai",
                "--model",
                "gpt-4o-mini",
                "--shell",
                "bash",
            ],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        child_args = arg_log.read_text()
        self.assertNotIn(marker, child_args)
        self.assertNotIn("OPENAI_API_KEY=", child_args)
        self.assertEqual(env_log.read_text(), f"openai={marker}\nopenrouter=unset\n")

    def test_interactive_key_prompt_does_not_echo(self):
        marker = "hidden-prompt-secret-sentinel"
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(ROOT)
            os.execve(
                "/bin/bash",
                [
                    "/bin/bash",
                    str(INSTALLER),
                    "--skip-deps",
                    "--skip-ai-test",
                    "--provider",
                    "openai",
                    "--model",
                    "gpt-4o-mini",
                    "--shell",
                    "zsh",
                ],
                self.env(),
            )
        output = bytearray()
        deadline = time.monotonic() + 20
        sent = False
        status = None
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([fd], [], [], 0.1)
                if ready:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        chunk = b""
                    output.extend(chunk)
                    if not sent and b"Paste key now" in output:
                        time.sleep(0.1)
                        os.write(fd, marker.encode() + b"\r")
                        sent = True
                waited, status = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    break
            else:
                os.kill(pid, signal.SIGKILL)
                self.fail(output.decode(errors="replace"))
        finally:
            os.close(fd)
        self.assertTrue(sent, output.decode(errors="replace"))
        self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode(errors="replace"))
        self.assertNotIn(marker, output.decode(errors="replace"))
        config = (self.home / ".zshrc").read_text()
        self.assertIn(f'export OPENAI_API_KEY="{marker}"', config)


if __name__ == "__main__":
    unittest.main()
