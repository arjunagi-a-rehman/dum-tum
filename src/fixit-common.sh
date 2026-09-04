# shellcheck shell=bash
# fixit-common.sh — shared core sourced by fixit.zsh and fixit.bash
# Stage 1: local fuzzy matching (instant, offline)
# Stage 2: AI resolver (OpenRouter / OpenCode / Claude / Codex / Antigravity)

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

# Confirm/run a suggestion. Enter = run · e = edit then run · anything else = cancel
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
  [[ -z "$key" ]] && key=$'\n'
  printf '\n' >&2
  case "$key" in
    $'\n'|$'\r')
      if [[ "${_FX_ZLE_CONFIRM:-0}" -eq 1 ]]; then
        _FX_ZLE_CMD="$cmd"
        _FX_ZLE_ACCEPT=1
      elif [[ "${_FX_READLINE_CONFIRM:-0}" -eq 1 ]]; then
        _FX_READLINE_CMD="$cmd"
        _FX_READLINE_ACCEPT=1
      else
        eval "$cmd"
      fi
      ;;
    e|E)
      if [[ "${_FX_ZLE_CONFIRM:-0}" -eq 1 ]]; then
        _FX_ZLE_CMD="$cmd"
        return 0
      elif [[ "${_FX_READLINE_CONFIRM:-0}" -eq 1 ]]; then
        _FX_READLINE_CMD="$cmd"
        _FX_READLINE_EDIT=1
        return 0
      elif [[ -n "${ZSH_VERSION:-}" ]]; then
        print -z -- "$cmd"   # prefill next prompt's line editor
        return 0
      fi
      IFS= read -r -e -i "$cmd" -p '$ ' cmd </dev/tty || return 1
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

# True when stdin contains a known secret shape — those lines are never sent to AI.
_fx_has_secrets() {  # stdin -> status
  python3 "$_FX_AI_PY" secrets-detect
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
  if printf '%s' "$_FX_LASTFAIL" | _fx_has_secrets; then
    printf '\033[33m? not sending to %s — line looks like it contains a secret\033[0m\n' "${FX_PROVIDER:-openrouter}" >&2
    return
  fi
  _fx_ai_resolve "fix this failed command: $_FX_LASTFAIL"
}

# ================= Stage 2: AI resolver =================
# Providers: openrouter (default) | openai | anthropic | gemini | opencode | claude | codex | antigravity | none
FX_PROVIDER=${FX_PROVIDER:-openrouter}

_fx_ai_sys_prompt() {
  printf '%s' "You translate user intent or broken shell commands into ONE correct shell command line for their machine. Reply with ONLY the command on the first line — no markdown fences, no backticks, no explanation, no thinking, do not run anything. Use the user's own aliases and project scripts (package.json scripts, make targets) when they fit. To start/run something, prefer the project's own script. On macOS, viewing/opening a file means the open command (e.g. open index.html for a browser, open -a Numbers file.xlsx); on Linux use xdg-open. If the action is destructive or irreversible, prefix with: # DANGER: "
}

_fx_redact_secrets() {  # stdin -> stdout
  python3 "$_FX_AI_PY" secrets-redact
}

# Strip terminal control bytes (ANSI escapes, cursor moves) from untrusted text.
_fx_strip_ctrl() {  # stdin -> stdout (keeps newline/tab)
  sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g' | tr -d '\000-\010\013-\037\177'
}

_fx_ai_user_payload() {  # $* = intent
  local ctx lsal proj als task
  ctx="OS: $(uname -sm); shell: $(_fx_shell_name); cwd: $PWD"
  lsal="$(ls -al 2>/dev/null | _fx_strip_ctrl | head -20 | _fx_redact_secrets)"
  proj="$(python3 "$_FX_AI_PY" proj 2>/dev/null | _fx_strip_ctrl | _fx_redact_secrets)"
  als="$(alias 2>/dev/null | _fx_strip_ctrl | head -30 | _fx_redact_secrets)"
  task="$(printf '%s' "$*" | _fx_strip_ctrl | _fx_redact_secrets)"
  printf '%s\nDirectory listing (ls -al):\n%s\nProject hints:\n%s\nMy aliases:\n%s\nTask/failed input: %s' "$ctx" "$lsal" "$proj" "$als" "$task"
}

_fx_shell_name() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then printf 'zsh'; else printf 'bash'; fi
}

_fx_help_has_options() {
  local help="$1"
  shift
  printf '%s\n' "$help" | python3 "$_FX_AI_PY" help-options "$@"
}

