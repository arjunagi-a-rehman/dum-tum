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
