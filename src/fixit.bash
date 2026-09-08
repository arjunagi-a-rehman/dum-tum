# fixit.bash — bash adapter (bash 4+). Shared logic lives in fixit-common.sh.
# type → runs like plain terminal; only failures wake this up.

# Locate and source the shared core (same directory as this file)
_fx_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_FX_BASH_ADAPTER="$_fx_dir/fixit.bash"
[[ -f "$_fx_dir/fixit-common.sh" ]] && source "$_fx_dir/fixit-common.sh"
unset _fx_dir

if [[ "${_FX_BASH_CNF_INSTALLED:-0}" != 1 ]]; then
  _FX_BASH_PREV_CNF="$(declare -f command_not_found_handle)"
  _FX_BASH_CNF_INSTALLED=1
fi

command_not_found_handle() {
  _fx_handle_not_found "$@"
  return $?
}

_FX_BASH_OWN_CNF="$(declare -f command_not_found_handle)"

_fx_preexec() { _FX_LAST="$1"; _FX_FIXED=0; }

_fx_precmd() {
  local rc=$?
  (( $# )) && rc="$1"
  { (( rc == 0 )) || (( _FX_FIXED )); } && return
  [[ -z "$_FX_LAST" ]] && return
  _FX_LASTFAIL="$_FX_LAST (exit $rc)"          # remember for the `fix` command
  local line="$_FX_LAST"
  _FX_LAST=""
  _fx_fix_failed_line "$rc" "$line"
}

_fx_bash_capture_binding() {
  local key="$1" line
  _FX_BASH_CAPTURE_TYPE=none
  _FX_BASH_CAPTURE_VALUE=""
  while IFS= read -r line; do
    if [[ "${line%%: *}" == "\"$key\"" ]]; then
      _FX_BASH_CAPTURE_TYPE=shell
      _FX_BASH_CAPTURE_VALUE="${line#*: }"
      return
    fi
  done < <(bind -m "$_FX_BASH_KEYMAP" -X 2>/dev/null)
  while IFS= read -r line; do
    if [[ "${line%%: *}" == "\"$key\"" ]]; then
      _FX_BASH_CAPTURE_TYPE=macro
      _FX_BASH_CAPTURE_VALUE="${line#*: }"
      return
    fi
  done < <(bind -m "$_FX_BASH_KEYMAP" -s 2>/dev/null)
  while IFS= read -r line; do
    if [[ "${line%%: *}" == "\"$key\"" ]]; then
      _FX_BASH_CAPTURE_TYPE=function
      _FX_BASH_CAPTURE_VALUE="${line#*: }"
      return
    fi
  done < <(bind -m "$_FX_BASH_KEYMAP" -p 2>/dev/null)
}

_fx_bash_apply_binding() {
  local key="$1" type="$2" value="$3"
  bind -m "$_FX_BASH_KEYMAP" -r "$key" 2>/dev/null
  case "$type" in
    shell) bind -m "$_FX_BASH_KEYMAP" -x "\"$key\": $value" 2>/dev/null ;;
    macro|function) bind -m "$_FX_BASH_KEYMAP" "\"$key\": $value" 2>/dev/null ;;
  esac
}

_fx_bash_install_enter_fallback() {
  if [[ "${_FX_BASH_BIND_TYPES[0]}" == none ]]; then
    bind -m "$_FX_BASH_KEYMAP" '"\C-xfa": accept-line' 2>/dev/null
  else
    _fx_bash_apply_binding '\C-xfa' "${_FX_BASH_BIND_TYPES[0]}" "${_FX_BASH_BIND_VALUES[0]}"
  fi
}

