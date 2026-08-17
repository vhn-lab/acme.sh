#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
VERIFIER=${AVAYA_TEST_VERIFIER:-$TEST_ROOT/custom/avaya/avaya-ipo-verify.sh}
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cleanup() { case "${TEST_DIR:-}" in /tmp/avaya-verify-test.*) rm -r "$TEST_DIR" ;; esac; }

TEST_DIR=$(mktemp -d /tmp/avaya-verify-test.XXXXXX)
trap cleanup EXIT HUP INT TERM

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=127.0.0.1' \
  -addext 'subjectAltName=IP:127.0.0.1' -keyout "$TEST_DIR/key" \
  -out "$TEST_DIR/cert" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=stale.invalid' \
  -keyout "$TEST_DIR/stale-key" -out "$TEST_DIR/stale-cert" >/dev/null 2>&1

GOOD_PORT=19443
STALE_PORT=19444
openssl s_server -quiet -accept "$GOOD_PORT" -cert "$TEST_DIR/cert" -key "$TEST_DIR/key" \
  >"$TEST_DIR/good.log" 2>&1 &
GOOD_PID=$!
openssl s_server -quiet -accept "$STALE_PORT" -cert "$TEST_DIR/stale-cert" -key "$TEST_DIR/stale-key" \
  >"$TEST_DIR/stale.log" 2>&1 &
STALE_PID=$!
trap 'kill "$GOOD_PID" "$STALE_PID" 2>/dev/null || true; cleanup' EXIT HUP INT TERM
sleep 1
mkdir "$TEST_DIR/avaya-certs"
touch "$TEST_DIR/avaya-certs/.distrib_complete"

OUTPUT=$(sh "$VERIFIER" --expected-cert "$TEST_DIR/cert" --host 127.0.0.1 \
  --ports "$GOOD_PORT" --webcontrol-port "$GOOD_PORT" --timeout 3 \
  --cert-dir "$TEST_DIR/avaya-certs")
printf '%s\n' "$OUTPUT" | grep 'IPO_VERIFY result=OK' >/dev/null || fail 'matching ports were rejected'
printf '%s\n' "$OUTPUT" | grep 'IPO_DISTRIBUTION status=COMPLETE' >/dev/null ||
  fail 'completed distribution was not reported'

touch "$TEST_DIR/avaya-certs/.distrib_inprogress"
if sh "$VERIFIER" --expected-cert "$TEST_DIR/cert" --host 127.0.0.1 \
  --ports "$GOOD_PORT" --webcontrol-port "$GOOD_PORT" --timeout 3 \
  --cert-dir "$TEST_DIR/avaya-certs" >/dev/null 2>&1; then
  fail 'in-progress distribution was accepted'
fi
rm "$TEST_DIR/avaya-certs/.distrib_inprogress"

if OUTPUT=$(sh "$VERIFIER" --expected-cert "$TEST_DIR/cert" --host 127.0.0.1 \
  --ports "$GOOD_PORT" --webcontrol-port "$STALE_PORT" --timeout 3 --skip-marker-check); then
  fail 'stale WebControl certificate was accepted'
fi
printf '%s\n' "$OUTPUT" | grep 'status=RESTART_REQUIRED' >/dev/null ||
  fail 'stale WebControl did not request a restart'

printf '%s\n' 'PASS: IP Office endpoint verification tests'
