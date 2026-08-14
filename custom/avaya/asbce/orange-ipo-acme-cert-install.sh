#!/usr/bin/env sh

set -eu

usage() {
  printf '%s\n' \
    'Usage: orange-ipo-acme-cert-install.sh [--apply --acknowledge-reboot]'
}

log() {
  printf 'ORANGE_IPO_ACME_ASBCE %s\n' "$1"
}

fail() {
  printf 'ORANGE_IPO_ACME_ASBCE result=FAILED reason=%s\n' "$1" >&2
  exit 1
}

APPLY=no
ACK_REBOOT=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=yes; shift ;;
    --acknowledge-reboot) ACK_REBOOT=yes; shift ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown_argument_$1" ;;
  esac
done

if [ "${ORANGE_ACME_TEST_MODE:-no}" = yes ]; then
  SPOOL_ROOT=${ORANGE_ACME_TEST_SPOOL:?test spool is required}
  STATE_ROOT=${ORANGE_ACME_TEST_STATE:?test state is required}
  KEY_DIR=${ORANGE_ACME_TEST_KEY_DIR:?test key directory is required}
  CERT_DIR=${ORANGE_ACME_TEST_CERT_DIR:?test certificate directory is required}
  CA_DIR=${ORANGE_ACME_TEST_CA_DIR:?test CA directory is required}
  REBOOT_CMD=${ORANGE_ACME_TEST_REBOOT_CMD:?test reboot command is required}
  EFFECTIVE_UID=${ORANGE_ACME_TEST_UID:-0}
  TRUST_FILE=${ORANGE_ACME_TEST_TRUST_FILE:-}
  EXPECTED_STAGING_OWNER=${ORANGE_ACME_TEST_STAGING_OWNER:-$(stat -c '%U' "$SPOOL_ROOT")}
else
  SPOOL_ROOT=/home/ipcs/.orange-ipo-acme-cert/incoming
  STATE_ROOT=/var/lib/orange-ipo-acme-cert
  KEY_DIR=/usr/local/ipcs/cert/key
  CERT_DIR=/usr/local/ipcs/cert/certificate
  CA_DIR=/usr/local/ipcs/cert/ca
  REBOOT_CMD=/sbin/reboot
  EFFECTIVE_UID=$(id -u)
  TRUST_FILE=
  EXPECTED_STAGING_OWNER=ipcs
fi

[ "$EFFECTIVE_UID" -eq 0 ] || fail root_privileges_required
for REQUIRED_DIR in "$SPOOL_ROOT" "$STATE_ROOT" "$KEY_DIR" "$CERT_DIR" "$CA_DIR"; do
  [ -d "$REQUIRED_DIR" ] || fail "missing_directory_$REQUIRED_DIR"
done

LOCK_DIR="$STATE_ROOT/install.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail installer_already_running
fi
TRANSACTION_DIR=
WORK_DIR=
NEW_KEY=
NEW_CERT=
NEW_CA=
cleanup() {
  [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  [ -n "$NEW_KEY" ] && [ -f "$NEW_KEY" ] && rm -f "$NEW_KEY"
  [ -n "$NEW_CERT" ] && [ -f "$NEW_CERT" ] && rm -f "$NEW_CERT"
  [ -n "$NEW_CA" ] && [ -f "$NEW_CA" ] && rm -f "$NEW_CA"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

for READY_FILE in "$SPOOL_ROOT"/*/READY; do
  [ -f "$READY_FILE" ] || continue
  TRANSACTION_DIR=${READY_FILE%/READY}
  break
done

if [ -z "$TRANSACTION_DIR" ]; then
  log 'result=NO_CHANGE reason=no_ready_transaction'
  exit 0
fi

TRANSACTION_ID=${TRANSACTION_DIR##*/}
case "$TRANSACTION_ID" in
  *[!A-Fa-f0-9]* | '') fail invalid_transaction_id ;;
esac
[ "${#TRANSACTION_ID}" -eq 64 ] || fail invalid_transaction_id_length
[ ! -L "$TRANSACTION_DIR" ] || fail transaction_directory_is_symlink
[ "$(stat -c '%U' "$TRANSACTION_DIR" 2>/dev/null)" = "$EXPECTED_STAGING_OWNER" ] ||
  fail invalid_transaction_owner

