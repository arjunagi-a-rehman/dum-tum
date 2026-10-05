import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WorkflowSecurityTest(unittest.TestCase):
    def test_external_actions_use_immutable_commit_ids(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            for action in re.findall(r"(?m)^\s*uses:\s*(\S+)", path.read_text()):
                with self.subTest(workflow=path.name, action=action):
                    if not action.startswith(("./", "docker://")):
                        self.assertRegex(action, r"^[^@]+@[a-f0-9]{40}$")

    def test_pages_job_restricts_all_triggers_to_main(self):
        text = (ROOT / ".github/workflows/pages.yml").read_text()
        job = text.split("  deploy:\n", 1)[1]
        guard = re.search(r"(?m)^    if:\s*(.+)$", job).group(1)
        self.assertEqual(guard, "${{ github.ref == 'refs/heads/main' }}")
        self.assertIn("  workflow_dispatch:", text)
