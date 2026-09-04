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

    def provider_stubs(self):
        stub_dir = self.base / "provider-stubs"
        stub_dir.mkdir(exist_ok=True)
        script = (
            "#!/bin/sh\n"
            "name=${0##*/}\n"
            "if [ \"$name\" = codex ] && [ \"$1\" = exec ] && [ \"$2\" = --help ]; then\n"
            "  printf '%s\\n' '--output-last-message <FILE>'\n"
            "  exit 0\n"
            "fi\n"
            "counter=\"$DUM_TUM_COUNTER_DIR/$name\"\n"
            "count=0\n"
            "[ ! -f \"$counter\" ] || IFS= read -r count < \"$counter\"\n"
            "printf '%s\\n' \"$((count + 1))\" > \"$counter\"\n"
            "case \"$name\" in\n"
            "  opencode) printf '%s\\n' '{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"ls -la\"}}' ;;\n"
            "  claude) printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ls -la\"}' ;;\n"
            "  codex)\n"
            "    while [ \"$#\" -gt 0 ]; do\n"
            "      if [ \"$1\" = \"-o\" ] || [ \"$1\" = \"--output-last-message\" ]; then shift; printf 'ls -la\\n' > \"$1\"; exit 0; fi\n"
            "      shift\n"
            "    done\n"
            "    exit 1\n"
            "    ;;\n"
            "  agy) printf '%s\\n' '{\"event\":\"result\",\"result\":{\"status\":\"SUCCESS\",\"response\":\"ls -la\\n\"}}' ;;\n"
            "esac\n"
        )
        for name in ("opencode", "claude", "codex", "agy"):
            executable = stub_dir / name
            executable.write_text(script)
            executable.chmod(0o755)
        return stub_dir

    def invocation_counts(self):
        return {
            name: int((self.base / name).read_text()) if (self.base / name).exists() else 0
            for name in ("opencode", "claude", "codex", "agy")
        }

    def clear_invocation_counts(self):
        for name in ("opencode", "claude", "codex", "agy"):
            (self.base / name).unlink(missing_ok=True)

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

    def test_skip_ai_test_never_executes_provider_cli_for_explicit_providers(self):
        stub_dir = self.provider_stubs()
        env = self.env(
            PATH=f"{stub_dir}:/usr/bin:/bin",
            DUM_TUM_COUNTER_DIR=str(self.base),
            OPENROUTER_API_KEY="router-value",
            OPENAI_API_KEY="openai-value",
            ANTHROPIC_API_KEY="anthropic-value",
            GEMINI_API_KEY="gemini-value",
        )
        providers = (
            "none",
            "openrouter",
            "openai",
            "anthropic",
            "gemini",
            "opencode",
            "claude",
            "codex",
            "antigravity",
        )
        for provider in providers:
            with self.subTest(provider=provider):
                self.clear_invocation_counts()
                result = self.run_installer("--provider", provider, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    self.invocation_counts(),
                    {"opencode": 0, "claude": 0, "codex": 0, "agy": 0},
                )

    def test_skip_ai_test_still_requires_selected_cli_on_path(self):
        result = self.run_installer("--provider", "opencode", env=self.env())
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("OpenCode CLI not found on PATH", result.stderr)
        self.assertFalse((self.home / ".zshrc").exists())

    def test_local_only_without_skip_executes_no_provider_or_network_client(self):
        stub_dir = self.provider_stubs()
        curl_marker = self.base / "curl-called"
        fake_curl = stub_dir / "curl"
        fake_curl.write_text("#!/bin/sh\ntouch \"$DUM_TUM_CURL_MARKER\"\nexit 1\n")
        fake_curl.chmod(0o755)
        env = self.env(
            PATH=f"{stub_dir}:/usr/bin:/bin",
            DUM_TUM_COUNTER_DIR=str(self.base),
            DUM_TUM_CURL_MARKER=str(curl_marker),
        )
        result = subprocess.run(
            [
                "/bin/bash",
                str(INSTALLER),
                "--yes",
                "--skip-deps",
                "--provider",
                "none",
                "--shell",
                "zsh",
            ],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.invocation_counts(),
            {"opencode": 0, "claude": 0, "codex": 0, "agy": 0},
        )
        self.assertFalse(curl_marker.exists())

    def test_smoke_test_executes_only_the_selected_provider_cli(self):
        stub_dir = self.provider_stubs()
        env = self.env(
            PATH=f"{stub_dir}:/usr/bin:/bin",
            DUM_TUM_COUNTER_DIR=str(self.base),
            SHELL="/bin/bash",
        )
        provider_to_command = {
            "opencode": "opencode",
            "claude": "claude",
            "codex": "codex",
            "antigravity": "agy",
        }
        for provider, selected_command in provider_to_command.items():
            with self.subTest(provider=provider):
                self.clear_invocation_counts()
                result = subprocess.run(
                    [
                        "/bin/bash",
                        str(INSTALLER),
                        "--yes",
                        "--skip-deps",
                        "--provider",
                        provider,
                        "--model",
                        "test-model",
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
                expected = {"opencode": 0, "claude": 0, "codex": 0, "agy": 0}
                expected[selected_command] = 1
                self.assertEqual(self.invocation_counts(), expected)


if __name__ == "__main__":
    unittest.main()
