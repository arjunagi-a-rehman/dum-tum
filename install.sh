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
FIXIT_HOME_WAS_SET="${FIXIT_HOME+x}"
INSTALL_DIR="${FIXIT_HOME:-$HOME/.local/share/fixit}"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
BASHRC="$HOME/.bashrc"
BASH_PROFILE="$HOME/.bash_profile"
MARKER_BEGIN="# >>> fixit.zsh >>>"
MARKER_END="# <<< fixit.zsh <<<"
BASH_PROFILE_MARKER_BEGIN="# >>> dum-tum bashrc loader >>>"
BASH_PROFILE_MARKER_END="# <<< dum-tum bashrc loader <<<"
INSTALL_SENTINEL=".dum-tum-install"
INSTALL_SENTINEL_VALUE="dum-tum-install-v1"
UNINSTALL_TARGET=""

INSTALLER_SOURCE="${BASH_SOURCE[0]:-}"
SELF_DIR=""
case "$INSTALLER_SOURCE" in
  ""|/dev/*|/proc/*) ;;
  *)
    if [[ -f "$INSTALLER_SOURCE" ]]; then
      SELF_DIR="$(cd "$(dirname "$INSTALLER_SOURCE")" 2>/dev/null && pwd || true)"
    fi
    ;;
esac

# Values from CLI flags only (env is a non-interactive fallback — does not skip menus)
API_KEY=""
PROVIDER=""
MODEL=""
VARIANT=""
PROVIDER_FROM_CLI=0
MODEL_FROM_CLI=0
KEY_FROM_CLI=0
VARIANT_FROM_CLI=0
PROVIDER_FROM_ENV=0
MODEL_FROM_ENV=0
VARIANT_FROM_ENV=0
KEY_FROM_ENV=0
ASSUME_YES=0
SKIP_DEPS=0
SKIP_AI_TEST=0
DO_UNINSTALL=0

HAVE_OPENCODE=0
HAVE_CLAUDE=0
HAVE_CODEX=0
HAVE_ANTIGRAVITY=0
SHELL_CHOICE=""
DO_ZSH=0
DO_BASH=0

TX_ACTIVE=0
TX_STAGE=""
TX_RUNTIME_BACKUP=""
TX_RUNTIME_HAD_OLD=0
TX_RUNTIME_STARTED=0
TX_RUNTIME_ACTIVE=0
TX_RC_COUNT=0
TX_RC_TARGETS=()
TX_RC_TEMPS=()
TX_RC_BACKUPS=()
TX_RC_EXISTED=()
TX_RC_STARTED=()
RENDERED_TARGET=""
RENDERED_TEMP=""

usage() {
  cat <<'EOF'
fixit.zsh installer (macOS + Ubuntu/Linux)

Usage:
  ./install.sh [options]
  ./install.sh --uninstall

Options:
  --provider NAME   openrouter | openai | anthropic | gemini | opencode | claude | codex | antigravity | none
  --model ID        Model id for the chosen provider
  --variant LEVEL   Reasoning effort (CLI providers: low|medium|high|...)
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
  KEY_FROM_ENV=0
  local kv
  for kv in OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY; do
    if [[ -n "${!kv:-}" ]]; then
      API_KEY="${!kv}"
      KEY_ENV_VAR="$kv"
      KEY_FROM_ENV=1
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
  PROVIDER_FROM_ENV=1
fi
if [[ "$MODEL_FROM_CLI" -eq 0 && -n "${FX_MODEL:-}" ]]; then
  MODEL="$FX_MODEL"
  MODEL_FROM_ENV=1
fi
if [[ "$VARIANT_FROM_CLI" -eq 0 && -n "${FX_VARIANT:-}" ]]; then
  VARIANT="$FX_VARIANT"
  VARIANT_FROM_ENV=1
fi

info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
err()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

require_single_line() {
  local name="$1" value="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    err "$name must not contain newline characters"
    return 1
  fi
}

validate_single_line_inputs() {
  require_single_line HOME "$HOME" || return 1
  require_single_line FIXIT_HOME "$INSTALL_DIR" || return 1
  require_single_line ZSHRC "$ZSHRC" || return 1
  require_single_line BASHRC "$BASHRC" || return 1
  require_single_line BASH_PROFILE "$BASH_PROFILE" || return 1
  require_single_line FIXIT_RAW "$REPO_RAW" || return 1
  require_single_line provider "$PROVIDER" || return 1
  require_single_line model "$MODEL" || return 1
  require_single_line variant "$VARIANT" || return 1
  require_single_line key "$API_KEY" || return 1
}

shell_quote() {
  local value="${1:-}"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

resolve_rc_file() {
  local path="$1" link dir hops=0
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  while [[ -L "$path" ]]; do
    hops=$((hops+1))
    if (( hops > 40 )); then
      err "Too many symlinks while resolving $1"
      return 1
    fi
    link="$(readlink "$path")" || return 1
    case "$link" in
      /*) path="$link" ;;
      *)
        dir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
        path="$dir/$link"
        ;;
    esac
  done
  dir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || {
    err "Parent directory does not exist for $1"
    return 1
  }
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

validate_marked_block() {
  local rc_file="$1" begin="$2" end="$3" label="$4" target
  target="$(resolve_rc_file "$rc_file")" || return 1
  [[ -e "$target" ]] || return 0
  if [[ ! -f "$target" ]]; then
    err "Refusing to update non-file rc path: $rc_file"
    return 1
  fi
  if ! awk -v begin="$begin" -v end="$end" '
    index($0, begin) {
      if ($0 != begin || state != 0) bad=1
      begins++
      state=1
      next
    }
    index($0, end) {
      if ($0 != end || state != 1) bad=1
      ends++
      state=2
      next
    }
    END {
      if (begins == 0 && ends == 0) exit 0
      if (!bad && begins == 1 && ends == 1 && state == 2) exit 0
      exit 1
    }
  ' "$target"; then
    err "Malformed $label block in $rc_file; leaving it unchanged"
    return 1
  fi
}

validate_managed_block() {
  validate_marked_block "$1" "$MARKER_BEGIN" "$MARKER_END" dum-tum
}

preflight_rc_updates() {
  [[ "$DO_ZSH" -eq 0 ]] || validate_managed_block "$ZSHRC" || return 1
  [[ "$DO_BASH" -eq 0 ]] || validate_managed_block "$BASHRC" || return 1
  if [[ "$OS" == Darwin && "$DO_BASH" -eq 1 ]]; then
    validate_marked_block "$BASH_PROFILE" "$BASH_PROFILE_MARKER_BEGIN" \
      "$BASH_PROFILE_MARKER_END" 'dum-tum bashrc loader' || return 1
  fi
}

preflight_rc_uninstall() {
  if [[ -e "$ZSHRC" || -L "$ZSHRC" ]]; then
    validate_managed_block "$ZSHRC" || return 1
  fi
  if [[ -e "$BASHRC" || -L "$BASHRC" ]]; then
    validate_managed_block "$BASHRC" || return 1
  fi
  if [[ -e "$BASH_PROFILE" || -L "$BASH_PROFILE" ]]; then
    validate_marked_block "$BASH_PROFILE" "$BASH_PROFILE_MARKER_BEGIN" \
      "$BASH_PROFILE_MARKER_END" 'dum-tum bashrc loader' || return 1
  fi
}

managed_assignment_line() {
  local rc_file="$1" var="$2" target
  target="$(resolve_rc_file "$rc_file")" || return 1
  [[ -f "$target" ]] || return 1
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v var="$var" '
    $0 == begin { inside=1; next }
    $0 == end { inside=0; next }
    inside && $0 ~ "^[[:space:]]*export[[:space:]]+" var "=" { value=$0; found=1 }
    END { if (found) print value; else exit 1 }
  ' "$target"
}

read_managed_value() {
  local rc_file="$1" var="$2" line
  line="$(managed_assignment_line "$rc_file" "$var")" || return 1
  printf '%s\n' "$line" | python3 -c '
import shlex
import sys

name = sys.argv[1]
try:
    words = shlex.split(sys.stdin.read(), comments=False, posix=True)
except ValueError:
    raise SystemExit(1)
if len(words) != 2 or words[0] != "export":
    raise SystemExit(1)
prefix = name + "="
if not words[1].startswith(prefix):
    raise SystemExit(1)
sys.stdout.write(words[1][len(prefix):])
' "$var"
}

load_existing_config() {
  local login_shell rc candidate normalized selected_provider="" selected_provider_rc="" key_var
  local requested_provider authoritative_rc=""
  local -a rc_files=()
  login_shell="$(basename "${SHELL:-}")"
  if [[ "$login_shell" == bash && "$DO_BASH" -eq 1 ]]; then
    rc_files+=("$BASHRC")
  elif [[ "$login_shell" == zsh && "$DO_ZSH" -eq 1 ]]; then
    rc_files+=("$ZSHRC")
  fi
  if [[ "$DO_ZSH" -eq 1 && "$login_shell" != zsh ]]; then
    rc_files+=("$ZSHRC")
  fi
  if [[ "$DO_BASH" -eq 1 && "$login_shell" != bash ]]; then
    rc_files+=("$BASHRC")
  fi

  for rc in "${rc_files[@]}"; do
    if candidate="$(read_managed_value "$rc" FX_PROVIDER)"; then
      normalized="$(normalize_provider "$candidate")"
      [[ -n "$normalized" ]] || continue
      if [[ -z "$selected_provider" ]]; then
        selected_provider="$normalized"
        selected_provider_rc="$rc"
      elif [[ "$normalized" != "$selected_provider" ]]; then
        warn "Selected rc files disagree on FX_PROVIDER; preferring $selected_provider_rc"
      fi
    fi
  done
  requested_provider="$(normalize_provider "$PROVIDER")"
  if [[ -n "$requested_provider" ]]; then
    for rc in "${rc_files[@]}"; do
      if candidate="$(read_managed_value "$rc" FX_PROVIDER)" && \
         [[ "$(normalize_provider "$candidate")" == "$requested_provider" ]]; then
        authoritative_rc="$rc"
        break
      fi
    done
  elif [[ "$PROVIDER_FROM_CLI" -eq 0 && "$PROVIDER_FROM_ENV" -eq 0 && -n "$selected_provider" ]]; then
    PROVIDER="$selected_provider"
    authoritative_rc="$selected_provider_rc"
    info "Keeping existing FX_PROVIDER=$PROVIDER from $selected_provider_rc"
  fi

  if [[ -n "$authoritative_rc" && "$MODEL_FROM_CLI" -eq 0 && "$MODEL_FROM_ENV" -eq 0 && -z "$MODEL" ]] && \
     candidate="$(read_managed_value "$authoritative_rc" FX_MODEL)"; then
    MODEL="$candidate"
    info "Keeping existing FX_MODEL from $authoritative_rc"
  fi
  if [[ -n "$authoritative_rc" && "$VARIANT_FROM_CLI" -eq 0 && "$VARIANT_FROM_ENV" -eq 0 && -z "$VARIANT" ]] && \
     candidate="$(read_managed_value "$authoritative_rc" FX_VARIANT)"; then
    VARIANT="$candidate"
    info "Keeping existing FX_VARIANT from $authoritative_rc"
  fi
  key_var="$(key_var_for_provider "${requested_provider:-$PROVIDER}")"
  if [[ -n "$authoritative_rc" && -n "$key_var" && "$KEY_FROM_CLI" -eq 0 && "$KEY_FROM_ENV" -eq 0 && -z "$API_KEY" ]] && \
     candidate="$(read_managed_value "$authoritative_rc" "$key_var")"; then
    API_KEY="$candidate"
    KEY_ENV_VAR="$key_var"
    info "Keeping existing $key_var from $authoritative_rc"
  fi
}

runtime_files_present() {
  local target="$1" f
  for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py; do
    [[ -f "$target/$f" && ! -L "$target/$f" ]] || return 1
  done
}

legacy_install_signature() {
  local target="$1" line
  runtime_files_present "$target" || return 1
  IFS= read -r line < "$target/fixit-common.sh" || return 1
  [[ "$line" == '# shellcheck shell=bash' ]] || return 1
  IFS= read -r line < "$target/fixit.zsh" || return 1
  [[ "$line" == '# fixit.zsh — zsh adapter. Shared logic lives in fixit-common.sh.' ]] || return 1
  IFS= read -r line < "$target/fixit.bash" || return 1
  [[ "$line" == '# fixit.bash — bash adapter (bash 4+). Shared logic lives in fixit-common.sh.' ]] || return 1
  line="$(sed -n '2p' "$target/fixit-ai.py")"
  [[ "$line" == '"""fixit AI helpers.' ]]
}

install_identity_valid() {
  local target="$1" sentinel="$1/$INSTALL_SENTINEL" lines
  if [[ -e "$sentinel" || -L "$sentinel" ]]; then
    [[ -f "$sentinel" && ! -L "$sentinel" ]] || return 1
    runtime_files_present "$target" || return 1
    lines="$(wc -l < "$sentinel")"
    [[ "$lines" -eq 1 ]] || return 1
    grep -qxF "$INSTALL_SENTINEL_VALUE" "$sentinel"
    return
  fi
  legacy_install_signature "$target"
}

target_contains_path() {
  local target="$1" protected="$2"
  [[ "$protected" == "$target" || "$protected" == "$target/"* ]]
}

validate_uninstall_target() {
  local target home_path pwd_path protected
  UNINSTALL_TARGET=""
  if [[ "$FIXIT_HOME_WAS_SET" == x && -z "${FIXIT_HOME:-}" ]]; then
    err "Refusing to uninstall with an empty FIXIT_HOME"
    return 1
  fi
  if [[ ! -e "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]]; then
    return 0
  fi
  if [[ -L "$INSTALL_DIR" ]]; then
    err "Refusing to uninstall a symlinked FIXIT_HOME: $INSTALL_DIR"
    return 1
  fi
  if [[ ! -d "$INSTALL_DIR" ]]; then
    err "Refusing to uninstall non-directory FIXIT_HOME: $INSTALL_DIR"
    return 1
  fi
  target="$(cd -P "$INSTALL_DIR" 2>/dev/null && pwd)" || return 1
  case "$target" in
    /|/Applications|/Library|/System|/bin|/boot|/dev|/etc|/lib|/lib64|/opt|/private|/proc|/run|/sbin|/tmp|/usr|/var)
      err "Refusing to uninstall dangerous path: $target"
      return 1
      ;;
  esac
  home_path="$(cd -P "$HOME" 2>/dev/null && pwd)" || return 1
  pwd_path="$(pwd -P)"
  for protected in "$home_path" "$pwd_path" ${SELF_DIR:+"$SELF_DIR"}; do
    if target_contains_path "$target" "$protected"; then
      err "Refusing to uninstall protected path: $target"
      return 1
    fi
  done
  if ! install_identity_valid "$target"; then
    err "Refusing to remove $target: no valid dum-tum installation identity"
    return 1
  fi
  UNINSTALL_TARGET="$target"
}

validate_install_target() {
  [[ ! -L "$INSTALL_DIR" ]] || {
    err "Refusing to install into symlinked FIXIT_HOME: $INSTALL_DIR"
    return 1
  }
  [[ ! -e "$INSTALL_DIR" || -d "$INSTALL_DIR" ]] || {
    err "Refusing to install into non-directory FIXIT_HOME: $INSTALL_DIR"
    return 1
  }
  if [[ -d "$INSTALL_DIR" && -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    if ! install_identity_valid "$INSTALL_DIR"; then
      err "Refusing to install into non-empty directory without a valid dum-tum identity: $INSTALL_DIR"
      return 1
    fi
  fi
}

remove_install_dir() {
  local target="$1" parent quarantine
  if [[ -L "$target" || ! -d "$target" ]] || ! install_identity_valid "$target"; then
    err "Installation target changed after validation; refusing to remove it: $target"
    return 1
  fi
  parent="$(dirname "$target")"
  quarantine="$(mktemp -d "$parent/.dum-tum-uninstall.XXXXXX")" || return 1
  if ! mv "$target" "$quarantine/install"; then
    rmdir "$quarantine" 2>/dev/null || true
    return 1
  fi
  if ! rm -rf "$quarantine"; then
    err "Could not remove quarantined installation: $quarantine"
    return 1
  fi
  ok "Removed $target"
}

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
  local targets=()
  [[ "$DO_ZSH" -eq 1 ]] && targets+=("zsh")
  [[ "$DO_BASH" -eq 1 ]] && targets+=("bash")
  ok "Shell targets: ${targets[*]}"
}

install_deps() {
  local need=()
  [[ "$DO_ZSH" -eq 1 ]] && { have zsh || need+=(zsh); }
  have python3 || need+=(python3)
  have curl    || need+=(curl)

  if [[ "$SKIP_DEPS" -eq 1 ]]; then
    if [[ ${#need[@]} -gt 0 ]]; then
      err "Missing required dependencies with --skip-deps: ${need[*]}"
      return 1
    fi
    return 0
  fi

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

  if ! { { [[ "$DO_ZSH" -eq 0 ]] || have zsh; } && have python3 && have curl; }; then
    err "Still missing tools after install attempt."
    exit 1
  fi
  ok "Dependencies installed"
}

runtime_mode() {
  if [[ "$OS" == Darwin ]]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

validate_staged_runtime() {
  local stage="$1" f mode
  runtime_files_present "$stage" || {
    err "Staged runtime is incomplete"
    return 1
  }
  for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py; do
    mode="$(runtime_mode "$stage/$f")" || return 1
    if [[ "$mode" != 644 ]]; then
      err "Invalid permissions on staged runtime file: $f"
      return 1
    fi
  done
  bash -n "$stage/fixit-common.sh" "$stage/fixit.bash" || {
    err "Invalid shell syntax in staged Bash runtime"
    return 1
  }
  if have zsh; then
    zsh -n "$stage/fixit.zsh" || {
      err "Invalid shell syntax in staged zsh runtime"
      return 1
    }
  fi
  python3 -c '
import ast
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
' "$stage/fixit-ai.py" || {
    err "Invalid Python syntax in staged runtime"
    return 1
  }
  install_identity_valid "$stage" || {
    err "Staged runtime identity validation failed"
    return 1
  }
}

rollback_install_transaction() {
  local i backup target
  [[ "$TX_ACTIVE" -eq 1 ]] || return 0
  set +e
  for ((i=TX_RC_COUNT-1; i>=0; i--)); do
    [[ "${TX_RC_STARTED[$i]}" -eq 1 ]] || continue
    target="${TX_RC_TARGETS[$i]}"
    backup="${TX_RC_BACKUPS[$i]}"
    if [[ "${TX_RC_EXISTED[$i]}" -eq 1 ]]; then
      if [[ -n "$backup" && -e "$backup" ]]; then
        rm -f "$target"
        mv "$backup" "$target"
      fi
    else
      rm -f "$target"
    fi
  done
  if [[ "$TX_RUNTIME_STARTED" -eq 1 ]]; then
    if [[ "$TX_RUNTIME_ACTIVE" -eq 1 ]]; then
      rm -rf "$INSTALL_DIR"
    fi
    if [[ "$TX_RUNTIME_HAD_OLD" -eq 1 && -d "$TX_RUNTIME_BACKUP" ]]; then
      mv "$TX_RUNTIME_BACKUP" "$INSTALL_DIR"
    fi
  fi
  for ((i=0; i<TX_RC_COUNT; i++)); do
    backup="${TX_RC_BACKUPS[$i]}"
    target="${TX_RC_TEMPS[$i]}"
    [[ -z "$backup" ]] || rm -f "$backup"
    [[ -z "$target" ]] || rm -f "$target"
  done
  [[ -z "$TX_STAGE" ]] || rm -rf "$TX_STAGE"
  [[ -z "$TX_RUNTIME_BACKUP" ]] || rm -rf "$TX_RUNTIME_BACKUP"
  TX_ACTIVE=0
  warn "Installation failed; restored the previous runtime and shell configuration"
}

transaction_exit_trap() {
  local status=$?
  rollback_install_transaction
  exit "$status"
}

begin_install_transaction() {
  TX_ACTIVE=1
  trap transaction_exit_trap EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

stage_runtime() {
  local parent f use_local=0
  parent="$(dirname "$INSTALL_DIR")"
  mkdir -p "$parent"
  TX_STAGE="$(mktemp -d "$parent/.dum-tum-install.XXXXXX")" || return 1
  if [[ -n "$SELF_DIR" ]]; then
    use_local=1
    for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py; do
      [[ -f "$SELF_DIR/src/$f" ]] || use_local=0
    done
  fi
  if [[ "$use_local" -eq 1 ]]; then
    info "Using local scripts from $SELF_DIR/src"
    for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py; do
      cp "$SELF_DIR/src/$f" "$TX_STAGE/$f"
    done
  else
    info "Downloading scripts from GitHub…"
    for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py; do
      curl -fsSL "$REPO_RAW/src/$f" -o "$TX_STAGE/$f"
    done
  fi
  chmod 644 "$TX_STAGE"/fixit-common.sh "$TX_STAGE"/fixit.zsh \
    "$TX_STAGE"/fixit.bash "$TX_STAGE"/fixit-ai.py
  printf '%s\n' "$INSTALL_SENTINEL_VALUE" > "$TX_STAGE/$INSTALL_SENTINEL"
  chmod 644 "$TX_STAGE/$INSTALL_SENTINEL"
  validate_staged_runtime "$TX_STAGE"
  ok "Staged and validated runtime"
}

detect_ai_clis() {
  local runtime_dir="${1:-$INSTALL_DIR}"
  HAVE_OPENCODE=0
  HAVE_CLAUDE=0
  HAVE_CODEX=0
  HAVE_ANTIGRAVITY=0
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
  if have agy && FX_PROVIDER=antigravity FX_AI_READY_TIMEOUT=10 bash -c '
    source "$1"
    _fx_ai_ready
  ' bash "$runtime_dir/fixit-common.sh"; then
    HAVE_ANTIGRAVITY=1
    ok "Detected Antigravity CLI ($(command -v agy))"
  elif have agy; then
    warn "Antigravity CLI found but not authenticated; run agy to sign in"
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
    antigravity|agy|ag) echo antigravity ;;
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
    elif [[ "$HAVE_ANTIGRAVITY" -eq 1 ]]; then
      PROVIDER="antigravity"
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
  if [[ "$HAVE_ANTIGRAVITY" -eq 1 ]]; then
    printf "  [%d] Antigravity CLI (uses your local agy auth)\n" "$i"
    labels+=("Antigravity CLI"); values+=("antigravity")
    [[ "$hint" == "antigravity" ]] && default=$i
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

  if [[ "$HAVE_OPENCODE" -eq 0 && "$HAVE_CLAUDE" -eq 0 && "$HAVE_CODEX" -eq 0 && "$HAVE_ANTIGRAVITY" -eq 0 ]]; then
    echo "  (tip: install opencode, claude, codex, or Antigravity CLI, then re-run to use them)"
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
        opencode|claude|codex|antigravity) MODEL="" ;;
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
    antigravity)
      local listed
      listed="$(agy models 2>/dev/null || true)"
      if [[ -n "$listed" ]]; then
        while IFS= read -r line; do
          line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
          [[ -z "$line" ]] && continue
          local tok
          tok="$(echo "$line" | awk '{print $1}')"
          [[ -n "$tok" ]] && models+=("$tok")
        done <<<"$listed"
      fi
      printf "  [1] (Antigravity CLI default — recommended)\n"
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
        printf "Model id (see 'agy models') [%s]: " "${hint:-}"
        read_tty custom
        MODEL="${custom:-$hint}"
      elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 2 && choice < max )); then
        MODEL="${models[$((choice-2))]}"
      else
        MODEL=""
      fi
      [[ -n "$MODEL" ]] && ok "Model: $MODEL" || ok "Model: (Antigravity default)"
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

# ---------- reasoning effort (codex/opencode/claude/antigravity) ----------
select_variant() {
  [[ "$PROVIDER" == "codex" || "$PROVIDER" == "opencode" || "$PROVIDER" == "claude" || "$PROVIDER" == "antigravity" ]] || { VARIANT=""; return 0; }

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
  elif [[ "$PROVIDER" == "opencode" ]]; then
    # opencode --variant: provider-specific; low/medium/high are the common ones
    levels=(low medium high)
  else
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
  if [[ "$PROVIDER" == "antigravity" && "$HAVE_ANTIGRAVITY" -eq 0 ]]; then
    err "Antigravity CLI is unavailable or not authenticated; run agy to sign in"
    return 1
  fi
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
    if [[ "$PROVIDER" == "antigravity" ]]; then
      err "Antigravity AI test failed; configuration was not written"
      return 1
    fi
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

validate_provider_candidate() {
  local normalized
  normalized="$(normalize_provider "$PROVIDER")"
  if [[ -z "$normalized" || "$normalized" != "$PROVIDER" ]]; then
    err "Invalid provider configuration candidate: $PROVIDER"
    return 1
  fi
  validate_single_line_inputs
}

queue_rendered_update() {
  local i
  for ((i=0; i<TX_RC_COUNT; i++)); do
    if [[ "${TX_RC_TARGETS[$i]}" == "$RENDERED_TARGET" ]]; then
      err "Selected shell files resolve to the same target: $RENDERED_TARGET"
      rm -f "$RENDERED_TEMP"
      return 1
    fi
  done
  TX_RC_TARGETS[$TX_RC_COUNT]="$RENDERED_TARGET"
  TX_RC_TEMPS[$TX_RC_COUNT]="$RENDERED_TEMP"
  TX_RC_BACKUPS[$TX_RC_COUNT]=""
  if [[ -f "$RENDERED_TARGET" ]]; then
    TX_RC_EXISTED[$TX_RC_COUNT]=1
  else
    TX_RC_EXISTED[$TX_RC_COUNT]=0
  fi
  TX_RC_STARTED[$TX_RC_COUNT]=0
  TX_RC_COUNT=$((TX_RC_COUNT+1))
}

render_marked_block() {
  local rc_file="$1" begin="$2" end="$3" label="$4" block="$5"
  local stores_api_key="$6" syntax_shell="$7"
  local target dir tmp repl_file mode
  RENDERED_TARGET=""
  RENDERED_TEMP=""
  validate_marked_block "$rc_file" "$begin" "$end" "$label" || return 1
  target="$(resolve_rc_file "$rc_file")" || return 1
  dir="$(dirname "$target")"
  tmp="$(mktemp "$dir/.dum-tum-rc.XXXXXX")" || return 1
  repl_file="$(mktemp "$dir/.dum-tum-block.XXXXXX")" || {
    rm -f "$tmp"
    return 1
  }
  printf '%s\n' "$block" > "$repl_file" || {
    rm -f "$tmp" "$repl_file"
    return 1
  }
  if ! "$syntax_shell" -n "$repl_file"; then
    err "Invalid generated configuration for $rc_file"
    rm -f "$tmp" "$repl_file"
    return 1
  fi
  if [[ -f "$target" ]] && grep -qxF "$begin" "$target" 2>/dev/null; then
    info "Updating existing $label block in $rc_file"
    awk -v begin="$begin" -v end="$end" -v rf="$repl_file" '
      $0 == begin { while ((getline line < rf) > 0) print line; skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$target" > "$tmp" || {
      rm -f "$tmp" "$repl_file"
      return 1
    }
  else
    info "Appending $label block to $rc_file"
    if [[ -f "$target" ]]; then
      cat "$target" > "$tmp" || {
        rm -f "$tmp" "$repl_file"
        return 1
      }
    fi
    printf '\n%s\n' "$block" >> "$tmp" || {
      rm -f "$tmp" "$repl_file"
      return 1
    }
  fi
  rm -f "$repl_file"
  mode="$(runtime_mode "$target" 2>/dev/null || true)"
  if [[ "$stores_api_key" -eq 1 && "$mode" != 600 ]]; then
    warn "$rc_file was readable by other users — tightening to 600 (key inside)"
  fi
  if [[ "$stores_api_key" -eq 1 ]]; then
    chmod 600 "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  elif [[ -n "$mode" ]]; then
    chmod "$mode" "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  fi
  RENDERED_TARGET="$target"
  RENDERED_TEMP="$tmp"
}

bash_profile_sources_bashrc() {
  local target bashrc_target
  target="$(resolve_rc_file "$BASH_PROFILE")" || return 1
  bashrc_target="$(resolve_rc_file "$BASHRC")" || return 1
  [[ -f "$target" ]] || return 1
  python3 -c '
import os
import shlex
import sys

profile, bashrc_target, home = sys.argv[1:]
dollar = chr(36)

def sourced_path(raw):
    if len(raw) >= 2 and raw[0] == raw[-1] == "\047":
        value = raw[1:-1]
    elif len(raw) >= 2 and raw[0] == raw[-1] == "\042":
        value = raw[1:-1]
        if "\\" in value:
            return None
        value = value.replace(dollar + "{HOME}", home).replace(dollar + "HOME", home)
        if dollar in value or "`" in value:
            return None
    else:
        try:
            values = shlex.split(raw, comments=False, posix=True)
        except ValueError:
            return None
        if len(values) != 1:
            return None
        value = values[0]
        if dollar + "(" in value or "`" in value:
            return None
        value = value.replace(dollar + "{HOME}", home).replace(dollar + "HOME", home)
        if value == "~":
            value = home
        elif value.startswith("~/"):
            value = os.path.join(home, value[2:])
        if dollar in value or "`" in value:
            return None
    if not os.path.isabs(value):
        return None
    return os.path.realpath(value)

with open(profile, encoding="utf-8", errors="surrogateescape") as handle:
    for line in handle:
        lexer = shlex.shlex(line, posix=False)
        lexer.whitespace_split = True
        lexer.commenters = "#"
        try:
            words = list(lexer)
        except ValueError:
            continue
        if len(words) != 2 or words[0] not in ("source", "."):
            continue
        if sourced_path(words[1]) == bashrc_target:
            raise SystemExit(0)
raise SystemExit(1)
' "$target" "$bashrc_target" "$HOME"
}

prepare_bash_profile_loader() {
  [[ "$OS" == Darwin && "$DO_BASH" -eq 1 ]] || return 0
  local target bashrc_target block
  target="$(resolve_rc_file "$BASH_PROFILE")" || return 1
  bashrc_target="$(resolve_rc_file "$BASHRC")" || return 1
  if [[ "$target" == "$bashrc_target" ]]; then
    return 0
  fi
  if [[ -f "$target" ]] && ! grep -qxF "$BASH_PROFILE_MARKER_BEGIN" "$target" 2>/dev/null && \
     bash_profile_sources_bashrc; then
    ok "$BASH_PROFILE already loads $BASHRC"
    return 0
  fi
  block=$(cat <<EOF
$BASH_PROFILE_MARKER_BEGIN
if [[ -z "\${_DUM_TUM_BASHRC_LOADED:-}" && -r $(shell_quote "$BASHRC") ]]; then
  _DUM_TUM_BASHRC_LOADED=1
  source $(shell_quote "$BASHRC")
fi
$BASH_PROFILE_MARKER_END
EOF
)
  render_marked_block "$BASH_PROFILE" "$BASH_PROFILE_MARKER_BEGIN" \
    "$BASH_PROFILE_MARKER_END" 'dum-tum bashrc loader' "$block" 0 bash || return 1
  queue_rendered_update
}

# prepare_rc_block <rc-file> <adapter-file> <syntax-shell>
prepare_rc_block() {
  local rc_file="$1" adapter="$2"
  local syntax_shell="$3"
  local key_line model_line provider_line variant_line stores_api_key=0
  provider_line="export FX_PROVIDER=$(shell_quote "${PROVIDER:-none}")"

  if [[ -n "$MODEL" ]]; then
    model_line="export FX_MODEL=$(shell_quote "$MODEL")"
  else
    model_line='# export FX_MODEL="..."   # optional; omit to use provider default'
  fi

  if [[ -n "$VARIANT" ]]; then
    variant_line="export FX_VARIANT=$(shell_quote "$VARIANT")"
  else
    variant_line='# export FX_VARIANT="medium"   # reasoning effort (codex/opencode/claude/antigravity)'
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
    key_line="export ${key_var}=$(shell_quote "$API_KEY")"
    stores_api_key=1
  elif [[ -n "$key_var" ]]; then
    key_line="# export ${key_var}=\"${key_placeholder}\"   # uncomment and add your key"
  else
    key_line='# no API key required for this provider'
  fi

  local block
  block=$(cat <<EOF
$MARKER_BEGIN
# https://github.com/arjunagi-a-rehman/dum-tum
source $(shell_quote "$INSTALL_DIR/$adapter")
$provider_line
$model_line
$variant_line
$key_line
$MARKER_END
EOF
)
  render_marked_block "$rc_file" "$MARKER_BEGIN" "$MARKER_END" dum-tum \
    "$block" "$stores_api_key" "$syntax_shell" || return 1
  queue_rendered_update
}

prepare_rc_updates() {
  if [[ "$DO_ZSH" -eq 1 ]]; then
    prepare_rc_block "$ZSHRC" "fixit.zsh" zsh || return 1
  fi
  if [[ "$DO_BASH" -eq 1 ]]; then
    prepare_rc_block "$BASHRC" "fixit.bash" bash || return 1
  fi
  prepare_bash_profile_loader
}

activate_install_transaction() {
  local parent placeholder i target temp backup
  validate_install_target || return 1
  parent="$(dirname "$INSTALL_DIR")"
  if [[ -e "$INSTALL_DIR" ]]; then
    TX_RUNTIME_HAD_OLD=1
    placeholder="$(mktemp -d "$parent/.dum-tum-backup.XXXXXX")" || return 1
    rmdir "$placeholder" || return 1
    TX_RUNTIME_BACKUP="$placeholder"
    TX_RUNTIME_STARTED=1
    mv "$INSTALL_DIR" "$TX_RUNTIME_BACKUP" || return 1
  else
    TX_RUNTIME_STARTED=1
  fi
  TX_RUNTIME_ACTIVE=1
  mv "$TX_STAGE" "$INSTALL_DIR" || return 1
  TX_STAGE=""

  for ((i=0; i<TX_RC_COUNT; i++)); do
    target="${TX_RC_TARGETS[$i]}"
    temp="${TX_RC_TEMPS[$i]}"
    if [[ "${TX_RC_EXISTED[$i]}" -eq 1 ]]; then
      placeholder="$(mktemp "$(dirname "$target")/.dum-tum-backup.XXXXXX")" || return 1
      rm -f "$placeholder" || return 1
      backup="$placeholder"
      TX_RC_BACKUPS[$i]="$backup"
      TX_RC_STARTED[$i]=1
      mv "$target" "$backup" || return 1
    else
      TX_RC_STARTED[$i]=1
    fi
    mv "$temp" "$target" || return 1
    TX_RC_TEMPS[$i]=""
    ok "Configured $target"
  done

  ok "Installed → $INSTALL_DIR"
}

complete_install_transaction() {
  local i backup cleanup_ok=1
  trap '' INT TERM
  [[ -z "$TX_RUNTIME_BACKUP" ]] || rm -rf "$TX_RUNTIME_BACKUP" || cleanup_ok=0
  for ((i=0; i<TX_RC_COUNT; i++)); do
    backup="${TX_RC_BACKUPS[$i]}"
    [[ -z "$backup" ]] || rm -f "$backup" || cleanup_ok=0
  done
  TX_ACTIVE=0
  trap - EXIT INT TERM
  if [[ "$cleanup_ok" -eq 0 ]]; then
    warn "Installation completed, but a transaction backup could not be removed"
  fi
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
    antigravity) ai_hint="Antigravity${MODEL:+ ($MODEL)}" ;;
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

  export FX_PROVIDER="opencode"   # or claude | codex | antigravity | openrouter | openai | anthropic | gemini | none
  export FX_MODEL="..."
  # key-based providers only:
  export OPENROUTER_API_KEY="sk-or-v1-..."   # or OPENAI_API_KEY / ANTHROPIC_API_KEY / GEMINI_API_KEY

Docs: https://github.com/arjunagi-a-rehman/dum-tum

EOF
}

remove_marked_block() {
  local rc_file="$1" begin="$2" end="$3" label="$4" target dir tmp mode
  [[ -e "$rc_file" || -L "$rc_file" ]] || return 1
  validate_marked_block "$rc_file" "$begin" "$end" "$label" || return 2
  target="$(resolve_rc_file "$rc_file")" || return 2
  [[ -f "$target" ]] || return 1
  grep -qxF "$begin" "$target" 2>/dev/null || return 1
  dir="$(dirname "$target")"
  mode="$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || true)"
  tmp="$(mktemp "$dir/.dum-tum-rc.XXXXXX")" || return 2
  awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip=1; next }
      $0 == end   { skip=0; next }
      !skip       { print }
    ' "$target" > "$tmp" || {
    rm -f "$tmp"
    return 2
  }
  [[ -z "$mode" ]] || chmod "$mode" "$tmp" || {
    rm -f "$tmp"
    return 2
  }
  mv "$tmp" "$target" || {
    rm -f "$tmp"
    return 2
  }
  ok "Updated $rc_file (removed dum-tum config)"
}

uninstall_rc() {
  remove_marked_block "$1" "$MARKER_BEGIN" "$MARKER_END" dum-tum
}

uninstall_fixit() {
  info "Uninstalling fixit…"
  local removed=0 rc=0

  validate_uninstall_target || return 1
  preflight_rc_uninstall || return 1
  uninstall_rc "$ZSHRC" || rc=$?
  case "$rc" in
    0) removed=1 ;;
    1) ;;
    *) return "$rc" ;;
  esac
  rc=0
  remove_marked_block "$BASH_PROFILE" "$BASH_PROFILE_MARKER_BEGIN" \
    "$BASH_PROFILE_MARKER_END" 'dum-tum bashrc loader' || rc=$?
  case "$rc" in
    0) removed=1 ;;
    1) ;;
    *) return "$rc" ;;
  esac
  rc=0
  uninstall_rc "$BASHRC" || rc=$?
  case "$rc" in
    0) removed=1 ;;
    1) ;;
    *) return "$rc" ;;
  esac

  if [[ -n "$UNINSTALL_TARGET" ]]; then
    remove_install_dir "$UNINSTALL_TARGET" || return 1
    removed=1
  else
    warn "Install dir not found: $INSTALL_DIR"
  fi

  if [[ "$removed" -eq 0 ]]; then
    warn "Nothing to uninstall."
  else
    ok "fixit uninstalled"
    echo ""
    echo "Restart your shell to drop the loaded hooks."
  fi
}

main() {
  validate_single_line_inputs
  if [[ "$DO_UNINSTALL" -eq 1 ]]; then
    uninstall_fixit
    return 0
  fi

  info "Installing fixit for ${OS_NAME}…"
  select_shells
  preflight_rc_updates
  validate_install_target
  install_deps
  load_existing_config
  begin_install_transaction
  stage_runtime
  detect_ai_clis "$TX_STAGE"
  select_provider
  maybe_ask_key
  select_model
  select_variant
  validate_provider_candidate
  test_ai
  prepare_rc_updates
  activate_install_transaction
  ensure_shell_default
  print_next_steps
  complete_install_transaction
}

main
