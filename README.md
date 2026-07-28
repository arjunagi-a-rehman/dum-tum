# dum-tum

> `dum-tum` is the project/repo name. The tool it installs is **fixit.zsh**.

Turn **typos** and **plain English** into real shell commands — on **macOS** and **Ubuntu/Linux**.

## Why this exists (intention)

The terminal is unforgiving: one wrong letter and you get `command not found`. Nobody remembers every flag for `find`, `tar`, `ffmpeg`, or `grep`. And more and more, people just want to type what they *mean* — "list all files", "where is the reno folder" — and have the machine figure out the command.

**dum-tum's goal: make your shell forgiving.**

1. **Typos shouldn't stop you.** `sl`, `gti`, `cat dcoument.txt` — obvious mistakes get fixed instantly, locally, offline.
2. **English should just work.** Type a sentence, get the right command from AI — but it *never* runs without your explicit Enter.
3. **Safety first.** Destructive fuzzy matches (`rm`, `dd`, `kill`, …) are never auto-run. AI output always goes through a confirm prompt. Nothing executes behind your back.
4. **Zero friction to install.** One `curl` or `npx` line on macOS or Ubuntu — no manual rc-file surgery.

In short: the terminal should feel less like an exam and more like a conversation.

| You type | What happens |
|----------|----------------|
| `sl` | Auto-runs `ls` |
| `list all files` | AI suggests `ls -la` → you confirm |
| `where is reno folder` | AI suggests `find` / `mdfind` → you confirm |
| `cat dcoument.txt` | Fixes the filename typo (safe commands only) |
| `fix` | AI-corrects the last failed command |