_fx_confinement_error() {
  printf '\033[31m? %s cannot prove read-only/no-tools support; update the CLI or choose an HTTP provider\033[0m\n' "$1" >&2
  return 126
}

_fx_antigravity_confinement_supported() {
  if [[ -z "${_FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED+x}" ]]; then
    local help
    _FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED=0
    if help="$(_fx_timeout "${FX_AI_READY_TIMEOUT:-10}" agy --help 2>&1)"; then
      if _fx_help_has_options "$help" --sandbox --mode=plan --disable-slash-commands \
          --input-format --output-format; then
        _FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED=1
      fi
    fi
  fi
  [[ "$_FX_ANTIGRAVITY_CONFINEMENT_SUPPORTED" == 1 ]]
}

_fx_antigravity_ready() {
  command -v agy >/dev/null 2>&1 || return 1
  if ! _fx_antigravity_confinement_supported; then
    _FX_ANTIGRAVITY_CONFINEMENT_FAILED=1
    return 1
  fi
  unset _FX_ANTIGRAVITY_CONFINEMENT_FAILED
  [[ "${_FX_ANTIGRAVITY_READY:-}" == "1" ]] && return 0
  local run_dir rc=0
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/fixit-agy-ready.XXXXXX")" || return 1
  (
    cd "$run_dir" || exit 1
    _fx_timeout "${FX_AI_READY_TIMEOUT:-10}" agy -p /usage --output-format text \
      --sandbox --mode plan --disable-slash-commands >/dev/null
  ) || rc=$?
  rm -rf "$run_dir"
  if (( rc == 0 )); then
    _FX_ANTIGRAVITY_READY=1
    return 0
  fi
  return 1
}

_fx_ai_ready() {
  case "${FX_PROVIDER:-openrouter}" in
    openrouter) [[ -n "${OPENROUTER_API_KEY:-}" ]] ;;
    openai)     [[ -n "${OPENAI_API_KEY:-}" ]] ;;
    anthropic)  [[ -n "${ANTHROPIC_API_KEY:-}" ]] ;;
    gemini)     [[ -n "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" ]] ;;
    opencode)   command -v opencode >/dev/null 2>&1 ;;
    claude)     command -v claude >/dev/null 2>&1 ;;
    codex)      command -v codex >/dev/null 2>&1 ;;
    antigravity) _fx_antigravity_ready ;;
    none|off|local|"") return 1 ;;
    *) return 1 ;;
  esac
}

_fx_ai_extract() {  # $1=provider output kind; stdin -> one command on stdout
  python3 "$_FX_AI_PY" extract "$1"
}

_fx_curl_config_header() {
  local value="$1"
  case "$value" in
    *$'\r'*|*$'\n'*) return 1 ;;
  esac
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf 'header = "%s"\n' "$value"
}

_fx_transport_extract() {
  local kind="$1" output rc=0
  shift
  output="$(mktemp "${TMPDIR:-/tmp}/fixit-output.XXXXXX")" || return 1
  "$@" >"$output" || rc=$?
  if (( rc == 0 )); then
    _fx_ai_extract "$kind" <"$output"
    rc=$?
  fi
  rm -f "$output"
  return "$rc"
}


_fx_ai_http() {  # $1=json body $2=url $3..=extra headers -> raw api response (overridable in tests)
  # Key (inside headers) and body go via stdin/tempfile, never argv (ps-visible to local users).
  local body="$1" url="$2" body_file rc h
  shift 2
  for h in "$@"; do
    _fx_curl_config_header "$h" >/dev/null || return 2
  done
  body_file="$(mktemp "${TMPDIR:-/tmp}/fixit-body.XXXXXX")" || return 1
  printf '%s' "$body" > "$body_file"
  for h in "$@"; do _fx_curl_config_header "$h"; done | \
    curl -sS --connect-timeout 10 --max-time 45 --retry 1 --retry-delay 1 \
      -K - -H "Content-Type: application/json" --data-binary @"$body_file" \
      "$url"
  rc=$?
  rm -f "$body_file"
  return $rc
}

_fx_ai_openrouter() {  # $* = intent
  local model="${FX_MODEL:-deepseek/deepseek-v4-flash}"
  local sys_p user_p body
  sys_p="$(_fx_ai_sys_prompt)"
  user_p="$(_fx_ai_user_payload "$@")"
  body=$(FX_SYS="$sys_p" FX_USER="$user_p" FX_MODEL="$model" python3 "$_FX_AI_PY" body-openrouter)
  _fx_transport_extract chat _fx_ai_http "$body" \
    https://openrouter.ai/api/v1/chat/completions \
    "Authorization: Bearer $OPENROUTER_API_KEY"
}

