# shellcheck shell=bash
# fixit-common.sh — shared core sourced by fixit.zsh and fixit.bash
# Stage 1: local fuzzy matching (instant, offline)
# Stage 2: AI resolver (OpenRouter / OpenCode / Codex)

# Directory of this file (for fixit-ai.py)
if [[ -n "${ZSH_VERSION:-}" ]]; then
  eval '_FX_DIR="${0:A:h}"'
else
  _FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi
_FX_AI_PY="$_FX_DIR/fixit-ai.py"

# ---------- best-match: edit distance over candidates on stdin ----------
_fx_best() { python3 -c '
import sys
t=sys.argv[1].lower()
def dist(a,b):
    if abs(len(a)-len(b))>2: return 99
    m,n=len(a),len(b)
    D=[[0]*(n+1) for _ in range(m+1)]
    for i in range(m+1): D[i][0]=i
    for j in range(n+1): D[0][j]=j
    for i in range(1,m+1):
        for j in range(1,n+1):
            c=(a[i-1]!=b[j-1])
            D[i][j]=min(D[i-1][j]+1,D[i][j-1]+1,D[i-1][j-1]+c)
            if i>1 and j>1 and a[i-1]==b[j-2] and a[i-2]==b[j-1]:
                D[i][j]=min(D[i][j],D[i-2][j-2]+1)
    return D[m][n]
best,bd=None,99
for line in sys.stdin:
    c=line.strip()
    if not c: continue
    dd=dist(t,c.lower())
    if dd<bd or (dd==bd and best and len(c)<len(best)): best,bd=c,dd
    if bd==0: break
print(str(bd)+"\t"+(best or ""))' "$1"
}

_fx_ok() { local _max="${3:-1}"; (( $1 <= _max && $1 * 2 < $2 + 2 )); }  # $1=dist $2=len $3=max dist

# Auto-run gate (allowlist): only these read-only commands run without a
# confirm prompt. Anything else — destructive or not — asks first.
_FX_AUTORUN_SAFE=(ls pwd echo which type date whoami cat head tail wc stat file less more man)

# Only read-only commands where re-running is guaranteed safe.
_FX_SAFE=(cd cat ls less more head tail wc stat file vim nano vi bat open code)

# Multi-command tools where a non-zero exit usually means a bad subcommand or
# usage mistake (go to desktop, git psuh, npm runn build, …).
_FX_MULTICMD=(go git docker kubectl helm npm npx yarn pnpm brew gh aws gcloud az cargo pip pip3 make terraform systemctl apt apt-get snap dnf pacman gem bundle composer)

# Builtins/commands that are also common English words.
_FX_EN_CMDS=(where which who what find open type time help locate why how show get)

_fx_in_list() {  # $1=needle, rest=list
  local n="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$n" ]] && return 0
  done
  return 1
}

