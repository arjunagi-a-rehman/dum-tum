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

protected_home="$TMPD/protected-install-home"
mkdir -p "$protected_home"
if env \
  HOME="$protected_home" FIXIT_HOME="$protected_home" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/protected-home-output" 2>&1; then
  exit 1
fi
grep -q 'Refusing to install into protected path' "$TMPD/protected-home-output"
[[ -z "$(find "$protected_home" -mindepth 1 -print -quit)" ]]

protected_work="$TMPD/protected-install-work"
protected_work_home="$TMPD/protected-install-work-home"
mkdir -p "$protected_work" "$protected_work_home"
if (
  cd "$protected_work"
  env HOME="$protected_work_home" FIXIT_HOME="$protected_work" \
    PATH=/usr/bin:/bin SHELL=/bin/bash \
    "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash
) > "$TMPD/protected-work-output" 2>&1; then
  exit 1
fi
grep -q 'Refusing to install into protected path' "$TMPD/protected-work-output"
[[ -z "$(find "$protected_work" -mindepth 1 -print -quit)" ]]
[[ -z "$(find "$protected_work_home" -mindepth 1 -print -quit)" ]]

lexical_home="$TMPD/protected-lexical-home"
mkdir -p "$lexical_home"
if env \
  HOME="$lexical_home" FIXIT_HOME="$lexical_home/missing/.." \
  PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/protected-lexical-output" 2>&1; then
  exit 1
fi
grep -q 'Refusing to install into protected path' "$TMPD/protected-lexical-output"
[[ ! -e "$lexical_home/missing" ]]

empty_home_target="$TMPD/empty-home-safe-target"
if env \
  HOME= FIXIT_HOME="$empty_home_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/empty-home-install-output" 2>&1; then
  exit 1
fi
grep -q 'HOME must not be empty' "$TMPD/empty-home-install-output"
[[ ! -e "$empty_home_target" ]]

if env \
  HOME="$validation_home" FIXIT_HOME=/private/tmp PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/dangerous-install-output" 2>&1; then
  exit 1
fi
grep -q 'Refusing to install into dangerous path' "$TMPD/dangerous-install-output"

if env \
  HOME="$validation_home" FIXIT_HOME="$ROOT" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$TMPD/source-install-output" 2>&1; then
  exit 1
fi
grep -q 'Refusing to install into protected path' "$TMPD/source-install-output"

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

