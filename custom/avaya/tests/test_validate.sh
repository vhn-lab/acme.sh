#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
VALIDATOR="$TEST_ROOT/custom/avaya/avaya-validate.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  case "${TEST_DIR:-}" in
    /tmp/avaya-validate-test.*) rm -r "$TEST_DIR" ;;
  esac
}

TEST_DIR=$(mktemp -d /tmp/avaya-validate-test.XXXXXX)
trap cleanup EXIT HUP INT TERM

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj '/CN=Test Root CA' \
  -keyout "$TEST_DIR/ca.key" -out "$TEST_DIR/ca.crt" >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes \
  -subj '/CN=ipo.example.invalid' \
  -addext 'subjectAltName=DNS:ipo.example.invalid,DNS:voice.example.invalid' \
  -keyout "$TEST_DIR/server.key" -out "$TEST_DIR/server.csr" >/dev/null 2>&1

printf '%s\n' \
  'basicConstraints=CA:FALSE' \
  'keyUsage=digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' \
  'subjectAltName=DNS:ipo.example.invalid,DNS:voice.example.invalid' >"$TEST_DIR/server.ext"

openssl x509 -req -days 30 -sha256 \
  -in "$TEST_DIR/server.csr" -CA "$TEST_DIR/ca.crt" -CAkey "$TEST_DIR/ca.key" \
  -CAcreateserial -extfile "$TEST_DIR/server.ext" -out "$TEST_DIR/server.crt" >/dev/null 2>&1

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$TEST_DIR/wrong.key" >/dev/null 2>&1

chmod 600 "$TEST_DIR/server.key" "$TEST_DIR/wrong.key"
cat "$TEST_DIR/server.crt" "$TEST_DIR/ca.crt" >"$TEST_DIR/fullchain.crt"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj '/CN=ipo.example.invalid' -addext 'subjectAltName=DNS:ipo.example.invalid' \
  -keyout "$TEST_DIR/ec.key" -out "$TEST_DIR/ec.crt" >/dev/null 2>&1
chmod 600 "$TEST_DIR/ec.key"
cat "$TEST_DIR/ec.crt" "$TEST_DIR/ca.crt" >"$TEST_DIR/ec-fullchain.crt"
if sh "$VALIDATOR" --cert "$TEST_DIR/ec.crt" --key "$TEST_DIR/ec.key" \
  --fullchain "$TEST_DIR/ec-fullchain.crt" --expected-name ipo.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" >/dev/null 2>&1; then
  fail 'ECC certificate was accepted for IP Office'
fi

sh "$VALIDATOR" \
  --cert "$TEST_DIR/server.crt" \
  --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" \
  --expected-name ipo.example.invalid \
  --min-days 7 \
  --trust-file "$TEST_DIR/ca.crt" >/dev/null || fail 'valid certificate was rejected'

sh "$VALIDATOR" \
  --cert "$TEST_DIR/server.crt" \
  --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" \
  --expected-name ipo.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" \
  --allow-partial-chain >/dev/null || fail 'explicit partial-chain validation was rejected'

if sh "$VALIDATOR" --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name ipo.example.invalid \
  --allow-partial-chain >/dev/null 2>&1; then
  fail 'partial-chain validation worked without an explicit trust file'
fi

if sh "$VALIDATOR" --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/wrong.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name ipo.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" >/dev/null 2>&1; then
  fail 'mismatched private key was accepted'
fi

if sh "$VALIDATOR" --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name wrong.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" >/dev/null 2>&1; then
  fail 'wrong SAN was accepted'
fi

if sh "$VALIDATOR" --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name ipo.example.invalid \
  --min-days 60 --trust-file "$TEST_DIR/ca.crt" >/dev/null 2>&1; then
  fail 'insufficient remaining validity was accepted'
fi

chmod 644 "$TEST_DIR/server.key"
if sh "$VALIDATOR" --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --expected-name ipo.example.invalid \
  --trust-file "$TEST_DIR/ca.crt" >/dev/null 2>&1; then
  fail 'insecure private-key permissions were accepted'
fi

printf '%s\n' 'PASS: Avaya certificate validation tests'
