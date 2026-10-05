import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from tests.test_shell_interactive import ShellSession, PROMPT


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
BASH_MAJOR = int(subprocess.check_output([BASH, "-c", "echo ${BASH_VERSINFO[0]}"], text=True))


@unittest.skipUnless(BASH_MAJOR >= 4, "Bash 4+ is required for the Enter hook")
class BashSecurityTest(unittest.TestCase):
    def test_queued_enter_is_discarded_after_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "executed"
            shell = ShellSession([BASH, "--noprofile", "--norc", "-i"], tmp)
            try:
                shell.command(f"source {shlex.quote(str(ROOT / 'src/fixit.bash'))}")
                shell.command(f"FX_PROVIDER=openai; _fx_ai_ready() {{ return 0; }}; _fx_ai() {{ sleep 1; printf 'touch %s\\n' {shlex.quote(str(marker))}; }}")
                shell.send("list all files\r")
                shell.read_until("[y] send  [n] cancel")
                shell.send("y")
                shell.read_until("…resolving")
                shell.send("\n")
                shell.read_until("[Enter] run  [e] edit  [n] cancel")
                time.sleep(0.2)
                self.assertFalse(marker.exists())
                shell.send("\n")
                shell.read_until_idle(PROMPT)
                self.assertTrue(marker.exists())
            finally:
                shell.close()

    def test_history_suggestion_is_refused_before_resubmission(self):
        with tempfile.TemporaryDirectory() as tmp:
            shell = ShellSession([BASH, "--noprofile", "--norc", "-i"], tmp)
            try:
                shell.command(f"source {shlex.quote(str(ROOT / 'src/fixit.bash'))}")
                shell.command("FX_PROVIDER=openai; _fx_ai_ready() { return 0; }; _fx_ai() { printf 'echo SHOULD_NOT_RUN; !!\\n'; }")
                shell.send("list all files\r")
                shell.read_until("[y] send  [n] cancel")
                shell.send("y")
                output = shell.read_until_idle(PROMPT)
                self.assertIn("refusing a suggestion", output)
                self.assertNotIn("SHOULD_NOT_RUN", output)
            finally:
                shell.close()
