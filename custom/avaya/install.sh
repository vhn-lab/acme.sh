#!/usr/bin/env sh

set -eu

REPOSITORY=https://github.com/vhn-lab/acme.sh
PROJECT_ROOT=/root/orange/script
INSTALL_HOME=$PROJECT_ROOT/acme.sh
CONFIG_ROOT=$PROJECT_ROOT/acme-avaya

usage() {
  printf '%s\n' \
    'Usage: install.sh --email ADDRESS --server-ip IPV4' \
    '       --revision COMMIT_OR_TAG --sha256 ARCHIVE_SHA256 [--dry-run]'
}

fail() {
  printf 'Avaya acme.sh installation failed: %s\n' "$1" >&2
  exit 1
}

EMAIL=
SERVER_IP=
REVISION=
EXPECTED_SHA256=
DRY_RUN=no
TEMP_DIR=
INSTALL_STARTED=no
INSTALL_COMPLETE=no
CRON_SNAPSHOT=

cleanup() {
  if [ "$INSTALL_STARTED" = yes ] && [ "$INSTALL_COMPLETE" != yes ]; then
    rm -rf "$INSTALL_HOME" "$CONFIG_ROOT"
    if [ -n "$CRON_SNAPSHOT" ] && [ -f "$CRON_SNAPSHOT" ]; then
      crontab "$CRON_SNAPSHOT" || true
    fi
    printf '%s\n' 'Partial installation rolled back.' >&2
  fi
  if [ -n "$TEMP_DIR" ]; then
    case "$TEMP_DIR" in
      /tmp/acme-avaya-install.*) rm -rf "$TEMP_DIR" ;;
    esac
  fi
}
trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --email) [ "$#" -ge 2 ] || fail 'missing value for --email'; EMAIL=$2; shift 2 ;;
    --server-ip) [ "$#" -ge 2 ] || fail 'missing value for --server-ip'; SERVER_IP=$2; shift 2 ;;
    --revision) [ "$#" -ge 2 ] || fail 'missing value for --revision'; REVISION=$2; shift 2 ;;
    --sha256) [ "$#" -ge 2 ] || fail 'missing value for --sha256'; EXPECTED_SHA256=$2; shift 2 ;;
    --dry-run) DRY_RUN=yes; shift ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$EMAIL" ] || fail '--email is required'
[ -n "$SERVER_IP" ] || fail '--server-ip is required'
[ -n "$REVISION" ] || fail '--revision is required'
[ -n "$EXPECTED_SHA256" ] || fail '--sha256 is required'

case "$EMAIL" in
  *[!A-Za-z0-9._%+@-]* | '') fail 'invalid email address' ;;
esac
case "$EMAIL" in
  *'@'*'.'*) ;;
  *) fail 'invalid email address' ;;
esac
case "$REVISION" in
  *[!A-Za-z0-9._-]* | '') fail 'invalid revision' ;;
esac
case "$REVISION" in
  v[0-9]*) ;;
  *)
    case "$REVISION" in *[!A-Fa-f0-9]*) fail 'revision must be a full commit or a version tag' ;; esac
    [ "${#REVISION}" -eq 40 ] || fail 'full commit revision must contain 40 hexadecimal characters'
    ;;
esac
case "$EXPECTED_SHA256" in
  *[!A-Fa-f0-9]* | '') fail 'invalid SHA256 checksum' ;;
esac
[ "${#EXPECTED_SHA256}" -eq 64 ] || fail 'SHA256 checksum must contain 64 hexadecimal characters'
EXPECTED_SHA256=$(printf '%s' "$EXPECTED_SHA256" | tr 'A-F' 'a-f')

if ! printf '%s\n' "$SERVER_IP" | awk -F. '
  NF != 4 { exit 1 }
  { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }
'; then
  fail 'invalid IP Office IPv4 address'
fi

if [ "$DRY_RUN" = yes ]; then
  printf 'INSTALL_PLAN repository=%s revision=%s install_home=%s config_root=%s server_ip=%s email=%s\n' \
    "$REPOSITORY" "$REVISION" "$INSTALL_HOME" "$CONFIG_ROOT" "$SERVER_IP" "$EMAIL"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || fail 'root privileges are required'
[ ! -e "$INSTALL_HOME" ] || fail "installation already exists: $INSTALL_HOME"
[ ! -e "$CONFIG_ROOT" ] || fail "configuration already exists: $CONFIG_ROOT"

