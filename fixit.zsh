# fixit.zsh — zsh adapter. Shared logic lives in fixit-common.sh.
# type → runs like plain terminal; only failures wake this up.

# Locate and source the shared core (same directory as this file)
_fx_dir="${0:A:h}"
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
    _fx_ai_resolve "$full"
    zle reset-prompt
    return
  fi
  zle .accept-line
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
  local -a w; w=(${(z)_FX_LAST}); _FX_LAST=""
  _fx_fix_failed_line "$rc" "${w[@]}"
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _fx_preexec
add-zsh-hook precmd  _fx_precmd
# Catch English sentences before builtins (where/which/find/…) execute them
zle -N accept-line _fx_accept_line
