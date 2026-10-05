# dum-tum

**Website:** https://arjunagi-a-rehman.github.io/dum-tum/

[![npm version](https://img.shields.io/npm/v/dum-tum.svg)](https://www.npmjs.com/package/dum-tum)
[![license](https://img.shields.io/npm/l/dum-tum.svg)](LICENSE)
[![CI](https://github.com/arjunagi-a-rehman/dum-tum/actions/workflows/ci.yml/badge.svg)](https://github.com/arjunagi-a-rehman/dum-tum/actions/workflows/ci.yml)

**The shell fixer with no trigger key.** Just type what you mean and press Enter.

```bash
$ sl
# → runs ls

$ list all files
AI request preview
[y] send  [n] cancel
…resolving
→ ls -la
[Enter] run  ·  [e] edit  ·  [n] cancel
```

No `f`. No `??`. No `sgpt "..."`. No mode switch. You type into your shell the way you already do, and the shell figures out what you meant.

macOS + Linux · zsh + bash · MIT

```bash
npx dum-tum@latest
```

---

## Why this is different

Every other terminal fixer makes you *ask* for help. That's the friction — you have to notice you're stuck, remember the tool exists, and invoke it.

| Tool | How you invoke it |
| --- | --- |
| thefuck | run the command, then type `fuck` |
| pay-respects | run the command, then press `F` |
| ShellGPT | `sgpt "list all files"` |
| ai-shell | `ai list all files` |
| Copilot CLI | `gh copilot suggest "..."` |
| **dum-tum** | **you just type. Enter.** |

dum-tum hooks `accept-line` — the moment you press Enter, before your shell rejects anything. Typos get fixed locally and instantly. Plain English that starts with an unknown command can be offered to AI. You review and approve the request before transmission. Everything else runs exactly as it always did.

When an AI suggestion needs confirmation, Enter submits it through your shell's normal line editor, `e` leaves it in the buffer for editing, and `n` cancels it.

The second difference: **it doesn't demand another API key.** Supported `opencode` and `claude` (Claude Code) versions can use your existing login. Codex and Antigravity are currently refused for lack of a verified no-tools boundary. OpenRouter is there if you'd rather bring a key. Local-only mode works with no AI at all.

---

## What it does

| You type | What happens |
| --- | --- |
| `sl` | auto-runs `ls` — local, offline, instant |
| `gti status` | close match, but not read-only → **confirms first** |
| `kil 1234` | **never** auto-runs `kill` — confirm prompt only |
| `cat dcoument.txt` | fuzzy-matches the filename on safe commands |
| `list all files` | AI suggests `ls -la` → you confirm |
| `create a python venv` | AI suggests the command → you confirm |
| `fix` | AI-corrects whatever just failed |

**Stage 1** is local fuzzy matching: instant, offline, never touches the network.
**Stage 2** is optional AI, and it *never* auto-runs. Enter to run, `e` to edit, `n` to cancel.

---

## Install or update

**macOS, Ubuntu, Debian, Fedora, Arch:**

```bash
npx dum-tum@latest
```

Or without Node:

```bash
curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash
```

The installer detects your login shell, installs deps, finds available CLI providers on your PATH, offers supported providers and models, smoke-tests it, and writes your rc file. The network smoke test sends only a fixed diagnostic task, with no local context. Then:

```bash
source ~/.zshrc   # or open a new tab
sl
list all files
```

Running the installer again updates the scripts in `~/.local/share/fixit` and replaces the existing marked config block instead of adding a duplicate. Reload the adapter in the active shell after an update, or temporarily remove its hooks and bindings without disturbing integrations that were already installed:

```bash
dum_tum_reload
dum_tum_unload
```

**Non-interactive:**

```bash
./install.sh --yes --provider opencode --model anthropic/claude-sonnet-4
./install.sh --yes --provider openrouter
./install.sh --yes --provider openai
./install.sh --yes --provider anthropic
./install.sh --yes --provider gemini
./install.sh --yes --provider none          # local typo fixing only
./install.sh --uninstall
```

For a key-based non-interactive install, provide only the environment variable matching the selected provider: `OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `GEMINI_API_KEY` (`GOOGLE_API_KEY` is also accepted for Gemini). The removed `--key` option is rejected because command-line values are exposed in shell history and process arguments. To enter a key without echoing it, omit `--yes` and run with the provider only, such as `./install.sh --provider openai`; the installer uses a hidden terminal prompt.

`--skip-ai-test` prevents all provider CLI execution, live model discovery, authentication checks, and network smoke tests. The installer still verifies that a selected local CLI exists on `PATH`; storing a legacy Codex or Antigravity choice does not enable it at runtime; a key-based provider without its matching key is disabled. Choosing `--provider none` performs no AI-provider or model-network activity.

Requires `python3`, `curl`, and either zsh or Bash 4+.

| Shell | Support |
| --- | --- |
| zsh 5+ on macOS or Linux | Full Enter hook, confirmation, edit, and cancel behavior |
| Bash 4+ on Linux or macOS | Full Enter hook, confirmation, edit, and cancel behavior |
| macOS `/bin/bash` 3.2 | Local typo handling works; install Homebrew Bash 5 or use zsh for the Enter hook |

---

## Safety

This tool runs things in your shell. That deserves a straight answer about what it will and won't do.

- **Only read-only commands auto-run.** `ls`, `cat`, `pwd` and friends. Everything else asks.
- **AI output never auto-runs.** Ever. It always waits for Enter.
- **Failed-command AI is off by default.** Set `FX_AI_ON_FAIL=1` to offer AI help for eligible failures. Every shell AI request shows the provider and exact JSON payload and requires a fresh `y` before transmission. The suggested command then needs a separate fresh Enter to run.
- **Known secret shapes are blocked or redacted** before AI calls. This includes quoted or spaced secret assignments, password/token/API-key flags and labels, authorization and API-key headers, credentials embedded in URLs, and high-confidence provider-key formats such as `sk-…`, GitHub, AWS, Google, Slack, and GitLab tokens.
- **Local mode is fully offline.** Nothing leaves your machine, period.
- **Keys aren't passed as process arguments.** The installer accepts them through a hidden prompt or provider-specific environment variable, and HTTP credentials and request bodies reach `curl` through stdin rather than argv. As with any environment-based secret, another process with sufficient permission may still inspect the environment. Your rc file is `chmod 600` after install.

Before sending a prompt to a local CLI backend, dum-tum requires controls that disable tools. OpenCode runs in an empty temporary directory without external plugins and with deny-all tool and permission configuration. Claude runs in an empty temporary directory in safe, plan mode with no tools or MCP servers. Installed versions without those controls are refused. Codex and Antigravity are currently refused because their sandbox or plan modes do not establish a complete no-tools boundary. Choose an HTTP provider, supported OpenCode, or supported Claude instead. These controls constrain model tools; the CLI executable itself remains trusted software with your user permissions.

OpenCode passes its prompt as a CLI argument, which may be visible to other local users in the process table. Claude sends its prompt through stdin.

What AI mode sends: OS and shell, cwd, up to 20 directory names, bounded project script or Make target names, bounded aliases, and the task or failed input. Context is encoded as JSON data, and the exact redacted payload is shown before you approve sending it. Existing commands such as `find`, `open`, and `type` are left to the shell. Failed commands matching a known secret pattern are not sent; matching values in other context are redacted. Detection is heuristic: novel, obfuscated, fragmented, or unlabeled secrets may not be recognized, and filenames, aliases, command arguments, and natural-language prompts can still be sensitive. Do not include secrets in data you allow AI mode to send.

---

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `FX_PROVIDER` | `openrouter` | `openrouter` · `openai` · `anthropic` · `gemini` · `opencode` · `claude` · `none`; legacy `codex`/`antigravity` values are refused |
| `FX_MODEL` | provider default | model id |
| `FX_VARIANT` | model default | reasoning effort (`low`/`medium`/`high`) |
| `FX_AI_TIMEOUT` | `90` | seconds before a CLI backend call and its descendants are killed |
| `FX_AI_ON_FAIL` | `0` | offer AI help for eligible failures; requires request approval |
| `OPENROUTER_API_KEY` | — | required only for `openrouter` |
| `OPENAI_API_KEY` | — | required only for `openai` |
| `ANTHROPIC_API_KEY` | — | required only for `anthropic` |
| `GEMINI_API_KEY` | — | required only for `gemini` (`GOOGLE_API_KEY` also works) |
| `FIXIT_HOME` | `~/.local/share/fixit` | install directory |

```bash
export FX_PROVIDER="opencode"
export FX_MODEL="anthropic/claude-sonnet-4"
```

---

## How it works

```
Enter pressed
    │
    ├─ Unknown-command sentence?   → approve request → AI → confirm
    │
    ├─ Unknown command?
    │     multi-word English       → AI → confirm
    │     close typo + read-only   → auto-run
    │     close typo + anything    → confirm only
    │     else                     → AI → confirm
    │
    └─ Known command failed?
          typo'd file arg (safe)   → fix path + re-run
          multi-tool usage error   → ask → AI → confirm
```

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Nothing happens in bash | bash 3.2 is too old — `brew install bash`, or use zsh |
| `where is …` runs builtin `where` | update to latest — needs the accept-line hook |
| `…resolving` then timeout | check network/VPN and provider auth; try another `FX_MODEL` |
| Old behavior after update | restart the loaded shell with `exec zsh` or `exec bash` |
| Suggestion appears but Enter does not run it | update with `npx dum-tum@latest`, then run `exec zsh` or `exec bash` |
| `opencode`/`claude`/`codex`/`agy` not found | install the CLI and ensure it's on `PATH`, or switch to OpenRouter |

Quick diagnostic:

```bash
echo $SHELL; python3 --version; echo $FX_PROVIDER $FX_MODEL
command -v opencode; command -v claude; command -v codex; command -v agy
whence -w command_not_found_handler
```

---

## Development and tests

Run the complete local suite before submitting a change:

```bash
bash tests/run-tests.sh
```

The suite covers Python parsing and payloads, shared shell helpers, syntax, shellcheck, and real pseudo-terminal confirmation flows. Interactive tests run for shells available on the machine: zsh on macOS and Bash 4+ on Linux. See [CONTRIBUTING.md](CONTRIBUTING.md) for the cross-platform test command and contribution workflow.

Every pull request automatically runs both supported interactive paths in GitHub Actions: Bash 5 and zsh on Linux, plus native zsh on macOS.

---

## Manual install

```bash
git clone https://github.com/arjunagi-a-rehman/dum-tum.git
mkdir -p ~/.local/share/fixit
cp dum-tum/src/* ~/.local/share/fixit/
echo 'source "$HOME/.local/share/fixit/fixit.zsh"' >> ~/.zshrc
```

## Repo layout

| Path | Role |
| --- | --- |
| `src/fixit.zsh` · `src/fixit.bash` | shell adapters (hooks) |
| `src/fixit-common.sh` | shared fuzzy + AI core |
| `src/fixit-ai.py` | AI payload/extract helper |
| `install.sh` | macOS + Linux installer |
| `bin/dum-tum.js` | `npx` entrypoint |
| `tests/test_shell_interactive.py` | PTY-level Zsh and Bash confirmation tests |
| `tests/` | full suite via `bash tests/run-tests.sh` |

## Project docs

- [Contributing and development](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Release process](RELEASING.md)
- [GitHub releases](https://github.com/arjunagi-a-rehman/dum-tum/releases)

## License

MIT. Use it, fork it, break it.
