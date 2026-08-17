#!/usr/bin/env sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
INSTALLER="$TEST_ROOT/custom/avaya/install.sh"
CHECKSUM=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

OUTPUT=$(sh "$INSTALLER" --dry-run --email admin@example.invalid \
  --server-ip 192.0.2.10 --revision v1.0.0 --sha256 "$CHECKSUM")
printf '%s\n' "$OUTPUT" | grep -F 'revision=v1.0.0' >/dev/null ||
  fail 'dry-run did not report revision'
printf '%s\n' "$OUTPUT" | grep -F 'install_home=/root/orange/script/acme.sh' >/dev/null ||
  fail 'dry-run reported the wrong installation home'
printf '%s\n' "$OUTPUT" | grep -F 'config_root=/root/orange/script/acme-avaya' >/dev/null ||
  fail 'dry-run reported the wrong configuration root'

if sh "$INSTALLER" --dry-run --email admin@example.invalid \
  --server-ip 999.0.2.10 --revision v1.0.0 --sha256 "$CHECKSUM" >/dev/null 2>&1; then
  fail 'invalid server IP was accepted'
fi
if sh "$INSTALLER" --dry-run --email invalid-email \
  --server-ip 192.0.2.10 --revision v1.0.0 --sha256 "$CHECKSUM" >/dev/null 2>&1; then
  fail 'invalid email was accepted'
fi
if sh "$INSTALLER" --dry-run --email admin@example.invalid \
  --server-ip 192.0.2.10 --revision '../main' --sha256 "$CHECKSUM" >/dev/null 2>&1; then
  fail 'unsafe revision was accepted'
fi
if sh "$INSTALLER" --dry-run --email admin@example.invalid \
  --server-ip 192.0.2.10 --revision v1.0.0 --sha256 deadbeef >/dev/null 2>&1; then
  fail 'short checksum was accepted'
fi
if sh "$INSTALLER" --dry-run --email admin@example.invalid \
  --server-ip 192.0.2.10 --revision master --sha256 "$CHECKSUM" >/dev/null 2>&1; then
  fail 'moving branch revision was accepted'
fi

printf '%s\n' 'PASS: Avaya bootstrap installer tests'
