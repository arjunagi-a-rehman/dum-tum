#!/usr/bin/env bash
# fixit.zsh installer — macOS + Ubuntu/Debian Linux
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash
#   npx github:arjunagi-a-rehman/dum-tum
#   ./install.sh
#   ./install.sh --key sk-or-v1-...
#   ./install.sh --provider opencode --model anthropic/claude-sonnet-4
#   ./install.sh --uninstall
set -euo pipefail

REPO_RAW="${FIXIT_RAW:-https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main}"
INSTALL_DIR="${FIXIT_HOME:-$HOME/.local/share/fixit}"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
BASHRC="$HOME/.bashrc"
MARKER_BEGIN="# >>> fixit.zsh >>>"
MARKER_END="# <<< fixit.zsh <<<"

SELF="${BASH_SOURCE[0]:-$0}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || true)"

# Values from CLI flags only (env is a non-interactive fallback — does not skip menus)
API_KEY=""
PROVIDER=""
MODEL=""
VARIANT=""
PROVIDER_FROM_CLI=0
MODEL_FROM_CLI=0
KEY_FROM_CLI=0
VARIANT_FROM_CLI=0
ASSUME_YES=0
SKIP_DEPS=0
SKIP_AI_TEST=0
DO_UNINSTALL=0

HAVE_OPENCODE=0
HAVE_CLAUDE=0
HAVE_CODEX=0
SHELL_CHOICE=""
DO_ZSH=0
DO_BASH=0

usage() {
  cat <<'EOF'
fixit.zsh installer (macOS + Ubuntu/Linux)

Usage:
  ./install.sh [options]
  ./install.sh --uninstall

Options:
  --provider NAME   openrouter | openai | anthropic | gemini | opencode | claude | codex | none
  --model ID        Model id for the chosen provider
  --variant LEVEL   Reasoning effort (codex/opencode/claude: low|medium|high|...)
  --key KEY         API key for key-based providers (openrouter/openai/anthropic/gemini)
  --shell NAME      zsh | bash | both (default: your login shell, else both)
  --yes, -y         Non-interactive where possible
  --skip-deps       Do not try to install zsh/python3/curl
  --skip-ai-test    Skip the post-setup AI smoke test
  --uninstall       Remove fixit from ~/.zshrc and ~/.bashrc
  --help, -h        Show this help

Env (used when --yes / non-interactive; interactive always prompts):
  OPENROUTER_API_KEY   Same as --key (provider=openrouter)
  OPENAI_API_KEY       Same as --key (provider=openai)
  ANTHROPIC_API_KEY    Same as --key (provider=anthropic)
  GEMINI_API_KEY       Same as --key (provider=gemini; GOOGLE_API_KEY also works)
  FX_PROVIDER          Same as --provider
  FX_MODEL             Same as --model
  FX_VARIANT           Same as --variant
  FIXIT_HOME           Install dir (default: ~/.local/share/fixit)
  FIXIT_RAW            Raw GitHub base URL override
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) API_KEY="${2:-}"; KEY_FROM_CLI=1; shift 2 ;;
    --key=*) API_KEY="${1#--key=}"; KEY_FROM_CLI=1; shift ;;
    --provider) PROVIDER="${2:-}"; PROVIDER_FROM_CLI=1; shift 2 ;;
    --provider=*) PROVIDER="${1#--provider=}"; PROVIDER_FROM_CLI=1; shift ;;
    --model) MODEL="${2:-}"; MODEL_FROM_CLI=1; shift 2 ;;
    --model=*) MODEL="${1#--model=}"; MODEL_FROM_CLI=1; shift ;;
    --variant) VARIANT="${2:-}"; VARIANT_FROM_CLI=1; shift 2 ;;
    --variant=*) VARIANT="${1#--variant=}"; VARIANT_FROM_CLI=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --skip-ai-test) SKIP_AI_TEST=1; shift ;;
    --shell) SHELL_CHOICE="${2:-}"; shift 2 ;;
    --shell=*) SHELL_CHOICE="${1#--shell=}"; shift ;;
    --uninstall|uninstall) DO_UNINSTALL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Env var that holds the API key for a given provider ("" for CLI/none providers)
key_var_for_provider() {
  case "${1:-}" in
    openrouter) echo OPENROUTER_API_KEY ;;
    openai)     echo OPENAI_API_KEY ;;
    anthropic)  echo ANTHROPIC_API_KEY ;;
    gemini)     echo GEMINI_API_KEY ;;
    *)          echo "" ;;
  esac
}

# Pick up an API key from the environment; records which var it came from
detect_key_env() {
  API_KEY=""
  KEY_ENV_VAR=""
  local kv
  for kv in OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY; do
    if [[ -n "${!kv:-}" ]]; then
      API_KEY="${!kv}"
      KEY_ENV_VAR="$kv"
      return 0
    fi
  done
}

# Env fills gaps only when not set by CLI
if [[ "$KEY_FROM_CLI" -eq 0 ]]; then
  detect_key_env
fi
if [[ "$PROVIDER_FROM_CLI" -eq 0 && -n "${FX_PROVIDER:-}" ]]; then
  PROVIDER="$FX_PROVIDER"
