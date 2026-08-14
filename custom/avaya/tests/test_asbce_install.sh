#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
INSTALLER=${ORANGE_TEST_INSTALLER:-$TEST_ROOT/custom/avaya/asbce/orange-ipo-acme-cert-install.sh}
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cleanup() { case "${TEST_DIR:-}" in /tmp/orange-asbce-test.*) rm -r "$TEST_DIR" ;; esac; }

TEST_DIR=$(mktemp -d /tmp/orange-asbce-test.XXXXXX)
trap cleanup EXIT HUP INT TERM
mkdir -p "$TEST_DIR/spool" "$TEST_DIR/state" "$TEST_DIR/key" "$TEST_DIR/cert" "$TEST_DIR/ca"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=Test Root' \
  -keyout "$TEST_DIR/root.key" -out "$TEST_DIR/root.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=sbc.example.invalid' \
  -addext 'subjectAltName=DNS:sbc.example.invalid' \
  -keyout "$TEST_DIR/server.key" -out "$TEST_DIR/server.csr" >/dev/null 2>&1
printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' 'subjectAltName=DNS:sbc.example.invalid' >"$TEST_DIR/server.ext"
openssl x509 -req -days 30 -sha256 -in "$TEST_DIR/server.csr" -CA "$TEST_DIR/root.crt" \
  -CAkey "$TEST_DIR/root.key" -CAcreateserial -extfile "$TEST_DIR/server.ext" \
  -out "$TEST_DIR/server.crt" >/dev/null 2>&1
cat "$TEST_DIR/server.crt" "$TEST_DIR/root.crt" >"$TEST_DIR/fullchain.pem"

FINGERPRINT=$(openssl x509 -in "$TEST_DIR/server.crt" -noout -fingerprint -sha256 |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//' | tr -d ':')

cat >"$TEST_DIR/reboot.sh" <<EOF
#!/usr/bin/env sh
printf '%s\n' reboot >>'$TEST_DIR/reboot.log'
EOF
chmod 700 "$TEST_DIR/reboot.sh"

run_installer() {
  ORANGE_ACME_TEST_MODE=yes ORANGE_ACME_TEST_UID=0 \
  ORANGE_ACME_TEST_SPOOL="$TEST_DIR/spool" ORANGE_ACME_TEST_STATE="$TEST_DIR/state" \
  ORANGE_ACME_TEST_KEY_DIR="$TEST_DIR/key" ORANGE_ACME_TEST_CERT_DIR="$TEST_DIR/cert" \
  ORANGE_ACME_TEST_CA_DIR="$TEST_DIR/ca" ORANGE_ACME_TEST_REBOOT_CMD="$TEST_DIR/reboot.sh" \
  ORANGE_ACME_TEST_TRUST_FILE="$TEST_DIR/root.crt" sh "$INSTALLER" "$@"
}

OUTPUT=$(run_installer)
printf '%s\n' "$OUTPUT" | grep 'result=NO_CHANGE' >/dev/null || fail 'empty spool was not a normal no-change result'

make_transaction() {
  TRANSACTION="$TEST_DIR/spool/$FINGERPRINT"
  rm -rf "$TRANSACTION"
  mkdir "$TRANSACTION"
  cp "$TEST_DIR/server.key" "$TRANSACTION/server.key"
  cp "$TEST_DIR/fullchain.pem" "$TRANSACTION/fullchain.pem"
  cp "$TEST_DIR/root.crt" "$TRANSACTION/chain.pem"
  chmod 600 "$TRANSACTION/server.key"
  printf 'PROFILE=voice-edge\nEXPECTED_NAME=sbc.example.invalid\nFINGERPRINT_SHA256=%s\n' \
    "$FINGERPRINT" >"$TRANSACTION/manifest"
  : >"$TRANSACTION/READY"
}

make_transaction
OUTPUT=$(run_installer)
printf '%s\n' "$OUTPUT" | grep 'result=WOULD_INSTALL' >/dev/null || fail 'default mode was not non-destructive'
[ ! -e "$TEST_DIR/cert/lets_encrypt_auto.crt" ] || fail 'default mode changed active certificate'

if run_installer --apply >/dev/null 2>&1; then fail 'apply worked without reboot acknowledgement'; fi
OUTPUT=$(run_installer --apply --acknowledge-reboot)
printf '%s\n' "$OUTPUT" | grep 'result=INSTALLED' >/dev/null || fail 'valid transaction was not installed'
[ "$(wc -l <"$TEST_DIR/reboot.log")" -eq 1 ] || fail 'reboot was not requested exactly once'

make_transaction
OUTPUT=$(run_installer --apply --acknowledge-reboot)
printf '%s\n' "$OUTPUT" | grep 'result=UNCHANGED' >/dev/null || fail 'identical certificate was not idempotent'
[ "$(wc -l <"$TEST_DIR/reboot.log")" -eq 1 ] || fail 'unchanged certificate requested another reboot'

make_transaction
printf '%s\n' 'not-a-private-key' >"$TEST_DIR/spool/$FINGERPRINT/server.key"
if run_installer --apply --acknowledge-reboot >/dev/null 2>&1; then fail 'invalid private key was accepted'; fi
[ "$(wc -l <"$TEST_DIR/reboot.log")" -eq 1 ] || fail 'failed validation requested a reboot'

printf '%s\n' 'PASS: ASBCE transactional certificate installer tests'
