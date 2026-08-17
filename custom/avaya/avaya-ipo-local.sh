#!/usr/bin/env sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fail() { printf 'Local IP Office deployment failed: %s\n' "$1" >&2; exit 1; }

SERVER_IP=
CERT_FILE=
KEY_FILE=
FULLCHAIN_FILE=
PASSWORD_FILE=
BACKUP_DIR=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --server-ip) SERVER_IP=$2; shift 2 ;;
    --cert) CERT_FILE=$2; shift 2 ;;
    --key) KEY_FILE=$2; shift 2 ;;
    --fullchain) FULLCHAIN_FILE=$2; shift 2 ;;
    --password-file) PASSWORD_FILE=$2; shift 2 ;;
    --backup-dir) BACKUP_DIR=$2; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$BACKUP_DIR" in /*) ;; *) fail 'backup directory must be an absolute path' ;; esac
for FILE in "$CERT_FILE" "$KEY_FILE" "$FULLCHAIN_FILE" "$PASSWORD_FILE"; do
  if [ ! -f "$FILE" ] || [ ! -r "$FILE" ]; then
    fail "missing or unreadable input: $FILE"
  fi
done

PKCS12_BUILDER=${AVAYA_PKCS12_BUILDER:-$SCRIPT_DIR/avaya-pkcs12.sh}
INSTALLER=${AVAYA_IPO_INSTALLER:-$SCRIPT_DIR/avaya-ipo-install.sh}
VERIFIER=${AVAYA_IPO_VERIFIER:-$SCRIPT_DIR/avaya-ipo-verify.sh}
for HELPER in "$PKCS12_BUILDER" "$INSTALLER" "$VERIFIER"; do
  if [ ! -f "$HELPER" ] || [ ! -r "$HELPER" ]; then
    fail "helper is unavailable: $HELPER"
  fi
done

LOCAL_TMP=$(mktemp -d /tmp/acme-avaya-local.XXXXXX) || fail 'cannot create temporary directory'
chmod 700 "$LOCAL_TMP"
# shellcheck disable=SC2317
cleanup() { rm -rf "$LOCAL_TMP"; }
trap cleanup EXIT HUP INT TERM

sh "$PKCS12_BUILDER" --cert "$CERT_FILE" --key "$KEY_FILE" \
  --fullchain "$FULLCHAIN_FILE" --password-file "$PASSWORD_FILE" \
  --output "$LOCAL_TMP/server.p12" >/dev/null || fail 'cannot build PKCS12 package'

sh "$INSTALLER" --apply --acknowledge-service-restarts \
  --server-ip "$SERVER_IP" --p12 "$LOCAL_TMP/server.p12" \
  --password-file "$PASSWORD_FILE" --expected-cert "$CERT_FILE" \
  --backup-dir "$BACKUP_DIR" || fail 'IP Office installer failed'

ATTEMPT=1
while [ "$ATTEMPT" -le 15 ]; do
  if sh "$VERIFIER" --expected-cert "$CERT_FILE" --host 127.0.0.1 \
    --ports 411,443,5061,7070,52233,9443 --webcontrol-port 7071 --timeout 5; then
    exit 0
  fi
  sleep 4
  ATTEMPT=$((ATTEMPT + 1))
done
fail 'installed certificate could not be verified'
