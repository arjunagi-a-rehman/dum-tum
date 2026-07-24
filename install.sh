#!/usr/bin/env bash
# fixit.zsh installer — macOS + Ubuntu/Debian Linux
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main/install.sh | bash
#   npx github:arjunagi-a-rehman/dum-tum
#   ./install.sh
#   ./install.sh --key sk-or-v1-...
set -euo pipefail

REPO_RAW="${FIXIT_RAW:-https://raw.githubusercontent.com/arjunagi-a-rehman/dum-tum/main}"
INSTALL_DIR="${FIXIT_HOME:-$HOME/.local/share/fixit}"
INSTALL_PATH="$INSTALL_DIR/fixit.zsh"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
MARKER_BEGIN="# >>> fixit.zsh >>>"
MARKER_END="# <<< fixit.zsh <<<"

# Resolve script directory when run from a local clone / npx extract
SELF="${BASH_SOURCE[0]:-$0}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || true)"

API_KEY="${OPENROUTER_API_KEY:-}"
ASSUME_YES=0
SKIP_DEPS=0

usage() {
  cat <<'EOF'
fixit.zsh installer (macOS + Ubuntu/Linux)

Usage:
  ./install.sh [options]

Options:
  --key KEY       Set OPENROUTER_API_KEY (optional; AI features)
  --yes, -y       Non-interactive where possible
  --skip-deps     Do not try to install zsh/python3/curl
  --help, -h      Show this help

Env:
  OPENROUTER_API_KEY   Same as --key
  FIXIT_HOME           Install dir (default: ~/.local/share/fixit)
  FIXIT_RAW            Raw GitHub base URL override
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) API_KEY="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
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

# Prompt for key if missing and interactive
maybe_ask_key() {
  if [[ -n "$API_KEY" ]]; then
    return 0
  fi
  # already in environment from existing zshrc? skip
  if grep -q 'OPENROUTER_API_KEY=.\+' "$ZSHRC" 2>/dev/null; then
    ok "OPENROUTER_API_KEY already set in $ZSHRC"
    return 0
  fi
  if [[ ! -t 0 ]] || [[ "$ASSUME_YES" -eq 1 ]]; then
    warn "No API key provided — local typo fixes will work; AI needs OPENROUTER_API_KEY later."
    return 0
  fi
  echo ""
  echo "OpenRouter API key enables natural language (optional)."
  echo "Get one free-ish at: https://openrouter.ai/keys"
  printf "Paste key now (or press Enter to skip): "
  # read from tty even if stdin was a pipe
  if [[ -r /dev/tty ]]; then
    IFS= read -r API_KEY </dev/tty || true
  else
    IFS= read -r API_KEY || true
  fi
  API_KEY="${API_KEY//$'\r'/}"
}

write_zshrc_block() {
  local key_line=""
  if [[ -n "$API_KEY" ]]; then
    # escape double quotes in key if any
    local esc="${API_KEY//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    key_line="export OPENROUTER_API_KEY=\"$esc\""
  else
    key_line='# export OPENROUTER_API_KEY="sk-or-v1-..."   # uncomment and add your key'
  fi

  local block
  block=$(cat <<EOF
$MARKER_BEGIN
# https://github.com/arjunagi-a-rehman/dum-tum
source "$INSTALL_PATH"
$key_line
# export FX_MODEL="deepseek/deepseek-v4-flash"
$MARKER_END
EOF
)

  touch "$ZSHRC"

  if grep -qF "$MARKER_BEGIN" "$ZSHRC" 2>/dev/null; then
    info "Updating existing fixit block in $ZSHRC"
    # Replace between markers (portable awk)
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v repl="$block" '
      $0 == begin { print repl; skip=1; next }
      $0 == end   { skip=0; next }
      !skip       { print }
    ' "$ZSHRC" > "$tmp"
    # If markers were incomplete, append
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
  cat <<EOF

┌─────────────────────────────────────────────────────────┐
│  fixit.zsh installed on $OS_NAME
│  Script:  $INSTALL_PATH
│  Config:  $ZSHRC
└─────────────────────────────────────────────────────────┘

Reload your shell:

  source $ZSHRC

  # or open a new terminal tab (must be zsh)

Try:

  sl                  # local typo → ls
  list all files      # AI (needs API key) → confirm with Enter

Set / change API key later:

  export OPENROUTER_API_KEY="sk-or-v1-..."
  # or edit $ZSHRC

Docs: https://github.com/arjunagi-a-rehman/dum-tum

EOF
}

main() {
  info "Installing fixit.zsh for $OS_NAME…"
  install_deps
  install_script
  maybe_ask_key
  write_zshrc_block
  ensure_zsh_default
  print_next_steps
}

main
