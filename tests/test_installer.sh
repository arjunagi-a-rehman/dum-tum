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

printf 'Installer tests passed\n'
