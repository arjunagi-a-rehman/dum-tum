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
INSTALL_PATH="$INSTALL_DIR/fixit.zsh"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
MARKER_BEGIN="# >>> fixit.zsh >>>"
MARKER_END="# <<< fixit.zsh <<<"

SELF="${BASH_SOURCE[0]:-$0}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || true)"

API_KEY="${OPENROUTER_API_KEY:-}"
PROVIDER="${FX_PROVIDER:-}"
MODEL="${FX_MODEL:-}"
ASSUME_YES=0
SKIP_DEPS=0
SKIP_AI_TEST=0
DO_UNINSTALL=0

HAVE_OPENCODE=0
HAVE_CODEX=0

usage() {
  cat <<'EOF'
fixit.zsh installer (macOS + Ubuntu/Linux)

Usage:
  ./install.sh [options]
  ./install.sh --uninstall

Options:
  --provider NAME   openrouter | opencode | codex | none
  --model ID        Model id for the chosen provider
  --key KEY         OpenRouter API key (provider=openrouter)
  --yes, -y         Non-interactive where possible
  --skip-deps       Do not try to install zsh/python3/curl
  --skip-ai-test    Skip the post-setup AI smoke test
  --uninstall       Remove fixit.zsh and its ~/.zshrc block
  --help, -h        Show this help

Env:
  OPENROUTER_API_KEY   Same as --key
  FX_PROVIDER          Same as --provider
  FX_MODEL             Same as --model
  FIXIT_HOME           Install dir (default: ~/.local/share/fixit)
  FIXIT_RAW            Raw GitHub base URL override
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) API_KEY="${2:-}"; shift 2 ;;
    --key=*) API_KEY="${1#--key=}"; shift ;;
    --provider) PROVIDER="${2:-}"; shift 2 ;;
    --provider=*) PROVIDER="${1#--provider=}"; shift ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --model=*) MODEL="${1#--model=}"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --skip-ai-test) SKIP_AI_TEST=1; shift ;;
    --uninstall|uninstall) DO_UNINSTALL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

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

install_deps() {
  [[ "$SKIP_DEPS" -eq 1 ]] && return 0
  local need=()
  have zsh     || need+=(zsh)
  have python3 || need+=(python3)
  have curl    || need+=(curl)

  if [[ ${#need[@]} -eq 0 ]]; then
    ok "Dependencies present (zsh, python3, curl)"
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

  have zsh && have python3 && have curl || {
    err "Still missing tools after install attempt."
    exit 1
  }
  ok "Dependencies installed"
}

install_script() {
  mkdir -p "$INSTALL_DIR"
  local src=""
  if [[ -n "$SELF_DIR" && -f "$SELF_DIR/fixit.zsh" ]]; then
    src="$SELF_DIR/fixit.zsh"
    info "Using local fixit.zsh from $SELF_DIR"
    cp "$src" "$INSTALL_PATH"
  else
    info "Downloading fixit.zsh from GitHub…"
    curl -fsSL "$REPO_RAW/fixit.zsh" -o "$INSTALL_PATH"
  fi
  chmod 644 "$INSTALL_PATH"
  ok "Installed → $INSTALL_PATH"
}

detect_ai_clis() {
  HAVE_OPENCODE=0
  HAVE_CODEX=0
  have opencode && HAVE_OPENCODE=1
  have codex && HAVE_CODEX=1
  if [[ "$HAVE_OPENCODE" -eq 1 ]]; then
    ok "Detected OpenCode CLI ($(command -v opencode))"
  fi
  if [[ "$HAVE_CODEX" -eq 1 ]]; then
    ok "Detected Codex CLI ($(command -v codex))"
  fi
}

normalize_provider() {
  case "${1:-}" in
    openrouter|or) echo openrouter ;;
    opencode|oc) echo opencode ;;
    codex|cx) echo codex ;;
    none|off|local|skip) echo none ;;
    "") echo "" ;;
    *) echo "" ;;
  esac
}