fi
if [[ "$MODEL_FROM_CLI" -eq 0 && -n "${FX_MODEL:-}" ]]; then
  MODEL="$FX_MODEL"
fi
if [[ "$VARIANT_FROM_CLI" -eq 0 && -n "${FX_VARIANT:-}" ]]; then
  VARIANT="$FX_VARIANT"
fi

info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
err()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
  Darwin) OS_NAME="macOS" ;;
  Linux)  OS_NAME="Linux" ;;
  *)      OS_NAME="$OS" ;;
esac

is_ubuntu() {
  [[ -f /etc/os-release ]] && grep -qiE 'ubuntu|debian|pop|linuxmint' /etc/os-release
}

have() { command -v "$1" >/dev/null 2>&1; }

read_tty() {
  # read a line from the real terminal (works when stdin is a curl pipe)
  local _var="$1" _val=""
  if [[ -r /dev/tty ]]; then
    IFS= read -r _val </dev/tty || true
  else
    IFS= read -r _val || true
  fi
  _val="${_val//$'\r'/}"
  printf -v "$_var" '%s' "$_val"
}

is_interactive() {
  [[ -t 0 || -r /dev/tty ]] && [[ "$ASSUME_YES" -eq 0 ]]
}

select_shells() {
  case "${SHELL_CHOICE:-auto}" in
    zsh)  DO_ZSH=1; DO_BASH=0 ;;
    bash) DO_ZSH=0; DO_BASH=1 ;;
    both|all) DO_ZSH=1; DO_BASH=1 ;;
    auto|"")
      local login_shell
      login_shell="$(basename "${SHELL:-}")"
      case "$login_shell" in
        zsh)  DO_ZSH=1; DO_BASH=0 ;;
        bash) DO_ZSH=0; DO_BASH=1 ;;
        *)    DO_ZSH=1; DO_BASH=1 ;;
      esac
      ;;
    *)
      err "Invalid --shell: $SHELL_CHOICE (use zsh|bash|both)"
      exit 1
      ;;
  esac
  # zsh selected but missing → fall back to bash
  if [[ "$DO_ZSH" -eq 1 ]] && ! have zsh; then
    warn "zsh not found — configuring bash only"
    DO_ZSH=0
    DO_BASH=1
  fi
  local targets=()
  [[ "$DO_ZSH" -eq 1 ]] && targets+=("zsh")
  [[ "$DO_BASH" -eq 1 ]] && targets+=("bash")
  ok "Shell targets: ${targets[*]}"
}

install_deps() {
  [[ "$SKIP_DEPS" -eq 1 ]] && return 0
  local need=()
  [[ "$DO_ZSH" -eq 1 ]] && { have zsh || need+=(zsh); }
  have python3 || need+=(python3)
  have curl    || need+=(curl)

  if [[ ${#need[@]} -eq 0 ]]; then
    ok "Dependencies present"
    return 0
  fi

  info "Missing: ${need[*]}"

  if [[ "$OS" == "Darwin" ]]; then
    if have brew; then
      info "Installing via Homebrew…"
      brew install "${need[@]}"
    else
      warn "Install Xcode CLT / Homebrew, then: brew install ${need[*]}"
      if [[ " ${need[*]} " == *" python3 "* ]] && ! have python3; then
        warn "Or run: xcode-select --install"
      fi
      if ! have zsh; then
        err "zsh is required on macOS (usually preinstalled)."
        exit 1
      fi
    fi
  elif is_ubuntu || [[ "$OS" == "Linux" ]]; then
    if have apt-get; then
      info "Installing via apt (may ask for sudo password)…"
      sudo apt-get update -y
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
    elif have dnf; then
      sudo dnf install -y "${need[@]}"
    elif have pacman; then
      sudo pacman -Sy --noconfirm "${need[@]}"
    else
      err "Install manually: ${need[*]}"
      exit 1
    fi
  else
    err "Unsupported OS for auto deps: $OS_NAME — install: ${need[*]}"
    exit 1
  fi

  { [[ "$DO_ZSH" -eq 0 ]] || have zsh; } && have python3 && have curl || {
    err "Still missing tools after install attempt."
    exit 1
  }
  ok "Dependencies installed"
}

install_script() {
  mkdir -p "$INSTALL_DIR"
  local f
  if [[ -n "$SELF_DIR" && -f "$SELF_DIR/src/fixit.zsh" && -f "$SELF_DIR/src/fixit-common.sh" ]]; then
    info "Using local scripts from $SELF_DIR/src"
    for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py; do
      [[ -f "$SELF_DIR/src/$f" ]] && cp "$SELF_DIR/src/$f" "$INSTALL_DIR/$f"
    done
  else
    info "Downloading scripts from GitHub…"
    for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py; do
      curl -fsSL "$REPO_RAW/src/$f" -o "$INSTALL_DIR/$f"
    done
  fi
  chmod 644 "$INSTALL_DIR"/fixit-common.sh "$INSTALL_DIR"/fixit.zsh "$INSTALL_DIR"/fixit.bash "$INSTALL_DIR"/fixit-ai.py
  ok "Installed → $INSTALL_DIR"
}

detect_ai_clis() {
  HAVE_OPENCODE=0
  HAVE_CLAUDE=0
  HAVE_CODEX=0
  have opencode && HAVE_OPENCODE=1
  have claude && HAVE_CLAUDE=1
  have codex && HAVE_CODEX=1
  if [[ "$HAVE_OPENCODE" -eq 1 ]]; then
    ok "Detected OpenCode CLI ($(command -v opencode))"
  fi
  if [[ "$HAVE_CLAUDE" -eq 1 ]]; then
    ok "Detected Claude Code CLI ($(command -v claude))"
  fi
  if [[ "$HAVE_CODEX" -eq 1 ]]; then
    ok "Detected Codex CLI ($(command -v codex))"
  fi
}

normalize_provider() {
  case "${1:-}" in
    openrouter|or) echo openrouter ;;
    openai|oa|gpt) echo openai ;;
    anthropic|claude-api|ac) echo anthropic ;;
    gemini|google|g) echo gemini ;;
    opencode|oc) echo opencode ;;
    claude|cc) echo claude ;;
    codex|cx) echo codex ;;
    none|off|local|skip) echo none ;;
    "") echo "" ;;
    *) echo "" ;;
  esac
}

