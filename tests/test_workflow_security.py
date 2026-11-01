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

    def test_npm_publish_is_limited_to_stable_releases(self):
        text = (ROOT / ".github/workflows/npm-publish.yml").read_text()
        self.assertIn("  release:\n    types: [published]", text)
        self.assertIn("    if: ${{ github.event.release.prerelease == false }}", text)
        self.assertIn("concurrency:\n  group: npm-publish\n  cancel-in-progress: false", text)
        self.assertNotIn("  workflow_dispatch:", text)

    def test_npm_publish_uses_oidc_without_long_lived_tokens(self):
        text = (ROOT / ".github/workflows/npm-publish.yml").read_text()
        self.assertIn("      id-token: write", text)
        self.assertIn("          node-version: 24.x", text)
        self.assertNotIn("NPM_TOKEN", text)
        self.assertNotIn("NODE_AUTH_TOKEN", text)
        self.assertIn("        run: npm publish --access public", text)

    def test_npm_publish_verifies_release_source_and_version(self):
        text = (ROOT / ".github/workflows/npm-publish.yml").read_text()
        version_check = '          test "$GITHUB_REF_NAME" = "v$(node -p "require(\'./package.json\').version")"'
        self.assertIn("          ref: ${{ github.event.release.tag_name }}", text)
        self.assertIn("          git merge-base --is-ancestor HEAD FETCH_HEAD", text)
        self.assertIn(version_check, text)
        publish = text.index("        run: npm publish --access public")
        self.assertLess(text.index("          git fetch origin main"), publish)
        self.assertLess(text.index("          git merge-base --is-ancestor HEAD FETCH_HEAD"), publish)
        self.assertLess(text.index(version_check), publish)
        self.assertLess(text.index("        run: bash tests/run-tests.sh"), publish)
        self.assertLess(text.index("        run: npm pack --dry-run"), publish)

    def test_npm_publish_does_not_move_latest_backward(self):
        text = (ROOT / ".github/workflows/npm-publish.yml").read_text()
        guard = text.index("      - name: Verify version advances npm latest")
        publish = text.index("        run: npm publish --access public")
        self.assertLess(guard, publish)
        self.assertIn('fetch("https://registry.npmjs.org/dum-tum")', text)
        self.assertIn("response.status !== 404", text)
        self.assertIn("compare(candidate, parse(latest)) <= 0", text)

    def test_release_instructions_verify_tag_and_watch_current_run(self):
        text = (ROOT / "RELEASING.md").read_text()
        self.assertIn("gh release create vX.Y.Z --verify-tag", text)
        self.assertIn('RELEASE_SHA="$(git rev-list -n 1 vX.Y.Z)"', text)
        self.assertIn('--event release --commit "$RELEASE_SHA"', text)
        self.assertIn("--json databaseId,headBranch", text)
        self.assertIn('select(.headBranch == "vX.Y.Z")', text)
        self.assertIn("for _ in {1..30}; do", text)
        self.assertIn('gh run watch --exit-status "$RUN_ID"', text)

    def test_npm_publish_verification_retries_until_visible(self):
        text = (ROOT / ".github/workflows/npm-publish.yml").read_text()
        verify = text.split("      - name: Verify published package\n", 1)[1]
        self.assertIn("DEADLINE=$((SECONDS + 120))", verify)
        self.assertIn('while [ "$SECONDS" -lt "$DEADLINE" ]; do', verify)
        self.assertIn("REMAINING=$((DEADLINE - SECONDS))", verify)
        self.assertIn('timeout "${REMAINING}s" npm view', verify)
        self.assertIn("exit 0", verify)
        self.assertIn('if [ "$REMAINING" -gt 10 ]; then', verify)
        self.assertIn("sleep 10", verify)
        self.assertIn("exit 1", verify)