_fx_ai_openai() {  # $* = intent
  local model="${FX_MODEL:-gpt-4o-mini}"
  local sys_p user_p body
  sys_p="$(_fx_ai_sys_prompt)"
  user_p="$(_fx_ai_user_payload "$@")"
  body=$(FX_SYS="$sys_p" FX_USER="$user_p" FX_MODEL="$model" python3 "$_FX_AI_PY" body-openai)
  _fx_transport_extract chat _fx_ai_http "$body" \
    https://api.openai.com/v1/chat/completions \
    "Authorization: Bearer $OPENAI_API_KEY"
}

_fx_ai_anthropic() {  # $* = intent
  local model="${FX_MODEL:-claude-sonnet-4-5}"
  local sys_p user_p body
  sys_p="$(_fx_ai_sys_prompt)"
  user_p="$(_fx_ai_user_payload "$@")"
  body=$(FX_SYS="$sys_p" FX_USER="$user_p" FX_MODEL="$model" python3 "$_FX_AI_PY" body-anthropic)
  _fx_transport_extract anthropic _fx_ai_http "$body" \
    https://api.anthropic.com/v1/messages \
    "x-api-key: $ANTHROPIC_API_KEY" "anthropic-version: 2023-06-01"
}

_fx_ai_gemini() {  # $* = intent
  local model="${FX_MODEL:-gemini-2.5-flash}"
  local sys_p user_p body key
  sys_p="$(_fx_ai_sys_prompt)"
  user_p="$(_fx_ai_user_payload "$@")"
  body=$(FX_SYS="$sys_p" FX_USER="$user_p" python3 "$_FX_AI_PY" body-gemini)
  key="${GEMINI_API_KEY:-$GOOGLE_API_KEY}"
  _fx_transport_extract gemini _fx_ai_http "$body" \
    "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent" \
    "x-goog-api-key: $key"
}

_fx_timeout() {  # $1=seconds, $2...=cmd
  local secs="$1"; shift
  python3 "$_FX_AI_PY" timeout "$secs" "$@"
}

_fx_opencode_confinement_supported() {
  if [[ -z "${_FX_OPENCODE_CONFINEMENT_SUPPORTED+x}" ]]; then
    local help
    _FX_OPENCODE_CONFINEMENT_SUPPORTED=0
    if help="$(_fx_timeout "${FX_AI_READY_TIMEOUT:-10}" opencode run --help 2>&1)" && \
        _fx_help_has_options "$help" --pure --format; then
      _FX_OPENCODE_CONFINEMENT_SUPPORTED=1
    fi
  fi
  [[ "$_FX_OPENCODE_CONFINEMENT_SUPPORTED" == 1 ]] || return 1

  local deny_config resolved
  deny_config='{"permission":{"*":"deny"},"tools":{"*":false}}'
  resolved="$(OPENCODE_CONFIG_CONTENT="$deny_config" \
    _fx_timeout "${FX_AI_READY_TIMEOUT:-10}" opencode debug config --pure 2>&1)" && \
    printf '%s' "$resolved" | python3 "$_FX_AI_PY" opencode-config-deny
}

_fx_ai_opencode() {  # $* = intent
  local prompt deny_config margs=()
  _fx_opencode_confinement_supported || { _fx_confinement_error opencode; return; }
  prompt="$(_fx_ai_sys_prompt)"$'\n\n'"$(_fx_ai_user_payload "$@")"
  deny_config='{"permission":{"*":"deny"},"tools":{"*":false}}'
  [[ -n "${FX_MODEL:-}" ]] && margs+=(-m "$FX_MODEL")
  [[ -n "${FX_VARIANT:-}" ]] && margs+=(--variant "$FX_VARIANT")
  OPENCODE_CONFIG_CONTENT="$deny_config" _fx_transport_extract opencode \
    _fx_timeout "${FX_AI_TIMEOUT:-90}" opencode run --pure \
      "${margs[@]}" --format json -- "$prompt"
}

