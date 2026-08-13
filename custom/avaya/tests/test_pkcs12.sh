#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
BUILDER=${AVAYA_TEST_BUILDER:-$TEST_ROOT/custom/avaya/avaya-pkcs12.sh}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cleanup() { case "${TEST_DIR:-}" in /tmp/avaya-pkcs12-test.*) rm -r "$TEST_DIR" ;; esac; }

TEST_DIR=$(mktemp -d /tmp/avaya-pkcs12-test.XXXXXX)
trap cleanup EXIT HUP INT TERM

openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=Test Root CA' \
  -keyout "$TEST_DIR/ca.key" -out "$TEST_DIR/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=voice.example.invalid' \
  -keyout "$TEST_DIR/server.key" -out "$TEST_DIR/server.csr" >/dev/null 2>&1
printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' 'subjectAltName=DNS:voice.example.invalid' >"$TEST_DIR/server.ext"
openssl x509 -req -days 30 -sha256 -in "$TEST_DIR/server.csr" \
  -CA "$TEST_DIR/ca.crt" -CAkey "$TEST_DIR/ca.key" -CAcreateserial \
  -extfile "$TEST_DIR/server.ext" -out "$TEST_DIR/server.crt" >/dev/null 2>&1
cat "$TEST_DIR/server.crt" "$TEST_DIR/ca.crt" >"$TEST_DIR/fullchain.crt"

SECRET='fictitious-temporary-password-7391'
printf '%s\n' "$SECRET" >"$TEST_DIR/password"
chmod 600 "$TEST_DIR/password"

OUTPUT=$(sh "$BUILDER" --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --password-file "$TEST_DIR/password" \
  --output "$TEST_DIR/server.p12")
printf '%s\n' "$OUTPUT" | grep '^PKCS12_READY ' >/dev/null || fail 'success was not reported'
if printf '%s\n' "$OUTPUT" | grep "$SECRET" >/dev/null; then fail 'password was exposed'; fi
[ "$(stat -c '%a' "$TEST_DIR/server.p12")" = 600 ] || fail 'PKCS12 mode is not 0600'

openssl pkcs12 -legacy -in "$TEST_DIR/server.p12" -noout \
  -passin "file:$TEST_DIR/password" >/dev/null 2>&1 || fail 'PKCS12 cannot be opened'
CERT_COUNT=$(openssl pkcs12 -legacy -in "$TEST_DIR/server.p12" -nokeys \
  -passin "file:$TEST_DIR/password" 2>/dev/null | grep -c -- '-----BEGIN CERTIFICATE-----')
[ "$CERT_COUNT" -eq 2 ] || fail 'PKCS12 does not contain exactly two certificates'

openssl req -newkey rsa:2048 -nodes -subj '/CN=wrong.invalid' \
  -keyout "$TEST_DIR/wrong.key" -out "$TEST_DIR/wrong.csr" >/dev/null 2>&1
if sh "$BUILDER" --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/wrong.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --password-file "$TEST_DIR/password" \
  --output "$TEST_DIR/wrong.p12" >/dev/null 2>&1; then fail 'mismatched key was accepted'; fi

chmod 644 "$TEST_DIR/password"
if sh "$BUILDER" --cert "$TEST_DIR/server.crt" --key "$TEST_DIR/server.key" \
  --fullchain "$TEST_DIR/fullchain.crt" --password-file "$TEST_DIR/password" \
  --output "$TEST_DIR/insecure.p12" >/dev/null 2>&1; then fail 'insecure password file was accepted'; fi

printf '%s\n' 'PASS: Avaya PKCS12 creation tests'
