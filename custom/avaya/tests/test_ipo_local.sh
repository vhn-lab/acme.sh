#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
HELPER="$TEST_ROOT/custom/avaya/avaya-ipo-local.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cleanup() { case "${TEST_DIR:-}" in /tmp/avaya-local-test.*) rm -r "$TEST_DIR" ;; esac; }

TEST_DIR=$(mktemp -d /tmp/avaya-local-test.XXXXXX)
trap cleanup EXIT HUP INT TERM
for FILE in cert.pem key.pem fullchain.pem password; do printf '%s\n' test >"$TEST_DIR/$FILE"; done
chmod 600 "$TEST_DIR/password"

cat >"$TEST_DIR/builder" <<'MOCK'
#!/usr/bin/env sh
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT=$2; shift 2 ;; *) shift ;; esac
done
printf '%s\n' p12 >"$OUTPUT"
printf '%s\n' builder >>"$AVAYA_LOCAL_TEST_LOG"
MOCK
cat >"$TEST_DIR/installer" <<'MOCK'
#!/usr/bin/env sh
printf 'installer %s\n' "$*" >>"$AVAYA_LOCAL_TEST_LOG"
MOCK
cat >"$TEST_DIR/verifier" <<'MOCK'
#!/usr/bin/env sh
printf 'verifier %s\n' "$*" >>"$AVAYA_LOCAL_TEST_LOG"
MOCK
chmod 700 "$TEST_DIR/builder" "$TEST_DIR/installer" "$TEST_DIR/verifier"

AVAYA_LOCAL_TEST_LOG="$TEST_DIR/log" \
AVAYA_PKCS12_BUILDER="$TEST_DIR/builder" \
AVAYA_IPO_INSTALLER="$TEST_DIR/installer" \
AVAYA_IPO_VERIFIER="$TEST_DIR/verifier" \
  sh "$HELPER" --server-ip 192.0.2.10 --cert "$TEST_DIR/cert.pem" \
  --key "$TEST_DIR/key.pem" --fullchain "$TEST_DIR/fullchain.pem" \
  --password-file "$TEST_DIR/password" --backup-dir /var/lib/acme-avaya/backups

grep -Fx builder "$TEST_DIR/log" >/dev/null || fail 'PKCS12 builder was not called'
grep 'installer .*--acknowledge-service-restarts' "$TEST_DIR/log" >/dev/null ||
  fail 'installer did not receive restart acknowledgement'
grep 'installer .*--backup-dir /var/lib/acme-avaya/backups' "$TEST_DIR/log" >/dev/null ||
  fail 'installer did not receive backup directory'
grep 'verifier .*--host 127.0.0.1' "$TEST_DIR/log" >/dev/null ||
  fail 'local endpoints were not verified'

printf '%s\n' 'PASS: IP Office local deployment tests'