_fx_claude_confinement_supported() {
  if [[ -z "${_FX_CLAUDE_CONFINEMENT_SUPPORTED+x}" ]]; then
    local help
    _FX_CLAUDE_CONFINEMENT_SUPPORTED=0
    if help="$(_fx_timeout "${FX_AI_READY_TIMEOUT:-10}" claude --help 2>&1)"; then
      if _fx_help_has_options "$help" --tools --permission-mode=plan --safe-mode \
          --disable-slash-commands --strict-mcp-config --mcp-config \
          --no-session-persistence; then
        _FX_CLAUDE_CONFINEMENT_SUPPORTED=1
      fi
    fi
  fi
  [[ "$_FX_CLAUDE_CONFINEMENT_SUPPORTED" == 1 ]]
}

_fx_ai_claude() {  # $* = intent
  local prompt margs=()
  _fx_claude_confinement_supported || { _fx_confinement_error claude; return; }
  prompt="$(_fx_ai_sys_prompt)"$'\n\n'"$(_fx_ai_user_payload "$@")"
  [[ -n "${FX_MODEL:-}" ]] && margs+=(--model "$FX_MODEL")
  [[ -n "${FX_VARIANT:-}" ]] && margs+=(--effort "$FX_VARIANT")
  # Prompt via stdin so it is not visible in `ps` to other local users.
  printf '%s' "$prompt" | _fx_transport_extract claude \
    _fx_timeout "${FX_AI_TIMEOUT:-90}" claude -p \
      --output-format json --max-turns 1 --tools "" \
      --permission-mode plan --safe-mode --disable-slash-commands \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --no-session-persistence "${margs[@]}"
}

_fx_codex_confinement_supported() {
  if [[ -z "${_FX_CODEX_CAPABILITIES_CHECKED+x}" ]]; then
    local help
    help="$(_fx_timeout "${FX_AI_READY_TIMEOUT:-10}" codex exec --help 2>&1)" || help=""
    _FX_CODEX_CAPABILITIES_CHECKED=1
    _FX_CODEX_CONFINEMENT_SUPPORTED=0
    if _fx_help_has_options "$help" --sandbox=read-only --ignore-user-config \
        --ignore-rules --ephemeral; then
      _FX_CODEX_CONFINEMENT_SUPPORTED=1
    fi
    if _fx_help_has_options "$help" --output-last-message; then
      _FX_CODEX_OUTPUT_FILE_OPTION=--output-last-message
    elif _fx_help_has_options "$help" -o; then
      _FX_CODEX_OUTPUT_FILE_OPTION=-o
    else
      _FX_CODEX_OUTPUT_FILE_OPTION=""
    fi
  fi
  [[ "$_FX_CODEX_CONFINEMENT_SUPPORTED" == 1 ]]
}

_fx_ai_codex() {  # $* = intent
  local prompt out run_dir rc=0 margs=()
  _fx_codex_confinement_supported || { _fx_confinement_error codex; return; }
  prompt="$(_fx_ai_sys_prompt)"$'\n\n'"$(_fx_ai_user_payload "$@")"
  [[ -n "${FX_MODEL:-}" ]] && margs+=(-m "$FX_MODEL")
  [[ -n "${FX_VARIANT:-}" ]] && margs+=(-c "model_reasoning_effort=\"$FX_VARIANT\"")
  out="$(mktemp)" || return 1
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/fixit-codex.XXXXXX")" || { rm -f "$out"; return 1; }
  # last message only; ephemeral; allow outside git repos
  # </dev/null so codex does not wait for extra stdin ("Reading additional input…")
  if [[ -n "$_FX_CODEX_OUTPUT_FILE_OPTION" ]]; then
    (
      cd "$run_dir" || exit 1
      _fx_timeout "${FX_AI_TIMEOUT:-90}" codex exec --ephemeral --skip-git-repo-check --color never \
        --sandbox read-only --ignore-user-config --ignore-rules \
        "$_FX_CODEX_OUTPUT_FILE_OPTION" "$out" "${margs[@]}" -- "$prompt" </dev/null >/dev/null
    ) || rc=$?
  else
    (
      cd "$run_dir" || exit 1
      _fx_timeout "${FX_AI_TIMEOUT:-90}" codex exec --ephemeral --skip-git-repo-check --color never \
        --sandbox read-only --ignore-user-config --ignore-rules \
        "${margs[@]}" -- "$prompt" </dev/null >"$out"
    ) || rc=$?
  fi
  if (( rc == 0 )); then
    _fx_ai_extract plain <"$out"
    rc=$?
  fi
  rm -rf "$run_dir"
  rm -f "$out"
  return "$rc"
}

