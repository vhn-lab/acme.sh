#!/usr/bin/env sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# shellcheck source=avaya-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/avaya-lib.sh"

usage() {
  printf '%s\n' \
    'Usage: avaya-deploy.sh (--dry-run | --apply --acknowledge-service-restarts)' \
    '       --config FILE --profile NAME' \
    '       --cert FILE --key FILE --fullchain FILE --expected-name FQDN' \
    '       [--trust-file FILE] [--allow-partial-chain]' \
    '       [--password-file FILE] [--simulate-failure TARGET]'
}

fail() {
  printf 'Avaya deployment failed: %s\n' "$1" >&2
  exit 1
}

DRY_RUN=no
APPLY=no
ACK_RESTARTS=no
CONFIG_FILE=
PROFILE=
CERT_FILE=
KEY_FILE=
FULLCHAIN_FILE=
EXPECTED_NAME=
TRUST_FILE=
SIMULATE_FAILURE=
PASSWORD_FILE=
ALLOW_PARTIAL_CHAIN=no
REMOTE_HELPER=${AVAYA_REMOTE_HELPER:-$SCRIPT_DIR/avaya-ipo-remote.sh}
LOCAL_HELPER=${AVAYA_LOCAL_HELPER:-$SCRIPT_DIR/avaya-ipo-local.sh}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=yes; shift ;;
    --apply) APPLY=yes; shift ;;
    --acknowledge-service-restarts) ACK_RESTARTS=yes; shift ;;
    --config) [ "$#" -ge 2 ] || fail 'missing value for --config'; CONFIG_FILE=$2; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || fail 'missing value for --profile'; PROFILE=$2; shift 2 ;;
    --cert) [ "$#" -ge 2 ] || fail 'missing value for --cert'; CERT_FILE=$2; shift 2 ;;
    --key) [ "$#" -ge 2 ] || fail 'missing value for --key'; KEY_FILE=$2; shift 2 ;;
    --fullchain) [ "$#" -ge 2 ] || fail 'missing value for --fullchain'; FULLCHAIN_FILE=$2; shift 2 ;;
    --expected-name) [ "$#" -ge 2 ] || fail 'missing value for --expected-name'; EXPECTED_NAME=$2; shift 2 ;;
    --trust-file) [ "$#" -ge 2 ] || fail 'missing value for --trust-file'; TRUST_FILE=$2; shift 2 ;;
    --allow-partial-chain) ALLOW_PARTIAL_CHAIN=yes; shift ;;
    --password-file) [ "$#" -ge 2 ] || fail 'missing value for --password-file'; PASSWORD_FILE=$2; shift 2 ;;
    --simulate-failure) [ "$#" -ge 2 ] || fail 'missing value for --simulate-failure'; SIMULATE_FAILURE=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ "$DRY_RUN" = yes ] || [ "$APPLY" = yes ] || fail '--dry-run or --apply is required'
[ "$DRY_RUN" != yes ] || [ "$APPLY" != yes ] || fail '--dry-run and --apply are mutually exclusive'
[ "$APPLY" != yes ] || [ "$ACK_RESTARTS" = yes ] || fail '--acknowledge-service-restarts is required with --apply'
[ "$APPLY" != yes ] || [ -n "$PASSWORD_FILE" ] || fail '--password-file is required with --apply'
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

