# fixit.zsh

Turn **typos** and **plain English** into real shell commands — on **macOS** and **Ubuntu/Linux**.

| You type | What happens |
|----------|----------------|
| `sl` | Auto-runs `ls` |
| `list all files` | AI suggests `ls -la` → you confirm |
| `where is reno folder` | AI suggests `find` / `mdfind` → you confirm |
| `cat dcoument.txt` | Fixes the filename typo (safe commands only) |
| `fix` | AI-corrects the last failed command |

- **Stage 1** — local fuzzy matching (instant, offline)
- **Stage 2** — optional AI via [OpenRouter](https://openrouter.ai)  
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

With an API key — any of these work:

```bash
# as a parameter
curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash -s -- --key "sk-or-v1-YOUR_KEY"
npx github:arjunagi-a-rehman/dum-tum --key "sk-or-v1-YOUR_KEY"
npx github:arjunagi-a-rehman/dum-tum --key="sk-or-v1-YOUR_KEY"

# from the environment
OPENROUTER_API_KEY="sk-or-v1-YOUR_KEY" npx github:arjunagi-a-rehman/dum-tum
export OPENROUTER_API_KEY="sk-or-v1-YOUR_KEY"   # then just run the installer
```

Non-interactive (CI / skip prompts):

```bash
curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash -s -- --yes
```

The installer will:

1. Check / install **zsh**, **python3**, **curl** (apt on Ubuntu, brew on Mac if needed)
2. Copy `fixit.zsh` → `~/.local/share/fixit/fixit.zsh`
3. Add a managed block to `~/.zshrc` (safe to re-run; updates in place)
4. Optionally prompt for an OpenRouter API key

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
| **OpenRouter key** | Optional (AI features) | Optional (AI features) |

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

Get an API key (AI): [https://openrouter.ai/keys](https://openrouter.ai/keys)

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

./install.sh --key sk-or-v1-...     # set API key
./install.sh --yes                  # less prompting
./install.sh --skip-deps            # do not apt/brew install
```

| Env var | Meaning |
|---------|---------|
| `OPENROUTER_API_KEY` | Same as `--key` |
| `FIXIT_HOME` | Install directory (default `~/.local/share/fixit`) |
| `FIXIT_RAW` | Override raw GitHub base URL |

**Uninstall**

```bash
# remove managed block from ~/.zshrc (delete lines between the markers)
# >>> fixit.zsh >>>
# ...
# <<< fixit.zsh <<<

rm -rf ~/.local/share/fixit
source ~/.zshrc
```

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
export OPENROUTER_API_KEY="sk-or-v1-YOUR_KEY"
# optional:
# export FX_MODEL="deepseek/deepseek-v4-flash"
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

### Natural language (AI key required)

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
| `OPENROUTER_API_KEY` | empty | Enables AI |
| `FX_MODEL` | `deepseek/deepseek-v4-flash` | OpenRouter model id |

```zsh
export FX_MODEL="deepseek/deepseek-chat"
# export FX_MODEL="openai/gpt-4o-mini"
# export FX_MODEL="google/gemini-2.5-flash"
```

See models: [openrouter.ai/models](https://openrouter.ai/models)

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
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Installer can’t find `zsh` on Ubuntu | `sudo apt install zsh` then re-run; `chsh -s $(which zsh)` |
| Commands do nothing in bash | You’re not in zsh — run `zsh` or change login shell |
| Old behavior after update | Re-run installer or `source ~/.zshrc` |
| `…resolving` then timeout | Network/VPN; check key & OpenRouter credits; try another `FX_MODEL` |
| `where is …` runs builtin `where` | Update to latest `fixit.zsh` (has accept-line hook) |
| `OPENROUTER_API_KEY` empty | Add to `~/.zshrc` inside the fixit block; `source ~/.zshrc` |
| Permission denied on install.sh | `chmod +x install.sh` or run via `bash install.sh` |

Test deps:

```bash
echo $SHELL
zsh --version
python3 --version
curl --version
echo ${OPENROUTER_API_KEY:0:12}
whence -w command_not_found_handler   # run inside zsh after source
```

---

## Privacy & safety

- **Local mode** never leaves your machine.
- **AI mode** sends OpenRouter a short prompt: OS/shell, cwd, ~15 filenames, sample aliases, and the text you typed.
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