# True when every arg looks like plain English (not a flag/path/existing file).
_fx_looks_like_nl() {
  (( $# == 0 )) && return 1
  local a
  for a in "$@"; do
    [[ "$a" == -* || "$a" == */* || -e "$a" ]] && return 1
  done
  return 0
}

# Candidate command list (shell-specific syntax isolated via eval)
if [[ -n "${ZSH_VERSION:-}" ]]; then
  eval '_fx_all_commands() { print -rl -- ${(k)commands} ${(k)aliases} ${(k)functions} ${(k)builtins} }'
else
  _fx_all_commands() { { compgen -c; compgen -A function; compgen -a; compgen -b; } 2>/dev/null | sort -u; }
fi

# Confirm/run a suggestion. Enter = run · e = edit then run · n / Ctrl-C = cancel
_fx_confirm_run() {
  local cmd="$1" key
  [[ -z "$cmd" ]] && return 1
  printf '\033[36m→ %s\033[0m\n' "$cmd" >&2
  printf '\033[36m[Enter] run  [e] edit  [n] cancel\033[0m ' >&2
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    IFS= read -r -k 1 key </dev/tty || return 1
  else
    IFS= read -r -n 1 key </dev/tty || return 1
  fi
  printf '\n' >&2
  case "$key" in
    $'\n'|$'\r'|'y'|'Y'|'')
      eval "$cmd"
      ;;
    e|E)
      printf '\033[36m$\033[0m ' >&2
      IFS= read -r cmd </dev/tty || return 1
      [[ -z "${cmd// /}" ]] && return 1
      eval "$cmd"
      ;;
    *)
      return 1
      ;;
  esac
}

# Shared command-not-found logic. $1 = unknown command, rest = args.
_fx_handle_not_found() {
  local cmd="$1"; shift
  local full="$cmd${*:+ $*}"
  local out d best

  # Natural language ("list all files") → AI, don't fuzzy-match the first word
  if _fx_looks_like_nl "$@"; then
    _fx_ai_resolve "$full"; return $?
  fi

  out=$(_fx_all_commands | _fx_best "$cmd")
  d=${out%%$'\t'*}; best=${out#*$'\t'}
  if [[ -n "$best" ]] && _fx_ok $d ${#cmd} 1; then
    if _fx_in_list "$best" "${_FX_AUTORUN_SAFE[@]}"; then
      printf '\033[33m↻ %s → %s\033[0m\n' "$cmd" "$best" >&2
      if "$best" "$@"; then
        return 0
      fi
      # Fuzzy guess was wrong — fall back to AI on original line
      _fx_ai_resolve "$full"; return $?
    else
      printf '\033[33m? %s not found — closest: %s (not auto-running)\033[0m\n' "'$cmd'" "$best" >&2
      _fx_confirm_run "$best${*:+ $*}" && return $?
    fi
  elif (( $# == 0 )) && [[ -n "$best" && $d -le 2 ]]; then
    printf '\033[33m? %s not found — closest: %s\033[0m\n' "'$cmd'" "$best" >&2
    _fx_confirm_run "$best" && return $?
  else
    _fx_ai_resolve "$full"; return $?
  fi
  return 127
}

# Ask before auto-sending a failed command line to a third-party AI provider.
_fx_confirm_ai_send() {
  local key
  printf '\033[33mSend this failed command to %s for a fix? [y/N] \033[0m' "${FX_PROVIDER:-openrouter}" >&2
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    IFS= read -r -k 1 key </dev/tty || return 1
  else
    IFS= read -r -n 1 key </dev/tty || return 1
  fi
  printf '\n' >&2
  [[ "$key" == y || "$key" == Y ]]
}

# Shared failed-command logic. $1 = exit code, rest = words of the failed line.
# Uses _FX_LASTFAIL / _FX_FIXED from the adapter hooks.
_fx_fix_failed_line() {
  local rc="$1"; shift
  (( $# == 0 )) && return
  if _fx_in_list "$1" "${_FX_SAFE[@]}"; then
    local head="$1"; shift
    local -a out_args=()
    local changed=0 arg out d fixed
    for arg in "$@"; do
      if (( changed )) || [[ "$arg" == -* || -e "$arg" ]]; then
        out_args+=("$arg"); continue
      fi
      out=$(find . -maxdepth 2 -not -path '*/.git*' 2>/dev/null | sed 's|^\./||' | _fx_best "$arg")
      d=${out%%$'\t'*}; fixed=${out#*$'\t'}
      if [[ -n "$fixed" ]] && _fx_ok $d ${#arg} 2; then
        printf '\033[33m↻ %s → %s\033[0m\n' "$arg" "$fixed" >&2
        out_args+=("$fixed"); changed=1
      else
        out_args+=("$arg")
      fi
    done
    if (( changed )); then
      _FX_FIXED=1
      local q
      printf -v q '%q ' "$head" "${out_args[@]}"
      eval "$q"
      return
    fi
    set -- "$head" "$@"
  fi
  # Failed multi-command tool → AI suggests the fix (still needs Enter).
  (( ${FX_AI_ON_FAIL:-1} )) || return
  _fx_ai_ready || return
  (( $# >= 2 )) || return
  _fx_in_list "$1" "${_FX_MULTICMD[@]}" || return
  _fx_confirm_ai_send || return
  _fx_ai_resolve "fix this failed command: $_FX_LASTFAIL"
}

# ================= Stage 2: AI resolver =================
# Providers: openrouter (default) | opencode | codex | none
FX_PROVIDER=${FX_PROVIDER:-openrouter}

_fx_ai_sys_prompt() {
  printf '%s' "You translate user intent or broken shell commands into ONE correct shell command line for their machine. Reply with ONLY the command on the first line — no markdown fences, no backticks, no explanation, no thinking, do not run anything. Use the user's own aliases when they fit. If the action is destructive or irreversible, prefix with: # DANGER: "
}

# Mask common secret shapes before anything is sent to an AI provider.
_fx_redact_secrets() {  # stdin -> stdout
  sed -E \
    -e 's/(--password|--passwd|--token)(=|[[:space:]]+)[^[:space:]]+/\1\2[REDACTED]/g' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+-]+/\1[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9_-]{8,}/[REDACTED-KEY]/g' \
    -e 's/([A-Za-z_][A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWD|PASSWORD)[A-Za-z0-9_]*)=[^[:space:]'"'"']+/\1=[REDACTED]/g'
}

# Strip terminal control bytes (ANSI escapes, cursor moves) from untrusted text.
_fx_strip_ctrl() {  # stdin -> stdout (keeps newline/tab)
  sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g' | tr -d '\000-\010\013-\037\177'
}

_fx_ai_user_payload() {  # $* = intent
  local ctx als task
  ctx="OS: $(uname -sm); shell: $(_fx_shell_name); cwd: $PWD; files here: $(ls -1 2>/dev/null | tr -d '[:cntrl:]' | head -15 | tr '\n' ' ')"
  als="$(alias 2>/dev/null | _fx_strip_ctrl | head -30 | _fx_redact_secrets)"
  task="$(printf '%s' "$*" | _fx_strip_ctrl | _fx_redact_secrets)"
  printf '%s\nMy aliases:\n%s\nTask/failed input: %s' "$ctx" "$als" "$task"
}

_fx_shell_name() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then printf 'zsh'; else printf 'bash'; fi
}

_fx_ai_ready() {
  case "${FX_PROVIDER:-openrouter}" in
    openrouter) [[ -n "${OPENROUTER_API_KEY:-}" ]] ;;
    opencode)   command -v opencode >/dev/null 2>&1 ;;
    codex)      command -v codex >/dev/null 2>&1 ;;
    none|off|local|"") return 1 ;;
    *) return 1 ;;
  esac
}

_fx_ai_extract() {  # stdin: free text or JSON/JSONL -> one command on stdout
  python3 "$_FX_AI_PY" extract
}


_fx_ai_http() {  # $1=json body -> raw api response (overridable in tests)
  # Key and body go via stdin/tempfile, never argv (ps-visible to local users).
  local body_file rc
  body_file="$(mktemp "${TMPDIR:-/tmp}/fixit-body.XXXXXX")" || return 1
  printf '%s' "$1" > "$body_file"
  printf 'header = "Authorization: Bearer %s"\n' "$OPENROUTER_API_KEY" | \
    curl -sS --connect-timeout 10 --max-time 45 --retry 1 --retry-delay 1 \
      -K - -H "Content-Type: application/json" --data-binary @"$body_file" \
      https://openrouter.ai/api/v1/chat/completions
  rc=$?
  rm -f "$body_file"
  return $rc
}

_fx_ai_openrouter() {  # $* = intent
  local model="${FX_MODEL:-deepseek/deepseek-v4-flash}"
  local sys_p user_p body
  sys_p="$(_fx_ai_sys_prompt)"
  user_p="$(_fx_ai_user_payload "$@")"
  body=$(FX_SYS="$sys_p" FX_USER="$user_p" FX_MODEL="$model" python3 "$_FX_AI_PY" body)
  _fx_ai_http "$body" | _fx_ai_extract
}

# Portable timeout (no GNU timeout on stock macOS). Kills cmd after N secs.
_fx_timeout() {  # $1=seconds, $2...=cmd
  local secs="$1"; shift
  local tmpout rc=0
  tmpout="$(mktemp)"
  "$@" >"$tmpout" 2>/dev/null &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= secs )); then
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rc=124
      break
    fi
    sleep 1
    (( waited += 1 ))
  done
  (( rc == 0 )) && wait "$pid" 2>/dev/null
  cat "$tmpout"
  rm -f "$tmpout"
  return $rc
}