KEY_FILE="$TRANSACTION_DIR/server.key"
FULLCHAIN_FILE="$TRANSACTION_DIR/fullchain.pem"
CHAIN_FILE="$TRANSACTION_DIR/chain.pem"
MANIFEST_FILE="$TRANSACTION_DIR/manifest"

for INPUT_FILE in "$KEY_FILE" "$FULLCHAIN_FILE" "$CHAIN_FILE" "$MANIFEST_FILE" "$READY_FILE"; do
  [ -f "$INPUT_FILE" ] && [ ! -L "$INPUT_FILE" ] || fail invalid_transaction_file
  [ "$(stat -c '%U' "$INPUT_FILE" 2>/dev/null)" = "$EXPECTED_STAGING_OWNER" ] ||
    fail invalid_transaction_file_owner
done

KEY_MODE=$(stat -c '%a' "$KEY_FILE" 2>/dev/null) || fail cannot_read_key_permissions
case "$KEY_MODE" in 400 | 600) ;; *) fail insecure_private_key_permissions ;; esac

PROFILE=
EXPECTED_NAME=
EXPECTED_FINGERPRINT=
MANIFEST_LINES=0
while IFS= read -r LINE || [ -n "$LINE" ]; do
  MANIFEST_LINES=$((MANIFEST_LINES + 1))
  case "$LINE" in
    PROFILE=*) PROFILE=${LINE#PROFILE=} ;;
    EXPECTED_NAME=*) EXPECTED_NAME=${LINE#EXPECTED_NAME=} ;;
    FINGERPRINT_SHA256=*) EXPECTED_FINGERPRINT=${LINE#FINGERPRINT_SHA256=} ;;
    *) fail invalid_manifest_entry ;;
  esac
done <"$MANIFEST_FILE"
[ "$MANIFEST_LINES" -eq 3 ] || fail invalid_manifest_line_count
case "$PROFILE" in *[!A-Za-z0-9._-]* | '') fail invalid_profile ;; esac
case "$EXPECTED_NAME" in *[!A-Za-z0-9.-]* | '' | .* | *.) fail invalid_expected_name ;; esac
case "$EXPECTED_FINGERPRINT" in *[!A-Fa-f0-9]* | '') fail invalid_expected_fingerprint ;; esac
[ "${#EXPECTED_FINGERPRINT}" -eq 64 ] || fail invalid_expected_fingerprint_length
[ "$(printf '%s' "$EXPECTED_FINGERPRINT" | tr '[:lower:]' '[:upper:]')" = \
  "$(printf '%s' "$TRANSACTION_ID" | tr '[:lower:]' '[:upper:]')" ] || fail transaction_fingerprint_mismatch

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orange-ipo-acme-asbce.XXXXXX") || fail cannot_create_work_directory
chmod 700 "$WORK_DIR"
LEAF_CERT="$WORK_DIR/leaf.pem"
openssl x509 -in "$FULLCHAIN_FILE" -out "$LEAF_CERT" >/dev/null 2>&1 || fail invalid_leaf_certificate
openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1 || fail invalid_private_key

CERT_PUBLIC=$(openssl x509 -in "$LEAF_CERT" -pubkey -noout |
  openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)
KEY_PUBLIC=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null |
  openssl dgst -sha256)
[ "$CERT_PUBLIC" = "$KEY_PUBLIC" ] || fail certificate_private_key_mismatch

openssl x509 -in "$LEAF_CERT" -noout -checkhost "$EXPECTED_NAME" >/dev/null 2>&1 || fail expected_name_not_in_certificate
openssl x509 -in "$LEAF_CERT" -noout -checkend 604800 >/dev/null 2>&1 || fail certificate_expires_too_soon
openssl crl2pkcs7 -nocrl -certfile "$CHAIN_FILE" 2>/dev/null |
  openssl pkcs7 -print_certs -noout >/dev/null 2>&1 || fail invalid_certificate_chain

if [ -n "$TRUST_FILE" ]; then
  openssl verify -CAfile "$TRUST_FILE" -untrusted "$CHAIN_FILE" "$LEAF_CERT" >/dev/null 2>&1 || fail chain_verification_failed
else
  openssl verify -untrusted "$CHAIN_FILE" "$LEAF_CERT" >/dev/null 2>&1 || fail chain_verification_failed
fi

ACTUAL_FINGERPRINT=$(openssl x509 -in "$LEAF_CERT" -noout -fingerprint -sha256 |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]')
EXPECTED_FINGERPRINT=$(printf '%s' "$EXPECTED_FINGERPRINT" | tr '[:lower:]' '[:upper:]')
[ "$ACTUAL_FINGERPRINT" = "$EXPECTED_FINGERPRINT" ] || fail certificate_fingerprint_mismatch

