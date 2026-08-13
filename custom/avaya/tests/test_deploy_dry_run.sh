#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
DEPLOYER="$TEST_ROOT/custom/avaya/avaya-deploy.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  case "${TEST_DIR:-}" in
    /tmp/avaya-deploy-test.*) rm -r "$TEST_DIR" ;;
  esac
}

TEST_DIR=$(mktemp -d /tmp/avaya-deploy-test.XXXXXX)
trap cleanup EXIT HUP INT TERM
mkdir -p "$TEST_DIR/state/voice-edge"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj '/CN=Test Root CA' \
  -keyout "$TEST_DIR/ca.key" -out "$TEST_DIR/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes \
  -subj '/CN=voice.example.invalid' \
  -addext 'subjectAltName=DNS:voice.example.invalid' \
  -keyout "$TEST_DIR/server.key" -out "$TEST_DIR/server.csr" >/dev/null 2>&1
printf '%s\n' \
  'basicConstraints=CA:FALSE' \
  'keyUsage=digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' \
  'subjectAltName=DNS:voice.example.invalid' >"$TEST_DIR/server.ext"
openssl x509 -req -days 30 -sha256 \
  -in "$TEST_DIR/server.csr" -CA "$TEST_DIR/ca.crt" -CAkey "$TEST_DIR/ca.key" \
  -CAcreateserial -extfile "$TEST_DIR/server.ext" -out "$TEST_DIR/server.crt" >/dev/null 2>&1
chmod 600 "$TEST_DIR/server.key"
cat "$TEST_DIR/server.crt" "$TEST_DIR/ca.crt" >"$TEST_DIR/fullchain.crt"

cp "$TEST_ROOT/custom/avaya/targets.example.csv" "$TEST_DIR/targets.csv"
sed \
  -e "s|^TARGETS_FILE=.*|TARGETS_FILE=$TEST_DIR/targets.csv|" \
  -e "s|^STATE_DIR=.*|STATE_DIR=$TEST_DIR/state|" \
  "$TEST_ROOT/custom/avaya/config.example" >"$TEST_DIR/config-continue"

if sh "$DEPLOYER" --config "$TEST_DIR/config-continue" --profile voice-edge \
  --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name voice.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" >/dev/null 2>&1; then
  fail 'deployment engine ran without --dry-run'
fi

sh "$DEPLOYER" --dry-run --config "$TEST_DIR/config-continue" --profile voice-edge \
  --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name voice.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" >"$TEST_DIR/plan-ok"
grep 'target=IPO1 .*status=WOULD_DEPLOY' "$TEST_DIR/plan-ok" >/dev/null ||
  fail 'valid target was not planned for deployment'

FINGERPRINT=$(openssl x509 -in "$TEST_DIR/server.crt" -noout -fingerprint -sha256 |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//')
printf '%s\n' "$FINGERPRINT" >"$TEST_DIR/state/voice-edge/IPO1.sha256"
sh "$DEPLOYER" --dry-run --config "$TEST_DIR/config-continue" --profile voice-edge \
  --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name voice.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" >"$TEST_DIR/plan-unchanged"
grep 'target=IPO1 .*status=UNCHANGED' "$TEST_DIR/plan-unchanged" >/dev/null ||
  fail 'matching fingerprint was not treated as unchanged'

if sh "$DEPLOYER" --dry-run --config "$TEST_DIR/config-continue" --profile voice-edge \
  --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name voice.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" --simulate-failure SBC1 >"$TEST_DIR/plan-continue"; then
  fail 'simulated failure returned success'
fi
grep 'target=SBC2 .*status=WOULD_DEPLOY' "$TEST_DIR/plan-continue" >/dev/null ||
  fail 'continue policy did not plan the target following a failure'

sed 's/^FAILURE_POLICY=.*/FAILURE_POLICY=stop/' "$TEST_DIR/config-continue" >"$TEST_DIR/config-stop"
if sh "$DEPLOYER" --dry-run --config "$TEST_DIR/config-stop" --profile voice-edge \
  --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name voice.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" --simulate-failure SBC1 >"$TEST_DIR/plan-stop"; then
  fail 'simulated stop-policy failure returned success'
fi
grep 'target=SBC2 .*status=NOT_ATTEMPTED' "$TEST_DIR/plan-stop" >/dev/null ||
  fail 'stop policy did not block the target following a failure'

if grep -E 'ssh|scp|sftp|systemctl|gen_certs[.]sh' "$DEPLOYER" >/dev/null; then
  fail 'dry-run engine contains a remote execution or service command'
fi

printf '%s\n' 'PASS: Avaya dry-run deployment planning tests'
