# Releasing dum-tum

dum-tum is published in two places from the same repo:

- **npm**: `dum-tum` — `npx dum-tum` always runs the latest published version
- **GitHub**: tags + releases at https://github.com/arjunagi-a-rehman/dum-tum/releases

## Release checklist

1. Start from an up-to-date `main`, never from a feature branch:
   ```bash
   git switch main
   test -z "$(git status --porcelain)"
   git fetch origin
   git pull --ff-only origin main
   test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
   ```
2. Make sure the audited `main` tree passes every release gate:
   ```bash
   bash tests/run-tests.sh
   ```
   On macOS, also exercise the Bash 5 PTY test in Linux:
   ```bash
   docker run --rm -v "$PWD:/repo:ro" -w /repo python:3.12-slim \
     python -m unittest \
     tests.test_shell_interactive.InteractiveAdapterTest.test_bash_confirmation_flow -v
   ```
3. Bump `version` in `package.json` (semver).
   Review README and SECURITY disclosures if shell behavior, transmitted context, or provider handling changed.
4. Verify that the version has not already been published, then inspect the exact package contents from the clean audited tree:
   ```bash
   VERSION="$(node -p "require('./package.json').version")"
   npm view "dum-tum@$VERSION" version
   npm pack --dry-run
   ```
   The `npm view` command must report that the version does not exist. Any other error must be investigated rather than treated as an unpublished version. Review the complete `npm pack --dry-run` file list and confirm it comes from the intended `main` commit.
5. Commit the bump and fast-forward `main` on GitHub:
   ```bash
   git add package.json && git commit -m "chore: bump version to X.Y.Z"
   git push origin main
   git fetch origin
   test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
   ```
6. Tag the verified `main` commit, check the tag target, and push it:
   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z — <short title>"
   test "$(git rev-list -n 1 vX.Y.Z)" = "$(git rev-parse main)"
   git push origin vX.Y.Z
   ```
7. Publish to npm (requires `npm login`; account has 2FA — you'll be prompted to authenticate in the browser):
   ```bash
   npm publish --access public
   ```
8. Create the GitHub release with notes:
   ```bash
   gh release create vX.Y.Z --title "vX.Y.Z — <short title>" --notes "<release notes>"
   ```
9. Verify both public release targets and their commit:
   ```bash
   npm view dum-tum@X.Y.Z version dist-tags.latest gitHead dist.shasum --json
   gh release view vX.Y.Z
   test "$(git rev-list -n 1 vX.Y.Z)" = "$(git rev-parse origin/main)"
   ```

## Notes

- npm versions are immutable — never reuse a version number. If you botch a publish, bump the version and republish.
- `.npmignore` excludes `__pycache__/` and `*.pyc` from the tarball. Verify contents before publishing with `npm pack --dry-run`.
- `npx github:arjunagi-a-rehman/dum-tum` runs **main branch HEAD**, not a release. Pin with `#vX.Y.Z` if you need a specific tag.
- `npx dum-tum` (no `github:` prefix) runs the npm-published code, which is the release.
- Merging functionality into `main` does not make it available through `npx dum-tum`; users receive it only after a new version is published to npm's `latest` dist-tag.
