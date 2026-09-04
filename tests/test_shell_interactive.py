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

    def exercise_autorun_safety(self):
        date_executable = Path(self.tempdir.name) / "date"
        date_marker = Path(self.tempdir.name) / "date-ran"
        redirected = Path(self.tempdir.name) / "redirected"
        visible_file = Path(self.tempdir.name) / "plain-safe-visible"
        date_executable.write_text(
            "#!/bin/sh\n"
            ": > \"$FX_DATE_MARKER\"\n",
            encoding="utf-8",
        )
        date_executable.chmod(0o755)
        visible_file.touch()
        self.shell.command(
            f"PATH='{self.tempdir.name}':$PATH; export PATH; "
            f"FX_DATE_MARKER='{date_marker}'; export FX_DATE_MARKER"
        )

        self.shell.command("_fx_all_commands() { printf '%s\\n' date; }")
        self.shell.send("_fx_handle_not_found dtae --set=2026-01-01\r")
        output = self.shell.read_until("[Enter] run  [e] edit  [n] cancel")
        self.assertIn("date", output)
        self.assertFalse(date_marker.exists(), output)
        self.shell.send("n\r")
        self.shell.read_until_idle(PROMPT)
        self.assertFalse(date_marker.exists(), output)

        self.shell.command("_fx_all_commands() { printf '%s\\n' ls; }")
        output = self.shell.command("_fx_handle_not_found sl")
        self.assertIn(visible_file.name, output)
        self.assertNotIn("[Enter] run", output)

        ls_executable = Path(self.tempdir.name) / "ls"
        ls_marker = Path(self.tempdir.name) / "shadowed-ls-ran"
        ls_executable.write_text(
            "#!/bin/sh\n"
            ": > \"$FX_LS_MARKER\"\n",
            encoding="utf-8",
        )
        ls_executable.chmod(0o755)
        self.shell.command(
            f"FX_LS_MARKER='{ls_marker}'; export FX_LS_MARKER; hash -r 2>/dev/null || true"
        )
        self.shell.send("_fx_handle_not_found sl\r")
        output = self.shell.read_until("[Enter] run  [e] edit  [n] cancel")
        self.assertFalse(ls_marker.exists(), output)
        self.shell.send("n\r")
        self.shell.read_until_idle(PROMPT)
        self.assertFalse(ls_marker.exists(), output)

        self.shell.send(f"_fx_handle_not_found sl > '{redirected}'\r")
        output = self.shell.read_until("[Enter] run  [e] edit  [n] cancel")
        self.shell.send("n\r")
        output += self.shell.read_until_idle(PROMPT)
        self.assertTrue(redirected.exists(), output)
        self.assertEqual("", redirected.read_text(encoding="utf-8"), output)

    def exercise_typo_routing(self):
        ai_marker = Path(self.tempdir.name) / "ai-ran"
        self.shell.command(
            f"FX_ROUTING_AI_MARKER='{ai_marker}'; "
            "_fx_ai_resolve() { : > \"$FX_ROUTING_AI_MARKER\"; }; "
            "_fx_all_commands() { printf '%s\\n' git; }"
        )
        self.shell.send("_fx_handle_not_found gti status\r")
        output = self.shell.read_until("[Enter] run  [e] edit  [n] cancel")
        self.assertIn("closest: git", output)
        self.assertIn("git status", output)
        self.assertFalse(ai_marker.exists(), output)
        self.shell.send("n\r")
        self.shell.read_until_idle(PROMPT)
        self.assertFalse(ai_marker.exists(), output)

    def exercise_failed_line_repair(self):
        document = Path(self.tempdir.name) / "document.txt"
        output_path = Path(self.tempdir.name) / "count.txt"
        spaced_document = Path(self.tempdir.name) / "document file.txt"
        document.write_text("payload\n", encoding="utf-8")
        spaced_document.write_text("must-not-run\n", encoding="utf-8")
        self.shell.command(
            f"FX_REPAIR_OUT='{output_path}'; FX_REPAIR_KEEP=kept; "
            "export FX_REPAIR_OUT FX_REPAIR_KEEP; set -o pipefail"
        )

        raw = 'cat "dcoument.txt" | wc -c > "$FX_REPAIR_OUT" && printf EXPANSION:$FX_REPAIR_KEEP'
        self.shell.send(raw + "\r")
        output = self.shell.read_until("[Enter] run  [e] edit  [n] cancel")
        expected = 'cat "document.txt" | wc -c > "$FX_REPAIR_OUT" && printf EXPANSION:$FX_REPAIR_KEEP'
        self.assertIn(expected, output)
        self.shell.send("\n")
        output += self.shell.read_until_idle(PROMPT)
        self.assertEqual(8, int(output_path.read_text(encoding="utf-8")), output)
        self.assertIn("EXPANSION:kept", output)

        ambiguous = r"cat dcoument\ file.txt"
        self.shell.send(ambiguous + "\r")
        output = self.shell.read_until("[e] edit  [n] cancel")
        self.assertIn("dcoument file.txt", output)
        self.assertIn("document file.txt", output)
        self.assertIn(ambiguous, output)
        self.shell.send("n\r")
        output += self.shell.read_until_idle(PROMPT)
        self.assertNotIn("must-not-run", output)

    @unittest.skipUnless(shutil.which("zsh"), "zsh is not installed")
    def test_zsh_hooks_coexist_and_unload_restores_state(self):
        zsh = shutil.which("zsh")
        self.shell = ShellSession([zsh, "-f"], self.tempdir.name)
        self.shell.command(
            "FX_PREEXEC_COUNT=0; FX_PRECMD_COUNT=0; FX_ACCEPT_COUNT=0; "
            "_fx_test_preexec() { (( FX_PREEXEC_COUNT += 1 )); }; "
            "_fx_test_precmd() { (( FX_PRECMD_COUNT += 1 )); }; "
            "_fx_test_accept() { (( FX_ACCEPT_COUNT += 1 )); zle .accept-line; }; "
            "autoload -Uz add-zsh-hook; "
            "add-zsh-hook preexec _fx_test_preexec; "
            "add-zsh-hook precmd _fx_test_precmd; "
            "zle -N accept-line _fx_test_accept"
        )
        adapter = ROOT / "src" / "fixit.zsh"
        self.shell.command(f"source '{adapter}'; source '{adapter}'")
        output = self.shell.command(
            "fx_preexec_hooks=0; fx_precmd_hooks=0; "
            "for fx_hook in $preexec_functions; do "
            "[[ $fx_hook == _fx_preexec ]] && (( fx_preexec_hooks += 1 )); done; "
            "for fx_hook in $precmd_functions; do "
            "[[ $fx_hook == _fx_precmd ]] && (( fx_precmd_hooks += 1 )); done; "
            "printf 'ZSH_HOOK_STATE=%s:%s:%s:%s:%s\\n' "
            '"$FX_PREEXEC_COUNT" "$FX_PRECMD_COUNT" "$FX_ACCEPT_COUNT" '
            '"$fx_preexec_hooks" "$fx_precmd_hooks"'
        )
        state = output.rsplit("ZSH_HOOK_STATE=", 1)[1].splitlines()[0].split(":")
        self.assertGreater(int(state[0]), 0, output)
        self.assertGreater(int(state[1]), 0, output)
        self.assertGreater(int(state[2]), 0, output)
        self.assertEqual(["1", "1"], state[3:], output)

        self.shell.command("dum_tum_reload")
        output = self.shell.command(
            "printf 'ZSH_RELOAD=%s:%s\\n' "
            '"${preexec_functions[(I)_fx_preexec]}" '
            '"${precmd_functions[(I)_fx_precmd]}"; '
            "zle -l -L accept-line"
        )
        state = output.rsplit("ZSH_RELOAD=", 1)[1].splitlines()[0].split(":")
        self.assertNotEqual("0", state[0], output)
        self.assertNotEqual("0", state[1], output)
        self.assertIn("zle -N accept-line _fx_accept_line", output)

        self.shell.command("dum_tum_unload")
        output = self.shell.command(
            "printf 'ZSH_RESTORE=%s:%s:%s:%s\\n' "
            '"${preexec_functions[(I)_fx_preexec]}" '
            '"${precmd_functions[(I)_fx_precmd]}" '
            '"${preexec_functions[(I)_fx_test_preexec]}" '
            '"${precmd_functions[(I)_fx_test_precmd]}"; '
            "zle -l -L accept-line"
        )
        state = output.rsplit("ZSH_RESTORE=", 1)[1].splitlines()[0].split(":")
        self.assertEqual(["0", "0"], state[:2], output)
        self.assertNotEqual("0", state[2], output)
        self.assertNotEqual("0", state[3], output)
        self.assertIn("zle -N accept-line _fx_test_accept", output)

        output = self.shell.command("printf 'ZSH_ACCEPT=%s\\n' \"$FX_ACCEPT_COUNT\"")
        before = int(output.rsplit("ZSH_ACCEPT=", 1)[1].splitlines()[0])
        self.shell.command("printf ZSH_PRIOR_WIDGET")
        output = self.shell.command("printf 'ZSH_ACCEPT=%s\\n' \"$FX_ACCEPT_COUNT\"")
        after = int(output.rsplit("ZSH_ACCEPT=", 1)[1].splitlines()[0])
        self.assertGreater(after, before)

        self.shell.command(f"source '{adapter}'")
        self.shell.command(
            "FX_LATER_ACCEPT_COUNT=0; "
            "_fx_test_later_accept() { (( FX_LATER_ACCEPT_COUNT += 1 )); zle .accept-line; }; "
            "_fx_test_later_precmd() { :; }; "
            "add-zsh-hook precmd _fx_test_later_precmd; "
            "zle -N accept-line _fx_test_later_accept"
        )
        self.shell.command("dum_tum_unload")
        output = self.shell.command(
            "printf 'ZSH_LATER=%s:%s\\n' "
            '"${precmd_functions[(I)_fx_test_later_precmd]}" "$FX_LATER_ACCEPT_COUNT"; '
            "zle -l -L accept-line"
        )
        state = output.rsplit("ZSH_LATER=", 1)[1].splitlines()[0].split(":")
        self.assertNotEqual("0", state[0], output)
        self.assertGreater(int(state[1]), 0, output)
        self.assertIn("zle -N accept-line _fx_test_later_accept", output)

    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_bash_hooks_coexist_and_unload_restores_state(self):
        bash = shutil.which("bash")
        version = subprocess.check_output([bash, "-c", "printf %s \"${BASH_VERSINFO[0]}\""]).decode()
        if int(version) < 4:
            self.skipTest("Bash 4+ is required for Readline binding coexistence")
        self.shell = ShellSession([bash, "--noprofile", "--norc", "-i"], self.tempdir.name)
        self.shell.command(
            "FX_DEBUG_COUNT=0; FX_PROMPT_COUNT=0; FX_ENTER_COUNT=0; "
            "_fx_test_prompt() { (( FX_PROMPT_COUNT += 1 )); }; "
            "_fx_test_enter() { (( FX_ENTER_COUNT += 1 )); }; "
            "trap ': \"$((FX_DEBUG_COUNT += 1))\"' DEBUG; "
            "FX_EXPECT_DEBUG=\"$(trap -p DEBUG)\"; "
            "PROMPT_COMMAND=_fx_test_prompt; "
            "bind -x '\"\\C-xft\": _fx_test_enter'; "
            "bind '\"\\C-xfx\": \"prior-hidden\"'; "
            "bind '\"\\C-m\": \"\\C-xft\\C-j\"'"
        )
        adapter = ROOT / "src" / "fixit.bash"
        self.shell.command(f"source '{adapter}'; source '{adapter}'")
        output = self.shell.command(
            "[[ \"$(trap -p DEBUG)\" == \"$FX_EXPECT_DEBUG\" ]]; fx_debug_live=$?; "
            "printf 'BASH_HOOK_STATE=%s:%s:%s:%s\\n' "
            '"$FX_DEBUG_COUNT" "$FX_PROMPT_COUNT" "$FX_ENTER_COUNT" "$PROMPT_COMMAND"; '
            "printf 'BASH_DEBUG_LIVE=%s\\n' \"$fx_debug_live\"; "
            "printf 'BASH_CAPTURE=%s:%s:%s:%s\\n' "
            '"${_FX_BASH_BIND_TYPES[0]}" "${_FX_BASH_BIND_VALUES[0]}" '
            '"${_FX_BASH_BIND_TYPES[1]}" "${_FX_BASH_BIND_VALUES[1]}"'
        )
        state = output.rsplit("BASH_HOOK_STATE=", 1)[1].splitlines()[0].split(":", 3)
        self.assertGreater(int(state[0]), 0, output)
        self.assertGreater(int(state[1]), 0, output)
        self.assertGreater(int(state[2]), 0, output)
        self.assertEqual("_fx_prompt_hook;_fx_test_prompt", state[3], output)
        self.assertIn("BASH_DEBUG_LIVE=0", output)
        self.assertIn("BASH_CAPTURE=macro", output)

        self.shell.command("dum_tum_reload")
        output = self.shell.command("printf 'BASH_RELOAD=%s\\n' \"$PROMPT_COMMAND\"")
        self.assertIn("BASH_RELOAD=_fx_prompt_hook;_fx_test_prompt", output)

        self.shell.command("dum_tum_unload")
        restore_command = (
            "[[ \"$(trap -p DEBUG)\" == \"$FX_EXPECT_DEBUG\" ]]; fx_debug_restored=$?; "
            "[[ $PROMPT_COMMAND == _fx_test_prompt ]]; fx_prompt_restored=$?; "
            "printf 'BASH_RESTORE=%s:%s:%s\\n' "
            '"$fx_debug_restored" "$fx_prompt_restored" "$FX_ENTER_COUNT"; '
            "bind -s"
        )
        self.shell.send(restore_command + "\n")
        output = self.shell.read_until_idle(PROMPT)
        state = output.rsplit("BASH_RESTORE=", 1)[1].splitlines()[0].split(":")
        self.assertEqual(["0", "0"], state[:2], output)
        self.assertGreater(int(state[2]), 0, output)
        self.assertIn(r'"\C-xfx": "prior-hidden"', output)
        self.assertIn(r'"\C-m": "\C-xft\C-j"', output)

        self.shell.command(f"source '{adapter}'")
        self.shell.command(
            "_fx_test_later_prompt() { :; }; "
            'PROMPT_COMMAND="$PROMPT_COMMAND;_fx_test_later_prompt"; '
            "bind '\"\\C-m\": \"\\C-j\"'"
        )
        self.shell.command("dum_tum_unload")
        output = self.shell.command(
            "printf 'BASH_LATER=%s\\n' \"$PROMPT_COMMAND\"; bind -s"
        )
        self.assertIn("BASH_LATER=_fx_test_prompt;_fx_test_later_prompt", output)
        self.assertIn(r'"\C-m": "\C-j"', output)

    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_bash_prompt_command_array_is_preserved(self):
        bash = shutil.which("bash")
        version = subprocess.check_output([bash, "-c", "printf %s \"${BASH_VERSINFO[0]}\""]).decode()
        if int(version) < 5:
            self.skipTest("Bash 5+ is required for PROMPT_COMMAND arrays")
        self.shell = ShellSession([bash, "--noprofile", "--norc", "-i"], self.tempdir.name)
        self.shell.command(
            "FX_PROMPT_ONE=0; FX_PROMPT_TWO=0; "
            "_fx_test_prompt_one() { (( FX_PROMPT_ONE += 1 )); }; "
            "_fx_test_prompt_two() { (( FX_PROMPT_TWO += 1 )); }; "
            "PROMPT_COMMAND=(_fx_test_prompt_one _fx_test_prompt_two)"
        )
        adapter = ROOT / "src" / "fixit.bash"
        self.shell.command(f"source '{adapter}'; source '{adapter}'")
        output = self.shell.command(
            "printf 'BASH_ARRAY=%s:%s:%s:%s:%s\\n' "
            '"${#PROMPT_COMMAND[@]}" "${PROMPT_COMMAND[0]}" '
            '"${PROMPT_COMMAND[1]}" "${PROMPT_COMMAND[2]}" '
            '"$FX_PROMPT_ONE,$FX_PROMPT_TWO"'
        )
        state = output.rsplit("BASH_ARRAY=", 1)[1].splitlines()[0].split(":")
        self.assertEqual(
            ["3", "_fx_prompt_hook", "_fx_test_prompt_one", "_fx_test_prompt_two"],
            state[:4],
            output,
        )
        counts = state[4].split(",")
        self.assertGreater(int(counts[0]), 0, output)
        self.assertGreater(int(counts[1]), 0, output)

        self.shell.command(
            "_fx_test_prompt_later() { :; }; PROMPT_COMMAND+=(_fx_test_prompt_later)"
        )
        self.shell.command("dum_tum_unload")
        output = self.shell.command(
            "printf 'BASH_ARRAY_RESTORE=%s:%s:%s:%s\\n' "
            '"${#PROMPT_COMMAND[@]}" "${PROMPT_COMMAND[0]}" "${PROMPT_COMMAND[1]}" '
            '"${PROMPT_COMMAND[2]}"'
        )
        state = output.rsplit("BASH_ARRAY_RESTORE=", 1)[1].splitlines()[0].split(":")
        self.assertEqual(
            ["3", "_fx_test_prompt_one", "_fx_test_prompt_two", "_fx_test_prompt_later"],
            state,
            output,
        )

    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_bash_nounset_loads_with_unset_prompt_command(self):
        bash = shutil.which("bash")
        self.shell = ShellSession([bash, "--noprofile", "--norc", "-u", "-i"], self.tempdir.name)
        self.shell.command("_FX_LAST=''; _FX_LASTFAIL=''; _FX_FIXED=0; unset PROMPT_COMMAND")
        adapter = ROOT / "src" / "fixit.bash"
        output = self.shell.command(
            f"source '{adapter}'; "
            "printf 'BASH_NOUNSET=%s:%s\\n' \"$_FX_BASH_LOADED\" \"$PROMPT_COMMAND\""
        )
        self.assertIn("BASH_NOUNSET=1:_fx_prompt_hook", output)
        output = self.shell.command(
            "dum_tum_unload; printf 'BASH_NOUNSET_UNLOAD=%s\\n' \"${PROMPT_COMMAND+x}\""
        )
        self.assertIn("BASH_NOUNSET_UNLOAD=", output)

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

    @unittest.skipUnless(shutil.which("zsh"), "zsh is not installed")
    def test_zsh_autorun_checks_arguments_and_streams(self):
        self.start([shutil.which("zsh"), "-f"], "fixit.zsh")
        self.exercise_autorun_safety()

    @unittest.skipUnless(shutil.which("zsh"), "zsh is not installed")
    def test_zsh_routes_typos_before_natural_language(self):
        self.start([shutil.which("zsh"), "-f"], "fixit.zsh")
        self.exercise_typo_routing()

    @unittest.skipUnless(shutil.which("zsh"), "zsh is not installed")
    def test_zsh_failed_line_repair_preserves_syntax(self):
        self.start([shutil.which("zsh"), "-f"], "fixit.zsh")
        self.exercise_failed_line_repair()

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

    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_bash_autorun_checks_arguments_and_streams(self):
        bash = shutil.which("bash")
        self.start([bash, "--noprofile", "--norc", "-i"], "fixit.bash")
        self.exercise_autorun_safety()

    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_bash_routes_typos_before_natural_language(self):
        bash = shutil.which("bash")
        self.start([bash, "--noprofile", "--norc", "-i"], "fixit.bash")
        self.exercise_typo_routing()

    @unittest.skipUnless(shutil.which("bash"), "bash is not installed")
    def test_bash_failed_line_repair_preserves_syntax(self):
        bash = shutil.which("bash")
        version = subprocess.check_output([bash, "-c", "printf %s \"${BASH_VERSINFO[0]}\""]).decode()
        if int(version) < 4:
            self.skipTest("Bash 4+ is required for full submitted-line capture")
        self.start([bash, "--noprofile", "--norc", "-i"], "fixit.bash")
        self.exercise_failed_line_repair()


if __name__ == "__main__":
    unittest.main()