_fx_ai_opencode() {  # $* = intent
  local prompt margs=()
  prompt="$(_fx_ai_sys_prompt)"$'\n\n'"$(_fx_ai_user_payload "$@")"
  [[ -n "${FX_MODEL:-}" ]] && margs+=(-m "$FX_MODEL")
  [[ -n "${FX_VARIANT:-}" ]] && margs+=(--variant "$FX_VARIANT")
  _fx_timeout "${FX_AI_TIMEOUT:-90}" opencode run "${margs[@]}" --format json -- "$prompt" | _fx_ai_extract
}

_fx_ai_codex() {  # $* = intent
  local prompt out margs=()
  prompt="$(_fx_ai_sys_prompt)"$'\n\n'"$(_fx_ai_user_payload "$@")"
  [[ -n "${FX_MODEL:-}" ]] && margs+=(-m "$FX_MODEL")
  [[ -n "${FX_VARIANT:-}" ]] && margs+=(-c "model_reasoning_effort=\"$FX_VARIANT\"")
  out="$(mktemp)"
  # last message only; ephemeral; allow outside git repos
  # </dev/null so codex does not wait for extra stdin ("Reading additional input…")
  if _fx_timeout "${FX_AI_TIMEOUT:-90}" codex exec --ephemeral --skip-git-repo-check --color never \
      -o "$out" "${margs[@]}" -- "$prompt" </dev/null >/dev/null 2>&1; then
    _fx_ai_extract <"$out"
  else
    # fallback: capture stdout if -o failed / older CLI
    _fx_timeout "${FX_AI_TIMEOUT:-90}" codex exec --ephemeral --skip-git-repo-check --color never \
      "${margs[@]}" -- "$prompt" </dev/null 2>/dev/null | _fx_ai_extract
  fi
  rm -f "$out"
}

