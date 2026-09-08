# Contributing to dum-tum

Thanks for helping improve dum-tum. Changes should keep ordinary shell input unsurprising, require confirmation for AI suggestions, and preserve the local-only path.

## Development setup

Required tools:

- Python 3
- zsh 5+ and Bash (Bash 4+ for the Bash PTY tests)
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

Every pull request triggers `.github/workflows/ci.yml`. The Linux job installs and explicitly runs both Bash 5 and zsh PTY tests before the complete suite and npm package check. The macOS job explicitly runs the native zsh PTY test before the complete suite.

## Cross-platform confirmation tests

`tests/test_shell_interactive.py` launches real interactive shells in pseudo-terminals. It verifies that Enter runs a confirmed suggestion through the normal shell editor, cancel does not execute it, edit keeps the suggestion changeable, and ordinary commands bypass AI handling.

Individual PTY tests skip unavailable shells, but the full suite requires both Bash and zsh and fails if zsh or shellcheck is missing. On macOS, zsh runs locally while the system Bash 3.2 is skipped. Exercise Bash 5 in a clean Linux container with:

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

Describe the user-visible behavior, supported shells tested, and the exact verification commands run. Keep unrelated changes out of the same pull request. Do not merge until both `Linux — Bash 5 and zsh` and `macOS — zsh` pass.

Releases are maintained separately using [RELEASING.md](RELEASING.md).
