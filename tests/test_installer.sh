#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

assert_runtime_matches_repo() {
  local install_dir="$1" f
  for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py; do
    cmp "$ROOT/src/$f" "$install_dir/$f"
  done
  grep -qxF 'dum-tum-install-v1' "$install_dir/.dum-tum-install"
}

assert_config_round_trip() {
  local shell_bin="$1" rc_file="$2" provider="$3" model="$4" variant="$5" key="$6"
  "$shell_bin" -c '
    source "$1"
    [[ "$FX_PROVIDER" == "$2" ]]
    [[ "$FX_MODEL" == "$3" ]]
    [[ "${FX_VARIANT:-}" == "$4" ]]
    [[ -z "$5" || "${OPENROUTER_API_KEY:-}" == "$5" ]]
  ' dum-tum-test "$rc_file" "$provider" "$model" "$variant" "$key"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

run_local_install() {
  local home="$1" install_dir="$2" shell_choice="$3"
  env \
    HOME="$home" \
    FIXIT_HOME="$install_dir" \
    PATH=/usr/bin:/bin \
    SHELL=/bin/bash \
    "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell "$shell_choice"
}

mkdir -p "$TMPD/hostile/src" "$TMPD/remote-home"
for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py; do
  printf 'hostile %s\n' "$f" > "$TMPD/hostile/src/$f"
done

remote_output="$TMPD/remote-output"
(
  cd "$TMPD/hostile"
  env \
    HOME="$TMPD/remote-home" \
    FIXIT_HOME="$TMPD/remote-install" \
    FIXIT_RAW="file://$ROOT" \
    PATH=/usr/bin:/bin \
    SHELL=/bin/bash \
    /bin/bash -s -- --yes --skip-deps --skip-ai-test --provider none --shell bash \
      < "$ROOT/install.sh" > "$remote_output"
)
assert_runtime_matches_repo "$TMPD/remote-install"
grep -q 'Downloading scripts from GitHub' "$remote_output"
if grep -q 'Using local scripts' "$remote_output"; then
  exit 1
fi

mkdir -p "$TMPD/local-home"
env \
  HOME="$TMPD/local-home" \
  FIXIT_HOME="$TMPD/local-install" \
  FIXIT_RAW=file:///does-not-exist \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/local-output"
assert_runtime_matches_repo "$TMPD/local-install"
grep -q 'Using local scripts' "$TMPD/local-output"

model_sub_marker="$TMPD/model-substitution-ran"
model_tick_marker="$TMPD/model-backtick-ran"
variant_sub_marker="$TMPD/variant-substitution-ran"
variant_tick_marker="$TMPD/variant-backtick-ran"
special_model="model ' \" \$value \$(touch '$model_sub_marker') \`touch '$model_tick_marker'\` \\\\ end"
special_variant="variant ' \" \$value \$(touch '$variant_sub_marker') \`touch '$variant_tick_marker'\` \\\\ end"
special_home="$TMPD/home dir ' \" \$value \`literal\` \$(literal) \\"
special_install="$TMPD/install dir ' \" \$value \`literal\` \$(literal) \\"
mkdir -p "$special_home"
env \
  HOME="$special_home" \
  FIXIT_HOME="$special_install" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider codex \
    --model "$special_model" --variant "$special_variant" --shell both \
    > "$TMPD/quoted-output"
assert_config_round_trip /bin/bash "$special_home/.bashrc" codex "$special_model" "$special_variant" ""
assert_config_round_trip "$(command -v zsh)" "$special_home/.zshrc" codex "$special_model" "$special_variant" ""
[[ ! -e "$model_sub_marker" && ! -e "$model_tick_marker" ]]
[[ ! -e "$variant_sub_marker" && ! -e "$variant_tick_marker" ]]

key_sub_marker="$TMPD/key-substitution-ran"
key_tick_marker="$TMPD/key-backtick-ran"
special_key="key ' \" \$value \$(touch '$key_sub_marker') \`touch '$key_tick_marker'\` \\\\ end"
key_home="$TMPD/key-home"
mkdir -p "$key_home"
env \
  HOME="$key_home" \
  FIXIT_HOME="$TMPD/key-install" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider openrouter \
    --model "$special_model" --key "$special_key" --shell both \
    > "$TMPD/key-output"
assert_config_round_trip /bin/bash "$key_home/.bashrc" openrouter "$special_model" "" "$special_key"
assert_config_round_trip "$(command -v zsh)" "$key_home/.zshrc" openrouter "$special_model" "" "$special_key"
[[ ! -e "$key_sub_marker" && ! -e "$key_tick_marker" ]]

newline_model=$'line one\nline two'
mkdir -p "$TMPD/newline-home"
if env \
  HOME="$TMPD/newline-home" \
  FIXIT_HOME="$TMPD/newline-install" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider codex \
    --model "$newline_model" --shell bash > "$TMPD/newline-output" 2>&1; then
  exit 1
fi
grep -q 'model must not contain newline characters' "$TMPD/newline-output"
[[ ! -e "$TMPD/newline-install" && ! -e "$TMPD/newline-home/.bashrc" ]]

newline_install="$TMPD/install"$'\n'"target"
if env \
  HOME="$TMPD/newline-home" \
  FIXIT_HOME="$newline_install" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/newline-path-output" 2>&1; then
  exit 1
fi
grep -q 'FIXIT_HOME must not contain newline characters' "$TMPD/newline-path-output"
[[ ! -e "$newline_install" ]]

assert_malformed_preserved() {
  local name="$1" content="$2"
  local home="$TMPD/malformed-$name" install_dir="$TMPD/malformed-install-$name"
  mkdir -p "$home"
  printf '%s' "$content" > "$home/.bashrc"
  cp "$home/.bashrc" "$home/original"
  if run_local_install "$home" "$install_dir" bash > "$home/output" 2>&1; then
    exit 1
  fi
  cmp "$home/original" "$home/.bashrc"
  [[ ! -e "$install_dir" ]]
  grep -q 'Malformed dum-tum block' "$home/output"
}

assert_malformed_preserved begin-only $'before\n# >>> fixit.zsh >>>\nafter\n'
assert_malformed_preserved end-only $'before\n# <<< fixit.zsh <<<\nafter\n'
assert_malformed_preserved reversed $'# <<< fixit.zsh <<<\nmiddle\n# >>> fixit.zsh >>>\n'
assert_malformed_preserved duplicate $'# >>> fixit.zsh >>>\none\n# <<< fixit.zsh <<<\n# >>> fixit.zsh >>>\ntwo\n# <<< fixit.zsh <<<\n'

update_home="$TMPD/update-home"
mkdir -p "$update_home"
printf '%s\n' \
  'before-config' \
  '# >>> fixit.zsh >>>' \
  'old-managed-content' \
  '# <<< fixit.zsh <<<' > "$update_home/.bashrc"
printf 'after-config-no-newline' >> "$update_home/.bashrc"
chmod 640 "$update_home/.bashrc"
run_local_install "$update_home" "$TMPD/update-install" bash > "$TMPD/update-output"
[[ "$(file_mode "$update_home/.bashrc")" == 640 ]]
grep -qxF 'before-config' "$update_home/.bashrc"
[[ "$(tail -c 23 "$update_home/.bashrc")" == 'after-config-no-newline' ]]
[[ "$(tail -c 1 "$update_home/.bashrc" | od -An -tuC | tr -d ' ')" != 10 ]]
if grep -qF 'old-managed-content' "$update_home/.bashrc"; then
  exit 1
fi
[[ "$(grep -cxF '# >>> fixit.zsh >>>' "$update_home/.bashrc")" -eq 1 ]]
[[ "$(grep -cxF '# <<< fixit.zsh <<<' "$update_home/.bashrc")" -eq 1 ]]

symlink_home="$TMPD/symlink-home"
mkdir -p "$symlink_home/config"
printf 'symlink-target-prefix\n' > "$symlink_home/config/bashrc"
chmod 644 "$symlink_home/config/bashrc"
ln -s config/bashrc "$symlink_home/.bashrc"
run_local_install "$symlink_home" "$TMPD/symlink-install" bash > "$TMPD/symlink-output"
[[ -L "$symlink_home/.bashrc" ]]
[[ "$(readlink "$symlink_home/.bashrc")" == 'config/bashrc' ]]
[[ "$(file_mode "$symlink_home/config/bashrc")" == 644 ]]
grep -qxF 'symlink-target-prefix' "$symlink_home/config/bashrc"
grep -qxF '# >>> fixit.zsh >>>' "$symlink_home/config/bashrc"

uninstall_home="$TMPD/uninstall-home"
mkdir -p "$uninstall_home"
touch "$uninstall_home/.bashrc" "$uninstall_home/.zshrc"
chmod 644 "$uninstall_home/.bashrc" "$uninstall_home/.zshrc"
env \
  HOME="$uninstall_home" \
  FIXIT_HOME="$TMPD/uninstall-target" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider openrouter \
    --model safe-model --key managed-secret --shell both > "$TMPD/uninstall-install-output"
[[ "$(file_mode "$uninstall_home/.bashrc")" == 600 ]]
[[ "$(file_mode "$uninstall_home/.zshrc")" == 600 ]]
printf '%s\n' "export OPENAI_API_KEY='outside-secret'" "export GOOGLE_API_KEY='outside-google'" \
  >> "$uninstall_home/.bashrc"
chmod 640 "$uninstall_home/.bashrc" "$uninstall_home/.zshrc"
env \
  HOME="$uninstall_home" \
  FIXIT_HOME="$TMPD/uninstall-target" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/uninstall-output"
[[ ! -e "$TMPD/uninstall-target" ]]
[[ "$(file_mode "$uninstall_home/.bashrc")" == 640 ]]
[[ "$(file_mode "$uninstall_home/.zshrc")" == 640 ]]
if grep -qF '# >>> fixit.zsh >>>' "$uninstall_home/.bashrc" || \
   grep -qF '# >>> fixit.zsh >>>' "$uninstall_home/.zshrc" || \
   grep -qE '^unset .*API_KEY' "$uninstall_home/.bashrc"; then
  exit 1
fi
/bin/bash -c '
  unset OPENAI_API_KEY GOOGLE_API_KEY
  source "$1"
  [[ "$OPENAI_API_KEY" == outside-secret ]]
  [[ "$GOOGLE_API_KEY" == outside-google ]]
' dum-tum-test "$uninstall_home/.bashrc"

byte_home="$TMPD/byte-uninstall-home"
mkdir -p "$byte_home"
printf '%s\n' \
  'before-byte-block' \
  '# >>> fixit.zsh >>>' \
  'managed' \
  '# <<< fixit.zsh <<<' > "$byte_home/.bashrc"
printf 'after-byte-block-no-newline' >> "$byte_home/.bashrc"
printf 'before-byte-block\nafter-byte-block-no-newline' > "$byte_home/expected"
env \
  HOME="$byte_home" \
  FIXIT_HOME="$TMPD/byte-uninstall-target" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/byte-uninstall-output"
cmp "$byte_home/expected" "$byte_home/.bashrc"

noop_home="$TMPD/noop-home"
mkdir -p "$noop_home"
env \
  HOME="$noop_home" \
  FIXIT_HOME="$TMPD/noop-target" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/noop-output"
[[ ! -e "$noop_home/.zshrc" && ! -e "$noop_home/.bashrc" && ! -e "$TMPD/noop-target" ]]
grep -q 'Nothing to uninstall' "$TMPD/noop-output"

preflight_home="$TMPD/uninstall-preflight-home"
mkdir -p "$preflight_home" "$TMPD/uninstall-preflight-target"
printf '%s\n' '# >>> fixit.zsh >>>' 'managed' '# <<< fixit.zsh <<<' > "$preflight_home/.zshrc"
printf '%s\n' 'before' '# >>> fixit.zsh >>>' 'unterminated' > "$preflight_home/.bashrc"
printf 'runtime-still-here\n' > "$TMPD/uninstall-preflight-target/runtime"
cp "$ROOT/src/fixit-common.sh" "$ROOT/src/fixit.zsh" "$ROOT/src/fixit.bash" \
  "$ROOT/src/fixit-ai.py" "$TMPD/uninstall-preflight-target/"
printf 'dum-tum-install-v1\n' > "$TMPD/uninstall-preflight-target/.dum-tum-install"
cp "$preflight_home/.zshrc" "$preflight_home/zshrc-original"
cp "$preflight_home/.bashrc" "$preflight_home/bashrc-original"
if env \
  HOME="$preflight_home" \
  FIXIT_HOME="$TMPD/uninstall-preflight-target" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/uninstall-preflight-output" 2>&1; then
  exit 1
fi
cmp "$preflight_home/zshrc-original" "$preflight_home/.zshrc"
cmp "$preflight_home/bashrc-original" "$preflight_home/.bashrc"
grep -qxF 'runtime-still-here' "$TMPD/uninstall-preflight-target/runtime"

library="$TMPD/install-library.sh"
sed '$d' "$ROOT/install.sh" > "$library"

assert_uninstall_target_rejected() {
  local name="$1" home="$2" target="$3"
  if ! env \
    HOME="$home" \
    FIXIT_HOME="$target" \
    PATH=/usr/bin:/bin \
    SHELL=/bin/bash \
    /bin/bash -c '
      library=$1
      set --
      source "$library"
      ! validate_uninstall_target >/dev/null 2>&1
    ' dum-tum-test "$library"; then
    printf 'Expected uninstall target rejection: %s\n' "$name" >&2
    exit 1
  fi
}

validation_home="$TMPD/validation-home"
mkdir -p "$validation_home"
assert_uninstall_target_rejected empty "$validation_home" ""
assert_uninstall_target_rejected root "$validation_home" /
assert_uninstall_target_rejected home "$validation_home" "$validation_home"
assert_uninstall_target_rejected workspace "$validation_home" "$ROOT"
assert_uninstall_target_rejected ancestor "$validation_home" "$TMPD"
assert_uninstall_target_rejected broad-system-dir "$validation_home" /etc

symlink_target="$TMPD/symlink-uninstall-real"
symlink_path="$TMPD/symlink-uninstall-target"
mkdir -p "$symlink_target"
printf 'dum-tum-install-v1\n' > "$symlink_target/.dum-tum-install"
ln -s "$symlink_target" "$symlink_path"
assert_uninstall_target_rejected symlink "$validation_home" "$symlink_path"

unrelated_target="$TMPD/unrelated-target"
mkdir -p "$unrelated_target"
printf 'keep-me\n' > "$unrelated_target/important"
assert_uninstall_target_rejected unrelated "$validation_home" "$unrelated_target"

incomplete_target="$TMPD/incomplete-target"
mkdir -p "$incomplete_target"
cp "$ROOT/src/fixit-common.sh" "$ROOT/src/fixit.zsh" "$ROOT/src/fixit.bash" "$incomplete_target/"
assert_uninstall_target_rejected incomplete-legacy "$validation_home" "$incomplete_target"

invalid_sentinel_target="$TMPD/invalid-sentinel-target"
mkdir -p "$invalid_sentinel_target"
cp "$ROOT/src/fixit-common.sh" "$ROOT/src/fixit.zsh" "$ROOT/src/fixit.bash" \
  "$ROOT/src/fixit-ai.py" "$invalid_sentinel_target/"
printf 'not-dum-tum\n' > "$invalid_sentinel_target/.dum-tum-install"
assert_uninstall_target_rejected invalid-sentinel "$validation_home" "$invalid_sentinel_target"

invalid_home="$TMPD/invalid-target-home"
mkdir -p "$invalid_home"
printf '%s\n' '# >>> fixit.zsh >>>' 'managed' '# <<< fixit.zsh <<<' > "$invalid_home/.bashrc"
cp "$invalid_home/.bashrc" "$invalid_home/bashrc-original"
if env \
  HOME="$invalid_home" \
  FIXIT_HOME="$unrelated_target" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/invalid-target-output" 2>&1; then
  exit 1
fi
cmp "$invalid_home/bashrc-original" "$invalid_home/.bashrc"
grep -qxF 'keep-me' "$unrelated_target/important"

empty_home="$TMPD/empty-target-home"
mkdir -p "$empty_home/.local/share/fixit"
printf 'dum-tum-install-v1\n' > "$empty_home/.local/share/fixit/.dum-tum-install"
printf '%s\n' '# >>> fixit.zsh >>>' 'managed' '# <<< fixit.zsh <<<' > "$empty_home/.bashrc"
cp "$empty_home/.bashrc" "$empty_home/bashrc-original"
if env \
  HOME="$empty_home" \
  FIXIT_HOME= \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/empty-target-output" 2>&1; then
  exit 1
fi
cmp "$empty_home/bashrc-original" "$empty_home/.bashrc"
[[ -d "$empty_home/.local/share/fixit" ]]

legacy_home="$TMPD/legacy-home"
legacy_target="$TMPD/legacy-target"
mkdir -p "$legacy_home" "$legacy_target"
cp "$ROOT/src/fixit-common.sh" "$ROOT/src/fixit.zsh" "$ROOT/src/fixit.bash" \
  "$ROOT/src/fixit-ai.py" "$legacy_target/"
env \
  HOME="$legacy_home" \
  FIXIT_HOME="$legacy_target" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/legacy-output"
[[ ! -e "$legacy_target" ]]

default_home="$TMPD/default-home"
mkdir -p "$default_home"
env -u FIXIT_HOME \
  HOME="$default_home" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/default-install-output"
grep -qxF 'dum-tum-install-v1' "$default_home/.local/share/fixit/.dum-tum-install"
env -u FIXIT_HOME \
  HOME="$default_home" \
  PATH=/usr/bin:/bin \
  SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/default-uninstall-output"
[[ ! -e "$default_home/.local/share/fixit" ]]

if [[ -n "$(find "$TMPD" -name '.dum-tum-uninstall.*' -print -quit)" ]]; then
  exit 1
fi

run_clean_upgrade() {
  local home="$1" install_dir="$2" login_shell="$3" shell_choice="$4" output="$5"
  env -u FX_PROVIDER -u FX_MODEL -u FX_VARIANT \
    -u OPENROUTER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    -u GEMINI_API_KEY -u GOOGLE_API_KEY \
    HOME="$home" \
    FIXIT_HOME="$install_dir" \
    PATH=/usr/bin:/bin \
    SHELL="$login_shell" \
    "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --shell "$shell_choice" > "$output"
}

bash_preserve_home="$TMPD/bash-preserve-home"
bash_preserve_target="$TMPD/bash-preserve-target"
mkdir -p "$bash_preserve_home"
env \
  HOME="$bash_preserve_home" FIXIT_HOME="$bash_preserve_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider openrouter \
    --model bash-preserved-model --key bash-preserved-key --shell bash > "$TMPD/bash-seed-output"
run_clean_upgrade "$bash_preserve_home" "$bash_preserve_target" /bin/bash bash "$TMPD/bash-upgrade-output"
assert_config_round_trip /bin/bash "$bash_preserve_home/.bashrc" openrouter \
  bash-preserved-model "" bash-preserved-key
grep -qF "Keeping existing FX_PROVIDER=openrouter from $bash_preserve_home/.bashrc" \
  "$TMPD/bash-upgrade-output"

zsh_preserve_home="$TMPD/zsh-preserve-home"
zsh_preserve_target="$TMPD/zsh-preserve-target"
mkdir -p "$zsh_preserve_home"
env \
  HOME="$zsh_preserve_home" FIXIT_HOME="$zsh_preserve_target" PATH=/usr/bin:/bin SHELL=/bin/zsh \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider codex \
    --model zsh-preserved-model --variant high --shell zsh > "$TMPD/zsh-seed-output"
run_clean_upgrade "$zsh_preserve_home" "$zsh_preserve_target" /bin/zsh zsh "$TMPD/zsh-upgrade-output"
assert_config_round_trip "$(command -v zsh)" "$zsh_preserve_home/.zshrc" codex \
  zsh-preserved-model high ""

multi_home="$TMPD/multi-rc-home"
multi_target="$TMPD/multi-rc-target"
mkdir -p "$multi_home"
env \
  HOME="$multi_home" FIXIT_HOME="$multi_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider openrouter \
    --model bash-priority-model --key bash-priority-key --shell bash > "$TMPD/multi-bash-output"
env \
  HOME="$multi_home" FIXIT_HOME="$multi_target" PATH=/usr/bin:/bin SHELL=/bin/zsh \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider codex \
    --model zsh-secondary-model --variant medium --shell zsh > "$TMPD/multi-zsh-output"
run_clean_upgrade "$multi_home" "$multi_target" /bin/bash both "$TMPD/multi-upgrade-output"
assert_config_round_trip /bin/bash "$multi_home/.bashrc" openrouter bash-priority-model "" bash-priority-key
assert_config_round_trip "$(command -v zsh)" "$multi_home/.zshrc" openrouter \
  bash-priority-model "" bash-priority-key
grep -q 'Selected rc files disagree on FX_PROVIDER' "$TMPD/multi-upgrade-output"

tuple_home="$TMPD/tuple-home"
tuple_target="$TMPD/tuple-target"
mkdir -p "$tuple_home"
env \
  HOME="$tuple_home" FIXIT_HOME="$tuple_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider codex \
    --shell bash > "$TMPD/tuple-bash-output"
env \
  HOME="$tuple_home" FIXIT_HOME="$tuple_target" PATH=/usr/bin:/bin SHELL=/bin/zsh \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider opencode \
    --model secondary-model --variant high --shell zsh > "$TMPD/tuple-zsh-output"
run_clean_upgrade "$tuple_home" "$tuple_target" /bin/bash both "$TMPD/tuple-upgrade-output"
assert_config_round_trip /bin/bash "$tuple_home/.bashrc" codex "" "" ""
assert_config_round_trip "$(command -v zsh)" "$tuple_home/.zshrc" codex "" "" ""
if grep -qF "Keeping existing FX_MODEL from $tuple_home/.zshrc" "$TMPD/tuple-upgrade-output" || \
   grep -qF "Keeping existing FX_VARIANT from $tuple_home/.zshrc" "$TMPD/tuple-upgrade-output"; then
  exit 1
fi

key_tuple_home="$TMPD/key-tuple-home"
key_tuple_target="$TMPD/key-tuple-target"
mkdir -p "$key_tuple_home"
env \
  HOME="$key_tuple_home" FIXIT_HOME="$key_tuple_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider openrouter \
    --key primary-key --shell bash > "$TMPD/key-tuple-bash-output"
awk '$0 !~ /^export OPENROUTER_API_KEY=/' "$key_tuple_home/.bashrc" \
  > "$key_tuple_home/.bashrc.without-key"
mv "$key_tuple_home/.bashrc.without-key" "$key_tuple_home/.bashrc"
env \
  HOME="$key_tuple_home" FIXIT_HOME="$key_tuple_target" PATH=/usr/bin:/bin SHELL=/bin/zsh \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider openrouter \
    --key secondary-key --shell zsh > "$TMPD/key-tuple-zsh-output"
run_clean_upgrade "$key_tuple_home" "$key_tuple_target" /bin/bash both \
  "$TMPD/key-tuple-upgrade-output"
assert_config_round_trip /bin/bash "$key_tuple_home/.bashrc" none "" "" ""
assert_config_round_trip "$(command -v zsh)" "$key_tuple_home/.zshrc" none "" "" ""
if grep -qF "Keeping existing OPENROUTER_API_KEY from $key_tuple_home/.zshrc" \
    "$TMPD/key-tuple-upgrade-output"; then
  exit 1
fi

env \
  FX_PROVIDER=codex FX_MODEL=environment-model FX_VARIANT=environment-variant \
  HOME="$bash_preserve_home" FIXIT_HOME="$bash_preserve_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --model cli-model --variant cli-variant \
    --shell bash > "$TMPD/precedence-output"
assert_config_round_trip /bin/bash "$bash_preserve_home/.bashrc" codex cli-model cli-variant ""

env \
  OPENROUTER_API_KEY=environment-key \
  HOME="$bash_preserve_home" FIXIT_HOME="$bash_preserve_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider openrouter \
    --model key-model --key cli-key --shell bash > "$TMPD/key-precedence-output"
assert_config_round_trip /bin/bash "$bash_preserve_home/.bashrc" openrouter key-model "" cli-key

parse_home="$TMPD/safe-parse-home"
parse_target="$TMPD/safe-parse-target"
parse_marker="$TMPD/unsafe-parse-ran"
parse_model="\$(touch '$parse_marker')"
mkdir -p "$parse_home" "$parse_target"
cp "$ROOT/src/fixit-common.sh" "$ROOT/src/fixit.zsh" "$ROOT/src/fixit.bash" \
  "$ROOT/src/fixit-ai.py" "$parse_target/"
printf 'dum-tum-install-v1\n' > "$parse_target/.dum-tum-install"
printf '%s\n' \
  '# >>> fixit.zsh >>>' \
  "source '$parse_target/fixit.bash'" \
  "export FX_PROVIDER=\"codex\"" \
  "export FX_MODEL=\"$parse_model\"" \
  "export FX_VARIANT=\"low\"" \
  '# <<< fixit.zsh <<<' > "$parse_home/.bashrc"
run_clean_upgrade "$parse_home" "$parse_target" /bin/bash bash "$TMPD/safe-parse-output"
[[ ! -e "$parse_marker" ]]
assert_config_round_trip /bin/bash "$parse_home/.bashrc" codex "$parse_model" low ""
[[ ! -e "$parse_marker" ]]

missing_bin="$TMPD/missing-zsh-bin"
missing_home="$TMPD/missing-zsh-home"
mkdir -p "$missing_bin" "$missing_home"
for command_name in uname basename dirname awk python3 curl; do
  ln -s "$(command -v "$command_name")" "$missing_bin/$command_name"
done
if env \
  HOME="$missing_home" FIXIT_HOME="$TMPD/missing-zsh-target" \
  PATH="$missing_bin" SHELL=/bin/zsh \
  /bin/bash "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell zsh \
    > "$TMPD/missing-zsh-output" 2>&1; then
  exit 1
fi
grep -q 'Shell targets: zsh' "$TMPD/missing-zsh-output"
grep -q 'Missing required dependencies with --skip-deps: zsh' "$TMPD/missing-zsh-output"
[[ ! -e "$TMPD/missing-zsh-target" && ! -e "$missing_home/.zshrc" && ! -e "$missing_home/.bashrc" ]]

darwin_bin="$TMPD/darwin-bin"
mkdir -p "$darwin_bin"
printf '%s\n' '#!/bin/sh' 'printf "Darwin\\n"' > "$darwin_bin/uname"
chmod +x "$darwin_bin/uname"
darwin_path="$darwin_bin:/usr/bin:/bin"
profile_home="$TMPD/profile-home"
profile_target="$TMPD/profile-target"
mkdir -p "$profile_home"
printf 'DUM_TUM_LOAD_COUNT=$(( ${DUM_TUM_LOAD_COUNT:-0} + 1 ))\n' > "$profile_home/.bashrc"
printf 'PROFILE_BEFORE=1\n' > "$profile_home/.bash_profile"
env \
  HOME="$profile_home" FIXIT_HOME="$profile_target" PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/profile-install-output"
printf 'PROFILE_AFTER=1' >> "$profile_home/.bash_profile"
/bin/bash -c '
  source "$1"
  source "$1"
  [[ "$DUM_TUM_LOAD_COUNT" -eq 1 ]]
  [[ "$FX_PROVIDER" == none ]]
' dum-tum-test "$profile_home/.bash_profile"
env \
  HOME="$profile_home" FIXIT_HOME="$profile_target" PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/profile-reinstall-output"
[[ "$(grep -cxF '# >>> dum-tum bashrc loader >>>' "$profile_home/.bash_profile")" -eq 1 ]]
env \
  HOME="$profile_home" FIXIT_HOME="$profile_target" PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/profile-uninstall-output"
printf 'PROFILE_BEFORE=1\n\nPROFILE_AFTER=1' > "$profile_home/profile-expected"
cmp "$profile_home/profile-expected" "$profile_home/.bash_profile"
if grep -qF 'dum-tum bashrc loader' "$profile_home/.bash_profile"; then
  exit 1
fi

existing_profile_home="$TMPD/existing-profile-home"
mkdir -p "$existing_profile_home"
printf 'source "$HOME/.bashrc"\n' > "$existing_profile_home/.bash_profile"
cp "$existing_profile_home/.bash_profile" "$existing_profile_home/profile-original"
env \
  HOME="$existing_profile_home" FIXIT_HOME="$TMPD/existing-profile-target" \
  PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/existing-profile-output"
cmp "$existing_profile_home/profile-original" "$existing_profile_home/.bash_profile"
env \
  HOME="$existing_profile_home" FIXIT_HOME="$TMPD/existing-profile-target" \
  PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$TMPD/existing-profile-uninstall-output"
cmp "$existing_profile_home/profile-original" "$existing_profile_home/.bash_profile"

other_profile_home="$TMPD/other-profile-home"
mkdir -p "$other_profile_home"
printf 'source "$HOME/.other.bashrc"\n' > "$other_profile_home/.bash_profile"
env \
  HOME="$other_profile_home" FIXIT_HOME="$TMPD/other-profile-target" \
  PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/other-profile-output"
grep -qxF 'source "$HOME/.other.bashrc"' "$other_profile_home/.bash_profile"
[[ "$(grep -cxF '# >>> dum-tum bashrc loader >>>' "$other_profile_home/.bash_profile")" -eq 1 ]]

same_profile_home="$TMPD/same-profile-home"
mkdir -p "$same_profile_home"
printf 'SAME_PROFILE_BEFORE=1\n' > "$same_profile_home/.bashrc"
ln -s .bashrc "$same_profile_home/.bash_profile"
env \
  HOME="$same_profile_home" FIXIT_HOME="$TMPD/same-profile-target" \
  PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/same-profile-output"
[[ -L "$same_profile_home/.bash_profile" ]]
grep -qxF 'SAME_PROFILE_BEFORE=1' "$same_profile_home/.bashrc"
if grep -qF 'dum-tum bashrc loader' "$same_profile_home/.bashrc"; then
  exit 1
fi
assert_config_round_trip /bin/bash "$same_profile_home/.bashrc" none "" "" ""

mkdir -p "$TMPD/pinned-home" "$TMPD/fake-bin"
cp "$ROOT/tests/fixtures/curl" "$TMPD/fake-bin/curl"
chmod +x "$TMPD/fake-bin/curl"
: > "$TMPD/curl-log"
env \
  HOME="$TMPD/pinned-home" \
  FIXIT_HOME="$TMPD/pinned-install" \
  FIXIT_TEST_ROOT="$ROOT" \
  FIXIT_TEST_CURL_LOG="$TMPD/curl-log" \
  PATH="$TMPD/fake-bin:/usr/bin:/bin" \
  SHELL=/bin/bash \
  /bin/bash -s -- --yes --skip-deps --skip-ai-test --provider none --shell bash \
    < "$ROOT/install.sh" > "$TMPD/pinned-output"
assert_runtime_matches_repo "$TMPD/pinned-install"
[[ "$(wc -l < "$TMPD/curl-log" | tr -d ' ')" == 4 ]]
if grep -v '/1111111111111111111111111111111111111111/src/' "$TMPD/curl-log"; then
  exit 1
fi
grep -q 'Pinned runtime source: 1111111111111111111111111111111111111111' "$TMPD/pinned-output"

mkdir -p "$TMPD/invalid-home"
: > "$TMPD/invalid-curl-log"
if env \
  HOME="$TMPD/invalid-home" \
  FIXIT_HOME="$TMPD/invalid-install" \
  FIXIT_TEST_ROOT="$ROOT" \
  FIXIT_TEST_CURL_LOG="$TMPD/invalid-curl-log" \
  FIXIT_TEST_API_SHA=main \
  PATH="$TMPD/fake-bin:/usr/bin:/bin" \
  SHELL=/bin/bash \
  /bin/bash -s -- --yes --skip-deps --skip-ai-test --provider none --shell bash \
    < "$ROOT/install.sh" > "$TMPD/invalid-output" 2>&1; then
  exit 1
fi
[[ ! -s "$TMPD/invalid-curl-log" ]]
[[ ! -e "$TMPD/invalid-install" ]]
grep -q 'GitHub returned an invalid dum-tum revision' "$TMPD/invalid-output"

printf 'Installer tests passed\n'
