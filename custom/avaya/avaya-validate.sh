#!/usr/bin/env sh

set -eu

usage() {
  printf '%s\n' \
    'Usage: avaya-validate.sh --cert FILE --key FILE --fullchain FILE' \
    '       --expected-name FQDN [--min-days DAYS] [--trust-file FILE]' \
    '       [--allow-partial-chain]'
}

fail() {
  printf 'Certificate validation failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  case "${VALIDATE_TMP_DIR:-}" in
    /tmp/avaya-cert-validate.*) rm -r "$VALIDATE_TMP_DIR" ;;
  esac
}

CERT_FILE=
KEY_FILE=
FULLCHAIN_FILE=
EXPECTED_NAME=
MIN_DAYS=7
TRUST_FILE=
ALLOW_PARTIAL_CHAIN=no

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cert) [ "$#" -ge 2 ] || fail 'missing value for --cert'; CERT_FILE=$2; shift 2 ;;
    --key) [ "$#" -ge 2 ] || fail 'missing value for --key'; KEY_FILE=$2; shift 2 ;;
    --fullchain) [ "$#" -ge 2 ] || fail 'missing value for --fullchain'; FULLCHAIN_FILE=$2; shift 2 ;;
    --expected-name) [ "$#" -ge 2 ] || fail 'missing value for --expected-name'; EXPECTED_NAME=$2; shift 2 ;;
    --min-days) [ "$#" -ge 2 ] || fail 'missing value for --min-days'; MIN_DAYS=$2; shift 2 ;;
    --trust-file) [ "$#" -ge 2 ] || fail 'missing value for --trust-file'; TRUST_FILE=$2; shift 2 ;;
    --allow-partial-chain) ALLOW_PARTIAL_CHAIN=yes; shift ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$CERT_FILE" ] || fail '--cert is required'
[ -n "$KEY_FILE" ] || fail '--key is required'
[ -n "$FULLCHAIN_FILE" ] || fail '--fullchain is required'
[ -n "$EXPECTED_NAME" ] || fail '--expected-name is required'

case "$MIN_DAYS" in
  '' | *[!0-9]*) fail '--min-days must be an integer' ;;
esac
if [ "$MIN_DAYS" -lt 1 ] || [ "$MIN_DAYS" -gt 90 ]; then
  fail '--min-days must be between 1 and 90'
fi

case "$EXPECTED_NAME" in
  '' | .* | *. | *..* | *[!A-Za-z0-9._-]*) fail 'invalid expected DNS name' ;;
esac

for REQUIRED_FILE in "$CERT_FILE" "$KEY_FILE" "$FULLCHAIN_FILE"; do
  if [ ! -f "$REQUIRED_FILE" ] || [ ! -r "$REQUIRED_FILE" ] || [ ! -s "$REQUIRED_FILE" ]; then
    fail "missing, unreadable, or empty file: $REQUIRED_FILE"
  fi
done
if [ -n "$TRUST_FILE" ]; then
  if [ ! -f "$TRUST_FILE" ] || [ ! -r "$TRUST_FILE" ] || [ ! -s "$TRUST_FILE" ]; then
    fail "invalid trust file: $TRUST_FILE"
  fi
fi
[ "$ALLOW_PARTIAL_CHAIN" != yes ] || [ -n "$TRUST_FILE" ] ||
  fail '--allow-partial-chain requires --trust-file'

KEY_MODE=$(stat -c '%a' "$KEY_FILE" 2>/dev/null) || fail 'unable to inspect private-key permissions'
case "$KEY_MODE" in
  400 | 600) ;;
  *) fail "private key must have mode 400 or 600, found $KEY_MODE" ;;
esac

openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 || fail 'certificate is not valid PEM'
openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1 || fail 'private key is not valid PEM'
CERT_TEXT=$(openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null) ||
  fail 'unable to inspect certificate public key'
printf '%s\n' "$CERT_TEXT" | grep 'Public Key Algorithm: rsaEncryption' >/dev/null 2>&1 ||
  fail 'IP Office certificate must use RSA'
