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
PROVIDERS = ("opencode", "claude", "codex", "antigravity")
COMMANDS = {
    "opencode": "_fx_ai_opencode list files",
    "claude": "_fx_ai_claude list files",
    "codex": "_fx_ai_codex list files",
    "antigravity": "_fx_ai_antigravity list files",
}
BINARIES = {
    "opencode": "opencode",
    "claude": "claude",
    "codex": "codex",
    "antigravity": "agy",
}
FAKE_PROVIDER = r'''#!/bin/sh
name=${0##*/}
capability=$FX_TEST_CAPABILITY
capability_log="$FX_TEST_LOG_DIR/$name.capability"
actual_log="$FX_TEST_LOG_DIR/$name.actual"
args_log="$FX_TEST_LOG_DIR/$name.args"
pwd_log="$FX_TEST_LOG_DIR/$name.cwd"

if [ "$name" = opencode ] && [ "$1" = run ] && [ "$2" = --help ]; then
  printf 'check\n' >>"$capability_log"
  [ "$capability" = hang ] && sleep 30
  case "$capability" in
    supported|error|weak-*) printf '%s\n' '  --pure  disable plugins' '  --format <FORMAT>  choices: json' ;;
    misleading) printf '%s\n' 'error: unrecognized --pure and --format options' ;;
    indented) printf '%s\n' 'Options:' '  --legacy <TEXT>  old examples:' '      --pure' '      --format json' ;;
  esac
  [ "$capability" = error ] && exit 23
  exit 0
fi
if [ "$name" = opencode ] && [ "$1" = debug ] && [ "$2" = config ]; then
  printf 'check\n' >>"$capability_log"
  if [ -e "$PWD/unsafe-config" ]; then
    printf '%s\n' '{"permission":{"*":"deny"},"tools":{"*":false},"agent":{"build":{"tools":{"bash":true}}},"plugin":[]}'
    exit 0
  fi
  case "$capability" in
    supported) printf '%s\n' '{"permission":{"*":"deny"},"tools":{"*":false},"plugin":[]}' ;;
    weak-top) printf '%s\n' '{"permission":{"*":"deny","bash":"allow"},"tools":{"*":false},"plugin":[]}' ;;
    weak-tool) printf '%s\n' '{"permission":{"*":"deny"},"tools":{"*":false,"bash":true},"plugin":[]}' ;;
    weak-agent) printf '%s\n' '{"permission":{"*":"deny"},"tools":{"*":false},"agent":{"build":{"permission":{"bash":"allow"}}},"plugin":[]}' ;;
    weak-agent-tool) printf '%s\n' '{"permission":{"*":"deny"},"tools":{"*":false},"agent":{"build":{"tools":{"bash":true}}},"plugin":[]}' ;;
    weak-numeric) printf '%s\n' '{"permission":{"*":"deny"},"tools":{"*":false,"bash":0},"plugin":[]}' ;;
    weak-nested) printf '%s\n' '{"permission":{"*":"deny"},"tools":{"*":false},"custom":{"permission":{"write":"ask"}},"plugin":[]}' ;;
    *) printf '%s\n' '{}' ;;
  esac
  exit 0
fi
if [ "$name" = claude ] && [ "$1" = --help ]; then
  printf 'check\n' >>"$capability_log"
  [ "$capability" = hang ] && sleep 30
  case "$capability" in
    supported|error) printf '%s\n' '  --tools <TOOLS>' '  --permission-mode <MODE>  choices: plan' '  --safe-mode' '  --disable-slash-commands' '  --strict-mcp-config' '  --mcp-config <CONFIG>' '  --no-session-persistence' ;;
    misleading) printf '%s\n' 'error mentions --tools --permission-mode plan --safe-mode --disable-slash-commands --strict-mcp-config --mcp-config --no-session-persistence' ;;
    indented) printf '%s\n' 'Options:' '  --legacy <TEXT>  old examples:' '      --tools' '      --permission-mode plan' '      --safe-mode' '      --disable-slash-commands' '      --strict-mcp-config' '      --mcp-config' '      --no-session-persistence' ;;
  esac
  [ "$capability" = error ] && exit 23
  exit 0
fi
if [ "$name" = codex ] && [ "$1" = exec ] && [ "$2" = --help ]; then
  printf 'check\n' >>"$capability_log"
  [ "$capability" = hang ] && sleep 30
  case "$capability" in
    supported|error) printf '%s\n' '  --sandbox <MODE>  choices: read-only' '  --ignore-user-config' '  --ignore-rules' '  --ephemeral' '  --output-last-message <FILE>' ;;
    misleading) printf '%s\n' 'error mentions --sandbox read-only --ignore-user-config --ignore-rules --ephemeral --output-last-message' ;;
    indented) printf '%s\n' 'Options:' '  --legacy <TEXT>  old examples:' '      --sandbox read-only' '      --ignore-user-config' '      --ignore-rules' '      --ephemeral' '      --output-last-message' ;;
  esac
  [ "$capability" = error ] && exit 23
  exit 0
fi
if [ "$name" = agy ] && [ "$1" = --help ]; then
  printf 'check\n' >>"$capability_log"
  [ "$capability" = hang ] && sleep 30
  case "$capability" in
    supported|error) printf '%s\n' '  --sandbox' '  --mode <MODE>  choices: plan' '  --disable-slash-commands' '  --input-format <FORMAT>' '  --output-format <FORMAT>' ;;
    misleading) printf '%s\n' 'error mentions --sandbox --mode plan --disable-slash-commands --input-format --output-format' ;;
    indented) printf '%s\n' 'Options:' '  --legacy <TEXT>  old examples:' '      --sandbox' '      --mode plan' '      --disable-slash-commands' '      --input-format' '      --output-format' ;;
  esac
  [ "$capability" = error ] && exit 23
  exit 0
fi

printf 'actual\n' >>"$actual_log"
printf '%s\n' "$PWD" >>"$pwd_log"
for arg in "$@"; do printf '<%s>\n' "$arg" >>"$args_log"; done

has_arg() {
  wanted=$1
  shift
  for arg in "$@"; do [ "$arg" = "$wanted" ] && return 0; done
  return 1
}
has_pair() {
  wanted_key=$1
  wanted_value=$2
  shift 2
  while [ "$#" -gt 1 ]; do
    [ "$1" = "$wanted_key" ] && [ "$2" = "$wanted_value" ] && return 0
    shift
  done
  return 1
}

safe=0
case "$name" in
  opencode)
    has_arg --pure "$@" && has_pair --format json "$@" &&
      [ "$OPENCODE_CONFIG_CONTENT" = '{"permission":{"*":"deny"},"tools":{"*":false}}' ] && safe=1
    ;;
  claude)
    has_pair --tools '' "$@" && has_pair --permission-mode plan "$@" &&
      has_arg --safe-mode "$@" && has_arg --disable-slash-commands "$@" &&
      has_arg --strict-mcp-config "$@" && has_arg --no-session-persistence "$@" && safe=1
    ;;
  codex)
    has_pair --sandbox read-only "$@" && has_arg --ignore-user-config "$@" &&
      has_arg --ignore-rules "$@" && has_arg --ephemeral "$@" && safe=1
    ;;
  agy)
    has_arg --sandbox "$@" && has_pair --mode plan "$@" &&
      has_arg --disable-slash-commands "$@" && safe=1
    ;;
esac
[ "$safe" -eq 1 ] || printf 'unconfined write\n' >"$FX_TEST_WRITE_MARKER"

case "$name" in
  opencode) printf '%s\n' '{"type":"text","part":{"type":"text","text":"ls -la"}}' ;;
  claude) printf '%s\n' '{"type":"result","subtype":"success","result":"ls -la"}' ;;
  codex)
    output_file=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o|--output-last-message) shift; output_file=$1 ;;
      esac
      shift
    done
    if [ -n "$output_file" ]; then printf 'ls -la\n' >"$output_file"; else printf 'ls -la\n'; fi
    ;;
  agy) printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"ls -la\n"}}' ;;
esac
case "$FX_TEST_ACTUAL_MODE" in
  failure) printf 'provider failed\n' >&2; exit 17 ;;
  timeout) printf 'provider still running\n' >&2; sleep 30 ;;
esac
exit 0
'''


class ProviderConfinementTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(dir="/tmp")
        self.tmpdir = Path(self.tempdir.name)
        self.bindir = self.tmpdir / "bin"
        self.bindir.mkdir()
        for binary in BINARIES.values():
            path = self.bindir / binary
            path.write_text(FAKE_PROVIDER)
            path.chmod(0o755)
        self.marker = self.tmpdir / "outside-project-write"

    def tearDown(self):
        self.tempdir.cleanup()

    def invoke(self, shell, provider, capability, actual_mode="success"):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bindir}{os.pathsep}{env['PATH']}",
                "FX_AI_TIMEOUT": "0.2" if actual_mode == "timeout" else "5",
                "FX_AI_READY_TIMEOUT": "0.2" if capability == "hang" else "5",
                "FX_TEST_ACTUAL_MODE": actual_mode,
                "FX_TEST_CAPABILITY": capability,
                "FX_TEST_LOG_DIR": str(self.tmpdir),
                "FX_TEST_WRITE_MARKER": str(self.marker),
            }
        )
        resets = (
            "unset _FX_OPENCODE_CONFINEMENT_SUPPORTED "
            "_FX_CLAUDE_CONFINEMENT_SUPPORTED "
            "_FX_CODEX_CAPABILITIES_CHECKED _FX_CODEX_CONFINEMENT_SUPPORTED "
            "_FX_CODEX_OUTPUT_FILE_OPTION _FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED"
        )
        script = (
            f"source {shlex.quote(str(COMMON))}; {resets}; {COMMANDS[provider]}"
        )
        return subprocess.run(
            [shell, "-c", script],
            cwd=self.tmpdir,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=8,
            check=False,
        )

    def invoke_resolver(self, shell, provider, capability, actual_mode="success", calls=1):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bindir}{os.pathsep}{env['PATH']}",
                "FX_AI_TIMEOUT": "5",
                "FX_AI_READY_TIMEOUT": "5",
                "FX_TEST_ACTUAL_MODE": actual_mode,
                "FX_TEST_CAPABILITY": capability,
                "FX_TEST_LOG_DIR": str(self.tmpdir),
                "FX_TEST_WRITE_MARKER": str(self.marker),
            }
        )
        resets = (
            "unset _FX_OPENCODE_CONFINEMENT_SUPPORTED "
            "_FX_CLAUDE_CONFINEMENT_SUPPORTED "
            "_FX_CODEX_CAPABILITIES_CHECKED _FX_CODEX_CONFINEMENT_SUPPORTED "
            "_FX_CODEX_OUTPUT_FILE_OPTION _FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED"
        )
        invocations = "; ".join(
            f"_fx_ai_resolve request-{index}" for index in range(calls)
        )
        script = (
            f"source {shlex.quote(str(COMMON))}; {resets}; "
            f"FX_PROVIDER={provider}; _fx_confirm_run() {{ return 0; }}; {invocations}"
        )
        return subprocess.run(
            [shell, "-c", script],
            cwd=self.tmpdir,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=8,
            check=False,
        )

    def count(self, provider, kind):
        path = self.tmpdir / f"{BINARIES[provider]}.{kind}"
        return len(path.read_text().splitlines()) if path.exists() else 0

    def clear_logs(self):
        for path in self.tmpdir.glob("*.capability"):
            path.unlink()
        for path in self.tmpdir.glob("*.actual"):
            path.unlink()
        for path in self.tmpdir.glob("*.args"):
            path.unlink()
        for path in self.tmpdir.glob("*.cwd"):
            path.unlink()
        self.marker.unlink(missing_ok=True)

    def test_supported_providers_run_once_without_unconfined_write(self):
        for shell in SHELLS:
            for provider in PROVIDERS:
                with self.subTest(shell=shell, provider=provider):
                    result = self.invoke(shell, provider, "supported")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "ls -la\n")
                    self.assertEqual(self.count(provider, "actual"), 1)
                    expected_checks = 2 if provider == "opencode" else 1
                    self.assertEqual(self.count(provider, "capability"), expected_checks)
                    actual_cwd = Path(
                        (self.tmpdir / f"{BINARIES[provider]}.cwd").read_text().strip()
                    )
                    if provider in ("codex", "antigravity"):
                        self.assertNotEqual(actual_cwd.resolve(), self.tmpdir.resolve())
                    else:
                        self.assertEqual(actual_cwd.resolve(), self.tmpdir.resolve())
                    if provider == "codex":
                        self.assertIn(
                            f"cwd: {self.tmpdir.resolve()}",
                            (self.tmpdir / "codex.args").read_text(),
                        )
                    self.assertFalse(self.marker.exists())
                    self.clear_logs()

    def test_antigravity_readiness_is_confined_and_isolated(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                env = os.environ.copy()
                env.update(
                    {
                        "PATH": f"{self.bindir}{os.pathsep}{env['PATH']}",
                        "FX_AI_READY_TIMEOUT": "5",
                        "FX_TEST_ACTUAL_MODE": "success",
                        "FX_TEST_CAPABILITY": "supported",
                        "FX_TEST_LOG_DIR": str(self.tmpdir),
                        "FX_TEST_WRITE_MARKER": str(self.marker),
                    }
                )
                script = (
                    f"source {shlex.quote(str(COMMON))}; "
                    "unset _FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED _FX_ANTIGRAVITY_READY; "
                    "FX_PROVIDER=antigravity; _fx_ai_ready"
                )
                result = subprocess.run(
                    [shell, "-c", script], cwd=self.tmpdir, env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotEqual(
                    Path((self.tmpdir / "agy.cwd").read_text().strip()).resolve(),
                    self.tmpdir.resolve(),
                )
                args = (self.tmpdir / "agy.args").read_text()
                for expected in ("<-p>", "</usage>", "<--sandbox>", "<plan>", "<--disable-slash-commands>"):
                    self.assertIn(expected, args)
                self.assertFalse(self.marker.exists())
                self.clear_logs()

    def test_resolver_preserves_status_and_capability_cache(self):
        for shell in SHELLS:
            with self.subTest(shell=shell, case="cache"):
                result = self.invoke_resolver(shell, "claude", "supported", calls=2)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.count("claude", "capability"), 1)
                self.assertEqual(self.count("claude", "actual"), 2)
                self.clear_logs()
            with self.subTest(shell=shell, case="transport"):
                result = self.invoke_resolver(shell, "claude", "supported", "failure")
                self.assertEqual(result.returncode, 17, result.stderr)
                self.assertIn("provider failed", result.stderr)
                self.assertNotIn("AI gave no answer", result.stderr)
                self.clear_logs()
            with self.subTest(shell=shell, case="confinement"):
                result = self.invoke_resolver(shell, "claude", "unsupported")
                self.assertEqual(result.returncode, 126, result.stderr)
                self.assertEqual(result.stderr.count("cannot prove read-only/no-tools support"), 1)
                self.assertNotIn("AI gave no answer", result.stderr)
                self.clear_logs()
            with self.subTest(shell=shell, case="antigravity-readiness-confinement"):
                result = self.invoke_resolver(shell, "antigravity", "unsupported")
                self.assertEqual(result.returncode, 126, result.stderr)
                self.assertEqual(result.stderr.count("cannot prove read-only/no-tools support"), 1)
                self.assertNotIn("AI gave no answer", result.stderr)
                self.clear_logs()

    def test_unsupported_providers_fail_before_prompt_invocation(self):
        for shell in SHELLS:
            for provider in PROVIDERS:
                with self.subTest(shell=shell, provider=provider):
                    result = self.invoke(shell, provider, "unsupported")
                    self.assertEqual(result.returncode, 126)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("cannot prove read-only/no-tools support", result.stderr)
                    self.assertEqual(self.count(provider, "actual"), 0)
                    self.assertFalse(self.marker.exists())
                    self.clear_logs()

    def test_nonzero_and_misleading_capability_output_fail_closed(self):
        for shell in SHELLS:
            for provider in PROVIDERS:
                for capability in ("error", "misleading", "indented"):
                    with self.subTest(shell=shell, provider=provider, capability=capability):
                        result = self.invoke(shell, provider, capability)
                        self.assertEqual(result.returncode, 126, result.stderr)
                        self.assertEqual(result.stdout, "")
                        self.assertEqual(self.count(provider, "actual"), 0)
                        self.clear_logs()

    def test_opencode_rejects_every_weaker_policy_override(self):
        for shell in SHELLS:
            for capability in (
                "weak-top",
                "weak-tool",
                "weak-agent",
                "weak-agent-tool",
                "weak-numeric",
                "weak-nested",
            ):
                with self.subTest(shell=shell, capability=capability):
                    result = self.invoke(shell, "opencode", capability)
                    self.assertEqual(result.returncode, 126, result.stderr)
                    self.assertEqual(self.count("opencode", "actual"), 0)
                    self.clear_logs()

    def test_opencode_revalidates_resolved_config_after_cwd_change(self):
        safe_dir = self.tmpdir / "safe"
        unsafe_dir = self.tmpdir / "unsafe"
        safe_dir.mkdir()
        unsafe_dir.mkdir()
        (unsafe_dir / "unsafe-config").touch()
        for shell in SHELLS:
            with self.subTest(shell=shell):
                env = os.environ.copy()
                env.update(
                    {
                        "PATH": f"{self.bindir}{os.pathsep}{env['PATH']}",
                        "FX_AI_TIMEOUT": "5",
                        "FX_AI_READY_TIMEOUT": "5",
                        "FX_TEST_ACTUAL_MODE": "success",
                        "FX_TEST_CAPABILITY": "supported",
                        "FX_TEST_LOG_DIR": str(self.tmpdir),
                        "FX_TEST_WRITE_MARKER": str(self.marker),
                    }
                )
                script = (
                    f"source {shlex.quote(str(COMMON))}; "
                    "unset _FX_OPENCODE_CONFINEMENT_SUPPORTED; "
                    f"cd {shlex.quote(str(safe_dir))}; _fx_ai_opencode first; "
                    f"cd {shlex.quote(str(unsafe_dir))}; _fx_ai_opencode second"
                )
                result = subprocess.run(
                    [shell, "-c", script], cwd=self.tmpdir, env=env, text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8, check=False,
                )
                self.assertEqual(result.returncode, 126, result.stderr)
                self.assertEqual(result.stdout, "ls -la\n")
                self.assertEqual(self.count("opencode", "capability"), 3)
                self.assertEqual(self.count("opencode", "actual"), 1)
                self.clear_logs()

    def test_hung_capability_probes_are_supervised(self):
        for shell in SHELLS:
            for provider in PROVIDERS:
                with self.subTest(shell=shell, provider=provider):
                    started = time.monotonic()
                    result = self.invoke(shell, provider, "hang")
                    self.assertEqual(result.returncode, 126, result.stderr)
                    self.assertLess(time.monotonic() - started, 4)
                    self.assertEqual(self.count(provider, "actual"), 0)
                    self.clear_logs()

    def test_local_transport_failures_are_never_parsed(self):
        for shell in SHELLS:
            for provider in ("opencode", "claude", "antigravity"):
                with self.subTest(shell=shell, provider=provider):
                    result = self.invoke(shell, provider, "supported", "failure")
                    self.assertEqual(result.returncode, 17)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr, "provider failed\n")
                    self.assertEqual(self.count(provider, "actual"), 1)
                    self.clear_logs()

    def test_local_transport_timeouts_are_never_parsed(self):
        for shell in SHELLS:
            for provider in ("opencode", "claude", "antigravity"):
                with self.subTest(shell=shell, provider=provider):
                    result = self.invoke(shell, provider, "supported", "timeout")
                    self.assertEqual(result.returncode, 124)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr, "provider still running\n")
                    self.assertEqual(self.count(provider, "actual"), 1)
                    self.clear_logs()


if __name__ == "__main__":
    unittest.main()
