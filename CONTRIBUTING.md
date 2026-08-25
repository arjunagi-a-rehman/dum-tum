# Contributing to dum-tum

Thanks for helping improve dum-tum. Changes should keep ordinary shell input unsurprising, require confirmation for AI suggestions, and preserve the local-only path.

## Development setup

Required tools:

- Python 3
- zsh 5+ or Bash 4+
- curl
- shellcheck
- Node.js 14+ for npm packaging checks

Clone the repository and run the full suite:

```bash
git clone https://github.com/arjunagi-a-rehman/dum-tum.git
cd dum-tum
bash tests/run-tests.sh
```

The command must finish with `All tests passed` and clean shellcheck output.

## Cross-platform confirmation tests

`tests/test_shell_interactive.py` launches real interactive shells in pseudo-terminals. It verifies that Enter runs a confirmed suggestion through the normal shell editor, cancel does not execute it, edit keeps the suggestion changeable, and ordinary commands bypass AI handling.

The test for an unavailable shell is skipped. On macOS, zsh runs locally while the system Bash 3.2 is skipped. Exercise Bash 5 in a clean Linux container with:

```bash
docker run --rm \
  -v "$PWD:/repo:ro" \
  -w /repo \
  python:3.12-slim \
  python -m unittest \
  tests.test_shell_interactive.InteractiveAdapterTest.test_bash_confirmation_flow -v
```

## Change guidelines

- Keep the user-facing name `dum-tum`. Internal `fixit-*` filenames and `FIXIT_HOME` remain for compatibility.
- Keep API keys and HTTP request bodies out of process arguments.
- Update README safety disclosures whenever transmitted context or automatic behavior changes.
- Add regression coverage for shell-hook and confirmation changes.
- Do not include generated tarballs, caches, credentials, or local shell configuration.
- Use conventional commit prefixes such as `fix:`, `feat:`, `test:`, `docs:`, and `chore:`.

## Pull requests

Describe the user-visible behavior, supported shells tested, and the exact verification commands run. Keep unrelated changes out of the same pull request.

Releases are maintained separately using [RELEASING.md](RELEASING.md).