# ---------- provider selection ----------
select_provider() {
  local p
  p="$(normalize_provider "$PROVIDER")"
  if [[ -n "$p" ]]; then
    PROVIDER="$p"
    ok "Provider: $PROVIDER"
    return 0
  fi

  # already configured in zshrc?
  if [[ -f "$ZSHRC" ]] && grep -qE '^\s*export FX_PROVIDER=' "$ZSHRC" 2>/dev/null; then
    local existing
    existing="$(grep -E '^\s*export FX_PROVIDER=' "$ZSHRC" | tail -1 | sed -E 's/.*FX_PROVIDER=//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"
    existing="$(normalize_provider "$existing")"
    if [[ -n "$existing" ]] && ! is_interactive; then
      PROVIDER="$existing"
      ok "Keeping existing FX_PROVIDER=$PROVIDER from $ZSHRC"
      return 0
    fi
  fi

  if ! is_interactive; then
    if [[ -n "$API_KEY" ]]; then
      PROVIDER="openrouter"
    elif [[ "$HAVE_OPENCODE" -eq 1 ]]; then
      PROVIDER="opencode"
    elif [[ "$HAVE_CODEX" -eq 1 ]]; then
      PROVIDER="codex"
    else
      PROVIDER="none"
      warn "No AI provider selected (non-interactive) — local typo fixes only."
    fi
    ok "Provider: $PROVIDER"
    return 0
  fi

  echo ""
  info "Choose AI backend for natural language / fix"
  local -a labels=() values=()
  local i=1
  if [[ "$HAVE_OPENCODE" -eq 1 ]]; then
    printf "  [%d] OpenCode  (uses your local opencode auth)\n" "$i"
    labels+=("OpenCode"); values+=("opencode"); i=$((i+1))
  fi
  if [[ "$HAVE_CODEX" -eq 1 ]]; then
    printf "  [%d] Codex CLI (uses your local codex auth)\n" "$i"
    labels+=("Codex CLI"); values+=("codex"); i=$((i+1))
  fi
  printf "  [%d] OpenRouter API key\n" "$i"
  labels+=("OpenRouter"); values+=("openrouter"); i=$((i+1))
  printf "  [%d] Skip AI (local typos only)\n" "$i"
  labels+=("Skip"); values+=("none")

  if [[ "$HAVE_OPENCODE" -eq 0 && "$HAVE_CODEX" -eq 0 ]]; then
    echo "  (tip: install opencode or codex CLI, then re-run to use them)"
  fi

  local choice default=1
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

# ---------- OpenRouter key ----------
maybe_ask_key() {
  [[ "$PROVIDER" == "openrouter" ]] || return 0

  if [[ -n "$API_KEY" ]]; then
    ok "OpenRouter API key provided"
    return 0
  fi
  if grep -qE '^\s*export OPENROUTER_API_KEY=.+' "$ZSHRC" 2>/dev/null; then
    # pull existing key so test/write can use it
    API_KEY="$(grep -E '^\s*export OPENROUTER_API_KEY=' "$ZSHRC" | tail -1 | sed -E 's/.*OPENROUTER_API_KEY=//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"
    if [[ -n "$API_KEY" ]]; then
      ok "OPENROUTER_API_KEY already set in $ZSHRC"
      return 0
    fi
  fi
  if ! is_interactive; then
    warn "No OpenRouter key — AI will not work until you set OPENROUTER_API_KEY."
    PROVIDER="none"
    return 0
  fi
  echo ""
  echo "OpenRouter API key enables natural language."
  echo "Get one at: https://openrouter.ai/keys"
  printf "Paste key now (or press Enter to skip AI): "
  read_tty API_KEY
  if [[ -z "$API_KEY" ]]; then
    warn "No key — skipping AI."
    PROVIDER="none"
  else
    ok "API key saved for config"
  fi
}

# ---------- model selection ----------
select_model() {
  [[ "$PROVIDER" == "none" ]] && { MODEL=""; return 0; }

  if [[ -n "$MODEL" ]]; then
    ok "Model: $MODEL"
    return 0
  fi

  if ! is_interactive; then
    case "$PROVIDER" in
      openrouter) MODEL="deepseek/deepseek-v4-flash" ;;
      opencode|codex) MODEL="" ;;  # CLI default
    esac
    [[ -n "$MODEL" ]] && ok "Model: $MODEL" || ok "Model: (provider default)"
    return 0
  fi

  echo ""
  info "Choose model for $PROVIDER"
  local -a models=()
  local i=1 choice custom

  case "$PROVIDER" in
    openrouter)
      models=(
        "deepseek/deepseek-v4-flash"
        "openai/gpt-4o-mini"
        "google/gemini-2.5-flash"
        "anthropic/claude-sonnet-4"
      )
      ;;
    opencode)
      # try live list; fall back to common ids
      local listed
      listed="$(opencode models 2>/dev/null | head -20 || true)"
      if [[ -n "$listed" ]]; then
        while IFS= read -r line; do
          line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
          [[ -z "$line" || "$line" == *"model"* && "$line" == *"provider"* ]] && continue
          # take first token that looks like provider/model
          local tok
          tok="$(echo "$line" | awk '{print $1}')"
          [[ "$tok" == */* ]] && models+=("$tok")
          (( ${#models[@]} >= 8 )) && break
        done <<<"$listed"
      fi
      if [[ ${#models[@]} -eq 0 ]]; then
        models=(
          "opencode/grok-code"
          "anthropic/claude-sonnet-4"
          "openai/gpt-4o-mini"
          "google/gemini-2.5-flash"
        )
      fi
      ;;
    codex)
      # ChatGPT-auth Codex rejects many API model ids (e.g. o4-mini).
      # Prefer CLI default; custom only if the user knows a valid id.
      printf "  [1] (Codex default — recommended)\n"
      printf "  [2] Custom model id…\n"
      printf "Select [1-2] (default 1): "
      read_tty choice
      choice="${choice:-1}"
      case "$choice" in
        2)
          printf "Model id (must be allowed for your Codex login): "
          read_tty custom
          MODEL="$custom"
          ;;
        *) MODEL="" ;;
      esac
      [[ -n "$MODEL" ]] && ok "Model: $MODEL" || ok "Model: (Codex default)"
      return 0
      ;;
  esac

  for m in "${models[@]}"; do
    printf "  [%d] %s\n" "$i" "$m"
    i=$((i+1))
  done
  printf "  [%d] Custom…\n" "$i"
  local max=$i
  printf "Select [1-%d] (default 1): " "$max"
  read_tty choice
  choice="${choice:-1}"
  if [[ "$choice" == "$max" ]]; then
    printf "Model id: "
    read_tty custom
    MODEL="$custom"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < max )); then
    MODEL="${models[$((choice-1))]}"
  else
    MODEL="${models[0]}"
  fi
  ok "Model: $MODEL"
}

# ---------- smoke test ----------
test_ai() {
  [[ "$SKIP_AI_TEST" -eq 1 ]] && return 0
  [[ "$PROVIDER" == "none" ]] && return 0

  if [[ "$PROVIDER" == "openrouter" && -z "$API_KEY" ]]; then
    warn "Skipping AI test (no API key)"
    return 0
  fi
  if [[ "$PROVIDER" == "opencode" && "$HAVE_OPENCODE" -eq 0 ]]; then
    warn "Skipping AI test (opencode missing)"
    return 0
  fi
  if [[ "$PROVIDER" == "codex" && "$HAVE_CODEX" -eq 0 ]]; then
    warn "Skipping AI test (codex missing)"
    return 0
  fi

  info "Testing AI backend ($PROVIDER)…"
  local sug rc=0
  set +e
  sug="$(
    FX_PROVIDER="$PROVIDER" \
    FX_MODEL="$MODEL" \
    OPENROUTER_API_KEY="$API_KEY" \
    zsh -c '
      source "$1"
      # disable hooks noise
      _fx_ai "print only this exact shell command on one line: ls -la"
    ' zsh "$INSTALL_PATH" 2>/dev/null
  )"
  rc=$?
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
      API_KEY="${OPENROUTER_API_KEY:-}"
      select_provider
      maybe_ask_key
      select_model
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

write_zshrc_block() {
  local key_line model_line provider_line
  provider_line="export FX_PROVIDER=\"${PROVIDER:-none}\""

  if [[ -n "$MODEL" ]]; then
    local mesc="${MODEL//\\/\\\\}"
    mesc="${mesc//\"/\\\"}"
    model_line="export FX_MODEL=\"$mesc\""
  else
    model_line='# export FX_MODEL="..."   # optional; omit to use provider default'
  fi

  if [[ "$PROVIDER" == "openrouter" && -n "$API_KEY" ]]; then
    local esc="${API_KEY//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    key_line="export OPENROUTER_API_KEY=\"$esc\""
  elif [[ "$PROVIDER" == "openrouter" ]]; then
    key_line='# export OPENROUTER_API_KEY="sk-or-v1-..."   # uncomment and add your key'
  else
    key_line='# OPENROUTER_API_KEY not required for this provider'
  fi

  local block
  block=$(cat <<EOF
$MARKER_BEGIN
# https://github.com/arjunagi-a-rehman/dum-tum
source "$INSTALL_PATH"
$provider_line
$model_line
$key_line
$MARKER_END
EOF
)

  touch "$ZSHRC"

  if grep -qF "$MARKER_BEGIN" "$ZSHRC" 2>/dev/null; then
    info "Updating existing fixit block in $ZSHRC"
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v repl="$block" '
      $0 == begin { print repl; skip=1; next }
      $0 == end   { skip=0; next }
      !skip       { print }
    ' "$ZSHRC" > "$tmp"
    if ! grep -qF "$MARKER_BEGIN" "$tmp"; then
      printf '\n%s\n' "$block" >> "$tmp"
    fi
    mv "$tmp" "$ZSHRC"
  else
    info "Appending fixit block to $ZSHRC"
    printf '\n%s\n' "$block" >> "$ZSHRC"
  fi
  ok "Configured $ZSHRC"
}

ensure_zsh_default() {
  local shell_now
  shell_now="$(basename "${SHELL:-}")"
  if [[ "$shell_now" == "zsh" ]]; then
    ok "Default shell is already zsh"
    return 0
  fi

  local zsh_path
  zsh_path="$(command -v zsh)"
  warn "Your login shell is '$shell_now', not zsh."
  echo "  fixit only runs inside zsh."
  echo "  Start zsh now:  zsh"
  echo "  Make default:   chsh -s \"$zsh_path\""
  if is_ubuntu || [[ "$OS" == "Linux" ]]; then
    if ! grep -q "^$zsh_path\$" /etc/shells 2>/dev/null; then
      echo "  (If chsh complains, run: echo \"$zsh_path\" | sudo tee -a /etc/shells)"
    fi
  fi
}

print_next_steps() {
  local ai_hint
  case "${PROVIDER:-none}" in
    openrouter) ai_hint="OpenRouter ($MODEL)" ;;
    opencode)   ai_hint="OpenCode${MODEL:+ ($MODEL)}" ;;
    codex)      ai_hint="Codex${MODEL:+ ($MODEL)}" ;;
    *)          ai_hint="off (local typos only)" ;;
  esac

  cat <<EOF

┌─────────────────────────────────────────────────────────┐
│  fixit.zsh installed on $OS_NAME
│  Script:   $INSTALL_PATH
│  Config:   $ZSHRC
│  AI:       $ai_hint
└─────────────────────────────────────────────────────────┘

Reload your shell:

  source $ZSHRC

  # or open a new terminal tab (must be zsh)

Try:

  sl                  # local typo → ls
  list all files      # AI → confirm with Enter

Change provider later:

  export FX_PROVIDER="opencode"   # or codex | openrouter | none
  export FX_MODEL="..."
  # openrouter only:
  export OPENROUTER_API_KEY="sk-or-v1-..."

Docs: https://github.com/arjunagi-a-rehman/dum-tum

EOF
}

uninstall_fixit() {
  info "Uninstalling fixit.zsh…"
  local removed=0

  if [[ -f "$ZSHRC" ]] && grep -qF "$MARKER_BEGIN" "$ZSHRC" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
      $0 == begin { skip=1; next }
      $0 == end   { skip=0; next }
      !skip       { print }
    ' "$ZSHRC" > "$tmp"
    mv "$tmp" "$ZSHRC"
    ok "Removed fixit block from $ZSHRC"
    removed=1
  else
    warn "No fixit block found in $ZSHRC"
  fi

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
    ok "fixit.zsh uninstalled"
    echo ""
    echo "Reload your shell:  source $ZSHRC"
    echo "Or open a new terminal tab."
  fi
}

main() {
  if [[ "$DO_UNINSTALL" -eq 1 ]]; then
    uninstall_fixit
    return 0
  fi

  info "Installing fixit.zsh for ${OS_NAME}…"
  install_deps
  install_script
  detect_ai_clis
  select_provider
  maybe_ask_key
  select_model
  test_ai
  write_zshrc_block
  ensure_zsh_default
  print_next_steps
}

main