smoke_bin="$TMPD/smoke-bin"
mkdir -p "$smoke_bin"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = models ]; then' \
  "  printf '%s\\n' 'stub/provider-model'" \
  'else' \
  "  printf '%s\\n' '{\"content\":\"ls -la\"}'" \
  'fi' > "$smoke_bin/opencode"
chmod +x "$smoke_bin/opencode"
smoke_path="$smoke_bin:$(dirname "$(command -v python3)"):/usr/bin:/bin"

fresh_smoke_home="$TMPD/fresh-smoke-home"
fresh_smoke_target="$TMPD/fresh-smoke-target"
mkdir -p "$fresh_smoke_home"
env \
  HOME="$fresh_smoke_home" FIXIT_HOME="$fresh_smoke_target" \
  PATH="$smoke_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --provider opencode --model stub/provider-model \
    --shell bash > "$TMPD/fresh-smoke-output"
grep -q 'AI test OK' "$TMPD/fresh-smoke-output" || {
  cat "$TMPD/fresh-smoke-output"
  exit 1
}
if grep -q 'AI test returned no command' "$TMPD/fresh-smoke-output"; then
  exit 1
fi

upgrade_smoke_home="$TMPD/upgrade-smoke-home"
upgrade_smoke_target="$TMPD/upgrade-smoke-target"
mkdir -p "$upgrade_smoke_home"
env \
  HOME="$upgrade_smoke_home" FIXIT_HOME="$upgrade_smoke_target" \
  PATH="$smoke_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider opencode \
    --model stub/provider-model --shell bash > "$TMPD/upgrade-smoke-seed-output"
printf '%s\n' '# shellcheck shell=bash' '_fx_ai() { :; }' > "$upgrade_smoke_target/fixit-common.sh"
env \
  HOME="$upgrade_smoke_home" FIXIT_HOME="$upgrade_smoke_target" \
  PATH="$smoke_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --provider opencode --model stub/provider-model \
    --shell bash > "$TMPD/upgrade-smoke-output"
grep -q 'AI test OK' "$TMPD/upgrade-smoke-output" || {
  cat "$TMPD/upgrade-smoke-output"
  exit 1
}
if grep -q 'AI test returned no command' "$TMPD/upgrade-smoke-output"; then
  exit 1
fi

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

tx_root="$TMPD/transaction"
tx_home="$tx_root/home"
tx_parent="$tx_root/runtime-parent"
tx_install="$tx_parent/fixit"
tx_snapshot="$tx_root/snapshot"
mkdir -p "$tx_home/config" "$tx_parent" "$tx_snapshot"
printf 'zsh-before\n' > "$tx_home/config/zshrc"
printf 'bash-before\n' > "$tx_home/.bashrc"
printf 'profile-before\n' > "$tx_home/.bash_profile"
chmod 640 "$tx_home/config/zshrc"
chmod 644 "$tx_home/.bashrc"
chmod 600 "$tx_home/.bash_profile"
ln -s config/zshrc "$tx_home/.zshrc"
env \
  HOME="$tx_home" FIXIT_HOME="$tx_install" PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider codex \
    --model transaction-old-model --variant low --shell both > "$tx_root/seed-output"
cp -Rp "$tx_install" "$tx_snapshot/runtime"
cp -p "$tx_home/config/zshrc" "$tx_snapshot/zshrc"
cp -p "$tx_home/.bashrc" "$tx_snapshot/bashrc"
cp -p "$tx_home/.bash_profile" "$tx_snapshot/bash-profile"
tx_zsh_mode="$(file_mode "$tx_home/config/zshrc")"
tx_bash_mode="$(file_mode "$tx_home/.bashrc")"
tx_profile_mode="$(file_mode "$tx_home/.bash_profile")"

assert_transaction_restored() {
  local f debris
  [[ -L "$tx_home/.zshrc" ]]
  [[ "$(readlink "$tx_home/.zshrc")" == config/zshrc ]]
  cmp "$tx_snapshot/zshrc" "$tx_home/config/zshrc"
  cmp "$tx_snapshot/bashrc" "$tx_home/.bashrc"
  cmp "$tx_snapshot/bash-profile" "$tx_home/.bash_profile"
  [[ "$(file_mode "$tx_home/config/zshrc")" == "$tx_zsh_mode" ]]
  [[ "$(file_mode "$tx_home/.bashrc")" == "$tx_bash_mode" ]]
  [[ "$(file_mode "$tx_home/.bash_profile")" == "$tx_profile_mode" ]]
  for f in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py .dum-tum-install; do
    cmp "$tx_snapshot/runtime/$f" "$tx_install/$f"
    [[ "$(file_mode "$tx_snapshot/runtime/$f")" == "$(file_mode "$tx_install/$f")" ]]
  done
  debris="$(find "$tx_parent" "$tx_home" \
    \( -name '.dum-tum-install.*' -o -name '.dum-tum-backup.*' \
       -o -name '.dum-tum-rc.*' -o -name '.dum-tum-block.*' \) \
    -print -quit)"
  if [[ -n "$debris" ]]; then
    printf 'Transaction debris remains: %s\n' "$debris" >&2
    exit 1
  fi
}

interrupted_bin="$tx_root/interrupted-bin"
mkdir -p "$interrupted_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'out=""' \
  'while [[ $# -gt 0 ]]; do' \
  '  if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi' \
  'done' \
  'printf "partial runtime\n" > "$out"' \
  'exit 130' > "$interrupted_bin/curl"
chmod +x "$interrupted_bin/curl"
if env \
  HOME="$tx_home" FIXIT_HOME="$tx_install" FIXIT_RAW="file://$ROOT" \
  PATH="$interrupted_bin:$darwin_path" SHELL=/bin/bash \
  /bin/bash -s -- --yes --skip-deps --skip-ai-test --provider none --shell both \
    < "$ROOT/install.sh" > "$tx_root/interrupted-output" 2>&1; then
  exit 1
fi
assert_transaction_restored
grep -q 'restored the previous runtime and shell configuration' "$tx_root/interrupted-output"

if env \
  HOME="$tx_home" FIXIT_HOME="$tx_install" PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider invalid-provider \
    --shell both > "$tx_root/invalid-provider-output" 2>&1; then
  exit 1
fi
assert_transaction_restored
grep -q 'Invalid --provider: invalid-provider' "$tx_root/invalid-provider-output"

activation_bin="$tx_root/activation-bin"
mkdir -p "$activation_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'src="${1:-}"' \
  'dest=""' \
  'for arg in "$@"; do dest="$arg"; done' \
  'if [[ "$src" == */.dum-tum-install.* && "$dest" == "$TX_TEST_INSTALL" && ! -e "$TX_TEST_FLAG" ]]; then' \
  '  touch "$TX_TEST_FLAG"' \
  '  exit 1' \
  'fi' \
  'exec /bin/mv "$@"' > "$activation_bin/mv"
chmod +x "$activation_bin/mv"
if env \
  TX_TEST_INSTALL="$tx_install" TX_TEST_FLAG="$tx_root/activation-failed" \
  HOME="$tx_home" FIXIT_HOME="$tx_install" PATH="$activation_bin:$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell both \
    > "$tx_root/activation-output" 2>&1; then
  exit 1
fi
assert_transaction_restored
[[ -e "$tx_root/activation-failed" ]]

rc_commit_bin="$tx_root/rc-commit-bin"
tx_bash_target="$(cd -P "$tx_home" && pwd)/.bashrc"
mkdir -p "$rc_commit_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'src="${1:-}"' \
  'dest=""' \
  'for arg in "$@"; do dest="$arg"; done' \
  'if [[ "$src" == */.dum-tum-rc.* && "$dest" == "$TX_TEST_FAIL_TARGET" && ! -e "$TX_TEST_FLAG" ]]; then' \
  '  touch "$TX_TEST_FLAG"' \
  '  exit 1' \
  'fi' \
  'exec /bin/mv "$@"' > "$rc_commit_bin/mv"
chmod +x "$rc_commit_bin/mv"
if env \
  TX_TEST_FAIL_TARGET="$tx_bash_target" TX_TEST_FLAG="$tx_root/rc-commit-failed" \
  HOME="$tx_home" FIXIT_HOME="$tx_install" PATH="$rc_commit_bin:$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider openrouter \
    --model transaction-new-model --key transaction-new-key --shell both \
    > "$tx_root/rc-commit-output" 2>&1; then
  exit 1
fi
assert_transaction_restored
[[ -e "$tx_root/rc-commit-failed" ]]

restore_fail_root="$TMPD/install-restore-failure"
restore_fail_home="$restore_fail_root/home"
restore_fail_parent="$restore_fail_root/runtime-parent"
restore_fail_target="$restore_fail_parent/fixit"
restore_fail_bin="$restore_fail_root/bin"
mkdir -p "$restore_fail_home" "$restore_fail_parent" "$restore_fail_bin"
env \
  HOME="$restore_fail_home" FIXIT_HOME="$restore_fail_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$restore_fail_root/seed-output"
printf '# previous-runtime\n' >> "$restore_fail_target/fixit-common.sh"
cp -p "$restore_fail_home/.bashrc" "$restore_fail_root/bashrc-before"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'src="${1:-}"' \
  'dest=""' \
  'for arg in "$@"; do dest="$arg"; done' \
  'if [[ "$dest" == "$TX_TEST_INSTALL" && ( "$src" == */.dum-tum-install.* || "$src" == */.dum-tum-backup.* ) ]]; then' \
  '  exit 1' \
  'fi' \
  'exec /bin/mv "$@"' > "$restore_fail_bin/mv"
chmod +x "$restore_fail_bin/mv"
if env \
  TX_TEST_INSTALL="$restore_fail_target" \
  HOME="$restore_fail_home" FIXIT_HOME="$restore_fail_target" \
  PATH="$restore_fail_bin:/usr/bin:/bin" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$restore_fail_root/output" 2>&1; then
  exit 1
fi
restore_fail_backup="$(find "$restore_fail_parent" -maxdepth 1 -type d -name '.dum-tum-backup.*' -print -quit)"
[[ -n "$restore_fail_backup" && ! -e "$restore_fail_target" ]]
grep -qxF '# previous-runtime' "$restore_fail_backup/fixit-common.sh"
cmp "$restore_fail_root/bashrc-before" "$restore_fail_home/.bashrc"
grep -q 'rollback is incomplete' "$restore_fail_root/output"
grep -qF "recovery backup retained at $restore_fail_backup" "$restore_fail_root/output"
if grep -q 'Installation failed; restored the previous runtime' "$restore_fail_root/output"; then
  exit 1
fi

rc_restore_fail_root="$TMPD/install-rc-restore-failure"
rc_restore_fail_home="$rc_restore_fail_root/home"
rc_restore_fail_target="$rc_restore_fail_root/runtime"
rc_restore_fail_bin="$rc_restore_fail_root/bin"
mkdir -p "$rc_restore_fail_home" "$rc_restore_fail_bin"
rc_restore_profile="$(cd -P "$rc_restore_fail_home" && pwd)/.bash_profile"
rc_restore_bashrc="$(cd -P "$rc_restore_fail_home" && pwd)/.bashrc"
env \
  HOME="$rc_restore_fail_home" FIXIT_HOME="$rc_restore_fail_target" \
  PATH="$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell both \
    > "$rc_restore_fail_root/seed-output"
cp -p "$rc_restore_fail_home/.zshrc" "$rc_restore_fail_root/zshrc-before"
cp -p "$rc_restore_fail_home/.bashrc" "$rc_restore_fail_root/bashrc-before"
cp -p "$rc_restore_fail_home/.bash_profile" "$rc_restore_fail_root/profile-before"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'src="${1:-}"' \
  'dest=""' \
  'for arg in "$@"; do dest="$arg"; done' \
  'if [[ "$src" == */.dum-tum-rc.* && "$dest" == "$TX_TEST_PROFILE" ]]; then exit 1; fi' \
  'if [[ "$src" == */.dum-tum-backup.* && "$dest" == "$TX_TEST_BASHRC" ]]; then exit 1; fi' \
  'exec /bin/mv "$@"' > "$rc_restore_fail_bin/mv"
chmod +x "$rc_restore_fail_bin/mv"
if env \
  TX_TEST_PROFILE="$rc_restore_profile" TX_TEST_BASHRC="$rc_restore_bashrc" \
  HOME="$rc_restore_fail_home" FIXIT_HOME="$rc_restore_fail_target" \
  PATH="$rc_restore_fail_bin:$darwin_path" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider codex \
    --model new-model --shell both > "$rc_restore_fail_root/output" 2>&1; then
  exit 1
fi
rc_restore_backup="$(find "$rc_restore_fail_home" -maxdepth 1 -type f \
  -name '.dum-tum-backup.*' -print -quit)"
[[ -n "$rc_restore_backup" ]]
rc_restore_backup_real="$(cd -P "$(dirname "$rc_restore_backup")" && pwd)/$(basename "$rc_restore_backup")"
cmp "$rc_restore_fail_root/bashrc-before" "$rc_restore_backup"
cmp "$rc_restore_fail_root/zshrc-before" "$rc_restore_fail_home/.zshrc"
cmp "$rc_restore_fail_root/profile-before" "$rc_restore_fail_home/.bash_profile"
assert_runtime_matches_repo "$rc_restore_fail_target"
grep -qF "recovery backup retained at $rc_restore_backup_real" "$rc_restore_fail_root/output"
grep -q 'rollback is incomplete' "$rc_restore_fail_root/output"
if grep -q 'Installation failed; restored the previous runtime' "$rc_restore_fail_root/output"; then
  exit 1
fi

assert_uninstall_commit_rollback() {
  local fail_at="$1" root="$TMPD/uninstall-commit-$1"
  local home="$root/home" target="$root/runtime" bin="$root/bin" debris runtime_file
  local zsh_mode bash_mode profile_mode
  mkdir -p "$home" "$bin"
  env \
    HOME="$home" FIXIT_HOME="$target" PATH="$darwin_path" SHELL=/bin/bash \
    "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell both \
      > "$root/seed-output"
  cp -Rp "$target" "$root/runtime-before"
  cp -p "$home/.zshrc" "$root/zshrc-before"
  cp -p "$home/.bash_profile" "$root/profile-before"
  cp -p "$home/.bashrc" "$root/bashrc-before"
  zsh_mode="$(file_mode "$home/.zshrc")"
  profile_mode="$(file_mode "$home/.bash_profile")"
  bash_mode="$(file_mode "$home/.bashrc")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'src="${1:-}"' \
    'dest=""' \
    'for arg in "$@"; do dest="$arg"; done' \
    'if [[ "$src" == */.dum-tum-rc.* ]]; then' \
    '  count=0' \
    '  [[ ! -f "$TX_TEST_COUNTER" ]] || IFS= read -r count < "$TX_TEST_COUNTER"' \
    '  count=$((count+1))' \
    '  printf "%s\\n" "$count" > "$TX_TEST_COUNTER"' \
    '  if [[ "$count" -eq "$TX_TEST_FAIL_AT" ]]; then exit 1; fi' \
    'fi' \
    'exec /bin/mv "$@"' > "$bin/mv"
  chmod +x "$bin/mv"
  if env \
    TX_TEST_FAIL_AT="$fail_at" TX_TEST_COUNTER="$root/commit-count" \
    HOME="$home" FIXIT_HOME="$target" PATH="$bin:$darwin_path" SHELL=/bin/bash \
    "$ROOT/install.sh" --uninstall > "$root/output" 2>&1; then
    exit 1
  fi
  cmp "$root/zshrc-before" "$home/.zshrc"
  cmp "$root/profile-before" "$home/.bash_profile"
  cmp "$root/bashrc-before" "$home/.bashrc"
  [[ "$(file_mode "$home/.zshrc")" == "$zsh_mode" ]]
  [[ "$(file_mode "$home/.bash_profile")" == "$profile_mode" ]]
  [[ "$(file_mode "$home/.bashrc")" == "$bash_mode" ]]
  assert_runtime_matches_repo "$target"
  for runtime_file in fixit-common.sh fixit.zsh fixit.bash fixit-ai.py .dum-tum-install; do
    cmp "$root/runtime-before/$runtime_file" "$target/$runtime_file"
    [[ "$(file_mode "$root/runtime-before/$runtime_file")" == \
       "$(file_mode "$target/$runtime_file")" ]]
  done
  grep -q 'Uninstall failed; restored the installation and shell configuration' "$root/output"
  debris="$(find "$root" \
    \( -name '.dum-tum-uninstall.*' -o -name '.dum-tum-backup.*' -o -name '.dum-tum-rc.*' \) \
    -print -quit)"
  [[ -z "$debris" ]]
}

assert_uninstall_commit_rollback 2
assert_uninstall_commit_rollback 3

relative_root="$TMPD/relative-fixit-home"
mkdir -p "$relative_root/home" "$relative_root/work"
if (
  cd "$relative_root/work"
  env HOME="$relative_root/home" FIXIT_HOME=runtime PATH=/usr/bin:/bin SHELL=/bin/bash \
    "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash
) > "$relative_root/output" 2>&1; then
  exit 1
fi
grep -q 'FIXIT_HOME must be an absolute path' "$relative_root/output"
[[ ! -e "$relative_root/work/runtime" && ! -e "$relative_root/home/.bashrc" ]]

exclusive_root="$TMPD/exclusive-runtime"
exclusive_home="$exclusive_root/home"
exclusive_target="$exclusive_root/runtime"
mkdir -p "$exclusive_home"
env HOME="$exclusive_home" FIXIT_HOME="$exclusive_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$exclusive_root/seed-output"
printf 'must survive\n' > "$exclusive_target/user-data"
cp -Rp "$exclusive_target" "$exclusive_root/runtime-before"
cp -p "$exclusive_home/.bashrc" "$exclusive_root/bashrc-before"
if env HOME="$exclusive_home" FIXIT_HOME="$exclusive_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$exclusive_root/update-output" 2>&1; then
  exit 1
fi
grep -q 'unexpected entries' "$exclusive_root/update-output"
diff -r "$exclusive_root/runtime-before" "$exclusive_target"
cmp "$exclusive_root/bashrc-before" "$exclusive_home/.bashrc"
if env HOME="$exclusive_home" FIXIT_HOME="$exclusive_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$exclusive_root/uninstall-output" 2>&1; then
  exit 1
fi
grep -q 'unexpected entries' "$exclusive_root/uninstall-output"
grep -qxF 'must survive' "$exclusive_target/user-data"
cmp "$exclusive_root/bashrc-before" "$exclusive_home/.bashrc"

smoke_root="$TMPD/smoke-status"
smoke_home="$smoke_root/home"
smoke_bin="$smoke_root/bin"
mkdir -p "$smoke_home" "$smoke_bin"
printf '%s\n' \
  '#!/bin/bash' \
  'if [[ "${1:-}" == -n ]]; then exec /bin/bash "$@"; fi' \
  'if [[ "${1:-}" == -c ]]; then' \
  '  printf "ls -la\n"' \
  '  printf "staged smoke failed\n" >&2' \
  '  exit 17' \
  'fi' \
  'exec /bin/bash "$@"' > "$smoke_bin/bash"
chmod +x "$smoke_bin/bash"
env HOME="$smoke_home" FIXIT_HOME="$smoke_root/runtime" \
  PATH="$smoke_bin:/usr/bin:/bin" SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --provider openrouter --model test-model \
    --key test-key --shell bash > "$smoke_root/output" 2>&1
grep -q 'staged smoke failed' "$smoke_root/output"
grep -q 'AI test returned no command' "$smoke_root/output"
if grep -q 'AI test OK' "$smoke_root/output"; then
  exit 1
fi

assert_signal_boundary() {
  local operation="$1" boundary="$2" root
  root="$TMPD/signal-$operation-$boundary"
  local home="$root/home" target="$root/runtime" bin="$root/bin" bashrc
  mkdir -p "$home" "$bin"
  env HOME="$home" FIXIT_HOME="$target" PATH=/usr/bin:/bin SHELL=/bin/bash \
    "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
      > "$root/seed-output"
  cp -Rp "$target" "$root/runtime-before"
  cp -p "$home/.bashrc" "$root/bashrc-before"
  [[ ! -f "$home/.bash_profile" ]] || cp -p "$home/.bash_profile" "$root/profile-before"
  bashrc="$(cd -P "$home" && pwd)/.bashrc"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'src="${1:-}"' \
    'dest=""' \
    'for arg in "$@"; do dest="$arg"; done' \
    '/bin/mv "$@"' \
    'rc=$?' \
    'match=0' \
    'if [[ "$TX_SIGNAL_BOUNDARY" == runtime-install && "$src" == */.dum-tum-install.* && "$dest" == "$TX_SIGNAL_TARGET" ]]; then match=1; fi' \
    'if [[ "$TX_SIGNAL_BOUNDARY" == rc-install && "$src" == */.dum-tum-rc.* && "$dest" == "$TX_SIGNAL_BASHRC" ]]; then match=1; fi' \
    'if [[ "$TX_SIGNAL_BOUNDARY" == runtime-uninstall && "$dest" == */.dum-tum-uninstall.*/install ]]; then match=1; fi' \
    'if [[ "$TX_SIGNAL_BOUNDARY" == rc-uninstall && "$src" == */.dum-tum-rc.* && "$dest" == "$TX_SIGNAL_BASHRC" ]]; then match=1; fi' \
    'if [[ "$rc" -eq 0 && "$match" -eq 1 && ! -e "$TX_SIGNAL_FLAG" ]]; then' \
    '  touch "$TX_SIGNAL_FLAG"' \
    '  kill -TERM "$PPID"' \
    'fi' \
    'exit "$rc"' > "$bin/mv"
  chmod +x "$bin/mv"
  if [[ "$operation" == install ]]; then
    if env TX_SIGNAL_BOUNDARY="$boundary-$operation" TX_SIGNAL_TARGET="$target" \
      TX_SIGNAL_BASHRC="$bashrc" TX_SIGNAL_FLAG="$root/signalled" \
      HOME="$home" FIXIT_HOME="$target" PATH="$bin:/usr/bin:/bin" SHELL=/bin/bash \
      "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
        > "$root/output" 2>&1; then
      exit 1
    fi
  else
    if env TX_SIGNAL_BOUNDARY="$boundary-$operation" TX_SIGNAL_TARGET="$target" \
      TX_SIGNAL_BASHRC="$bashrc" TX_SIGNAL_FLAG="$root/signalled" \
      HOME="$home" FIXIT_HOME="$target" PATH="$bin:/usr/bin:/bin" SHELL=/bin/bash \
      "$ROOT/install.sh" --uninstall > "$root/output" 2>&1; then
      exit 1
    fi
  fi
  [[ -e "$root/signalled" ]]
  diff -r "$root/runtime-before" "$target"
  cmp "$root/bashrc-before" "$home/.bashrc"
  if [[ -f "$root/profile-before" ]]; then
    cmp "$root/profile-before" "$home/.bash_profile"
  fi
  grep -q 'restored the .*shell configuration' "$root/output"
}

assert_signal_boundary install runtime
assert_signal_boundary install rc
assert_signal_boundary uninstall runtime
assert_signal_boundary uninstall rc

partial_root="$TMPD/partial-uninstall"
partial_home="$partial_root/home"
partial_target="$partial_root/runtime"
partial_bin="$partial_root/bin"
mkdir -p "$partial_home" "$partial_bin"
env HOME="$partial_home" FIXIT_HOME="$partial_target" PATH=/usr/bin:/bin SHELL=/bin/bash \
  "$ROOT/install.sh" --yes --skip-deps --skip-ai-test --provider none --shell bash \
    > "$partial_root/seed-output"
cp -p "$partial_home/.bashrc" "$partial_root/bashrc-before"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == -rf && "${2:-}" == */.dum-tum-uninstall.* ]]; then' \
  '  /bin/rm -f "$2/install/fixit-ai.py"' \
  '  exit 1' \
  'fi' \
  'exec /bin/rm "$@"' > "$partial_bin/rm"
chmod +x "$partial_bin/rm"
if env HOME="$partial_home" FIXIT_HOME="$partial_target" \
  PATH="$partial_bin:/usr/bin:/bin" SHELL=/bin/bash \
  "$ROOT/install.sh" --uninstall > "$partial_root/output" 2>&1; then
  exit 1
fi
[[ ! -e "$partial_target" ]]
partial_quarantine="$(find "$partial_root" -maxdepth 1 -type d \
  -name '.dum-tum-uninstall.*' -print -quit)"
[[ -n "$partial_quarantine" && -d "$partial_quarantine/install" ]]
[[ ! -e "$partial_quarantine/install/fixit-ai.py" ]]
cmp "$partial_root/bashrc-before" "$partial_home/.bashrc"
grep -q 'rollback is incomplete' "$partial_root/output"
grep -q 'remaining recovery data is retained' "$partial_root/output"
if grep -q 'Uninstall failed; restored' "$partial_root/output"; then
  exit 1
fi

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
