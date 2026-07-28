# fixit.bash — bash adapter (bash 4+). Shared logic lives in fixit-common.sh.
# type → runs like plain terminal; only failures wake this up.

# Locate and source the shared core (same directory as this file)
_fx_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[[ -f "$_fx_dir/fixit-common.sh" ]] && source "$_fx_dir/fixit-common.sh"
unset _fx_dir

command_not_found_handle() {
  _fx_handle_not_found "$@"
  return $?
}

_fx_preexec() { _FX_LAST="$1"; _FX_FIXED=0; }

_fx_precmd() {
  local rc=$?
  { (( rc == 0 )) || (( _FX_FIXED )); } && return
  [[ -z "$_FX_LAST" ]] && return
  _FX_LASTFAIL="$_FX_LAST (exit $rc)"          # remember for the `fix` command
  local -a w
  read -ra w <<< "$_FX_LAST"
  _FX_LAST=""
  (( ${#w[@]} )) && _fx_fix_failed_line "$rc" "${w[@]}"
}

# Only hook interactive shells
if [[ $- == *i* ]]; then
  # DEBUG trap as preexec: capture the command line about to run.
  _fx_debug_trap() {
    [[ -n "${COMP_LINE:-}" ]] && return        # inside completion
    case "$BASH_COMMAND" in
      _fx_*|*"_fx_precmd"*|*PROMPT_COMMAND*) return ;;
    esac
    [[ "$_FX_AT_PROMPT" == "1" ]] || return    # only first command after a prompt
    _FX_AT_PROMPT=0
    _fx_preexec "$BASH_COMMAND"
  }
  _FX_AT_PROMPT=1
  _fx_prompt_hook() { _fx_precmd; _FX_AT_PROMPT=1; }
  trap '_fx_debug_trap' DEBUG
  PROMPT_COMMAND="_fx_prompt_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

  # Intercept English sentences at Enter (bash 4+ readline vars).
  # Ctrl-M first runs our function, then accept-line (\C-j) submits what's left.
  if (( ${BASH_VERSINFO[0]} >= 4 )); then
    _fx_accept_line() {
      if _fx_is_english_line "$READLINE_LINE"; then
        local full="$READLINE_LINE"
        READLINE_LINE=""
        printf '\n'
        _fx_ai_resolve "$full"
      fi
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
    bind -x '"\C-xfx": _fx_accept_line' 2>/dev/null
    bind '"\C-m": "\C-xfx\C-j"' 2>/dev/null
  fi
fi