# ---------- provider selection ----------
select_provider() {
  local p
  # Explicit CLI --provider always wins (interactive or not)
  if [[ "$PROVIDER_FROM_CLI" -eq 1 ]]; then
    p="$(normalize_provider "$PROVIDER")"
    if [[ -z "$p" ]]; then
      err "Invalid --provider: $PROVIDER"
      exit 1
    fi
    PROVIDER="$p"
    ok "Provider: $PROVIDER (from --provider)"
    return 0
  fi

  if ! is_interactive; then
    p="$(normalize_provider "$PROVIDER")"
    if [[ -n "$p" ]]; then
      PROVIDER="$p"
      ok "Provider: $PROVIDER"
      return 0
    fi
    if [[ -f "$ZSHRC" ]] && grep -qE '^\s*export FX_PROVIDER=' "$ZSHRC" 2>/dev/null; then
      local existing
      existing="$(grep -E '^\s*export FX_PROVIDER=' "$ZSHRC" | tail -1 | sed -E 's/.*FX_PROVIDER=//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"
      existing="$(normalize_provider "$existing")"
      if [[ -n "$existing" ]]; then
        PROVIDER="$existing"
        ok "Keeping existing FX_PROVIDER=$PROVIDER from $ZSHRC"
        return 0
      fi
    fi
    if [[ -n "$API_KEY" ]]; then
      case "${KEY_ENV_VAR:-OPENROUTER_API_KEY}" in
        OPENAI_API_KEY)                  PROVIDER="openai" ;;
        ANTHROPIC_API_KEY)               PROVIDER="anthropic" ;;
        GEMINI_API_KEY|GOOGLE_API_KEY)   PROVIDER="gemini" ;;
        *)                               PROVIDER="openrouter" ;;
      esac
    elif [[ "$HAVE_OPENCODE" -eq 1 ]]; then
      PROVIDER="opencode"
    elif [[ "$HAVE_CLAUDE" -eq 1 ]]; then
      PROVIDER="claude"
    elif [[ "$HAVE_CODEX" -eq 1 ]]; then
      PROVIDER="codex"
    else
      PROVIDER="none"
      warn "No AI provider selected (non-interactive) — local typo fixes only."
    fi
    ok "Provider: $PROVIDER"
    return 0
  fi

  # Interactive: always ask (env/zshrc only seed the default choice)
  local hint=""
  p="$(normalize_provider "$PROVIDER")"
  [[ -z "$p" && -f "$ZSHRC" ]] && p="$(normalize_provider "$(grep -E '^\s*export FX_PROVIDER=' "$ZSHRC" 2>/dev/null | tail -1 | sed -E 's/.*FX_PROVIDER=//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')")"
  [[ -n "$p" ]] && hint="$p"

  echo ""
  info "Choose AI backend for natural language / fix"
  local -a labels=() values=()
  local i=1 default=1
  if [[ "$HAVE_OPENCODE" -eq 1 ]]; then
    printf "  [%d] OpenCode  (uses your local opencode auth)\n" "$i"
    labels+=("OpenCode"); values+=("opencode")
    [[ "$hint" == "opencode" ]] && default=$i
    i=$((i+1))
  fi
  if [[ "$HAVE_CLAUDE" -eq 1 ]]; then
    printf "  [%d] Claude Code (uses your local claude auth)\n" "$i"
    labels+=("Claude Code"); values+=("claude")
    [[ "$hint" == "claude" ]] && default=$i
    i=$((i+1))
  fi
  if [[ "$HAVE_CODEX" -eq 1 ]]; then
    printf "  [%d] Codex CLI (uses your local codex auth)\n" "$i"
    labels+=("Codex CLI"); values+=("codex")
    [[ "$hint" == "codex" ]] && default=$i
    i=$((i+1))
  fi
  printf "  [%d] OpenRouter API key\n" "$i"
  labels+=("OpenRouter"); values+=("openrouter")
  [[ "$hint" == "openrouter" ]] && default=$i
  i=$((i+1))
  printf "  [%d] OpenAI API key\n" "$i"
  labels+=("OpenAI"); values+=("openai")
  [[ "$hint" == "openai" ]] && default=$i
  i=$((i+1))
  printf "  [%d] Anthropic (Claude) API key\n" "$i"
  labels+=("Anthropic"); values+=("anthropic")
  [[ "$hint" == "anthropic" ]] && default=$i
  i=$((i+1))
  printf "  [%d] Google Gemini API key\n" "$i"
  labels+=("Gemini"); values+=("gemini")
  [[ "$hint" == "gemini" ]] && default=$i
  i=$((i+1))
  printf "  [%d] Skip AI (local typos only)\n" "$i"
  labels+=("Skip"); values+=("none")
  [[ "$hint" == "none" ]] && default=$i

  if [[ "$HAVE_OPENCODE" -eq 0 && "$HAVE_CLAUDE" -eq 0 && "$HAVE_CODEX" -eq 0 ]]; then
    echo "  (tip: install opencode, claude, or codex CLI, then re-run to use them)"
  fi
  [[ -n "$hint" ]] && echo "  (current shell/env default: $hint)"

  local choice
  printf "Select [1-%d] (default %d): " "${#values[@]}" "$default"
  read_tty choice
  choice="${choice:-$default}"
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#values[@]} )); then
    PROVIDER="${values[$((choice-1))]}"
  else
    warn "Invalid choice — skipping AI."
    PROVIDER="none"
  fi
  ok "Provider: $PROVIDER"
}

