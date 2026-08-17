#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
HOOK="$TEST_ROOT/deploy/avaya_ipo.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  case "${TEST_DIR:-}" in
    /tmp/avaya-hook-test.*) rm -r "$TEST_DIR" ;;
  esac
}

TEST_DIR=$(mktemp -d /tmp/avaya-hook-test.XXXXXX)
trap cleanup EXIT HUP INT TERM

for FILE in config password key.pem cert.pem ca.pem fullchain.pem trust.pem; do
  printf '%s\n' "test-$FILE" >"$TEST_DIR/$FILE"
done
chmod 600 "$TEST_DIR/password"

cat >"$TEST_DIR/deployer" <<'MOCK'
#!/usr/bin/env sh
printf '%s\n' "$@" >"$AVAYA_HOOK_TEST_ARGS"
MOCK
chmod 700 "$TEST_DIR/deployer"

_debug() { :; }
_info() { :; }
_err() { printf '%s\n' "$*" >&2; }
_getdeployconf() { :; }
_savedeployconf() { printf '%s=%s\n' "$1" "$2" >>"$AVAYA_HOOK_TEST_SAVED"; }

# shellcheck source=../../../deploy/avaya_ipo.sh
# shellcheck disable=SC1091
. "$HOOK"

run_hook() {
  AVAYA_IPO_CONFIG="$TEST_DIR/config" \
    AVAYA_IPO_PROFILE=voice-edge \
    AVAYA_IPO_PASSWORD_FILE="$TEST_DIR/password" \
    AVAYA_IPO_DEPLOYER="$TEST_DIR/deployer" \
    AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS=yes \
    AVAYA_IPO_EXPECTED_NAME=voice.example.invalid \
    AVAYA_IPO_TRUST_FILE="$TEST_DIR/trust.pem" \
    AVAYA_IPO_ALLOW_PARTIAL_CHAIN=yes \
    AVAYA_HOOK_TEST_ARGS="$TEST_DIR/args" \
    AVAYA_HOOK_TEST_SAVED="$TEST_DIR/saved" \
    avaya_ipo_deploy voice.example.invalid "$TEST_DIR/key.pem" \
      "$TEST_DIR/cert.pem" "$TEST_DIR/ca.pem" "$TEST_DIR/fullchain.pem"
}

run_hook
grep -Fx -- '--apply' "$TEST_DIR/args" >/dev/null || fail 'apply mode was not requested'
grep -Fx -- '--acknowledge-service-restarts' "$TEST_DIR/args" >/dev/null ||
  fail 'service restart acknowledgement was not forwarded'
grep -Fx -- '--allow-partial-chain' "$TEST_DIR/args" >/dev/null ||
  fail 'partial chain setting was not forwarded'
grep -Fx -- "$TEST_DIR/password" "$TEST_DIR/args" >/dev/null ||
  fail 'password file was not forwarded'
grep -Fx 'AVAYA_IPO_PROFILE=voice-edge' "$TEST_DIR/saved" >/dev/null ||
  fail 'profile was not persisted'

if AVAYA_IPO_CONFIG="$TEST_DIR/config" \
  AVAYA_IPO_PROFILE=voice-edge AVAYA_IPO_PASSWORD_FILE="$TEST_DIR/password" \
  AVAYA_IPO_DEPLOYER="$TEST_DIR/deployer" \
  AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS=no \
  AVAYA_HOOK_TEST_ARGS="$TEST_DIR/rejected-args" \
  AVAYA_HOOK_TEST_SAVED="$TEST_DIR/rejected-saved" \
  avaya_ipo_deploy voice.example.invalid "$TEST_DIR/key.pem" \
    "$TEST_DIR/cert.pem" "$TEST_DIR/ca.pem" "$TEST_DIR/fullchain.pem" \
    >/dev/null 2>&1; then
  fail 'deployment worked without restart acknowledgement'
fi
[ ! -e "$TEST_DIR/rejected-args" ] || fail 'rejected deployment invoked the engine'

printf '%s\n' 'PASS: Avaya IP Office deploy hook tests'
