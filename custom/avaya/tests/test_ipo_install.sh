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
openssl pkcs12 -export -legacy -macalg SHA1 -name server -in "$TEST_DIR/server.crt" \
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
    openssl pkcs12 -legacy -in "$AVAYA_TEST_CERT_DIR/server_$IP.p12" -nocerts -nodes \
      -passin "pass:$PASS" 2>/dev/null >"$AVAYA_TEST_CERT_DIR/cert_to_import.pem"
    openssl pkcs12 -legacy -in "$AVAYA_TEST_CERT_DIR/server_$IP.p12" -clcerts -nokeys \
      -passin "pass:$PASS" 2>/dev/null >>"$AVAYA_TEST_CERT_DIR/cert_to_import.pem"
    rm -f "$AVAYA_TEST_CERT_DIR/server_$IP.p12"
    ;;
  --distribute-server-cert)
    [ "${AVAYA_TEST_DISTRIBUTE_FAIL:-no}" != yes ] || exit 91
    printf '%s\n' distributed >>"$AVAYA_TEST_CERT_DIR/distribution.log"
    ;;
  *) exit 92 ;;
esac
MOCK
chmod 700 "$TEST_DIR/gen_certs.sh"

run_installer() {
  AVAYA_TEST_MODE=yes AVAYA_TEST_UID=0 AVAYA_TEST_CERT_DIR="$TEST_DIR/certs" \
    AVAYA_TEST_GEN_CERTS="$TEST_DIR/gen_certs.sh" sh "$INSTALLER" "$@"
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
[ "$(wc -l <"$TEST_DIR/certs/distribution.log")" -eq 1 ] || fail 'distribution did not run exactly once'

OUTPUT=$(run_installer --apply --acknowledge-service-restarts --server-ip 192.0.2.10 \
  --p12 "$TEST_DIR/server.p12" --password-file "$TEST_DIR/password" \
  --expected-cert "$TEST_DIR/server.crt")
printf '%s\n' "$OUTPUT" | grep 'result=UNCHANGED' >/dev/null || fail 'identical certificate was not idempotent'
[ "$(wc -l <"$TEST_DIR/certs/distribution.log")" -eq 1 ] || fail 'unchanged certificate was redistributed'

if grep -r 'temporary-test-password' "$TEST_DIR/certs" >/dev/null 2>&1; then
  fail 'password was left in Avaya files or logs'
fi

printf '%s\n' 'PASS: IP Office installation adapter tests'