# ---------- API key (openrouter/openai/anthropic/gemini) ----------
maybe_ask_key() {
  local key_var
  key_var="$(key_var_for_provider "$PROVIDER")"
  [[ -n "$key_var" ]] || return 0

  local label key_url
  case "$PROVIDER" in
    openrouter) label="OpenRouter";    key_url="https://openrouter.ai/keys" ;;
    openai)     label="OpenAI";        key_url="https://platform.openai.com/api-keys" ;;
    anthropic)  label="Anthropic";     key_url="https://console.anthropic.com/settings/keys" ;;
    gemini)     label="Google Gemini"; key_url="https://aistudio.google.com/apikey" ;;
  esac

  # Explicit --key wins
  if [[ "$KEY_FROM_CLI" -eq 1 && -n "$API_KEY" ]]; then
    ok "$label API key provided (from --key)"
    return 0
  fi

  if ! is_interactive; then
    if [[ -z "$API_KEY" ]] && grep -qE "^\s*export ${key_var}=.+" "$ZSHRC" 2>/dev/null; then
      API_KEY="$(grep -E "^\s*export ${key_var}=" "$ZSHRC" | tail -1 | sed -E "s/.*${key_var}=//; s/^\"//; s/\"$//; s/^'//; s/'$//")"
    fi
    if [[ -n "$API_KEY" ]]; then
      ok "$label API key provided"
      return 0
    fi
    warn "No $label key — AI will not work until you set $key_var."
    PROVIDER="none"
    return 0
  fi

  local hint=""
  [[ -n "$API_KEY" ]] && hint="(env key detected — Enter keeps it, or paste a new one)"
  if [[ -z "$hint" ]] && grep -qE "^\s*export ${key_var}=.+" "$ZSHRC" 2>/dev/null; then
    hint="(key already in zshrc — Enter keeps it, or paste a new one)"
    API_KEY="$(grep -E "^\s*export ${key_var}=" "$ZSHRC" | tail -1 | sed -E "s/.*${key_var}=//; s/^\"//; s/\"$//; s/^'//; s/'$//")"
  fi

  echo ""
  echo "$label API key enables natural language."
  echo "Get one at: $key_url"
  [[ -n "$hint" ]] && echo "  $hint"
  printf "Paste key now (Enter = keep/skip): "
  local typed=""
  read_tty typed
  if [[ -n "$typed" ]]; then
    API_KEY="$typed"
    ok "API key saved for config"
  elif [[ -n "$API_KEY" ]]; then
    ok "Keeping existing $label API key"
  else
    warn "No key — skipping AI."
    PROVIDER="none"
  fi
}

