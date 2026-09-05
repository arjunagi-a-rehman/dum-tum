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

printf 'Installer source tests passed\n'