ACTIVE_KEY="$KEY_DIR/lets_encrypt_auto.key"
ACTIVE_CERT="$CERT_DIR/lets_encrypt_auto.crt"
ACTIVE_CA="$CA_DIR/lets_encrypt_ca_auto.crt"
CURRENT_FINGERPRINT=
if [ -s "$ACTIVE_CERT" ] && openssl x509 -in "$ACTIVE_CERT" -noout >/dev/null 2>&1; then
  CURRENT_FINGERPRINT=$(openssl x509 -in "$ACTIVE_CERT" -noout -fingerprint -sha256 |
    sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]')
fi

if [ "$CURRENT_FINGERPRINT" = "$EXPECTED_FINGERPRINT" ]; then
  rm -rf "$TRANSACTION_DIR"
  log "result=UNCHANGED profile=$PROFILE fingerprint=$EXPECTED_FINGERPRINT reboot=no"
  exit 0
fi

if [ "$APPLY" != yes ]; then
  log "result=WOULD_INSTALL profile=$PROFILE fingerprint=$EXPECTED_FINGERPRINT reboot=required"
  exit 0
fi
[ "$ACK_REBOOT" = yes ] || fail acknowledge_reboot_required

BACKUP_DIR="$STATE_ROOT/backups/$TRANSACTION_ID"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
for ACTIVE_FILE in "$ACTIVE_KEY" "$ACTIVE_CERT" "$ACTIVE_CA"; do
  if [ -e "$ACTIVE_FILE" ]; then
    cp -p "$ACTIVE_FILE" "$BACKUP_DIR/$(basename "$ACTIVE_FILE")" || fail backup_failed
  fi
done

NEW_KEY="$KEY_DIR/.lets_encrypt_auto.key.$TRANSACTION_ID"
NEW_CERT="$CERT_DIR/.lets_encrypt_auto.crt.$TRANSACTION_ID"
NEW_CA="$CA_DIR/.lets_encrypt_ca_auto.crt.$TRANSACTION_ID"
umask 077
cp "$KEY_FILE" "$NEW_KEY" || fail key_staging_failed
cp "$FULLCHAIN_FILE" "$NEW_CERT" || fail certificate_staging_failed
cp "$CHAIN_FILE" "$NEW_CA" || fail chain_staging_failed
chown root:root "$NEW_KEY" "$NEW_CERT" "$NEW_CA" || fail ownership_update_failed
chmod 600 "$NEW_KEY" || fail key_permissions_failed
chmod 640 "$NEW_CERT" "$NEW_CA" || fail certificate_permissions_failed

rollback() {
  for NAME in lets_encrypt_auto.key lets_encrypt_auto.crt lets_encrypt_ca_auto.crt; do
    case "$NAME" in
      *.key) DESTINATION=$ACTIVE_KEY ;;
      *.crt)
        if [ "$NAME" = lets_encrypt_auto.crt ]; then DESTINATION=$ACTIVE_CERT; else DESTINATION=$ACTIVE_CA; fi
        ;;
    esac
    if [ -e "$BACKUP_DIR/$NAME" ]; then cp -p "$BACKUP_DIR/$NAME" "$DESTINATION"; else rm -f "$DESTINATION"; fi
  done
}

if ! mv "$NEW_KEY" "$ACTIVE_KEY" || ! mv "$NEW_CERT" "$ACTIVE_CERT" || ! mv "$NEW_CA" "$ACTIVE_CA"; then
  rollback
  fail installation_failed_and_rolled_back
fi

INSTALLED_FINGERPRINT=$(openssl x509 -in "$ACTIVE_CERT" -noout -fingerprint -sha256 2>/dev/null |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]') || true
if [ "$INSTALLED_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]; then
  rollback
  fail post_install_verification_failed_and_rolled_back
fi

printf '%s\n' "$EXPECTED_FINGERPRINT" >"$STATE_ROOT/installed.sha256"
chmod 600 "$STATE_ROOT/installed.sha256"
rm -rf "$TRANSACTION_DIR"

if ! "$REBOOT_CMD"; then
  fail certificate_installed_but_reboot_failed
fi
log "result=INSTALLED profile=$PROFILE fingerprint=$EXPECTED_FINGERPRINT reboot=requested"
