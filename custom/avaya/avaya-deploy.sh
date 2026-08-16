#!/usr/bin/env sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# shellcheck source=avaya-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/avaya-lib.sh"

usage() {
  printf '%s\n' \
    'Usage: avaya-deploy.sh --dry-run --config FILE --profile NAME' \
    '       --cert FILE --key FILE --fullchain FILE --expected-name FQDN' \
    '       [--trust-file FILE] [--simulate-failure TARGET]'
}

fail() {
  printf 'Deployment planning failed: %s\n' "$1" >&2
  exit 1
}

DRY_RUN=no
CONFIG_FILE=
PROFILE=
CERT_FILE=
KEY_FILE=
FULLCHAIN_FILE=
EXPECTED_NAME=
TRUST_FILE=
SIMULATE_FAILURE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=yes; shift ;;
    --config) [ "$#" -ge 2 ] || fail 'missing value for --config'; CONFIG_FILE=$2; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || fail 'missing value for --profile'; PROFILE=$2; shift 2 ;;
    --cert) [ "$#" -ge 2 ] || fail 'missing value for --cert'; CERT_FILE=$2; shift 2 ;;
    --key) [ "$#" -ge 2 ] || fail 'missing value for --key'; KEY_FILE=$2; shift 2 ;;
    --fullchain) [ "$#" -ge 2 ] || fail 'missing value for --fullchain'; FULLCHAIN_FILE=$2; shift 2 ;;
    --expected-name) [ "$#" -ge 2 ] || fail 'missing value for --expected-name'; EXPECTED_NAME=$2; shift 2 ;;
    --trust-file) [ "$#" -ge 2 ] || fail 'missing value for --trust-file'; TRUST_FILE=$2; shift 2 ;;
    --simulate-failure) [ "$#" -ge 2 ] || fail 'missing value for --simulate-failure'; SIMULATE_FAILURE=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ "$DRY_RUN" = yes ] || fail 'only --dry-run mode is implemented; no production deployment is possible'
[ -n "$CONFIG_FILE" ] || fail '--config is required'
[ -n "$PROFILE" ] || fail '--profile is required'
[ -n "$CERT_FILE" ] || fail '--cert is required'
[ -n "$KEY_FILE" ] || fail '--key is required'
[ -n "$FULLCHAIN_FILE" ] || fail '--fullchain is required'
[ -n "$EXPECTED_NAME" ] || fail '--expected-name is required'

case "$PROFILE" in
  *[!A-Za-z0-9._-]* | '') fail 'invalid profile name' ;;
esac
case "$SIMULATE_FAILURE" in
  *[!A-Za-z0-9._-]*) fail 'invalid simulated target name' ;;
esac

avaya_load_config "$CONFIG_FILE" || exit 1
avaya_validate_targets "$TARGETS_FILE" || exit 1

if [ -n "$TRUST_FILE" ]; then
  VALIDATION_OUTPUT=$(sh "$SCRIPT_DIR/avaya-validate.sh" \
    --cert "$CERT_FILE" --key "$KEY_FILE" --fullchain "$FULLCHAIN_FILE" \
    --expected-name "$EXPECTED_NAME" --min-days "$MIN_REMAINING_DAYS" \
    --trust-file "$TRUST_FILE") || exit 1
else
  VALIDATION_OUTPUT=$(sh "$SCRIPT_DIR/avaya-validate.sh" \
    --cert "$CERT_FILE" --key "$KEY_FILE" --fullchain "$FULLCHAIN_FILE" \
    --expected-name "$EXPECTED_NAME" --min-days "$MIN_REMAINING_DAYS") || exit 1
fi

FINGERPRINT=$(printf '%s\n' "$VALIDATION_OUTPUT" | sed -n 's/^VALID fingerprint=\([^[:space:]]*\).*/\1/p')
[ -n "$FINGERPRINT" ] || fail 'validator did not return a certificate fingerprint'

TARGET_LIST=$(avaya_targets_for_profile "$TARGETS_FILE" "$PROFILE") || exit 1
[ -n "$TARGET_LIST" ] || fail "no active targets use profile $PROFILE"

printf 'PLAN_START mode=dry-run profile=%s fingerprint=%s failure_policy=%s\n' \
  "$PROFILE" "$FINGERPRINT" "$FAILURE_POLICY"

PLAN_STOPPED=no
PLAN_FAILURES=0
while IFS=';' read -r TARGET_ENABLED TARGET_TYPE TARGET_NAME TARGET_HOST TARGET_USER TARGET_PROFILE TARGET_ROLE; do

  [ "$TARGET_ENABLED" = yes ] || fail "inactive target unexpectedly selected: $TARGET_NAME"
  [ "$TARGET_PROFILE" = "$PROFILE" ] || fail "wrong profile unexpectedly selected: $TARGET_NAME"

  if [ "$PLAN_STOPPED" = yes ]; then
    TARGET_STATUS=NOT_ATTEMPTED
  elif [ -n "$SIMULATE_FAILURE" ] && [ "$TARGET_NAME" = "$SIMULATE_FAILURE" ]; then
    TARGET_STATUS=SIMULATED_FAILURE
    PLAN_FAILURES=$((PLAN_FAILURES + 1))
    if [ "$FAILURE_POLICY" = stop ]; then
      PLAN_STOPPED=yes
    fi
  else
    STATE_FILE="$STATE_DIR/$PROFILE/$TARGET_NAME.sha256"
    INSTALLED_FINGERPRINT=
    if [ -f "$STATE_FILE" ] && [ -r "$STATE_FILE" ]; then
      IFS= read -r INSTALLED_FINGERPRINT <"$STATE_FILE" || true
    fi
    if [ "$INSTALLED_FINGERPRINT" = "$FINGERPRINT" ]; then
      TARGET_STATUS=UNCHANGED
    else
      TARGET_STATUS=WOULD_DEPLOY
    fi
  fi

  printf 'PLAN target=%s type=%s host=%s user=%s role=%s status=%s\n' \
    "$TARGET_NAME" "$TARGET_TYPE" "$TARGET_HOST" "$TARGET_USER" "$TARGET_ROLE" "$TARGET_STATUS"
done <<EOF
$TARGET_LIST
EOF

if [ "$PLAN_FAILURES" -gt 0 ]; then
  printf 'PLAN_END result=FAILED simulated_failures=%s\n' "$PLAN_FAILURES"
  exit 1
fi

printf '%s\n' 'PLAN_END result=OK simulated_failures=0'