_fx_ai() {  # $* = intent or failed command -> prints one suggested command
  case "${FX_PROVIDER:-openrouter}" in
    openrouter) _fx_ai_openrouter "$@" ;;
    opencode)   _fx_ai_opencode "$@" ;;
    codex)      _fx_ai_codex "$@" ;;
    *) return 1 ;;
  esac
}

_fx_ai_resolve() {   # called with the full original line
  if ! _fx_ai_ready; then
    case "${FX_PROVIDER:-openrouter}" in
      openrouter)
        printf '\033[31m? set OPENROUTER_API_KEY for AI (or FX_PROVIDER=opencode|codex)\033[0m\n' >&2
        ;;
      opencode)
        printf '\033[31m? opencode not found on PATH\033[0m\n' >&2
        ;;
      codex)
        printf '\033[31m? codex not found on PATH\033[0m\n' >&2
        ;;
      *)
        printf '\033[31m? AI not configured (FX_PROVIDER=none)\033[0m\n' >&2
        ;;
    esac
    return 127
  fi
  printf '\033[36m…resolving\033[0m\n' >&2
  local sug
  sug="$(_fx_ai "$@" | _fx_strip_ctrl)"
  if [[ -z "$sug" ]]; then
    printf '\033[31m? AI gave no answer (timeout/network/auth?)\033[0m\n' >&2
    return 127
  fi
  _fx_confirm_run "$sug" && return $?
  return 127
}

# `fix` — send the last failed command for a corrected version
fix() { [[ -z "$_FX_LASTFAIL" ]] && { echo "nothing failed recently"; return; }; _fx_ai_resolve "fix this failed command: $_FX_LASTFAIL"; }