for COMMAND in curl tar sha256sum openssl install awk sed crontab; do
  command -v "$COMMAND" >/dev/null 2>&1 || fail "required command is unavailable: $COMMAND"
done

TEMP_DIR=$(mktemp -d /tmp/acme-avaya-install.XXXXXX) || fail 'cannot create temporary directory'
chmod 700 "$TEMP_DIR"
ARCHIVE=$TEMP_DIR/acme.sh.tar.gz
SOURCE_DIR=$TEMP_DIR/source
CRON_SNAPSHOT=$TEMP_DIR/crontab.before
(crontab -l 2>/dev/null || true) >"$CRON_SNAPSHOT"

curl -fL --connect-timeout 15 --max-time 300 \
  "$REPOSITORY/archive/$REVISION.tar.gz" -o "$ARCHIVE" || fail 'cannot download approved archive'
printf '%s  %s\n' "$EXPECTED_SHA256" "$ARCHIVE" |
  sha256sum --check --strict >/dev/null 2>&1 || fail 'archive SHA256 verification failed'

mkdir -m 700 "$SOURCE_DIR"
tar -xzf "$ARCHIVE" -C "$SOURCE_DIR" --strip-components=1 || fail 'cannot extract archive'

for REQUIRED_FILE in \
  acme.sh deploy/avaya_ipo.sh custom/avaya/avaya-deploy.sh \
  custom/avaya/avaya-ipo-install.sh custom/avaya/avaya-ipo-local.sh \
  custom/avaya/avaya-ipo-remote.sh custom/avaya/avaya-ipo-verify.sh; do
  [ -s "$SOURCE_DIR/$REQUIRED_FILE" ] || fail "approved archive is missing: $REQUIRED_FILE"
done
# The literal PROJECT_NAME reference is required in the controlled source file.
# shellcheck disable=SC2016
grep -F 'PROJECT="https://github.com/vhn-lab/$PROJECT_NAME"' "$SOURCE_DIR/acme.sh" >/dev/null ||
  fail 'archive does not use the controlled fork upgrade source'
sh -n "$SOURCE_DIR/acme.sh" "$SOURCE_DIR/deploy/avaya_ipo.sh" "$SOURCE_DIR"/custom/avaya/*.sh ||
  fail 'shell syntax validation failed'

umask 077
install -d -m 700 "$PROJECT_ROOT"
INSTALL_STARTED=yes

(
  cd "$SOURCE_DIR"
  ./acme.sh --install --home "$INSTALL_HOME" --config-home "$INSTALL_HOME" \
    --no-profile --email "$EMAIL"
) || fail 'acme.sh installation failed'

install -d -m 700 "$INSTALL_HOME/custom/avaya"
for SOURCE_FILE in "$SOURCE_DIR"/custom/avaya/*.sh; do
  install -m 700 "$SOURCE_FILE" "$INSTALL_HOME/custom/avaya/${SOURCE_FILE##*/}"
done
install -m 600 "$SOURCE_DIR/custom/avaya/openssl-legacy.cnf" \
  "$INSTALL_HOME/custom/avaya/openssl-legacy.cnf"

install -d -m 700 "$CONFIG_ROOT" "$CONFIG_ROOT/state" \
  "$CONFIG_ROOT/logs" "$CONFIG_ROOT/backups"
install -m 600 "$SOURCE_DIR/custom/avaya/config.example" "$CONFIG_ROOT/config"
printf '%s\n' \
  '# enabled;type;name;host;sshUser;serverIp;certificateProfile;role;transport' \
  "yes;ipo;PRIMARY_IPO;localhost;root;$SERVER_IP;voice-edge;standalone;local" \
  >"$CONFIG_ROOT/targets.csv"
chmod 600 "$CONFIG_ROOT/targets.csv"
install -m 600 /dev/null "$CONFIG_ROOT/ssh_known_hosts"
openssl rand -base64 36 >"$CONFIG_ROOT/p12-password"
chmod 600 "$CONFIG_ROOT/p12-password"

INSTALL_COMPLETE=yes
printf 'INSTALL_OK revision=%s install_home=%s config_root=%s\n' \
  "$REVISION" "$INSTALL_HOME" "$CONFIG_ROOT"
