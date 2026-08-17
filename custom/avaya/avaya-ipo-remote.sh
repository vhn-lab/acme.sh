#!/usr/bin/env sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fail() { printf 'Remote IP Office deployment failed: %s\n' "$1" >&2; exit 1; }

HOST=
USER=
SERVER_IP=
CERT_FILE=
KEY_FILE=
FULLCHAIN_FILE=
PASSWORD_FILE=
KNOWN_HOSTS=
CONNECT_TIMEOUT=10

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) HOST=$2; shift 2 ;;
    --user) USER=$2; shift 2 ;;
    --server-ip) SERVER_IP=$2; shift 2 ;;
    --cert) CERT_FILE=$2; shift 2 ;;
    --key) KEY_FILE=$2; shift 2 ;;
    --fullchain) FULLCHAIN_FILE=$2; shift 2 ;;
    --password-file) PASSWORD_FILE=$2; shift 2 ;;
    --known-hosts) KNOWN_HOSTS=$2; shift 2 ;;
    --connect-timeout) CONNECT_TIMEOUT=$2; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$HOST" in '' | *[!A-Za-z0-9._-]*) fail 'invalid host' ;; esac
case "$USER" in '' | *[!A-Za-z0-9_-]*) fail 'invalid user' ;; esac
if ! printf '%s\n' "$SERVER_IP" | awk -F. '
  NF != 4 { exit 1 }
  { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }
'; then
  fail 'invalid server IP'
fi
for FILE in "$CERT_FILE" "$KEY_FILE" "$FULLCHAIN_FILE" "$PASSWORD_FILE" "$KNOWN_HOSTS"; do
  [ -f "$FILE" ] && [ -r "$FILE" ] || fail "missing or unreadable input: $FILE"
done
case "$CONNECT_TIMEOUT" in '' | *[!0-9]*) fail 'invalid SSH timeout' ;; esac

SSH_BIN=${AVAYA_SSH_BIN:-ssh}
SCP_BIN=${AVAYA_SCP_BIN:-scp}
LOCAL_TMP=$(mktemp -d /tmp/acme-avaya-remote.XXXXXX)
chmod 700 "$LOCAL_TMP"
REMOTE_DIR=
cleanup() {
  rm -rf "$LOCAL_TMP"
  if [ -n "$REMOTE_DIR" ]; then
    case "$REMOTE_DIR" in /tmp/acme-avaya-deploy.*)
      "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
        "$USER@$HOST" "rm -rf -- '$REMOTE_DIR'" >/dev/null 2>&1 || true ;;
    esac
  fi
}
trap cleanup EXIT HUP INT TERM

mkdir "$LOCAL_TMP/payload"
cp "$SCRIPT_DIR/avaya-ipo-install.sh" "$SCRIPT_DIR/avaya-ipo-verify.sh" \
  "$SCRIPT_DIR/openssl-legacy.cnf" "$LOCAL_TMP/payload/"
cp "$CERT_FILE" "$LOCAL_TMP/payload/cert.pem"
cp "$PASSWORD_FILE" "$LOCAL_TMP/payload/password"
chmod 600 "$LOCAL_TMP/payload/"*
sh "$SCRIPT_DIR/avaya-pkcs12.sh" --cert "$CERT_FILE" --key "$KEY_FILE" \
  --fullchain "$FULLCHAIN_FILE" --password-file "$PASSWORD_FILE" \
  --output "$LOCAL_TMP/payload/server.p12" >/dev/null
tar -czf "$LOCAL_TMP/payload.tar.gz" -C "$LOCAL_TMP" payload

REMOTE_DIR=$("$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
  "$USER@$HOST" 'umask 077; mktemp -d /tmp/acme-avaya-deploy.XXXXXX') ||
  fail 'could not create private remote staging directory'
case "$REMOTE_DIR" in /tmp/acme-avaya-deploy.*) ;; *) fail 'remote staging path was invalid' ;; esac

"$SCP_BIN" -q -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
  "$LOCAL_TMP/payload.tar.gz" "$USER@$HOST:$REMOTE_DIR/payload.tar.gz" ||
  fail 'could not upload deployment payload'

"$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
  "$USER@$HOST" sh -s -- "$REMOTE_DIR" "$SERVER_IP" <<'REMOTE'
set -eu
REMOTE_DIR=$1
SERVER_IP=$2
case "$REMOTE_DIR" in /tmp/acme-avaya-deploy.*) ;; *) exit 97 ;; esac
cleanup_remote() { rm -rf "$REMOTE_DIR"; }
trap cleanup_remote EXIT HUP INT TERM
tar -xzf "$REMOTE_DIR/payload.tar.gz" -C "$REMOTE_DIR"
chmod 700 "$REMOTE_DIR/payload/avaya-ipo-install.sh" "$REMOTE_DIR/payload/avaya-ipo-verify.sh"
chmod 600 "$REMOTE_DIR/payload/openssl-legacy.cnf" "$REMOTE_DIR/payload/server.p12" \
  "$REMOTE_DIR/payload/cert.pem" "$REMOTE_DIR/payload/password"
"$REMOTE_DIR/payload/avaya-ipo-install.sh" --apply --acknowledge-service-restarts \
  --server-ip "$SERVER_IP" --p12 "$REMOTE_DIR/payload/server.p12" \
  --password-file "$REMOTE_DIR/payload/password" --expected-cert "$REMOTE_DIR/payload/cert.pem" \
  --backup-dir /root/orange/script/acme.sh/avaya-backups \
  --openssl-config "$REMOTE_DIR/payload/openssl-legacy.cnf"
N=1
while [ "$N" -le 15 ]; do
  if "$REMOTE_DIR/payload/avaya-ipo-verify.sh" --expected-cert "$REMOTE_DIR/payload/cert.pem" \
    --host 127.0.0.1 --ports 411,443,5061,7070,52233,9443 \
    --webcontrol-port 7071 --timeout 5; then
    exit 0
  fi
  sleep 4
  N=$((N + 1))
done
exit 1
REMOTE
