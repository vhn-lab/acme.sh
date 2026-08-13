#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)

# shellcheck source=../../../dnsapi/dns_obs.sh
# shellcheck disable=SC1091
. "$TEST_ROOT/dnsapi/dns_obs.sh"

_readaccountconf_mutable() { return 0; }
_saveaccountconf_mutable() { return 0; }
_sleep() { :; }
_head_n() { head -n "$1"; }
_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}
_info() { printf 'INFO: %s\n' "$*" >>"$TEST_LOG"; }
_err() { printf 'ERROR: %s\n' "$*" >>"$TEST_LOG"; }

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  case "${TEST_DIR:-}" in
    /tmp/avaya-obs-test.*) rm -r "$TEST_DIR" ;;
  esac
}

TEST_DIR=$(mktemp -d /tmp/avaya-obs-test.XXXXXX)
trap cleanup EXIT HUP INT TERM
TEST_LOG="$TEST_DIR/test.log"
OBS_File="$TEST_DIR/credentials.csv"

write_valid_credentials() {
  printf '%s\n' \
    '# hostName;zoneName;apiToken' \
    'ipo1.example.invalid;example.invalid;OLD_SECRET_TOKEN' \
    'ipo2.example.invalid;example.invalid;SECOND_SECRET_TOKEN' >"$OBS_File"
  chmod 600 "$OBS_File"
}

mock_future_expiry() {
  # shellcheck disable=SC2317
  _get() {
    printf '%s\n' '{"expiresAt":"2099-01-01T00:00:00Z"}'
  }
}

mock_expired_token() {
  # shellcheck disable=SC2317
  _get() {
    printf '%s\n' '{"expiresAt":"2000-01-01T00:00:00Z"}'
  }
}

_post() {
  case "$2:$4" in
    */record:POST) printf '%s\n' '{"message":"Record added successfully"}' ;;
    */record:DELETE) printf '%s\n' '{"message":"Record deleted successfully"}' ;;
    */token/rotate:POST) printf '%s\n' '{"token":"NEW_SECRET_TOKEN"}' ;;
    *) return 1 ;;
  esac
}

write_valid_credentials
mock_future_expiry

dns_obs_add '_acme-challenge.ipo1.example.invalid' 'TXT_VALUE' ||
  fail 'valid TXT addition was rejected'
dns_obs_rm '_acme-challenge.ipo1.example.invalid' 'TXT_VALUE' ||
  fail 'valid TXT removal was rejected'

if _obs_load_credentials 'missing.example.invalid'; then
  fail 'missing credential entry was accepted'
fi

printf '%s\n' 'ipo1.example.invalid;example.invalid;DUPLICATE_TOKEN' >>"$OBS_File"
if _obs_load_credentials 'ipo1.example.invalid'; then
  fail 'duplicate credential entries were accepted'
fi
sed -i '$d' "$OBS_File"

chmod 644 "$OBS_File"
if _obs_check_file_permissions "$OBS_File"; then
  fail 'insecure credential permissions were accepted'
fi
chmod 600 "$OBS_File"

mock_expired_token
_obs_prepare '_acme-challenge.ipo1.example.invalid' ||
  fail 'token rotation failed'

awk -F ';' '
  $1 == "ipo1.example.invalid" && $3 == "NEW_SECRET_TOKEN" { renewed++ }
  $1 == "ipo2.example.invalid" && $3 == "SECOND_SECRET_TOKEN" { unchanged++ }
  END { exit renewed == 1 && unchanged == 1 ? 0 : 1 }
' "$OBS_File" || fail 'rotation changed an unexpected credential entry'

[ "$(stat -c '%a' "$OBS_File")" = '600' ] ||
  fail 'rotation did not preserve secure permissions'

if grep -E 'OLD_SECRET_TOKEN|NEW_SECRET_TOKEN|SECOND_SECRET_TOKEN|Authorization:' "$TEST_LOG" >/dev/null; then
  fail 'a secret was written to logs'
fi

mkdir "${OBS_File}.lock"
printf '%s\n' '99999999' >"${OBS_File}.lock/pid"
OBS_LockStaleSeconds=0
_obs_lock || fail 'stale credentials lock was not recovered'
_obs_unlock
[ ! -d "${OBS_File}.lock" ] || fail 'credentials lock was not released by its owner'

printf '%s\n' \
  '# hostName;zoneName;apiToken' \
  'ipo1.example.invalid;example.invalid;OLD_SECRET_TOKEN' >"$OBS_File"
chmod 600 "$OBS_File"
_obs_preflight_credentials_update() { return 1; }
if _obs_prepare '_acme-challenge.ipo1.example.invalid'; then
  fail 'token rotation continued after preflight storage failure'
fi
grep 'OLD_SECRET_TOKEN' "$OBS_File" >/dev/null ||
  fail 'preflight failure unexpectedly changed credentials'

printf '%s\n' 'PASS: dns_obs.sh unit tests'