_fx_ai_antigravity() {  # $* = intent
  local prompt body run_dir response rc=0 margs=()
  _fx_antigravity_confinement_supported || { _fx_confinement_error antigravity; return; }
  prompt="$(_fx_ai_sys_prompt)"$'\n\n'"$(_fx_ai_user_payload "$@")"
  body="$(printf '%s' "$prompt" | python3 "$_FX_AI_PY" body-antigravity)"
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/fixit-agy.XXXXXX")" || return 1
  [[ -n "${FX_MODEL:-}" ]] && margs+=(--model "$FX_MODEL")
  [[ -n "${FX_VARIANT:-}" ]] && margs+=(--effort "$FX_VARIANT")
  response="$(printf '%s\n' "$body" | (
    cd "$run_dir" || exit 1
    _fx_transport_extract antigravity _fx_timeout "${FX_AI_TIMEOUT:-90}" \
      agy --input-format stream-json \
      --output-format stream-json --sandbox --mode plan \
      --disable-slash-commands "${margs[@]}"
  ))" || rc=$?
  rm -rf "$run_dir"
  (( rc == 0 )) || return "$rc"
  printf '%s\n' "$response"
}

_fx_ai() {  # $* = intent or failed command -> prints one suggested command
  case "${FX_PROVIDER:-openrouter}" in
    openrouter) _fx_ai_openrouter "$@" ;;
    openai)     _fx_ai_openai "$@" ;;
    anthropic)  _fx_ai_anthropic "$@" ;;
    gemini)     _fx_ai_gemini "$@" ;;
    opencode)   _fx_ai_opencode "$@" ;;
    claude)     _fx_ai_claude "$@" ;;
    codex)      _fx_ai_codex "$@" ;;
    antigravity) _fx_ai_antigravity "$@" ;;
    *) return 1 ;;
  esac
}

_fx_ai_resolve() {   # called with the full original line
  if ! _fx_ai_ready; then
    case "${FX_PROVIDER:-openrouter}" in
      openrouter)
        printf '\033[31m? set OPENROUTER_API_KEY for AI (or FX_PROVIDER=openai|anthropic|gemini|opencode|claude|codex|antigravity)\033[0m\n' >&2
        ;;
      openai)
        printf '\033[31m? set OPENAI_API_KEY for AI\033[0m\n' >&2
        ;;
      anthropic)
        printf '\033[31m? set ANTHROPIC_API_KEY for AI\033[0m\n' >&2
        ;;
      gemini)
        printf '\033[31m? set GEMINI_API_KEY (or GOOGLE_API_KEY) for AI\033[0m\n' >&2
        ;;
      opencode)
        printf '\033[31m? opencode not found on PATH\033[0m\n' >&2
        ;;
      claude)
        printf '\033[31m? claude not found on PATH\033[0m\n' >&2
        ;;
      codex)
        printf '\033[31m? codex not found on PATH\033[0m\n' >&2
        ;;
      antigravity)
        if [[ "${_FX_ANTIGRAVITY_CONFINEMENT_FAILED:-}" == 1 ]]; then
          _fx_confinement_error antigravity
          return $?
        elif command -v agy >/dev/null 2>&1; then
          printf '\033[31m? agy authentication check failed; run agy to sign in and retry\033[0m\n' >&2
        else
          printf '\033[31m? agy not found on PATH\033[0m\n' >&2
        fi
        ;;
      *)
        printf '\033[31m? AI not configured (FX_PROVIDER=none)\033[0m\n' >&2
        ;;
    esac
    return 127
  fi
  printf '\033[36m…resolving\033[0m\n' >&2
  local sug output rc=0
  output="$(mktemp "${TMPDIR:-/tmp}/fixit-resolve.XXXXXX")" || return 1
  _fx_ai "$@" >"$output" || rc=$?
  if (( rc != 0 )); then
    rm -f "$output"
    return "$rc"
  fi
  sug="$(_fx_strip_ctrl <"$output")"
  rm -f "$output"
  if [[ -z "$sug" ]]; then
    printf '\033[31m? AI gave no answer (timeout/network/auth?)\033[0m\n' >&2
    return 127
  fi
  _fx_confirm_run "$sug" && return $?
  return 127
}

# `fix` — send the last failed command for a corrected version
fix() {
  [[ -z "$_FX_LASTFAIL" ]] && { echo "nothing failed recently"; return; }
  if printf '%s' "$_FX_LASTFAIL" | _fx_has_secrets; then
    printf '\033[33m? not sending to %s — line looks like it contains a secret\033[0m\n' "${FX_PROVIDER:-openrouter}" >&2
    return 1
  fi
  _fx_ai_resolve "fix this failed command: $_FX_LASTFAIL"
}
