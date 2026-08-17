#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
HELPER="$TEST_ROOT/custom/avaya/avaya-ipo-remote.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cleanup() { case "${TEST_DIR:-}" in /tmp/avaya-remote-test.*) rm -r "$TEST_DIR" ;; esac; }

TEST_DIR=$(mktemp -d /tmp/avaya-remote-test.XXXXXX)
trap cleanup EXIT HUP INT TERM

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=ipo.example.invalid' \
  -keyout "$TEST_DIR/key.pem" -out "$TEST_DIR/cert.pem" >/dev/null 2>&1
cat "$TEST_DIR/cert.pem" "$TEST_DIR/cert.pem" >"$TEST_DIR/fullchain.pem"
printf '%s\n' fictitious-remote-password >"$TEST_DIR/password"
chmod 600 "$TEST_DIR/password" "$TEST_DIR/key.pem"
touch "$TEST_DIR/known_hosts"

cat >"$TEST_DIR/ssh" <<'MOCK'
#!/usr/bin/env sh
set -eu
printf 'SSH %s\n' "$*" >>"$AVAYA_TEST_TRANSPORT_LOG"
case "$*" in
  *'mktemp -d /tmp/acme-avaya-deploy.XXXXXX'*)
    printf '%s\n' /tmp/acme-avaya-deploy.mock
    ;;
  *' sh -s -- '*)
    cat >/dev/null
    printf '%s\n' REMOTE_SIMULATION=OK
    ;;
  *) ;;
esac
MOCK
chmod 700 "$TEST_DIR/ssh"

cat >"$TEST_DIR/scp" <<'MOCK'
#!/usr/bin/env sh
set -eu
printf 'SCP %s\n' "$*" >>"$AVAYA_TEST_TRANSPORT_LOG"
ARCHIVE=
for ARG in "$@"; do
  case "$ARG" in *.tar.gz) [ -f "$ARG" ] && ARCHIVE=$ARG ;; esac
done
[ -n "$ARCHIVE" ]
tar -tzf "$ARCHIVE" >"$AVAYA_TEST_ARCHIVE_LIST"
MOCK
chmod 700 "$TEST_DIR/scp"

AVAYA_TEST_TRANSPORT_LOG="$TEST_DIR/transport.log" \
AVAYA_TEST_ARCHIVE_LIST="$TEST_DIR/archive.list" \
AVAYA_SSH_BIN="$TEST_DIR/ssh" AVAYA_SCP_BIN="$TEST_DIR/scp" \
  sh "$HELPER" --host ipo --user root --server-ip 192.0.2.10 \
  --cert "$TEST_DIR/cert.pem" --key "$TEST_DIR/key.pem" \
  --fullchain "$TEST_DIR/fullchain.pem" --password-file "$TEST_DIR/password" \
  --known-hosts "$TEST_DIR/known_hosts" --connect-timeout 10 \
  --backup-dir /var/lib/acme-avaya/backups \
  >"$TEST_DIR/output"

grep 'REMOTE_SIMULATION=OK' "$TEST_DIR/output" >/dev/null || fail 'remote execution was not invoked'
grep 'BatchMode=yes' "$TEST_DIR/transport.log" >/dev/null || fail 'SSH BatchMode was not enforced'
grep 'StrictHostKeyChecking=yes' "$TEST_DIR/transport.log" >/dev/null || fail 'strict host-key checking was not enforced'
grep '/var/lib/acme-avaya/backups' "$TEST_DIR/transport.log" >/dev/null || fail 'backup directory was not forwarded'
grep 'payload/server.p12' "$TEST_DIR/archive.list" >/dev/null || fail 'PKCS12 payload is missing'
grep 'payload/password' "$TEST_DIR/archive.list" >/dev/null || fail 'password payload is missing'
if grep 'payload/key.pem' "$TEST_DIR/archive.list" >/dev/null; then
  fail 'raw private key was included in the remote payload'
fi
grep "rm -rf -- '/tmp/acme-avaya-deploy.mock'" "$TEST_DIR/transport.log" >/dev/null ||
  fail 'remote staging cleanup was not attempted'

printf '%s\n' 'PASS: IP Office remote transport tests'