_fx_bash_restore_prompt_command() {
  [[ -n "${PROMPT_COMMAND+x}" ]] || return 0
  local current_decl
  current_decl="$(declare -p PROMPT_COMMAND 2>/dev/null)"
  if [[ "$current_decl" == declare\ -a* ]]; then
    local -a remaining_prompts=()
    local i removed=0
    for (( i=0; i<${#PROMPT_COMMAND[@]}; i++ )); do
      if [[ "$removed" -eq 0 && "${PROMPT_COMMAND[i]}" == _fx_prompt_hook ]]; then
        removed=1
      else
        remaining_prompts+=("${PROMPT_COMMAND[i]}")
      fi
    done
    if [[ "$removed" -eq 1 ]]; then
      if (( ${#remaining_prompts[@]} )); then
        PROMPT_COMMAND=("${remaining_prompts[@]}")
      elif [[ "$_FX_BASH_PREV_PROMPT_SET" == 1 ]]; then
        PROMPT_COMMAND=()
      else
        unset PROMPT_COMMAND
      fi
    fi
  else
    local current="${PROMPT_COMMAND-}" remaining_prompt="" before after
    case "$current" in
      _fx_prompt_hook) ;;
      _fx_prompt_hook\;*) remaining_prompt="${current#_fx_prompt_hook;}" ;;
      *\;_fx_prompt_hook\;*)
        before="${current%%;_fx_prompt_hook;*}"
        after="${current#"$before;_fx_prompt_hook;"}"
        remaining_prompt="$before;$after"
        ;;
      *\;_fx_prompt_hook) remaining_prompt="${current%;_fx_prompt_hook}" ;;
      *) return 0 ;;
    esac
    if [[ -n "$remaining_prompt" || "$_FX_BASH_PREV_PROMPT_SET" == 1 ]]; then
      builtin printf -v PROMPT_COMMAND '%s' "$remaining_prompt"
    else
      unset PROMPT_COMMAND
    fi
  fi
}

_fx_bash_unload_state() {
  [[ "${_FX_BASH_LOADED:-0}" == 1 ]] || return 0
  if [[ "$(declare -f command_not_found_handle)" == "$_FX_BASH_OWN_CNF" ]]; then
    unset -f command_not_found_handle
    [[ -z "$_FX_BASH_PREV_CNF" ]] || eval "$_FX_BASH_PREV_CNF"
  fi
  _FX_BASH_CNF_INSTALLED=0
  _fx_bash_restore_prompt_command
  if (( ${BASH_VERSINFO[0]} >= 4 )); then
    local i
    for (( i=0; i<${#_FX_BASH_BIND_KEYS[@]}; i++ )); do
      _fx_bash_capture_binding "${_FX_BASH_BIND_KEYS[i]}"
      if [[ "$_FX_BASH_CAPTURE_TYPE" == "${_FX_BASH_OWN_BIND_TYPES[i]}" && \
            "$_FX_BASH_CAPTURE_VALUE" == "${_FX_BASH_OWN_BIND_VALUES[i]}" ]]; then
        _fx_bash_apply_binding "${_FX_BASH_BIND_KEYS[i]}" "${_FX_BASH_BIND_TYPES[i]}" "${_FX_BASH_BIND_VALUES[i]}"
      fi
    done
    unset _FX_BASH_CAPTURE_TYPE _FX_BASH_CAPTURE_VALUE
  fi
  _FX_BASH_LOADED=0
}

dum_tum_unload() {
  _fx_bash_unload_state
}

dum_tum_reload() {
  local adapter="$_FX_BASH_ADAPTER"
  _fx_bash_unload_state
  builtin source "$adapter"
}

# Only hook interactive shells
if [[ $- == *i* ]]; then
  _fx_prompt_hook() {
    local rc=$?
    if [[ "${_FX_BASH_READLINE_CAPTURED:-0}" != 1 ]]; then
      local last_history
      last_history="$(HISTTIMEFORMAT='' builtin history 1)"
      last_history="${last_history#"${last_history%%[![:space:]]*}"}"
      last_history="${last_history#*[[:space:]]}"
      last_history="${last_history#"${last_history%%[![:space:]]*}"}"
      [[ -z "$last_history" ]] || _fx_preexec "$last_history"
    fi
    _FX_BASH_READLINE_CAPTURED=0
    _fx_precmd "$rc"
    return "$rc"
  }

  if (( ${BASH_VERSINFO[0]} >= 4 )); then
    _fx_accept_line() {
      _FX_BASH_READLINE_CAPTURED=1
      _fx_preexec "$READLINE_LINE"
      if _fx_is_english_line "$READLINE_LINE"; then
        local full="$READLINE_LINE"
        local _FX_READLINE_CONFIRM=1 _FX_READLINE_ACCEPT=0 _FX_READLINE_EDIT=0 _FX_READLINE_CMD=""
        READLINE_LINE=""
        printf '\n'
        _fx_ai_resolve "$full"
        if (( _FX_READLINE_ACCEPT )); then
          READLINE_LINE="$_FX_READLINE_CMD"
          READLINE_POINT=${#READLINE_LINE}
          _fx_preexec "$READLINE_LINE"
        elif (( _FX_READLINE_EDIT )); then
          READLINE_LINE="$_FX_READLINE_CMD"
          READLINE_POINT=${#READLINE_LINE}
          _FX_LAST=""
          bind -m "$_FX_BASH_KEYMAP" '"\C-xfa": "\C-xfr"' 2>/dev/null
        else
          _FX_LAST=""
        fi
      fi
    }
    _fx_resume_edit() {
      _fx_bash_install_enter_fallback
    }
    _fx_is_english_line() {
      local line="${1#"${1%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && return 1
      [[ "$line" == *['|><;&$()`\\']* || "$line" == */* ]] && return 1
      local -a w
      read -ra w <<< "$line"
      (( ${#w[@]} < 3 )) && return 1
      local head="${w[0]}"
      if ! _fx_in_list "$head" "${_FX_EN_CMDS[@]}"; then
        type -t "$head" >/dev/null 2>&1 && return 1
      fi
      local a
      for a in "${w[@]}"; do
        [[ "$a" == -* || "$a" == *=* ]] && return 1
        [[ "$a" =~ ^[A-Za-z0-9][A-Za-z0-9\'-]*$ ]] || return 1
      done
      return 0
    }
  fi

  if [[ "${_FX_BASH_LOADED:-0}" != 1 ]]; then
    _FX_BASH_PREV_PROMPT_SET=0
    [[ -n "${PROMPT_COMMAND+x}" ]] && _FX_BASH_PREV_PROMPT_SET=1
    _FX_BASH_PREV_PROMPT_ARRAY=0
    _fx_prompt_decl="$(declare -p PROMPT_COMMAND 2>/dev/null)"
    [[ "$_fx_prompt_decl" == declare\ -a* ]] && _FX_BASH_PREV_PROMPT_ARRAY=1
    unset _fx_prompt_decl

    if [[ "$_FX_BASH_PREV_PROMPT_ARRAY" == 1 ]]; then
      if (( ${#PROMPT_COMMAND[@]} )); then
        PROMPT_COMMAND=("_fx_prompt_hook" "${PROMPT_COMMAND[@]}")
      else
        PROMPT_COMMAND=("_fx_prompt_hook")
      fi
    else
      _fx_previous_prompt="${PROMPT_COMMAND-}"
      builtin printf -v PROMPT_COMMAND '%s' "_fx_prompt_hook${_fx_previous_prompt:+;$_fx_previous_prompt}"
      unset _fx_previous_prompt
    fi

    if (( ${BASH_VERSINFO[0]} >= 4 )); then
      _FX_BASH_KEYMAP="$(bind -v 2>/dev/null | sed -n 's/^set keymap //p')"
      _FX_BASH_KEYMAP="${_FX_BASH_KEYMAP:-emacs-standard}"
      _FX_BASH_BIND_KEYS=('\C-m' '\C-xfx' '\C-xfr' '\C-xfa')
      _FX_BASH_BIND_TYPES=()
      _FX_BASH_BIND_VALUES=()
      for _fx_bind_key in "${_FX_BASH_BIND_KEYS[@]}"; do
        _fx_bash_capture_binding "$_fx_bind_key"
        _FX_BASH_BIND_TYPES+=("$_FX_BASH_CAPTURE_TYPE")
        _FX_BASH_BIND_VALUES+=("$_FX_BASH_CAPTURE_VALUE")
      done
      unset _fx_bind_key _FX_BASH_CAPTURE_TYPE _FX_BASH_CAPTURE_VALUE
      bind -m "$_FX_BASH_KEYMAP" -x '"\C-xfx": _fx_accept_line' 2>/dev/null
      bind -m "$_FX_BASH_KEYMAP" -x '"\C-xfr": _fx_resume_edit' 2>/dev/null
      _fx_bash_install_enter_fallback
      bind -m "$_FX_BASH_KEYMAP" '"\C-m": "\C-xfx\C-xfa"' 2>/dev/null
      _FX_BASH_OWN_BIND_TYPES=()
      _FX_BASH_OWN_BIND_VALUES=()
      for _fx_bind_key in "${_FX_BASH_BIND_KEYS[@]}"; do
        _fx_bash_capture_binding "$_fx_bind_key"
        _FX_BASH_OWN_BIND_TYPES+=("$_FX_BASH_CAPTURE_TYPE")
        _FX_BASH_OWN_BIND_VALUES+=("$_FX_BASH_CAPTURE_VALUE")
      done
      unset _fx_bind_key _FX_BASH_CAPTURE_TYPE _FX_BASH_CAPTURE_VALUE
    fi
    _FX_BASH_LOADED=1
  fi
fi
