#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
INSTALLER=${AVAYA_TEST_INSTALLER:-$TEST_ROOT/custom/avaya/avaya-ipo-install.sh}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cleanup() { case "${TEST_DIR:-}" in /tmp/avaya-ipo-test.*) rm -r "$TEST_DIR" ;; esac; }

TEST_DIR=$(mktemp -d /tmp/avaya-ipo-test.XXXXXX)
trap cleanup EXIT HUP INT TERM
mkdir "$TEST_DIR/certs"

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=ipo.example.invalid' \
  -keyout "$TEST_DIR/server.key" -out "$TEST_DIR/server.crt" >/dev/null 2>&1
printf '%s\n' 'temporary-test-password' >"$TEST_DIR/password"
chmod 600 "$TEST_DIR/password"
openssl pkcs12 -export -name server -in "$TEST_DIR/server.crt" \
  -inkey "$TEST_DIR/server.key" -passout "file:$TEST_DIR/password" \
  -out "$TEST_DIR/server.p12" >/dev/null 2>&1

cat >"$TEST_DIR/gen_certs.sh" <<'MOCK'
#!/usr/bin/env sh
set -eu
case "$1" in
  --install-p12cert)
    shift
    PASS=
    IP=
    while [ "$#" -gt 0 ]; do
      case "$1" in --pass) PASS=$2; shift 2 ;; --server-ip) IP=$2; shift 2 ;; *) exit 90 ;; esac
    done
    [ "${AVAYA_TEST_IMPORT_FAIL:-no}" != yes ] || exit 95
    openssl pkcs12 -legacy -in "$AVAYA_TEST_CERT_DIR/server_$IP.p12" -nocerts -nodes \
      -passin "pass:$PASS" 2>/dev/null >"$AVAYA_TEST_CERT_DIR/cert_to_import.pem"
    openssl pkcs12 -legacy -in "$AVAYA_TEST_CERT_DIR/server_$IP.p12" -clcerts -nokeys \
      -passin "pass:$PASS" 2>/dev/null >>"$AVAYA_TEST_CERT_DIR/cert_to_import.pem"
    rm -f "$AVAYA_TEST_CERT_DIR/server_$IP.p12"
    ;;
  --distribute-server-cert)
    [ "${AVAYA_TEST_DISTRIBUTE_FAIL:-no}" != yes ] || exit 91
    openssl x509 -in "$AVAYA_TEST_CERT_DIR/cert_to_import.pem" \
      -out "$AVAYA_TEST_CERT_DIR/cert.pem" 2>/dev/null
    rm -f "$AVAYA_TEST_CERT_DIR/cert_to_import.pem"
    rm -f "$AVAYA_TEST_CERT_DIR/.distrib_inprogress"
    touch "$AVAYA_TEST_CERT_DIR/.distrib_complete"
    printf '%s\n' distributed >>"$AVAYA_TEST_CERT_DIR/distribution.log"
    printf '%s\n' distribution >>"$AVAYA_TEST_CERT_DIR/sequence.log"
    ;;
  *) exit 92 ;;
esac
MOCK
chmod 700 "$TEST_DIR/gen_certs.sh"

cat >"$TEST_DIR/systemctl" <<'MOCK'
#!/usr/bin/env sh
set -eu
case "$1 $2" in
  'restart webcontrol.service')
    printf '%s\n' webcontrol-restart >>"$AVAYA_TEST_CERT_DIR/sequence.log"
    ;;
  'is-active --quiet')
    [ "${3:-}" = webcontrol.service ] || exit 93
    ;;
  *) exit 94 ;;
esac
MOCK
chmod 700 "$TEST_DIR/systemctl"

run_installer() {
  AVAYA_TEST_MODE=yes AVAYA_TEST_UID=0 AVAYA_TEST_CERT_DIR="$TEST_DIR/certs" \
    AVAYA_TEST_GEN_CERTS="$TEST_DIR/gen_certs.sh" AVAYA_TEST_SYSTEMCTL="$TEST_DIR/systemctl" \
    sh "$INSTALLER" \
    --backup-dir "$TEST_DIR/backups" "$@"
}

OUTPUT=$(run_installer --server-ip 192.0.2.10 --p12 "$TEST_DIR/server.p12" \
  --password-file "$TEST_DIR/password" --expected-cert "$TEST_DIR/server.crt")
printf '%s\n' "$OUTPUT" | grep 'result=WOULD_INSTALL' >/dev/null || fail 'default mode was not non-mutating'
[ ! -e "$TEST_DIR/certs/cert_to_import.pem" ] || fail 'default mode modified Avaya files'

if run_installer --apply --server-ip 192.0.2.10 --p12 "$TEST_DIR/server.p12" \
  --password-file "$TEST_DIR/password" --expected-cert "$TEST_DIR/server.crt" >/dev/null 2>&1; then
  fail 'apply worked without restart acknowledgement'
fi