if [ "$APPLY" = yes ]; then
  command -v flock >/dev/null 2>&1 || fail 'flock is required for --apply'
  LOCK_DIR=${LOCK_FILE%/*}
  mkdir -p "$LOCK_DIR" || fail "cannot create lock directory: $LOCK_DIR"
  umask 077
  # File descriptor 9 remains open for the complete deployment.
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail 'another Avaya deployment is already running'
  chmod 600 "$LOCK_FILE" || fail 'cannot protect deployment lock file'
fi

VALIDATE_PARTIAL=
[ "$ALLOW_PARTIAL_CHAIN" != yes ] || VALIDATE_PARTIAL=--allow-partial-chain
if [ -n "$TRUST_FILE" ]; then
  # VALIDATE_PARTIAL is either empty or the fixed option above.
  # shellcheck disable=SC2086
  VALIDATION_OUTPUT=$(sh "$SCRIPT_DIR/avaya-validate.sh" \
    --cert "$CERT_FILE" --key "$KEY_FILE" --fullchain "$FULLCHAIN_FILE" \
    --expected-name "$EXPECTED_NAME" --min-days "$MIN_REMAINING_DAYS" \
    --trust-file "$TRUST_FILE" $VALIDATE_PARTIAL) || exit 1
else
  VALIDATION_OUTPUT=$(sh "$SCRIPT_DIR/avaya-validate.sh" \
    --cert "$CERT_FILE" --key "$KEY_FILE" --fullchain "$FULLCHAIN_FILE" \
    --expected-name "$EXPECTED_NAME" --min-days "$MIN_REMAINING_DAYS") || exit 1
fi

FINGERPRINT=$(printf '%s\n' "$VALIDATION_OUTPUT" | sed -n 's/^VALID fingerprint=\([^[:space:]]*\).*/\1/p')
[ -n "$FINGERPRINT" ] || fail 'validator did not return a certificate fingerprint'

TARGET_LIST=$(avaya_targets_for_profile "$TARGETS_FILE" "$PROFILE") || exit 1
[ -n "$TARGET_LIST" ] || fail "no active targets use profile $PROFILE"

MODE=dry-run
[ "$APPLY" != yes ] || MODE=apply
printf 'PLAN_START mode=%s profile=%s fingerprint=%s failure_policy=%s\n' \
  "$MODE" "$PROFILE" "$FINGERPRINT" "$FAILURE_POLICY"

PLAN_STOPPED=no
PLAN_FAILURES=0
while IFS=';' read -r TARGET_ENABLED TARGET_TYPE TARGET_NAME TARGET_HOST TARGET_USER TARGET_SERVER_IP TARGET_PROFILE TARGET_ROLE TARGET_TRANSPORT; do

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
    if [ "$APPLY" != yes ] && [ "$INSTALLED_FINGERPRINT" = "$FINGERPRINT" ]; then
      TARGET_STATUS=UNCHANGED
    elif [ "$APPLY" = yes ]; then
      if [ "$TARGET_TRANSPORT" = local ]; then
        TARGET_HELPER=$LOCAL_HELPER
        set -- --server-ip "$TARGET_SERVER_IP" --cert "$CERT_FILE" --key "$KEY_FILE" \
          --fullchain "$FULLCHAIN_FILE" --password-file "$PASSWORD_FILE" \
          --backup-dir "$REMOTE_BACKUP_DIR"
      else
        TARGET_HELPER=$REMOTE_HELPER
        set -- --host "$TARGET_HOST" --user "$TARGET_USER" \
          --server-ip "$TARGET_SERVER_IP" --cert "$CERT_FILE" --key "$KEY_FILE" \
          --fullchain "$FULLCHAIN_FILE" --password-file "$PASSWORD_FILE" \
          --known-hosts "$SSH_KNOWN_HOSTS" --connect-timeout "$SSH_CONNECT_TIMEOUT" \
          --backup-dir "$REMOTE_BACKUP_DIR"
      fi
      if TARGET_OUTPUT=$(sh "$TARGET_HELPER" "$@"); then
        printf '%s\n' "$TARGET_OUTPUT"
        mkdir -p "$STATE_DIR/$PROFILE"
        chmod 700 "$STATE_DIR" "$STATE_DIR/$PROFILE"
        STATE_TMP="$STATE_FILE.tmp.$$"
        printf '%s\n' "$FINGERPRINT" >"$STATE_TMP"
        chmod 600 "$STATE_TMP"
        mv "$STATE_TMP" "$STATE_FILE"
        if printf '%s\n' "$TARGET_OUTPUT" | grep '^IPO_INSTALL result=UNCHANGED ' >/dev/null; then
          TARGET_STATUS=UNCHANGED
        else
          TARGET_STATUS=DEPLOYED
        fi
      else
        [ -z "$TARGET_OUTPUT" ] || printf '%s\n' "$TARGET_OUTPUT"
        TARGET_STATUS=FAILED
        PLAN_FAILURES=$((PLAN_FAILURES + 1))
        [ "$FAILURE_POLICY" != stop ] || PLAN_STOPPED=yes
      fi
    else
      TARGET_STATUS=WOULD_DEPLOY
    fi
  fi

  printf 'PLAN target=%s type=%s host=%s user=%s server_ip=%s role=%s transport=%s status=%s\n' \
    "$TARGET_NAME" "$TARGET_TYPE" "$TARGET_HOST" "$TARGET_USER" \
    "$TARGET_SERVER_IP" "$TARGET_ROLE" "$TARGET_TRANSPORT" "$TARGET_STATUS"
done <<EOF
$TARGET_LIST
EOF

if [ "$PLAN_FAILURES" -gt 0 ]; then
  printf 'PLAN_END result=FAILED failures=%s\n' "$PLAN_FAILURES"
  exit 1
fi

printf '%s\n' 'PLAN_END result=OK simulated_failures=0'
