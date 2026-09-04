# fixit.zsh — zsh adapter. Shared logic lives in fixit-common.sh.
# type → runs like plain terminal; only failures wake this up.

# Locate and source the shared core (same directory as this file)
_fx_dir="${0:A:h}"
_FX_ZSH_ADAPTER="$_fx_dir/fixit.zsh"
[[ -f "$_fx_dir/fixit-common.sh" ]] && source "$_fx_dir/fixit-common.sh"
unset _fx_dir

# Full-line English detector for the accept-line hook (3+ plain words, no shell syntax).
_fx_is_english_line() {
  local line="${1#"${1%%[![:space:]]*}"}"  # trim leading
  line="${line%"${line##*[![:space:]]}"}"  # trim trailing
  [[ -z "$line" ]] && return 1
  # reject shell operators / expansions / paths-with-slash in the raw line
  [[ "$line" == *['|><;&$()`\\']* || "$line" == */* ]] && return 1
  local -a w; w=(${(z)line})
  (( $#w < 3 )) && return 1
  # first word must be an English-collision command OR not a real command at all
  local head=$w[1]
  if ! _fx_in_list "$head" "${_FX_EN_CMDS[@]}"; then
    # real non-English command (git, npm, ls, …) → leave it alone
    (( ${+commands[$head]} || ${+builtins[$head]} || ${+aliases[$head]} || ${+functions[$head]} )) && return 1
  fi
  local a
  for a in $w; do
    [[ "$a" == -* || "$a" == *=* ]] && return 1
    # plain word: letters/digits with optional apostrophe or hyphen inside
    [[ "$a" =~ '^[A-Za-z0-9][A-Za-z0-9'\''-]*$' ]] || return 1
  done
  return 0
}

# Intercept English sentences at Enter, before builtins like `where` run.
_fx_accept_line() {
  local full="$BUFFER"
  if _fx_is_english_line "$full"; then
    BUFFER=""
    zle -I
    local _FX_ZLE_CONFIRM=1 _FX_ZLE_ACCEPT=0 _FX_ZLE_CMD=""
    _fx_ai_resolve "$full"
    if (( _FX_ZLE_ACCEPT )); then
      BUFFER="$_FX_ZLE_CMD"
      zle "$_FX_ZSH_SAVED_WIDGET"
    else
      [[ -n "$_FX_ZLE_CMD" ]] && BUFFER="$_FX_ZLE_CMD"
      zle reset-prompt
      zle end-of-line
    fi
    return
  fi
  zle "$_FX_ZSH_SAVED_WIDGET"
}

command_not_found_handler() {
  _fx_handle_not_found "$@"
}

_fx_preexec() { _FX_LAST="$1"; _FX_FIXED=0 }
_fx_precmd() {
  local rc=$?
  { (( rc == 0 )) || (( _FX_FIXED )) } && return
  [[ -z "$_FX_LAST" ]] && return
  _FX_LASTFAIL="$_FX_LAST (exit $rc)"          # remember for the `fix` command
  local line="$_FX_LAST"; _FX_LAST=""
  _fx_fix_failed_line "$rc" "$line"
}

dum_tum_unload() {
  [[ "${_FX_ZSH_LOADED:-0}" == 1 ]] || return 0
  autoload -Uz add-zsh-hook
  add-zsh-hook -d preexec _fx_preexec 2>/dev/null
  add-zsh-hook -d precmd _fx_precmd 2>/dev/null
  if [[ "$(zle -l -L accept-line 2>/dev/null)" == 'zle -N accept-line _fx_accept_line' ]] && \
     zle -l "$_FX_ZSH_SAVED_WIDGET" >/dev/null 2>&1; then
    zle -A "$_FX_ZSH_SAVED_WIDGET" accept-line
  fi
  zle -D "$_FX_ZSH_SAVED_WIDGET" 2>/dev/null
  unset _FX_ZSH_SAVED_WIDGET
  _FX_ZSH_LOADED=0
}

dum_tum_reload() {
  local adapter="$_FX_ZSH_ADAPTER"
  dum_tum_unload
  source "$adapter"
}

if [[ -o interactive && "${_FX_ZSH_LOADED:-0}" != 1 ]]; then
  autoload -Uz add-zsh-hook
  add-zsh-hook -d preexec _fx_preexec 2>/dev/null
  add-zsh-hook -d precmd _fx_precmd 2>/dev/null
  add-zsh-hook preexec _fx_preexec
  add-zsh-hook precmd _fx_precmd
  _FX_ZSH_WIDGET_COUNTER=$((${_FX_ZSH_WIDGET_COUNTER:-0} + 1))
  _FX_ZSH_SAVED_WIDGET="_dum_tum_saved_accept_line_$$_$_FX_ZSH_WIDGET_COUNTER"
  zle -A accept-line "$_FX_ZSH_SAVED_WIDGET"
  zle -N accept-line _fx_accept_line
  _FX_ZSH_LOADED=1
fi