- **Stage 1** — local fuzzy matching (instant, offline)
- **Stage 2** — optional AI via **OpenCode**, **Codex CLI**, or [OpenRouter](https://openrouter.ai)  
  Suggestions are **never auto-run**: **Enter** = run · **e** = edit · **n** = cancel

---

## One-line install (easiest)

### macOS or Ubuntu / Debian

**Option A — curl (no Node required)**

```bash
curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash
```

**Option B — npx (if you have Node.js)**

```bash
npx github:arjunagi-a-rehman/dum-tum
```

Interactive install flow:

1. Install deps + copy `fixit.zsh`
2. Detect **OpenCode** / **Codex** on `PATH`
3. **Select provider** — OpenCode · Codex · OpenRouter key · Skip AI
4. **Select model** (curated list or custom)
5. **Smoke-test** the backend
6. Write `~/.zshrc` · done

Non-interactive examples:

```bash
# OpenRouter
curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash -s -- \
  --yes --provider openrouter --key "sk-or-v1-YOUR_KEY"

# OpenCode or Codex (must already be installed + logged in)
./install.sh --yes --provider opencode --model anthropic/claude-sonnet-4
./install.sh --yes --provider codex --model o4-mini

# Local typos only
./install.sh --yes --provider none
```

Also works with env vars: `FX_PROVIDER`, `FX_MODEL`, `OPENROUTER_API_KEY`.

Then reload:

```bash
source ~/.zshrc
# or open a new terminal tab (zsh)
```

Try:

```bash
sl
list all files
```

---

## What you need

| Tool | macOS | Ubuntu |
|------|--------|--------|
| **zsh** | Default since Catalina | Install via installer / `sudo apt install zsh` |
| **python3** | `/usr/bin/python3` or Homebrew | `sudo apt install python3` |
| **curl** | Preinstalled | Preinstalled or `apt install curl` |
| **AI backend** | Optional — OpenCode, Codex CLI, or OpenRouter key | same |

### Default shell must be zsh

fixit only hooks into **zsh**.

**macOS** — usually already zsh:

```bash
echo $SHELL    # expect /bin/zsh
```

**Ubuntu** — often bash by default. After installing zsh:

```bash
chsh -s $(which zsh)
```

Log out and back in (or restart the terminal). Until then you can still run `zsh` manually.

AI backends (pick one at install, or set later):

| Provider | Needs |
|----------|--------|
| **OpenCode** | `opencode` on `PATH`, already authenticated |
| **Codex CLI** | `codex` on `PATH`, already authenticated |
| **OpenRouter** | API key from [openrouter.ai/keys](https://openrouter.ai/keys) |
| **none** | Local typo fixes only |

---

## Platform notes

### macOS

- Works in Terminal.app, iTerm2, Ghostty, Warp, etc.
- If `python3` is missing: `xcode-select --install` or `brew install python`
- If the installer needs packages and Homebrew exists, it uses `brew install`

### Ubuntu / Debian / Pop!_OS / Mint

```bash
# Manual deps (only if you skip the installer)
sudo apt update
sudo apt install -y zsh python3 curl

# Install fixit
curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash

# Make zsh your login shell (recommended)
chsh -s $(which zsh)
```

Then open a new terminal session (or reboot once) so the login shell switches.

Other distros:

| Distro | Deps |
|--------|------|
| Fedora | `sudo dnf install zsh python3 curl` |
| Arch | `sudo pacman -S zsh python curl` |

The installer tries `apt`, then `dnf`, then `pacman` automatically.

---

## Installer CLI reference

```bash
./install.sh --help

./install.sh --provider openrouter --key sk-or-v1-...
./install.sh --provider opencode --model anthropic/claude-sonnet-4
./install.sh --provider codex
./install.sh --provider none
./install.sh --yes                  # less prompting
./install.sh --skip-deps            # do not apt/brew install
./install.sh --skip-ai-test         # skip smoke test
./install.sh --uninstall            # remove fixit from this machine
```

| Env var | Meaning |
|---------|---------|
| `FX_PROVIDER` | `openrouter` · `opencode` · `codex` · `none` |
| `FX_MODEL` | Model id (provider-specific) |
| `OPENROUTER_API_KEY` | Same as `--key` (OpenRouter only) |
| `FIXIT_HOME` | Install directory (default `~/.local/share/fixit`) |
| `FIXIT_RAW` | Override raw GitHub base URL |

**Uninstall**

```bash
# npx
npx github:arjunagi-a-rehman/dum-tum --uninstall

# curl
curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash -s -- --uninstall

# local clone
./install.sh --uninstall
```

Then reload: `source ~/.zshrc`

This removes `~/.local/share/fixit` and the managed `# >>> fixit.zsh >>>` block from `~/.zshrc`.

---

## Manual install (no installer)

```bash
git clone https://github.com/arjunagi-a-rehman/dum-tum.git
cd dum-tum
mkdir -p ~/.local/share/fixit
cp fixit.zsh ~/.local/share/fixit/fixit.zsh
```

Add to `~/.zshrc`:

```zsh
source "$HOME/.local/share/fixit/fixit.zsh"
export FX_PROVIDER="openrouter"   # or opencode | codex | none
export FX_MODEL="deepseek/deepseek-v4-flash"
export OPENROUTER_API_KEY="sk-or-v1-YOUR_KEY"   # openrouter only
```

```bash
source ~/.zshrc
```

---

## Usage

### Local typos (offline)

| Typed | Result |
|-------|--------|
| `sl` | runs `ls` |
| `gti status` | close match may auto-run if safe |
| `kil 1234` | **won’t** auto-run `kill` (dangerous list) |

### Natural language (AI provider required)

```text
list all files
show large files here
where is reno folder
create a python venv
```

```text
…resolving
→ ls -la
[Enter] run  [e] edit  [n] cancel
```

### Filename typos on safe commands

`cd`, `cat`, `ls`, `head`, `bat`, … — fuzzy-matches paths under `.` (depth 2).

### After any failure

```bash
grep foo /bad/path
fix
```

---

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `FX_PROVIDER` | `openrouter` | `openrouter` · `opencode` · `codex` · `none` |
| `FX_MODEL` | provider default | Model id (`deepseek/deepseek-v4-flash` if OpenRouter + unset) |
| `OPENROUTER_API_KEY` | empty | Required when `FX_PROVIDER=openrouter` |
| `FX_AI_ON_FAIL` | `1` | Ask AI to fix failed multi-command tools (`go`, `git`, `npm`, `docker`, …) |

```zsh
export FX_PROVIDER="opencode"
export FX_MODEL="anthropic/claude-sonnet-4"

# or OpenRouter:
export FX_PROVIDER="openrouter"
export OPENROUTER_API_KEY="sk-or-v1-..."
export FX_MODEL="deepseek/deepseek-v4-flash"
```

Models: [openrouter.ai/models](https://openrouter.ai/models) · `opencode models` · Codex `-m` ids

---

## How it works

```text
Enter pressed
    │
    ├─ English sentence?  (accept-line)  → AI → confirm
    │
    ├─ Unknown command?
    │     multi-word English             → AI
    │     close typo + safe              → auto-run
    │     close typo + dangerous         → confirm only
    │     else                           → AI
    │
    └─ Known command failed?
          typo’d file arg on safe cmd    → fix path + re-run
          multi-tool usage error
          (go to desktop, git psuh, …)   → AI → confirm
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Installer can’t find `zsh` on Ubuntu | `sudo apt install zsh` then re-run; `chsh -s $(which zsh)` |
| Commands do nothing in bash | You’re not in zsh — run `zsh` or change login shell |
| Old behavior after update | Re-run installer or `source ~/.zshrc` |
| `…resolving` then timeout | Network/VPN; check provider auth; try another `FX_MODEL` |
| `where is …` runs builtin `where` | Update to latest `fixit.zsh` (has accept-line hook) |
| `OPENROUTER_API_KEY` empty | Only needed for OpenRouter — set in fixit block or switch `FX_PROVIDER` |
| `opencode/codex not found` | Install CLI + ensure it’s on `PATH`, or use OpenRouter |
| Permission denied on install.sh | `chmod +x install.sh` or run via `bash install.sh` |

Test deps:

```bash
echo $SHELL
zsh --version
python3 --version
curl --version
echo $FX_PROVIDER $FX_MODEL
echo ${OPENROUTER_API_KEY:0:12}
command -v opencode; command -v codex
whence -w command_not_found_handler   # run inside zsh after source
```

---

## Privacy & safety

- **Local mode** never leaves your machine.
- **AI mode** sends a short prompt (OS/shell, cwd, ~15 filenames, sample aliases, typed text) to your chosen backend (OpenRouter API, or local OpenCode/Codex which use their own auth/providers).
- Don’t paste secrets into natural-language prompts.
- Destructive fuzzy matches are not auto-run; AI always needs Enter.
- Keep API keys out of git. If a key leaked, rotate it at [openrouter.ai/keys](https://openrouter.ai/keys).

---

## Repo layout

| Path | Role |
|------|------|
| `fixit.zsh` | Main shell script |
| `install.sh` | macOS + Ubuntu installer |
| `bin/fixit-zsh.js` | `npx` entrypoint |
| `package.json` | npm / npx metadata |
| `README.md` | This file |

---

## Publish to npm (optional)

So people can run `npx fixit-zsh` without the `github:` prefix:

```bash
cd dum-tum
npm login
npm publish --access public
```

Until then, prefer:

```bash
npx github:arjunagi-a-rehman/dum-tum
# or
curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash
```

---

## License

MIT — use and modify freely on your machines.