printf '%s\n' "$CERT_TEXT" | grep 'Public-Key: (2048 bit)' >/dev/null 2>&1 ||
  fail 'IP Office certificate must use a 2048-bit RSA key'

VALIDATE_TMP_DIR=$(mktemp -d /tmp/avaya-cert-validate.XXXXXX)
trap cleanup EXIT HUP INT TERM
CERT_PUBLIC_KEY="$VALIDATE_TMP_DIR/cert-public.der"
KEY_PUBLIC_KEY="$VALIDATE_TMP_DIR/key-public.der"
INTERMEDIATES="$VALIDATE_TMP_DIR/intermediates.pem"

openssl x509 -in "$CERT_FILE" -pubkey -noout |
  openssl pkey -pubin -outform DER >"$CERT_PUBLIC_KEY" 2>/dev/null ||
  fail 'unable to extract certificate public key'
openssl pkey -in "$KEY_FILE" -pubout -outform DER >"$KEY_PUBLIC_KEY" 2>/dev/null ||
  fail 'unable to derive public key from private key'
cmp -s "$CERT_PUBLIC_KEY" "$KEY_PUBLIC_KEY" || fail 'certificate and private key do not match'

NOT_BEFORE=$(openssl x509 -in "$CERT_FILE" -noout -startdate | sed 's/^notBefore=//')
NOT_BEFORE_EPOCH=$(date -d "$NOT_BEFORE" +%s 2>/dev/null) || fail 'unable to parse certificate start date'
NOW_EPOCH=$(date +%s)
[ "$NOT_BEFORE_EPOCH" -le "$NOW_EPOCH" ] || fail 'certificate is not valid yet'

CHECK_SECONDS=$((MIN_DAYS * 86400))
openssl x509 -in "$CERT_FILE" -noout -checkend "$CHECK_SECONDS" >/dev/null 2>&1 ||
  fail "certificate expires in fewer than $MIN_DAYS days"

HOST_CHECK=$(openssl x509 -in "$CERT_FILE" -noout -checkhost "$EXPECTED_NAME" 2>/dev/null) ||
  fail "unable to check certificate SAN for $EXPECTED_NAME"
printf '%s\n' "$HOST_CHECK" | grep 'does match certificate' >/dev/null 2>&1 ||
  fail "certificate SAN does not cover $EXPECTED_NAME"

awk '
  /-----BEGIN CERTIFICATE-----/ { certificate++ }
  certificate >= 2 { print }
' "$FULLCHAIN_FILE" >"$INTERMEDIATES"
[ -s "$INTERMEDIATES" ] || fail 'fullchain does not contain an issuer certificate'

if [ -n "$TRUST_FILE" ]; then
  if [ "$ALLOW_PARTIAL_CHAIN" = yes ]; then
    openssl verify -partial_chain -CAfile "$TRUST_FILE" \
      -untrusted "$INTERMEDIATES" "$CERT_FILE" >/dev/null 2>&1 ||
      fail 'certificate partial-chain validation failed'
  else
    openssl verify -CAfile "$TRUST_FILE" -untrusted "$INTERMEDIATES" "$CERT_FILE" >/dev/null 2>&1 ||
      fail 'certificate chain validation failed'
  fi
else
  openssl verify -untrusted "$INTERMEDIATES" "$CERT_FILE" >/dev/null 2>&1 ||
    fail 'certificate chain validation failed against system trust store'
fi

FINGERPRINT=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//')
SERIAL=$(openssl x509 -in "$CERT_FILE" -noout -serial | sed 's/^serial=//')
NOT_AFTER=$(openssl x509 -in "$CERT_FILE" -noout -enddate | sed 's/^notAfter=//')

printf 'VALID fingerprint=%s serial=%s not_after=%s expected_name=%s\n' \
  "$FINGERPRINT" "$SERIAL" "$NOT_AFTER" "$EXPECTED_NAME"
