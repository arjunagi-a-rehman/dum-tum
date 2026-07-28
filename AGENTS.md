# AGENTS.md — notes for AI agents working in this repo

## What this project is

**dum-tum** (formerly fixit-zsh) — a typo + AI shell helper for zsh/bash on macOS and Ubuntu. Repo: https://github.com/arjunagi-a-rehman/dum-tum. The user-facing name is **dum-tum** everywhere (npm package, bin, docs); `fixit` still appears internally in filenames (`src/fixit-*`) and env vars (`FIXIT_HOME`) — do not rename those without a dedicated migration.

## Layout

| Path | Purpose |
| --- | --- |
| `src/fixit.zsh` / `src/fixit.bash` | shell adapters (hooks) |
| `src/fixit-common.sh` | shared fuzzy + AI core |
| `src/fixit-ai.py` | AI payload/extract helper (python3) |
| `install.sh` | macOS + Linux installer |
| `bin/dum-tum.js` | `npx` entrypoint — just execs `install.sh` |
| `tests/run-tests.sh` | full test suite (shell + Python + shellcheck) |

## Verify changes

Always run before considering work done:

```bash
bash tests/run-tests.sh
```

Must end with "All tests passed" (44 tests + shellcheck). shellcheck must be clean.

## Releasing

See [RELEASING.md](RELEASING.md). Short version: bump `package.json` version → tag `vX.Y.Z` → `npm publish --access public` (user runs this; npm account has 2FA, needs browser auth) → `gh release create`.

Key facts:
- `npx dum-tum` = npm release (latest dist-tag). `npx github:...` = main HEAD, not a release.
- npm versions are immutable; never retag/reuse a published version.
- Check tarball contents with `npm pack --dry-run` before publishing.

## Conventions

- Commits: conventional style (`fix:`, `feat:`, `test:`, `chore:`, `docs:`), merged via PRs on GitHub (`gh`).
- Never commit secrets; OpenRouter keys go to curl via stdin, not argv.
- No code comments unless asked.
