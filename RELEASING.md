# Releasing dum-tum

dum-tum is published in two places from the same repo:

- **npm**: `dum-tum` — `npx dum-tum` always runs the latest published version
- **GitHub**: tags + releases at https://github.com/arjunagi-a-rehman/dum-tum/releases

## Release checklist

1. Make sure the working tree is clean and tests pass:
   ```bash
   bash tests/run-tests.sh
   ```
   On macOS, also exercise the Bash 5 PTY test in Linux:
   ```bash
   docker run --rm -v "$PWD:/repo:ro" -w /repo python:3.12-slim \
     python -m unittest \
     tests.test_shell_interactive.InteractiveAdapterTest.test_bash_confirmation_flow -v
   ```
2. Bump `version` in `package.json` (semver).
   Review README and SECURITY disclosures if shell behavior, transmitted context, or provider handling changed.
3. Commit the bump:
   ```bash
   git add package.json && git commit -m "chore: bump version to X.Y.Z"
   git push origin main
   ```
4. Tag and push:
   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z — <short title>"
   git push origin vX.Y.Z
   ```
5. Publish to npm (requires `npm login`; account has 2FA — you'll be prompted to authenticate in the browser):
   ```bash
   npm pack --dry-run
   npm publish --access public
   ```
6. Create the GitHub release with notes:
   ```bash
   gh release create vX.Y.Z --title "vX.Y.Z — <short title>" --notes "<release notes>"
   ```
7. Verify both public release targets:
   ```bash
   npm view dum-tum@X.Y.Z version dist-tags.latest gitHead dist.shasum --json
   gh release view vX.Y.Z
   ```

## Notes

- npm versions are immutable — never reuse a version number. If you botch a publish, bump the version and republish.
- `.npmignore` excludes `__pycache__/` and `*.pyc` from the tarball. Verify contents before publishing with `npm pack --dry-run`.
- `npx github:arjunagi-a-rehman/dum-tum` runs **main branch HEAD**, not a release. Pin with `#vX.Y.Z` if you need a specific tag.
- `npx dum-tum` (no `github:` prefix) runs the npm-published code, which is the release.
