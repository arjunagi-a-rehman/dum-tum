# dum-tum

**The shell fixer with no trigger key.** Just type what you mean and press Enter.

```bash
$ sl
# → runs ls

$ where is the com folder
…resolving
→ find . -type d -iname "*com*"
[Enter] run  ·  [e] edit  ·  [n] cancel
```

No `f`. No `??`. No `sgpt "..."`. No mode switch. You type into your shell the way you already do, and the shell figures out what you meant.

macOS + Linux · zsh + bash · MIT

```bash
npx dum-tum
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

dum-tum hooks `accept-line` — the moment you press Enter, before your shell rejects anything. Typos get fixed locally and instantly. Plain English gets routed to AI. Everything else runs exactly as it always did.

The second difference: **it doesn't demand another API key.** If you already have `opencode` or `codex` installed and logged in, dum-tum uses them. OpenRouter is there if you'd rather bring a key. Local-only mode works with no AI at all.

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

## Install

**macOS, Ubuntu, Debian, Fedora, Arch:**

```bash
npx dum-tum
```

Or without Node:

```bash
curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash
```

The installer detects your login shell, installs deps, finds `opencode`/`codex` on your PATH, lets you pick a provider and model, smoke-tests it, and writes your rc file. Then:

```bash
source ~/.zshrc   # or open a new tab
sl
list all files
```

**Non-interactive:**

```bash
./install.sh --yes --provider opencode --model anthropic/claude-sonnet-4
./install.sh --yes --provider openrouter --key sk-or-v1-...
./install.sh --yes --provider none          # local typo fixing only
./install.sh --uninstall
```

Requires zsh or bash 4+, `python3`, and `curl`. On macOS, `/bin/bash` 3.2 is too old for the Enter-hook — typo fixing still works, or install Homebrew bash 5 for the full experience.

---

## Safety

This tool runs things in your shell. That deserves a straight answer about what it will and won't do.

- **Only read-only commands auto-run.** `ls`, `cat`, `pwd` and friends. Everything else asks.
- **AI output never auto-runs.** Ever. It always waits for Enter.
- **Failed-command auto-fix asks before sending.** When a broken `git`/`npm`/`docker` command would go to AI, you get `Send this failed command? [y/N]` first. Nothing is transmitted silently.
- **Secrets are redacted** before anything leaves the machine — `--password X`, `Bearer X`, `sk-…`, `*_KEY=…`, `*_TOKEN=…`.
- **Local mode is fully offline.** Nothing leaves your machine, period.
- **Keys don't hit the process table.** The OpenRouter key and request body go to `curl` via stdin, not argv, so they don't show in `ps`. Your rc file is `chmod 600` after install.

One honest caveat: with the `opencode`/`codex` providers, the prompt is passed as a CLI argument and is visible to other local users via `ps` for the duration of that call.

What AI mode sends: OS and shell, cwd, ~15 filenames, sample aliases, and what you typed. Don't paste secrets into natural-language prompts.

---

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `FX_PROVIDER` | `openrouter` | `openrouter` · `opencode` · `codex` · `none` |
| `FX_MODEL` | provider default | model id |
| `FX_VARIANT` | model default | reasoning effort (`low`/`medium`/`high`) |
| `FX_AI_TIMEOUT` | `90` | seconds before a CLI backend call is killed |
| `FX_AI_ON_FAIL` | `1` | ask AI to fix failed `go`/`git`/`npm`/`docker` commands |
| `OPENROUTER_API_KEY` | — | required only for OpenRouter |
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
    ├─ English sentence?           → AI → confirm
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
| Old behavior after update | `source ~/.zshrc` or re-run the installer |
| `opencode`/`codex` not found | install the CLI and ensure it's on `PATH`, or switch to OpenRouter |

Quick diagnostic:

```bash
echo $SHELL; python3 --version; echo $FX_PROVIDER $FX_MODEL
command -v opencode; command -v codex
whence -w command_not_found_handler
```

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
| `tests/` | `bash tests/run-tests.sh` |

## License

MIT. Use it, fork it, break it.
