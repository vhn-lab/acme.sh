#!/usr/bin/env sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

usage() {
  printf '%s\n' \
    'Usage: avaya-ipo-install.sh [--apply --acknowledge-service-restarts]' \
    '       --server-ip ADDRESS --p12 FILE --password-file FILE' \
    '       --expected-cert FILE [--backup-dir DIRECTORY]' \
    '       [--openssl-config FILE]'
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
BACKUP_DIR=${AVAYA_BACKUP_DIR:-/root/orange/script/acme.sh/avaya-backups}
TRANSACTION_DIR=
OPENSSL_CONFIG="$SCRIPT_DIR/openssl-legacy.cnf"
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
    --backup-dir) [ "$#" -ge 2 ] || fail 'missing value for --backup-dir'; BACKUP_DIR=$2; shift 2 ;;
    --openssl-config) [ "$#" -ge 2 ] || fail 'missing value for --openssl-config'; OPENSSL_CONFIG=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$SERVER_IP" ] || fail '--server-ip is required'
[ -n "$P12_FILE" ] || fail '--p12 is required'
[ -n "$PASSWORD_FILE" ] || fail '--password-file is required'
[ -n "$EXPECTED_CERT" ] || fail '--expected-cert is required'
case "$BACKUP_DIR" in /*) ;; *) fail '--backup-dir must be an absolute path' ;; esac
case "$OPENSSL_CONFIG" in /*) ;; *) fail '--openssl-config must be an absolute path' ;; esac

if ! printf '%s\n' "$SERVER_IP" | awk -F. '
  NF != 4 { exit 1 }
  { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }
'; then
  fail 'server IP must be a valid IPv4 address'
fi

for INPUT_FILE in "$P12_FILE" "$PASSWORD_FILE" "$EXPECTED_CERT"; do
  if [ ! -f "$INPUT_FILE" ] || [ ! -r "$INPUT_FILE" ]; then
    fail "input is missing or unreadable: $INPUT_FILE"
  fi
done

PASSWORD_MODE=$(stat -c '%a' "$PASSWORD_FILE" 2>/dev/null) || fail 'cannot inspect password file permissions'
case "$PASSWORD_MODE" in 400 | 600) ;; *) fail 'password file permissions must be 0400 or 0600' ;; esac
[ -s "$PASSWORD_FILE" ] || fail 'password file is empty'
[ "$(wc -l <"$PASSWORD_FILE" | tr -d ' ')" -le 1 ] || fail 'password file must contain one line'

openssl x509 -in "$EXPECTED_CERT" -noout >/dev/null 2>&1 || fail 'expected certificate is invalid'
EXPECTED_CERT_TEXT=$(openssl x509 -in "$EXPECTED_CERT" -noout -text 2>/dev/null) ||
  fail 'cannot inspect expected certificate public key'
printf '%s\n' "$EXPECTED_CERT_TEXT" | grep 'Public Key Algorithm: rsaEncryption' >/dev/null 2>&1 ||
  fail 'IP Office certificate must use RSA'
printf '%s\n' "$EXPECTED_CERT_TEXT" | grep 'Public-Key: (2048 bit)' >/dev/null 2>&1 ||
  fail 'IP Office certificate must use a 2048-bit RSA key'
openssl pkcs12 -in "$P12_FILE" -noout -passin "file:$PASSWORD_FILE" >/dev/null 2>&1 ||
  fail 'PKCS12 file is not readable by the OpenSSL mode used by Avaya'

if [ "${AVAYA_TEST_MODE:-no}" = yes ]; then
  CERT_DIR=${AVAYA_TEST_CERT_DIR:?AVAYA_TEST_CERT_DIR is required in test mode}
  GEN_CERTS=${AVAYA_TEST_GEN_CERTS:?AVAYA_TEST_GEN_CERTS is required in test mode}
  SYSTEMCTL=${AVAYA_TEST_SYSTEMCTL:?AVAYA_TEST_SYSTEMCTL is required in test mode}
  EFFECTIVE_UID=${AVAYA_TEST_UID:-0}
  MARKER_STABLE_REQUIRED=1
  MARKER_POLL_SECONDS=0
  MARKER_MAX_POLLS=3
else
  CERT_DIR=/opt/Avaya/certs
  GEN_CERTS=/opt/Avaya/scripts/gen_certs.sh
  SYSTEMCTL=systemctl
  EFFECTIVE_UID=$(id -u)
  MARKER_STABLE_REQUIRED=3
  MARKER_POLL_SECONDS=2
  MARKER_MAX_POLLS=600
fi

[ "$EFFECTIVE_UID" -eq 0 ] || fail 'root privileges are required'
if [ ! -d "$CERT_DIR" ] || [ ! -w "$CERT_DIR" ]; then
  fail "Avaya certificate directory is unavailable: $CERT_DIR"
fi
if [ ! -f "$GEN_CERTS" ] || [ ! -x "$GEN_CERTS" ]; then
  fail "Avaya certificate script is unavailable: $GEN_CERTS"
fi

OPENSSL_MAJOR=$(openssl version | awk '{ split($2, version, "."); print version[1] }')
case "$OPENSSL_MAJOR" in '' | *[!0-9]*) fail 'cannot determine OpenSSL major version' ;; esac
USE_LEGACY_PROVIDER=no
if [ "$OPENSSL_MAJOR" -ge 3 ]; then
  if [ ! -f "$OPENSSL_CONFIG" ] || [ ! -r "$OPENSSL_CONFIG" ]; then
    fail "OpenSSL 3 compatibility configuration is unavailable: $OPENSSL_CONFIG"
  fi
  OPENSSL_CONF="$OPENSSL_CONFIG" openssl list -providers 2>/dev/null |
    grep -q '^  legacy$' || fail 'OpenSSL legacy provider could not be activated'
  USE_LEGACY_PROVIDER=yes
fi

run_gen_certs() {
  if [ "$USE_LEGACY_PROVIDER" = yes ]; then
    OPENSSL_CONF="$OPENSSL_CONFIG" "$GEN_CERTS" "$@"
  else
    "$GEN_CERTS" "$@"
  fi
}

OUT_CERT="$CERT_DIR/cert_to_import.pem"
CURRENT_CERT="$CERT_DIR/cert.pem"
DEST_P12="$CERT_DIR/server_$SERVER_IP.p12"
EXPECTED_FP=$(openssl x509 -in "$EXPECTED_CERT" -noout -fingerprint -sha256 |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//')

CURRENT_FP=
if [ -s "$CURRENT_CERT" ] && openssl x509 -in "$CURRENT_CERT" -noout >/dev/null 2>&1; then
  CURRENT_FP=$(openssl x509 -in "$CURRENT_CERT" -noout -fingerprint -sha256 |
    sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//')
elif [ -s "$OUT_CERT" ] && openssl x509 -in "$OUT_CERT" -noout >/dev/null 2>&1; then
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
BACKUP_NEEDED=no
for BACKUP_SOURCE in "$CERT_DIR/server.pem" "$CERT_DIR/cert.pem" \
  "$CERT_DIR/key.pem" "$CERT_DIR/ca" "$OUT_CERT"; do
  [ ! -e "$BACKUP_SOURCE" ] || BACKUP_NEEDED=yes
done
if [ "$BACKUP_NEEDED" = yes ]; then
  mkdir -p "$BACKUP_DIR" || fail 'cannot create transactional backup directory'
  chmod 700 "$BACKUP_DIR" || fail 'cannot protect transactional backup directory'
  TRANSACTION_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
  TRANSACTION_DIR="$BACKUP_DIR/ipo-$TRANSACTION_ID"
  mkdir "$TRANSACTION_DIR" || fail 'cannot create transactional backup'
  chmod 700 "$TRANSACTION_DIR" || fail 'cannot protect transactional backup'
  mkdir "$TRANSACTION_DIR/active" "$TRANSACTION_DIR/import" ||
    fail 'cannot create transactional backup structure'

  for BACKUP_NAME in server.pem cert.pem key.pem; do
    if [ -f "$CERT_DIR/$BACKUP_NAME" ] && [ ! -L "$CERT_DIR/$BACKUP_NAME" ]; then
      cp -p "$CERT_DIR/$BACKUP_NAME" "$TRANSACTION_DIR/active/$BACKUP_NAME" ||
        fail "cannot back up active Avaya file: $BACKUP_NAME"
    fi
  done
  if [ -d "$CERT_DIR/ca" ] && [ ! -L "$CERT_DIR/ca" ]; then
    mkdir "$TRANSACTION_DIR/active/ca" || fail 'cannot create CA backup directory'
    cp -pR "$CERT_DIR/ca/." "$TRANSACTION_DIR/active/ca/" ||
      fail 'cannot back up active Avaya CA directory'
  fi
  if [ -f "$OUT_CERT" ] && [ ! -L "$OUT_CERT" ]; then
    BACKUP_FILE="$TRANSACTION_DIR/import/cert_to_import.pem"
    cp -p "$OUT_CERT" "$BACKUP_FILE" || fail 'cannot back up current Avaya import certificate'
  fi

  find "$TRANSACTION_DIR" -type d -exec chmod 700 {} \; ||
    fail 'cannot protect transactional backup directories'
  find "$TRANSACTION_DIR" -type f -exec chmod 600 {} \; ||
    fail 'cannot protect transactional backup files'
  if [ "${AVAYA_TEST_MODE:-no}" != yes ]; then
    chown -R root:root "$TRANSACTION_DIR" || fail 'cannot set transactional backup ownership'
  fi
fi

STAGED_P12="$CERT_DIR/.server_$SERVER_IP.p12.acme-avaya.$$"
cp "$P12_FILE" "$STAGED_P12" || fail 'cannot stage PKCS12 file'
chmod 600 "$STAGED_P12"
mv "$STAGED_P12" "$DEST_P12"
STAGED_P12=$DEST_P12

PASSWORD=$(sed -n '1p' "$PASSWORD_FILE")
if ! run_gen_certs --install-p12cert --pass "$PASSWORD" --server-ip "$SERVER_IP"; then
  fail 'Avaya PKCS12 import failed; Avaya certificate files were not modified by the adapter'
fi
PASSWORD=
IMPORT_COMPLETED=yes
STAGED_P12=

[ -s "$OUT_CERT" ] || fail 'Avaya import did not create cert_to_import.pem'
IMPORTED_FP=$(openssl x509 -in "$OUT_CERT" -noout -fingerprint -sha256 2>/dev/null |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//') || true
if [ "$IMPORTED_FP" != "$EXPECTED_FP" ]; then
  fail 'imported certificate fingerprint is wrong; distribution was not started and Avaya files were not modified by the adapter'
fi

if ! run_gen_certs --distribute-server-cert; then
  printf 'IP Office installation failed: distribution may be partial; backup retained at %s\n' \
    "${TRANSACTION_DIR:-none}" >&2
  exit 1
fi

# .wcp_no_restart makes the Avaya distribution copy the WebControl certificate
# without reloading it. Restart only after distribution has completed so port
# 7071 cannot continue serving the previous in-memory certificate.
if ! "$SYSTEMCTL" restart webcontrol.service; then
  printf 'IP Office installation failed: distribution completed but WebControl restart failed; backup retained at %s\n' \
    "${TRANSACTION_DIR:-none}" >&2
  exit 1
fi
if ! "$SYSTEMCTL" is-active --quiet webcontrol.service; then
  printf 'IP Office installation failed: WebControl is not active after restart; backup retained at %s\n' \
    "${TRANSACTION_DIR:-none}" >&2
  exit 1
fi

# Restarted Avaya components can launch another distribution in the background.
# Require a stable completed state instead of trusting only the first command's
# exit status. The production timeout matches Avaya's 1200-second lock wait.
MARKER_STABLE_COUNT=0
MARKER_POLL_COUNT=0
while [ "$MARKER_POLL_COUNT" -lt "$MARKER_MAX_POLLS" ]; do
  if [ ! -e "$CERT_DIR/.distrib_inprogress" ] && [ -e "$CERT_DIR/.distrib_complete" ]; then
    MARKER_STABLE_COUNT=$((MARKER_STABLE_COUNT + 1))
    [ "$MARKER_STABLE_COUNT" -lt "$MARKER_STABLE_REQUIRED" ] || break
  else
    MARKER_STABLE_COUNT=0
  fi
  MARKER_POLL_COUNT=$((MARKER_POLL_COUNT + 1))
  [ "$MARKER_POLL_SECONDS" -eq 0 ] || sleep "$MARKER_POLL_SECONDS"
done
if [ "$MARKER_STABLE_COUNT" -lt "$MARKER_STABLE_REQUIRED" ]; then
  printf 'IP Office installation failed: Avaya distribution did not reach a stable completed state; backup retained at %s\n' \
    "${TRANSACTION_DIR:-none}" >&2
  exit 1
fi

printf 'IPO_INSTALL result=INSTALLED fingerprint=%s import=%s distribution=OK markers=COMPLETE webcontrol=RESTARTED openssl_legacy_provider=%s backup=%s\n' \
  "$EXPECTED_FP" "$IMPORT_COMPLETED" "$USE_LEGACY_PROVIDER" "${TRANSACTION_DIR:-none}"