# ---------- model selection ----------
select_model() {
  [[ "$PROVIDER" == "none" ]] && { MODEL=""; return 0; }

  # Explicit CLI --model always wins
  if [[ "$MODEL_FROM_CLI" -eq 1 ]]; then
    ok "Model: ${MODEL:-"(provider default)"} (from --model)"
    return 0
  fi

  if ! is_interactive; then
    if [[ -z "$MODEL" ]]; then
      case "$PROVIDER" in
        openrouter) MODEL="deepseek/deepseek-v4-flash" ;;
        openai)     MODEL="gpt-4o-mini" ;;
        anthropic)  MODEL="claude-sonnet-4-5" ;;
        gemini)     MODEL="gemini-2.5-flash" ;;
        opencode|claude|codex) MODEL="" ;;
      esac
    fi
    [[ -n "$MODEL" ]] && ok "Model: $MODEL" || ok "Model: (provider default)"
    return 0
  fi

  # Interactive: always ask; pre-select env/previous model when listed
  local hint="$MODEL"
  MODEL=""

  echo ""
  info "Choose model for $PROVIDER"
  local -a models=()
  local i=1 choice custom default=1

  case "$PROVIDER" in
    openrouter)
      models=(
        "deepseek/deepseek-v4-flash"
        "openai/gpt-4o-mini"
        "google/gemini-2.5-flash"
        "anthropic/claude-sonnet-4"
      )
      ;;
    openai)
      models=(
        "gpt-4o-mini"
        "gpt-4o"
        "gpt-5-mini"
      )
      ;;
    anthropic)
      models=(
        "claude-sonnet-4-5"
        "claude-haiku-4-5"
        "claude-opus-4-1"
      )
      ;;
    gemini)
      models=(
        "gemini-2.5-flash"
        "gemini-2.5-flash-lite"
        "gemini-2.5-pro"
      )
      ;;
    opencode)
      # Full live list from the CLI (all providers configured in opencode)
      local listed
      listed="$(opencode models 2>/dev/null || true)"
      if [[ -n "$listed" ]]; then
        while IFS= read -r line; do
          line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
          [[ -z "$line" ]] && continue
          local tok
          tok="$(echo "$line" | awk '{print $1}')"
          [[ "$tok" == */* ]] && models+=("$tok")
        done <<<"$listed"
      fi
      if [[ ${#models[@]} -eq 0 ]]; then
        models=(
          "opencode/big-pickle"
          "opencode-go/deepseek-v4-flash"
          "anthropic/claude-sonnet-4"
          "openai/gpt-4o-mini"
        )
      fi
      ;;
    claude)
      # No model-list command in the CLI; offer common aliases + default
      models=("sonnet" "opus" "haiku")
      printf "  [1] (Claude Code default — recommended)\n"
      i=2
      for m in "${models[@]}"; do
        printf "  [%d] %s\n" "$i" "$m"
        [[ -n "$hint" && "$m" == "$hint" ]] && default=$i
        i=$((i+1))
      done
      printf "  [%d] Custom model id…\n" "$i"
      local max=$i
      [[ -n "$hint" ]] && echo "  (current shell/env default: $hint)"
      printf "Select [1-%d] (default %d): " "$max" "$default"
      read_tty choice
      choice="${choice:-$default}"
      if [[ "$choice" == "1" ]]; then
        MODEL=""
      elif [[ "$choice" == "$max" ]]; then
        printf "Model id or alias [%s]: " "${hint:-}"
        read_tty custom
        MODEL="${custom:-$hint}"
      elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 2 && choice < max )); then
        MODEL="${models[$((choice-2))]}"
      else
        MODEL=""
      fi
      [[ -n "$MODEL" ]] && ok "Model: $MODEL" || ok "Model: (Claude default)"
      return 0
      ;;
    codex)
      # Live catalog from the CLI (visibility=list only)
      local listed
      listed="$(codex debug models 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for m in d.get("models", []):
        s = m.get("slug") or ""
        if m.get("visibility") == "list" and s and not s.startswith("codex-"):
            print(s)
except Exception:
    pass
' 2>/dev/null || true)"
      if [[ -n "$listed" ]]; then
        while IFS= read -r slug; do
          [[ -n "$slug" ]] && models+=("$slug")
        done <<<"$listed"
      fi
      if [[ ${#models[@]} -eq 0 ]]; then
        models=("gpt-5.6-sol" "gpt-5.5" "gpt-5.4")
      fi
      # Codex CLI default comes first; selecting it leaves FX_MODEL unset
      printf "  [1] (Codex CLI default — recommended)\n"
      i=2
      for m in "${models[@]}"; do
        printf "  [%d] %s\n" "$i" "$m"
        [[ -n "$hint" && "$m" == "$hint" ]] && default=$i
        i=$((i+1))
      done
      printf "  [%d] Custom model id…\n" "$i"
      local max=$i
      [[ -n "$hint" ]] && echo "  (current shell/env default: $hint)"
      printf "Select [1-%d] (default %d): " "$max" "$default"
      read_tty choice
      choice="${choice:-$default}"
      if [[ "$choice" == "1" ]]; then
        MODEL=""
      elif [[ "$choice" == "$max" ]]; then
        printf "Model id (must be allowed for your Codex login) [%s]: " "${hint:-}"
        read_tty custom
        MODEL="${custom:-$hint}"
      elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 2 && choice < max )); then
        MODEL="${models[$((choice-2))]}"
      else
        MODEL=""
      fi
      [[ -n "$MODEL" ]] && ok "Model: $MODEL" || ok "Model: (Codex default)"
      return 0
      ;;
  esac

  for m in "${models[@]}"; do
    printf "  [%d] %s\n" "$i" "$m"
    [[ -n "$hint" && "$m" == "$hint" ]] && default=$i
    i=$((i+1))
  done
  printf "  [%d] Custom…\n" "$i"
  local max=$i
  [[ -n "$hint" ]] && echo "  (current shell/env default: $hint)"
  printf "Select [1-%d] (default %d): " "$max" "$default"
  read_tty choice
  choice="${choice:-$default}"
  if [[ "$choice" == "$max" ]]; then
    printf "Model id [%s]: " "${hint:-}"
    read_tty custom
    MODEL="${custom:-$hint}"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < max )); then
    MODEL="${models[$((choice-1))]}"
  else
    MODEL="${models[$((default-1))]:-${models[0]}}"
  fi
  ok "Model: $MODEL"
}

# ---------- reasoning effort (codex/opencode/claude) ----------
select_variant() {
  [[ "$PROVIDER" == "codex" || "$PROVIDER" == "opencode" || "$PROVIDER" == "claude" ]] || { VARIANT=""; return 0; }

  if [[ "$VARIANT_FROM_CLI" -eq 1 ]]; then
    ok "Reasoning: ${VARIANT:-"(model default)"} (from --variant)"
    return 0
  fi

  local -a levels=() def_level=""
  if [[ "$PROVIDER" == "codex" ]]; then
    local info_line
    info_line="$(codex debug models 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ms = [m for m in d.get("models", []) if m.get("visibility") == "list"]
pick = None
for m in ms:
    if m.get("slug") == want:
        pick = m
        break
if pick is None and ms:
    pick = ms[0]
if pick:
    lv = [x["effort"] for x in pick.get("supported_reasoning_levels", [])]
    print((pick.get("default_reasoning_level") or "") + "|" + ",".join(lv))
' "${MODEL:-}" 2>/dev/null || true)"
    def_level="${info_line%%|*}"
    if [[ "$info_line" == *"|"* ]]; then
      local csv="${info_line#*|}" lvl
      IFS=',' read -ra levels <<< "$csv"
      local -a clean=()
      for lvl in "${levels[@]}"; do
        [[ -n "$lvl" ]] && clean+=("$lvl")
      done
      levels=("${clean[@]}")
    fi
    [[ ${#levels[@]} -eq 0 ]] && levels=(low medium high)
  elif [[ "$PROVIDER" == "claude" ]]; then
    # claude --effort levels
    levels=(low medium high xhigh max)
  else
    # opencode --variant: provider-specific; low/medium/high are the common ones
    levels=(low medium high)
  fi

  if ! is_interactive; then
    [[ -n "$VARIANT" ]] && ok "Reasoning: $VARIANT" || ok "Reasoning: (model default)"
    return 0
  fi

  local hint="$VARIANT"
  echo ""
  info "Reasoning effort for ${MODEL:-$PROVIDER}"
  local i=1 choice default=1
  printf "  [1] (model default%s)\n" "${def_level:+: $def_level}"
  i=2
  local -a shown=()
  local l
  for l in "${levels[@]}"; do
    printf "  [%d] %s\n" "$i" "$l"
    shown+=("$l")
    [[ -n "$hint" && "$l" == "$hint" ]] && default=$i
    i=$((i+1))
  done
  local max=$((i-1))
  [[ -n "$hint" ]] && echo "  (current shell/env default: $hint)"
  printf "Select [1-%d] (default %d): " "$max" "$default"
  read_tty choice
  choice="${choice:-$default}"
  if [[ "$choice" == "1" ]]; then
    VARIANT=""
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 2 && choice <= max )); then
    VARIANT="${shown[$((choice-2))]}"
  else
    VARIANT=""
  fi
  [[ -n "$VARIANT" ]] && ok "Reasoning: $VARIANT" || ok "Reasoning: (model default)"
}

# ---------- smoke test ----------
test_ai() {
  [[ "$SKIP_AI_TEST" -eq 1 ]] && return 0
  [[ "$PROVIDER" == "none" ]] && return 0

  local key_var
  key_var="$(key_var_for_provider "$PROVIDER")"
  if [[ -n "$key_var" && -z "$API_KEY" ]]; then
    warn "Skipping AI test (no API key)"
    return 0
  fi
  if [[ "$PROVIDER" == "opencode" && "$HAVE_OPENCODE" -eq 0 ]]; then
    warn "Skipping AI test (opencode missing)"
    return 0
  fi
  if [[ "$PROVIDER" == "claude" && "$HAVE_CLAUDE" -eq 0 ]]; then
    warn "Skipping AI test (claude missing)"
    return 0
  fi
  if [[ "$PROVIDER" == "codex" && "$HAVE_CODEX" -eq 0 ]]; then
    warn "Skipping AI test (codex missing)"
    return 0
  fi

  info "Testing AI backend ($PROVIDER)…"
  local sug rc=0
  local test_shell="zsh" test_file="$INSTALL_DIR/fixit.zsh"
  if [[ "$DO_ZSH" -eq 0 ]]; then
    test_shell="bash"
    test_file="$INSTALL_DIR/fixit.bash"
  fi
  set +e
  # background + watchdog: CLI backends can queue for a long time
  local tmpout pid waited=0 limit=120
  tmpout="$(mktemp)"
  local -a envargs=()
  [[ -n "$key_var" ]] && envargs+=("${key_var}=${API_KEY}")
  (
    FX_PROVIDER="$PROVIDER" \
    FX_MODEL="$MODEL" \
    FX_VARIANT="$VARIANT" \
    FX_AI_TIMEOUT=100 \
    env "${envargs[@]}" \
    "$test_shell" -c '
      source "$1"
      _fx_ai "print only this exact shell command on one line: ls -la"
    ' "$test_shell" "$test_file" 2>/dev/null
  ) >"$tmpout" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rc=124
      break
    fi
    sleep 1
    waited=$((waited+1))
  done
  [[ "$rc" -eq 0 ]] && wait "$pid" 2>/dev/null
  sug="$(cat "$tmpout" 2>/dev/null)"
  rm -f "$tmpout"
  set -e

  sug="$(echo "$sug" | head -1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [[ -n "$sug" ]]; then
    ok "AI test OK → $sug"
    return 0
  fi

  warn "AI test returned no command (auth/network/model?)."
  if ! is_interactive; then
    warn "Continuing anyway (non-interactive)."
    return 0
  fi
  echo "  [1] Continue anyway"
  echo "  [2] Re-pick provider"
  echo "  [3] Skip AI"
  printf "Select [1-3] (default 1): "
  local c
  read_tty c
  c="${c:-1}"
  case "$c" in
    2)
      PROVIDER=""
      MODEL=""
      detect_key_env
      select_provider
      maybe_ask_key
      select_model
      select_variant
      test_ai
      ;;
    3)
      PROVIDER="none"
      MODEL=""
      API_KEY=""
      warn "AI disabled."
      ;;
    *)
      warn "Keeping provider config despite failed test."
      ;;
  esac
}

# write_rc_block <rc-file> <adapter-file>
write_rc_block() {
  local rc_file="$1" adapter="$2"
  local key_line model_line provider_line variant_line
  provider_line="export FX_PROVIDER=\"${PROVIDER:-none}\""

  if [[ -n "$MODEL" ]]; then
    local mesc="${MODEL//\\/\\\\}"
    mesc="${mesc//\"/\\\"}"
    model_line="export FX_MODEL=\"$mesc\""
  else
    model_line='# export FX_MODEL="..."   # optional; omit to use provider default'
  fi

  if [[ -n "$VARIANT" ]]; then
    local vesc="${VARIANT//\\/\\\\}"
    vesc="${vesc//\"/\\\"}"
    variant_line="export FX_VARIANT=\"$vesc\""
  else
    variant_line='# export FX_VARIANT="medium"   # reasoning effort (codex/opencode/claude)'
  fi

  local key_var key_placeholder=""
  key_var="$(key_var_for_provider "$PROVIDER")"
  case "$PROVIDER" in
    openrouter) key_placeholder="sk-or-v1-..." ;;
    openai)     key_placeholder="sk-..." ;;
    anthropic)  key_placeholder="sk-ant-..." ;;
    gemini)     key_placeholder="AIza..." ;;
  esac
  if [[ -n "$key_var" && -n "$API_KEY" ]]; then
    local esc="${API_KEY//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    key_line="export ${key_var}=\"$esc\""
  elif [[ -n "$key_var" ]]; then
    key_line="# export ${key_var}=\"${key_placeholder}\"   # uncomment and add your key"
  else
    key_line='# no API key required for this provider'
  fi

  local block
  block=$(cat <<EOF
$MARKER_BEGIN
# https://github.com/arjunagi-a-rehman/dum-tum
source "$INSTALL_DIR/$adapter"
$provider_line
$model_line
$variant_line
$key_line
$MARKER_END
EOF
)

  touch "$rc_file"

  if grep -qF "$MARKER_BEGIN" "$rc_file" 2>/dev/null; then
    info "Updating existing fixit block in $rc_file"
    local tmp repl_file
    tmp="$(mktemp)"
    repl_file="$(mktemp)"
    printf '%s\n' "$block" > "$repl_file"
    # Replace the marker block; insert replacement via file (no multiline -v)
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v rf="$repl_file" '
      $0 == begin { while ((getline line < rf) > 0) print line; skip=1; next }
      $0 == end   { skip=0; next }
      !skip       { print }
    ' "$rc_file" > "$tmp"
    rm -f "$repl_file"
    if ! grep -qF "$MARKER_BEGIN" "$tmp"; then
      printf '\n%s\n' "$block" >> "$tmp"
    fi
    mv "$tmp" "$rc_file"
  else
    info "Appending fixit block to $rc_file"
    printf '\n%s\n' "$block" >> "$rc_file"
  fi

  # The block can contain an API key — never leave the file
  # group/world-readable (stock ~/.bashrc from /etc/skel is 0644).
  if [[ "$(stat -f '%Lp' "$rc_file" 2>/dev/null || stat -c '%a' "$rc_file" 2>/dev/null)" != "600" ]]; then
    warn "$rc_file was readable by other users — tightening to 600 (key inside)"
    chmod 600 "$rc_file"
  fi
  ok "Configured $rc_file"
}

write_rc_blocks() {
  [[ "$DO_ZSH" -eq 1 ]]  && write_rc_block "$ZSHRC" "fixit.zsh"
  [[ "$DO_BASH" -eq 1 ]] && write_rc_block "$BASHRC" "fixit.bash"
  return 0
}

ensure_shell_default() {
  local shell_now
  shell_now="$(basename "${SHELL:-}")"

  if [[ "$DO_ZSH" -eq 1 ]]; then
    if [[ "$shell_now" == "zsh" ]]; then
      ok "Default shell is already zsh"
    else
      local zsh_path
      zsh_path="$(command -v zsh)"
      warn "Your login shell is '$shell_now', not zsh."
      echo "  Start zsh now:  zsh"
      echo "  Make default:   chsh -s \"$zsh_path\""
      if is_ubuntu || [[ "$OS" == "Linux" ]]; then
        if ! grep -q "^$zsh_path\$" /etc/shells 2>/dev/null; then
          echo "  (If chsh complains, run: echo \"$zsh_path\" | sudo tee -a /etc/shells)"
        fi
      fi
    fi
  fi

  if [[ "$DO_BASH" -eq 1 && "$shell_now" != "bash" ]]; then
    warn "fixit for bash is configured in $BASHRC — it loads when you run bash."
  fi
}

print_next_steps() {
  local ai_hint
  case "${PROVIDER:-none}" in
    openrouter) ai_hint="OpenRouter ($MODEL)" ;;
    openai)     ai_hint="OpenAI ($MODEL)" ;;
    anthropic)  ai_hint="Anthropic ($MODEL)" ;;
    gemini)     ai_hint="Gemini ($MODEL)" ;;
    opencode)   ai_hint="OpenCode${MODEL:+ ($MODEL)}" ;;
    claude)     ai_hint="Claude Code${MODEL:+ ($MODEL)}" ;;
    codex)      ai_hint="Codex${MODEL:+ ($MODEL)}" ;;
    *)          ai_hint="off (local typos only)" ;;
  esac

  local cfg_lines=""
  [[ "$DO_ZSH" -eq 1 ]]  && cfg_lines="$cfg_lines
│  zshrc:    $ZSHRC"
  [[ "$DO_BASH" -eq 1 ]] && cfg_lines="$cfg_lines
│  bashrc:   $BASHRC"

  cat <<EOF

┌─────────────────────────────────────────────────────────┐
│  fixit installed on $OS_NAME
│  Scripts:  $INSTALL_DIR$cfg_lines
│  AI:       $ai_hint
└─────────────────────────────────────────────────────────┘

Reload your shell:

EOF
  [[ "$DO_ZSH" -eq 1 ]]  && echo "  source $ZSHRC"
  [[ "$DO_BASH" -eq 1 ]] && echo "  source $BASHRC"
  cat <<EOF

  # or open a new terminal tab

Try:

  sl                  # local typo → ls
  list all files      # AI → confirm with Enter

Change provider later:

  export FX_PROVIDER="opencode"   # or claude | codex | openrouter | openai | anthropic | gemini | none
  export FX_MODEL="..."
  # key-based providers only:
  export OPENROUTER_API_KEY="sk-or-v1-..."   # or OPENAI_API_KEY / ANTHROPIC_API_KEY / GEMINI_API_KEY

Docs: https://github.com/arjunagi-a-rehman/dum-tum

EOF
}

# leave cleanup block in one rc file so sourcing clears leftover env
uninstall_rc() {
  local rc_file="$1" cleanup="$2"
  touch "$rc_file"
  local tmp repl_file
  tmp="$(mktemp)"
  repl_file="$(mktemp)"
  printf '%s\n' "$cleanup" > "$repl_file"
  if grep -qF "$MARKER_BEGIN" "$rc_file" 2>/dev/null; then
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v rf="$repl_file" '
      $0 == begin { while ((getline line < rf) > 0) print line; skip=1; next }
      $0 == end   { skip=0; next }
      !skip       { print }
    ' "$rc_file" > "$tmp"
    if ! grep -qF "$MARKER_BEGIN" "$tmp"; then
      printf '\n%s\n' "$cleanup" >> "$tmp"
    fi
    mv "$tmp" "$rc_file"
    ok "Updated $rc_file (removed config; clears FX_* on source)"
  else
    printf '\n%s\n' "$cleanup" >> "$rc_file"
    ok "Added cleanup block to $rc_file (clears FX_* on source)"
  fi
  rm -f "$repl_file"
}

uninstall_fixit() {
  info "Uninstalling fixit…"
  local removed=0

  # Leave a tiny marker block that unsets exports so `source ~/.zshrc`
  # clears leftovers in the *current* shell (child process can't unset parent env).
  # Re-install replaces this block with the real config.
  local cleanup
  cleanup=$(cat <<EOF
$MARKER_BEGIN
# fixit uninstalled — clear leftover exports when you source this file
unset FX_PROVIDER FX_MODEL FX_VARIANT OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY 2>/dev/null || true
$MARKER_END
EOF
)

  uninstall_rc "$ZSHRC" "$cleanup"
  [[ -f "$BASHRC" ]] && uninstall_rc "$BASHRC" "$cleanup"
  removed=1

  if [[ -e "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    ok "Removed $INSTALL_DIR"
    removed=1
  else
    warn "Install dir not found: $INSTALL_DIR"
  fi

  if [[ "$removed" -eq 0 ]]; then
    warn "Nothing to uninstall."
  else
    ok "fixit uninstalled"
    echo ""
    echo "Finish cleanup in this shell:"
    echo "  source $ZSHRC      # zsh"
    echo "  source $BASHRC     # bash"
    echo ""
    echo "That unsets FX_PROVIDER, FX_MODEL, FX_VARIANT, the API key vars and drops the hooks."
  fi
}

main() {
  if [[ "$DO_UNINSTALL" -eq 1 ]]; then
    uninstall_fixit
    return 0
  fi

  info "Installing fixit for ${OS_NAME}…"
  select_shells
  install_deps
  install_script
  detect_ai_clis
  select_provider
  maybe_ask_key
  select_model
  select_variant
  test_ai
  write_rc_blocks
  ensure_shell_default
  print_next_steps
}

main