OUTPUT=$(run_installer --apply --acknowledge-service-restarts --server-ip 192.0.2.10 \
  --p12 "$TEST_DIR/server.p12" --password-file "$TEST_DIR/password" \
  --expected-cert "$TEST_DIR/server.crt")
printf '%s\n' "$OUTPUT" | grep 'result=INSTALLED' >/dev/null || fail 'installation did not succeed'
printf '%s\n' "$OUTPUT" | grep 'webcontrol=RESTARTED' >/dev/null || fail 'WebControl restart was not reported'
printf '%s\n' "$OUTPUT" | grep 'markers=COMPLETE' >/dev/null || fail 'stable distribution markers were not reported'
[ "$(wc -l <"$TEST_DIR/certs/distribution.log")" -eq 1 ] || fail 'distribution did not run exactly once'
[ ! -e "$TEST_DIR/certs/cert_to_import.pem" ] || fail 'mock did not consume import certificate'
EXPECTED_SEQUENCE=$(printf '%s\n' distribution webcontrol-restart)
[ "$(cat "$TEST_DIR/certs/sequence.log")" = "$EXPECTED_SEQUENCE" ] ||
  fail 'WebControl was not restarted after distribution'
[ ! -d "$TEST_DIR/backups" ] ||
  fail 'backup was created when no previous certificate existed'

OUTPUT=$(run_installer --apply --acknowledge-service-restarts --server-ip 192.0.2.10 \
  --p12 "$TEST_DIR/server.p12" --password-file "$TEST_DIR/password" \
  --expected-cert "$TEST_DIR/server.crt")
printf '%s\n' "$OUTPUT" | grep 'result=UNCHANGED' >/dev/null || fail 'identical certificate was not idempotent'
[ "$(wc -l <"$TEST_DIR/certs/distribution.log")" -eq 1 ] || fail 'unchanged certificate was redistributed'

cp "$TEST_DIR/server.crt" "$TEST_DIR/certs/cert_to_import.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=replacement.example.invalid' \
  -keyout "$TEST_DIR/replacement.key" -out "$TEST_DIR/replacement.crt" >/dev/null 2>&1
openssl pkcs12 -export -name server -in "$TEST_DIR/replacement.crt" \
  -inkey "$TEST_DIR/replacement.key" -passout "file:$TEST_DIR/password" \
  -out "$TEST_DIR/replacement.p12" >/dev/null 2>&1
IMPORT_FP=$(openssl x509 -in "$TEST_DIR/certs/cert_to_import.pem" -noout -fingerprint -sha256)
if AVAYA_TEST_IMPORT_FAIL=yes run_installer --apply --acknowledge-service-restarts \
  --server-ip 192.0.2.11 --p12 "$TEST_DIR/replacement.p12" \
  --password-file "$TEST_DIR/password" --expected-cert "$TEST_DIR/replacement.crt" \
  >/dev/null 2>&1; then
  fail 'simulated Avaya import failure returned success'
fi
[ "$(openssl x509 -in "$TEST_DIR/certs/cert_to_import.pem" -noout -fingerprint -sha256)" = "$IMPORT_FP" ] ||
  fail 'adapter modified the Avaya import certificate after a script failure'
OUTPUT=$(run_installer --apply --acknowledge-service-restarts --server-ip 192.0.2.11 \
  --p12 "$TEST_DIR/replacement.p12" --password-file "$TEST_DIR/password" \
  --expected-cert "$TEST_DIR/replacement.crt")
TRANSACTION_DIR=$(printf '%s\n' "$OUTPUT" | sed -n 's/.* backup=\(.*\)$/\1/p')
[ -d "$TRANSACTION_DIR" ] || fail 'transactional backup was not retained'
BACKUP_FILE="$TRANSACTION_DIR/import/cert_to_import.pem"
[ -f "$BACKUP_FILE" ] || fail 'import certificate backup was not retained'
[ -f "$TRANSACTION_DIR/active/cert.pem" ] || fail 'active certificate backup was not retained'
[ "$(stat -c '%a' "$TEST_DIR/backups")" = 700 ] || fail 'backup root permissions are unsafe'
[ "$(stat -c '%a' "$TRANSACTION_DIR")" = 700 ] || fail 'transaction directory permissions are unsafe'
[ "$(stat -c '%a' "$TRANSACTION_DIR/active")" = 700 ] || fail 'active backup directory permissions are unsafe'
[ "$(stat -c '%a' "$BACKUP_FILE")" = 600 ] || fail 'backup file permissions are unsafe'
openssl x509 -in "$BACKUP_FILE" -noout -subject 2>/dev/null |
  grep 'ipo.example.invalid' >/dev/null || fail 'transactional backup has the wrong certificate'

if grep -r 'temporary-test-password' "$TEST_DIR/certs" >/dev/null 2>&1; then
  fail 'password was left in Avaya files or logs'
fi

printf '%s\n' 'PASS: IP Office installation adapter tests'
