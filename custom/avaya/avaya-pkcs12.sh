#!/usr/bin/env sh

set -eu

usage() {
  printf '%s\n' \
    'Usage: avaya-pkcs12.sh --cert FILE --key FILE --fullchain FILE' \
    '       --password-file FILE --output FILE [--compatibility modern|legacy]'
}

fail() {
  printf 'PKCS12 creation failed: %s\n' "$1" >&2
  exit 1
}

CERT_FILE=
KEY_FILE=
FULLCHAIN_FILE=
PASSWORD_FILE=
OUTPUT_FILE=
COMPATIBILITY=modern
TMP_DIR=
TMP_P12=

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  if [ -n "$TMP_P12" ] && [ -f "$TMP_P12" ]; then
    rm -f "$TMP_P12"
  fi
}
trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cert) [ "$#" -ge 2 ] || fail 'missing value for --cert'; CERT_FILE=$2; shift 2 ;;
    --key) [ "$#" -ge 2 ] || fail 'missing value for --key'; KEY_FILE=$2; shift 2 ;;
    --fullchain) [ "$#" -ge 2 ] || fail 'missing value for --fullchain'; FULLCHAIN_FILE=$2; shift 2 ;;
    --password-file) [ "$#" -ge 2 ] || fail 'missing value for --password-file'; PASSWORD_FILE=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || fail 'missing value for --output'; OUTPUT_FILE=$2; shift 2 ;;
    --compatibility) [ "$#" -ge 2 ] || fail 'missing value for --compatibility'; COMPATIBILITY=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$CERT_FILE" ] || fail '--cert is required'
[ -n "$KEY_FILE" ] || fail '--key is required'
[ -n "$FULLCHAIN_FILE" ] || fail '--fullchain is required'
[ -n "$PASSWORD_FILE" ] || fail '--password-file is required'
[ -n "$OUTPUT_FILE" ] || fail '--output is required'
case "$COMPATIBILITY" in modern | legacy) ;; *) fail '--compatibility must be modern or legacy' ;; esac

for INPUT_FILE in "$CERT_FILE" "$KEY_FILE" "$FULLCHAIN_FILE" "$PASSWORD_FILE"; do
  if [ ! -f "$INPUT_FILE" ] || [ ! -r "$INPUT_FILE" ]; then
    fail "input is missing or unreadable: $INPUT_FILE"
  fi
done

case "$OUTPUT_FILE" in
  /*) ;;
  *) fail '--output must be an absolute path' ;;
esac
[ ! -e "$OUTPUT_FILE" ] || fail "output already exists: $OUTPUT_FILE"

OUTPUT_DIR=${OUTPUT_FILE%/*}
if [ ! -d "$OUTPUT_DIR" ] || [ ! -w "$OUTPUT_DIR" ]; then
  fail "output directory is missing or unwritable: $OUTPUT_DIR"
fi

PASSWORD_MODE=$(stat -c '%a' "$PASSWORD_FILE" 2>/dev/null) ||
  fail 'cannot inspect password file permissions'
case "$PASSWORD_MODE" in
  400 | 600) ;;
  *) fail 'password file permissions must be 0400 or 0600' ;;
esac
[ -s "$PASSWORD_FILE" ] || fail 'password file is empty'
[ "$(wc -l <"$PASSWORD_FILE" | tr -d ' ')" -le 1 ] ||
  fail 'password file must contain one line'

openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 || fail 'invalid leaf certificate'
openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1 || fail 'invalid private key'
CERT_TEXT=$(openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null) ||
  fail 'unable to inspect certificate public key'
printf '%s\n' "$CERT_TEXT" | grep 'Public Key Algorithm: rsaEncryption' >/dev/null 2>&1 ||
  fail 'IP Office certificate must use RSA'
printf '%s\n' "$CERT_TEXT" | grep 'Public-Key: (2048 bit)' >/dev/null 2>&1 ||
  fail 'IP Office certificate must use a 2048-bit RSA key'

CERT_PUBLIC=$(openssl x509 -in "$CERT_FILE" -pubkey -noout |
  openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)
KEY_PUBLIC=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null |
  openssl dgst -sha256)
[ "$CERT_PUBLIC" = "$KEY_PUBLIC" ] || fail 'certificate and private key do not match'

umask 077
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/avaya-pkcs12.XXXXXX") || fail 'cannot create temporary directory'
CHAIN_FILE="$TMP_DIR/chain.pem"

awk '
  /-----BEGIN CERTIFICATE-----/ { certificate++ }
  certificate >= 2 { print }
' "$FULLCHAIN_FILE" >"$CHAIN_FILE"

[ -s "$CHAIN_FILE" ] || fail 'fullchain does not contain an intermediate certificate'
openssl crl2pkcs7 -nocrl -certfile "$CHAIN_FILE" 2>/dev/null |
  openssl pkcs7 -print_certs -noout >/dev/null 2>&1 || fail 'invalid intermediate chain'

TMP_P12=$(mktemp "$OUTPUT_DIR/.avaya-pkcs12.XXXXXX") || fail 'cannot create temporary output file'
chmod 600 "$TMP_P12"

if [ "$COMPATIBILITY" = legacy ]; then
  PKCS12_EXPORT_OPTIONS='-legacy -macalg SHA1'
  PKCS12_READ_OPTIONS=-legacy
else
  PKCS12_EXPORT_OPTIONS=
  PKCS12_READ_OPTIONS=
fi

# PKCS12_EXPORT_OPTIONS contains only the fixed values defined above.
# shellcheck disable=SC2086
openssl pkcs12 -export $PKCS12_EXPORT_OPTIONS \
  -name server -in "$CERT_FILE" -inkey "$KEY_FILE" -certfile "$CHAIN_FILE" \
  -passout "file:$PASSWORD_FILE" -out "$TMP_P12" >/dev/null 2>&1 ||
  fail 'OpenSSL could not create an Avaya-compatible PKCS12 file'

# shellcheck disable=SC2086
openssl pkcs12 $PKCS12_READ_OPTIONS -in "$TMP_P12" -noout \
  -passin "file:$PASSWORD_FILE" >/dev/null 2>&1 || fail 'generated PKCS12 file could not be reopened'

# shellcheck disable=SC2086
P12_CERT_PUBLIC=$(openssl pkcs12 $PKCS12_READ_OPTIONS -in "$TMP_P12" -clcerts -nokeys \
  -passin "file:$PASSWORD_FILE" 2>/dev/null |
  openssl x509 -pubkey -noout 2>/dev/null |
  openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)
[ "$P12_CERT_PUBLIC" = "$CERT_PUBLIC" ] || fail 'generated PKCS12 contains the wrong leaf certificate'

mv "$TMP_P12" "$OUTPUT_FILE"
TMP_P12=
chmod 600 "$OUTPUT_FILE"

FINGERPRINT=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//')
printf 'PKCS12_READY output=%s fingerprint=%s mode=600 compatibility=%s\n' \
  "$OUTPUT_FILE" "$FINGERPRINT" "$COMPATIBILITY"
