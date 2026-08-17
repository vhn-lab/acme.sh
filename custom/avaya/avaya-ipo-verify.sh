#!/usr/bin/env sh

set -eu

usage() {
  printf '%s\n' \
    'Usage: avaya-ipo-verify.sh --expected-cert FILE [--host HOST]' \
    '       [--ports CSV] [--webcontrol-port PORT] [--timeout SECONDS]' \
    '       [--cert-dir DIRECTORY | --skip-marker-check]'
}

fail() { printf 'IPO verification failed: %s\n' "$1" >&2; exit 1; }

EXPECTED_CERT=
HOST=127.0.0.1
PORTS=411,443,5061,7070,52233,9443
WEBCONTROL_PORT=7071
TIMEOUT=8
CERT_DIR=/opt/Avaya/certs
SKIP_MARKER_CHECK=no
FAILURES=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --expected-cert) [ "$#" -ge 2 ] || fail 'missing value for --expected-cert'; EXPECTED_CERT=$2; shift 2 ;;
    --host) [ "$#" -ge 2 ] || fail 'missing value for --host'; HOST=$2; shift 2 ;;
    --ports) [ "$#" -ge 2 ] || fail 'missing value for --ports'; PORTS=$2; shift 2 ;;
    --webcontrol-port) [ "$#" -ge 2 ] || fail 'missing value for --webcontrol-port'; WEBCONTROL_PORT=$2; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || fail 'missing value for --timeout'; TIMEOUT=$2; shift 2 ;;
    --cert-dir) [ "$#" -ge 2 ] || fail 'missing value for --cert-dir'; CERT_DIR=$2; shift 2 ;;
    --skip-marker-check) SKIP_MARKER_CHECK=yes; shift ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$EXPECTED_CERT" ] || fail '--expected-cert is required'
[ -s "$EXPECTED_CERT" ] || fail 'expected certificate is missing or empty'
openssl x509 -in "$EXPECTED_CERT" -noout >/dev/null 2>&1 || fail 'expected certificate is invalid'
case "$HOST" in '' | *[!A-Za-z0-9._:-]*) fail 'invalid host' ;; esac
case "$TIMEOUT" in '' | *[!0-9]*) fail 'timeout must be an integer' ;; esac
if [ "$TIMEOUT" -lt 1 ] || [ "$TIMEOUT" -gt 60 ]; then
  fail 'timeout must be between 1 and 60'
fi
case "$CERT_DIR" in /*) ;; *) fail '--cert-dir must be an absolute path' ;; esac

if [ "$SKIP_MARKER_CHECK" != yes ]; then
  [ -d "$CERT_DIR" ] || fail "certificate directory is unavailable: $CERT_DIR"
  if [ -e "$CERT_DIR/.distrib_inprogress" ]; then
    printf '%s\n' 'IPO_DISTRIBUTION status=IN_PROGRESS'
    fail 'certificate distribution is still in progress'
  fi
  if [ ! -e "$CERT_DIR/.distrib_complete" ]; then
    printf '%s\n' 'IPO_DISTRIBUTION status=NOT_CONFIRMED'
    fail 'certificate distribution completion marker is absent'
  fi
  printf '%s\n' 'IPO_DISTRIBUTION status=COMPLETE'
fi

EXPECTED_FP=$(openssl x509 -in "$EXPECTED_CERT" -noout -fingerprint -sha256 |
  sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//')

check_port() {
  PORT=$1
  ROLE=$2
  case "$PORT" in '' | *[!0-9]*) fail "invalid port: $PORT" ;; esac
  if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    fail "invalid port: $PORT"
  fi

  PRESENTED=$(timeout "$TIMEOUT" openssl s_client -connect "$HOST:$PORT" \
    -servername "$HOST" </dev/null 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 2>/dev/null |
    sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//') || true

  if [ -z "$PRESENTED" ]; then
    printf 'IPO_PORT port=%s role=%s status=UNAVAILABLE\n' "$PORT" "$ROLE"
    FAILURES=$((FAILURES + 1))
  elif [ "$PRESENTED" = "$EXPECTED_FP" ]; then
    printf 'IPO_PORT port=%s role=%s status=MATCH fingerprint=%s\n' "$PORT" "$ROLE" "$PRESENTED"
  elif [ "$ROLE" = webcontrol ]; then
    printf 'IPO_PORT port=%s role=%s status=RESTART_REQUIRED fingerprint=%s\n' \
      "$PORT" "$ROLE" "$PRESENTED"
    FAILURES=$((FAILURES + 1))
  else
    printf 'IPO_PORT port=%s role=%s status=MISMATCH fingerprint=%s\n' "$PORT" "$ROLE" "$PRESENTED"
    FAILURES=$((FAILURES + 1))
  fi
}

OLD_IFS=$IFS
IFS=,
for PORT in $PORTS; do check_port "$PORT" service; done
IFS=$OLD_IFS
check_port "$WEBCONTROL_PORT" webcontrol

if [ "$FAILURES" -gt 0 ]; then
  printf 'IPO_VERIFY result=FAILED failures=%s expected_fingerprint=%s\n' "$FAILURES" "$EXPECTED_FP"
  exit 1
fi
printf 'IPO_VERIFY result=OK failures=0 expected_fingerprint=%s\n' "$EXPECTED_FP"
