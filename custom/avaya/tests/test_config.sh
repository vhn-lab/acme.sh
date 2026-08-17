#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)

# shellcheck source=../avaya-lib.sh
# shellcheck disable=SC1091
. "$TEST_ROOT/custom/avaya/avaya-lib.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  case "${TEST_DIR:-}" in
    /tmp/avaya-config-test.*) rm -r "$TEST_DIR" ;;
  esac
}

TEST_DIR=$(mktemp -d /tmp/avaya-config-test.XXXXXX)
trap cleanup EXIT HUP INT TERM

cp "$TEST_ROOT/custom/avaya/config.example" "$TEST_DIR/config"
cp "$TEST_ROOT/custom/avaya/targets.example.csv" "$TEST_DIR/targets.csv"

avaya_load_config "$TEST_DIR/config" || fail 'valid config was rejected'
avaya_validate_targets "$TEST_DIR/targets.csv" || fail 'valid targets were rejected'

[ "$(avaya_targets_for_profile "$TEST_DIR/targets.csv" voice-edge | wc -l)" -eq 1 ] ||
  fail 'profile target selection returned an unexpected count'

printf '%s\n' 'UNKNOWN_KEY=value' >>"$TEST_DIR/config"
if avaya_load_config "$TEST_DIR/config" >/dev/null 2>&1; then
  fail 'unknown config key was accepted'
fi
sed -i '$d' "$TEST_DIR/config"

sed -i 's/^no;ipo;IPOS;/yes;ipo;IPOS;/' "$TEST_DIR/targets.csv"
printf '%s\n' 'yes;ipo;IPO-EXTRA;ipo-extra.example.invalid;root;192.0.2.12;voice-edge;standalone' >>"$TEST_DIR/targets.csv"
if avaya_validate_targets "$TEST_DIR/targets.csv" >/dev/null 2>&1; then
  fail 'more than two active IP Office targets were accepted'
fi
sed -i '$d' "$TEST_DIR/targets.csv"
sed -i 's/^yes;ipo;IPOS;/no;ipo;IPOS;/' "$TEST_DIR/targets.csv"

printf '%s\n' 'yes;ipo;BAD;ipo.example.invalid;root;192.0.2.12;voice-edge;primary;extra' >>"$TEST_DIR/targets.csv"
if avaya_validate_targets "$TEST_DIR/targets.csv" >/dev/null 2>&1; then
  fail 'target with an extra field was accepted'
fi
sed -i '$d' "$TEST_DIR/targets.csv"

# The literal command substitution below is malicious test data and must not expand.
# shellcheck disable=SC2016
printf '%s\n' 'yes;ipo;BAD;$(touch /tmp/injected);root;192.0.2.12;voice-edge;primary' >>"$TEST_DIR/targets.csv"
if avaya_validate_targets "$TEST_DIR/targets.csv" >/dev/null 2>&1; then
  fail 'target containing command syntax was accepted'
fi
[ ! -e /tmp/injected ] || fail 'configuration content was executed'

sed -i '$d' "$TEST_DIR/targets.csv"
printf '%s\n' 'yes;other;BAD;other.example.invalid;root;192.0.2.12;voice-edge;primary' >>"$TEST_DIR/targets.csv"
if avaya_validate_targets "$TEST_DIR/targets.csv" >/dev/null 2>&1; then
  fail 'unsupported target type was accepted'
fi

sed -i '$d' "$TEST_DIR/targets.csv"
printf '%s\n' 'yes;ipo;BAD;ipo.example.invalid;root;999.0.2.12;voice-edge;primary' >>"$TEST_DIR/targets.csv"
if avaya_validate_targets "$TEST_DIR/targets.csv" >/dev/null 2>&1; then
  fail 'invalid server IP was accepted'
fi

printf '%s\n' 'PASS: Avaya configuration parser tests'
