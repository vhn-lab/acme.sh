#!/usr/bin/env sh

set -eu

usage() {
  printf '%s\n' \
    'Usage: avaya-ipo-install.sh [--apply --acknowledge-service-restarts]' \
    '       --server-ip ADDRESS --p12 FILE --password-file FILE' \
    '       --expected-cert FILE'
}

fail() {
  printf 'IP Office installation failed: %s\n' "$1" >&2
  exit 1
}

APPLY=no
ACK_RESTARTS=no
SERVER_IP=
P12_FILE=
PASSWORD_FILE=
EXPECTED_CERT=
STAGED_P12=
BACKUP_FILE=
IMPORT_COMPLETED=no

cleanup() {
  if [ -n "$STAGED_P12" ] && [ -f "$STAGED_P12" ]; then
    rm -f "$STAGED_P12"
  fi
}
trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=yes; shift ;;
    --acknowledge-service-restarts) ACK_RESTARTS=yes; shift ;;
    --server-ip) [ "$#" -ge 2 ] || fail 'missing value for --server-ip'; SERVER_IP=$2; shift 2 ;;
    --p12) [ "$#" -ge 2 ] || fail 'missing value for --p12'; P12_FILE=$2; shift 2 ;;
    --password-file) [ "$#" -ge 2 ] || fail 'missing value for --password-file'; PASSWORD_FILE=$2; shift 2 ;;
    --expected-cert) [ "$#" -ge 2 ] || fail 'missing value for --expected-cert'; EXPECTED_CERT=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$SERVER_IP" ] || fail '--server-ip is required'
[ -n "$P12_FILE" ] || fail '--p12 is required'
[ -n "$PASSWORD_FILE" ] || fail '--password-file is required'
[ -n "$EXPECTED_CERT" ] || fail '--expected-cert is required'

if ! printf '%s\n' "$SERVER_IP" | awk -F. '
  NF != 4 { exit 1 }
  { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }
'; then
  fail 'server IP must be a valid IPv4 address'
fi

for INPUT_FILE in "$P12_FILE" "$PASSWORD_FILE" "$EXPECTED_CERT"; do
  [ -f "$INPUT_FILE" ] && [ -r "$INPUT_FILE" ] || fail "input is missing or unreadable: $INPUT_FILE"
done

PASSWORD_MODE=$(stat -c '%a' "$PASSWORD_FILE" 2>/dev/null) || fail 'cannot inspect password file permissions'
case "$PASSWORD_MODE" in 400 | 600) ;; *) fail 'password file permissions must be 0400 or 0600' ;; esac
[ -s "$PASSWORD_FILE" ] || fail 'password file is empty'
[ "$(wc -l <"$PASSWORD_FILE" | tr -d ' ')" -le 1 ] || fail 'password file must contain one line'

openssl x509 -in "$EXPECTED_CERT" -noout >/dev/null 2>&1 || fail 'expected certificate is invalid'
openssl pkcs12 -legacy -in "$P12_FILE" -noout -passin "file:$PASSWORD_FILE" >/dev/null 2>&1 ||
  fail 'PKCS12 file or password is invalid'

if [ "${AVAYA_TEST_MODE:-no}" = yes ]; then
  CERT_DIR=${AVAYA_TEST_CERT_DIR:?AVAYA_TEST_CERT_DIR is required in test mode}
  GEN_CERTS=${AVAYA_TEST_GEN_CERTS:?AVAYA_TEST_GEN_CERTS is required in test mode}
  EFFECTIVE_UID=${AVAYA_TEST_UID:-0}
else
  CERT_DIR=/opt/Avaya/certs
  GEN_CERTS=/opt/Avaya/scripts/gen_certs.sh
  EFFECTIVE_UID=$(id -u)
fi

[ "$EFFECTIVE_UID" -eq 0 ] || fail 'root privileges are required'
[ -d "$CERT_DIR" ] && [ -w "$CERT_DIR" ] || fail "Avaya certificate directory is unavailable: $CERT_DIR"
[ -f "$GEN_CERTS" ] && [ -x "$GEN_CERTS" ] || fail "Avaya certificate script is unavailable: $GEN_CERTS"

OUT_CERT="$CERT_DIR/cert_to_import.pem"
DEST_P12="$CERT_DIR/server_$SERVER_IP.p12"
EXPECTED_FP=$(openssl x509 -in "$EXPECTED_CERT" -noout -fingerprint -sha256 |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//')

CURRENT_FP=
if [ -s "$OUT_CERT" ] && openssl x509 -in "$OUT_CERT" -noout >/dev/null 2>&1; then
  CURRENT_FP=$(openssl x509 -in "$OUT_CERT" -noout -fingerprint -sha256 |
    sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//')
fi
if [ "$CURRENT_FP" = "$EXPECTED_FP" ]; then
  printf 'IPO_INSTALL result=UNCHANGED fingerprint=%s\n' "$EXPECTED_FP"
  exit 0
fi

if [ "$APPLY" != yes ]; then
  printf 'IPO_INSTALL result=WOULD_INSTALL fingerprint=%s restarts=required\n' "$EXPECTED_FP"
  exit 0
fi
[ "$ACK_RESTARTS" = yes ] || fail '--acknowledge-service-restarts is required with --apply'
[ ! -e "$DEST_P12" ] || fail "stale Avaya PKCS12 file already exists: $DEST_P12"

umask 077
if [ -e "$OUT_CERT" ]; then
  BACKUP_FILE="$CERT_DIR/cert_to_import.pem.acme-avaya-backup.$$"
  cp -p "$OUT_CERT" "$BACKUP_FILE" || fail 'cannot back up current Avaya certificate'
  chmod 600 "$BACKUP_FILE"
fi

STAGED_P12="$CERT_DIR/.server_$SERVER_IP.p12.acme-avaya.$$"
cp "$P12_FILE" "$STAGED_P12" || fail 'cannot stage PKCS12 file'
chmod 600 "$STAGED_P12"
mv "$STAGED_P12" "$DEST_P12"
STAGED_P12=$DEST_P12

PASSWORD=$(sed -n '1p' "$PASSWORD_FILE")
if ! "$GEN_CERTS" --install-p12cert --pass "$PASSWORD" --server-ip "$SERVER_IP"; then
  if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    cp -p "$BACKUP_FILE" "$OUT_CERT"
  else
    rm -f "$OUT_CERT"
  fi
  fail 'Avaya PKCS12 import failed; previous certificate restored when available'
fi
PASSWORD=
IMPORT_COMPLETED=yes
STAGED_P12=

[ -s "$OUT_CERT" ] || fail 'Avaya import did not create cert_to_import.pem'
IMPORTED_FP=$(openssl x509 -in "$OUT_CERT" -noout -fingerprint -sha256 2>/dev/null |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//') || true
if [ "$IMPORTED_FP" != "$EXPECTED_FP" ]; then
  if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    cp -p "$BACKUP_FILE" "$OUT_CERT"
  else
    rm -f "$OUT_CERT"
  fi
  fail 'imported certificate fingerprint is wrong; distribution was not started'
fi

if ! "$GEN_CERTS" --distribute-server-cert; then
  printf 'IP Office installation failed: distribution may be partial; backup retained at %s\n' \
    "${BACKUP_FILE:-none}" >&2
  exit 1
fi

if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
  rm -f "$BACKUP_FILE"
fi
printf 'IPO_INSTALL result=INSTALLED fingerprint=%s import=%s distribution=OK\n' \
  "$EXPECTED_FP" "$IMPORT_COMPLETED"
