# fixit.zsh

A **zsh** helper for macOS that turns typos and plain English into real shell commands.

| You type | What happens |
|----------|----------------|
| `sl` | Auto-runs `ls` |
| `list all files` | AI suggests `ls -la` → you confirm |
| `where is reno folder` | AI suggests a `find`/`mdfind` command → you confirm |
| `cat dcoument.txt` | Fixes the filename typo and re-runs (safe commands only) |
| `fix` | Sends the last failed command to AI for a correction |

Stage 1 is local and instant (fuzzy matching).  
Stage 2 is optional AI via [OpenRouter](https://openrouter.ai) — suggestions are **never auto-run**; you press Enter to run, `e` to edit, or `n` to cancel.

---

## Requirements (Mac)

- **macOS** with the default shell set to **zsh** (Catalina and later — default)
- **python3** (preinstalled on modern macOS as `/usr/bin/python3`, or via Homebrew)
- **curl** (preinstalled)
- An interactive terminal (Terminal.app, iTerm2, Ghostty, Warp, etc.)
- Optional but recommended: an [OpenRouter](https://openrouter.ai) API key for natural-language / hard fixes

Check you have the tools:

```bash
echo $SHELL          # should end with /zsh
python3 --version
curl --version
zsh --version
```

If `python3` is missing:

```bash
xcode-select --install
# or
brew install python
```

---

## Quick setup (5 minutes)

### 1. Get the script

**Option A — clone this repo**

```bash
git clone https://github.com/arjunagi-a-rehman/dum-tum.git
cd dum-tum
```

**Option B — copy just the script**

```bash
mkdir -p ~/bin
# copy "Terminal Commands and Aliases Fixit.zsh" to:
cp "Terminal Commands and Aliases Fixit.zsh" ~/bin/fixit.zsh
```

Using a short path like `~/bin/fixit.zsh` is easier than a long Desktop path.

### 2. Get an OpenRouter API key (for AI features)

1. Sign up at [https://openrouter.ai](https://openrouter.ai)
2. Open [https://openrouter.ai/keys](https://openrouter.ai/keys)
3. Create a key — it looks like `sk-or-v1-...`
4. Add a little credit if the free tier is empty (AI calls are cheap for this use case)

Without a key, **local typo fixes still work**; only natural-language / AI fallback needs the key.

### 3. Wire it into `~/.zshrc`

Open your zsh config:

```bash
nano ~/.zshrc
# or: code ~/.zshrc   /   open -e ~/.zshrc
```

Add these lines at the **bottom** (adjust the `source` path to where the file actually lives):

```zsh
# ----- fixit.zsh -----
# Typo auto-fixer + optional AI command resolver
source "$HOME/bin/fixit.zsh"
# If you kept the repo path instead:
# source "$HOME/Desktop/rehmanPersonal/dum-tum/Terminal Commands and Aliases Fixit.zsh"

export OPENROUTER_API_KEY="sk-or-v1-YOUR_KEY_HERE"

# Optional: pick another OpenRouter model
# export FX_MODEL="deepseek/deepseek-v4-flash"
```

Save and exit (`nano`: `Ctrl+O`, Enter, `Ctrl+X`).

> **Security:** Do not commit your API key to git. Prefer keeping it only in `~/.zshrc` (or a private file you `source`, e.g. `~/.zshrc.local` with `chmod 600`).

### 4. Reload the shell

```bash
source ~/.zshrc
```

Or open a **new** terminal tab/window.

### 5. Verify

```bash
# Functions loaded?
whence -w command_not_found_handler _fx_ai_resolve fix

# Key visible to this shell? (only first chars)
echo ${OPENROUTER_API_KEY:0:12}…

# Local typo fix (no AI)
sl
# expect: ↻ sl → ls   and a directory listing

# Natural language (needs API key)
list all files
# expect:
#   …resolving
#   → ls -la
#   [Enter] run  [e] edit  [n] cancel
```

Press **Enter** to run the suggestion.

---

## Recommended install layout

```text
~/bin/fixit.zsh          ← the script (stable path)
~/.zshrc                 ← source + OPENROUTER_API_KEY
```

Example one-shot from this repo:

```bash
mkdir -p ~/bin
cp "/path/to/dum-tum/Terminal Commands and Aliases Fixit.zsh" ~/bin/fixit.zsh

cat >> ~/.zshrc << 'EOF'

# fixit.zsh — typo auto-fixer + AI command resolver
source "$HOME/bin/fixit.zsh"
export OPENROUTER_API_KEY="sk-or-v1-YOUR_KEY_HERE"
EOF

source ~/.zshrc
```

To update later after `git pull` in the repo:

```bash
cp "/path/to/dum-tum/Terminal Commands and Aliases Fixit.zsh" ~/bin/fixit.zsh
source ~/.zshrc
```

Or `source` the file **directly from the cloned repo** so `git pull` updates you automatically (no copy step).

---

## How to use it

### A. Obvious typos (local, auto-run)

| Typed | Result |
|-------|--------|
| `sl` | runs `ls` |
| `gti status` | may run `git status` if match is close and safe |
| `kil 1234` | does **not** auto-run `kill` — dangerous commands only suggest |

Dangerous commands (`rm`, `dd`, `kill`, `sudo`, `chmod`, …) are never auto-executed from a fuzzy match.

### B. Natural language (AI)

Type a short English sentence and press Enter:

```text
list all files
show me large files in this folder
where is reno folder
create a python venv here
```

Flow:

```text
…resolving
→ <suggested command>
[Enter] run  [e] edit  [n] cancel
```

| Key | Action |
|-----|--------|
| **Enter** | Run the suggestion |
| **e** | Type an edited command, then Enter |
| **n** | Cancel |

### C. Wrong filename on a safe command

For read-ish commands (`cd`, `cat`, `ls`, `head`, `bat`, …), a typo’d path can be fuzzy-matched under the current directory (depth 2) and re-run:

```text
cat readme.md     # if file is README.md
```

### D. `fix` after any failure

```bash
grep foo /no/such/file
fix
```

`fix` sends the last failed command line to the AI and offers a corrected version with the same Enter / e / n prompt.

---

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `OPENROUTER_API_KEY` | _(empty)_ | Required for AI path |
| `FX_MODEL` | `deepseek/deepseek-v4-flash` | OpenRouter model id |

Change model (examples — check [openrouter.ai/models](https://openrouter.ai/models) for current ids):

```zsh
export FX_MODEL="deepseek/deepseek-chat"
# export FX_MODEL="openai/gpt-4o-mini"
# export FX_MODEL="google/gemini-2.5-flash"
```

Put that in `~/.zshrc` under the `source` line, then `source ~/.zshrc`.

---

## How it works (short)

```text
You press Enter
        │
        ▼
┌───────────────────────────┐
│ English sentence?         │  e.g. "where is reno folder"
│ (accept-line hook)        │  → AI → confirm
└───────────┬───────────────┘
            │ no
            ▼
┌───────────────────────────┐
│ Unknown command?          │  command_not_found_handler
│  • multi-word English     │  → AI
│  • close typo, safe       │  → auto-run
│  • close typo, dangerous  │  → confirm only
│  • else                   │  → AI
└───────────┬───────────────┘
            │
            ▼
┌───────────────────────────┐
│ Known command failed?     │  precmd + safe list
│ typo’d file argument      │  → fix path + re-run
└───────────────────────────┘
```

AI never executes by itself. Local auto-run only happens for high-confidence, non-destructive matches.

---

## Troubleshooting

### `source ~/.zshrc` prints errors about other tools

Unrelated lines in `~/.zshrc` can break (e.g. two commands glued on one line). Open the file and fix the reported line number. fixit only needs its own `source` + `export` lines to be valid.

### Still seeing old behavior after an update

The shell loads the script once at startup:

```bash
source ~/.zshrc
# or open a new tab
```

If you `source` a **copy** in `~/bin/fixit.zsh`, re-copy from the repo after pulls.

### `…resolving` then timeout / no answer

- Check network / VPN
- Confirm key: `echo $OPENROUTER_API_KEY`
- Confirm credit/usage on OpenRouter
- Try another model: `export FX_MODEL="deepseek/deepseek-chat"`
- Curl manually:

```bash
curl -sS https://openrouter.ai/api/v1/models \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" | head
```

### `where is reno folder` runs the `where` builtin

You need a current script with the **accept-line** English interceptor. Update the file and `source ~/.zshrc`.

### Suggestion appears but nothing is runnable

Current versions use:

```text
[Enter] run  [e] edit  [n] cancel
```

If you still see “pre-typed on the next prompt”, you’re on an old build — update and reload.

### AI not used; only local fuzzy matches

`OPENROUTER_API_KEY` is missing in that session:

```bash
echo $OPENROUTER_API_KEY
# empty → add export to ~/.zshrc and source again
```

### Default shell is not zsh

```bash
cat /etc/shells
chsh -s /bin/zsh
```

Log out and back in (or restart the terminal).

### Conflict with another `command_not_found_handler`

fixit defines `command_not_found_handler`. Load fixit **last** in `~/.zshrc` so it wins, or remove the other handler.

---

## Uninstall

1. Remove the fixit block from `~/.zshrc` (`source …fixit…` and `OPENROUTER_API_KEY`).
2. Optional: delete the script file / repo.
3. `source ~/.zshrc` or open a new terminal.

Revoke the OpenRouter key at [openrouter.ai/keys](https://openrouter.ai/keys) if you no longer need it.

---

## Privacy & safety

- **Local mode** never leaves your machine.
- **AI mode** sends to OpenRouter: a short system prompt, OS/shell, cwd, up to ~15 filenames in the current directory, a sample of your aliases, and the text you typed.
- Do not type secrets into natural-language prompts.
- Destructive fuzzy matches are blocked from auto-run; AI suggestions still require explicit Enter.
- Keep `OPENROUTER_API_KEY` out of git and public gists. If a key was ever pasted into chat or a ticket, **rotate it**.

---

## File map

| File | Role |
|------|------|
| `Terminal Commands and Aliases Fixit.zsh` | Main script (source this from `~/.zshrc`) |
| `README.md` | This setup guide |

---

## License / status

Personal utility script — use and modify freely on your own machines.
