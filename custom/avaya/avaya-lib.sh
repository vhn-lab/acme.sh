#!/usr/bin/env sh

avaya_config_error() {
  printf 'Configuration error: %s\n' "$1" >&2
  return 1
}

avaya_load_config() {
  AVAYA_CONFIG_FILE=$1

  TARGETS_FILE=/root/orange/script/acme-avaya/targets.csv
  STATE_DIR=/root/orange/script/acme-avaya/state
  LOG_FILE=/root/orange/script/acme-avaya/logs/deploy.log
  LOCK_FILE=/run/lock/acme-avaya-deploy.lock
  SSH_KNOWN_HOSTS=/root/orange/script/acme-avaya/ssh_known_hosts
  REMOTE_BACKUP_DIR=/root/orange/script/acme-avaya/backups
  SSH_CONNECT_TIMEOUT=10
  FAILURE_POLICY='continue'
  MIN_REMAINING_DAYS=7

  if [ ! -f "$AVAYA_CONFIG_FILE" ] || [ ! -r "$AVAYA_CONFIG_FILE" ]; then
    avaya_config_error "file is missing or unreadable: $AVAYA_CONFIG_FILE"
    return 1
  fi

  AVAYA_LINE_NUMBER=0
  while IFS= read -r AVAYA_LINE || [ -n "$AVAYA_LINE" ]; do
    AVAYA_LINE_NUMBER=$((AVAYA_LINE_NUMBER + 1))
    case "$AVAYA_LINE" in
      '' | '#'* ) continue ;;
      *'='*) ;;
      *)
        avaya_config_error "line $AVAYA_LINE_NUMBER does not contain '='"
        return 1
        ;;
    esac

    AVAYA_KEY=${AVAYA_LINE%%=*}
    AVAYA_VALUE=${AVAYA_LINE#*=}
    if [ -z "$AVAYA_VALUE" ]; then
      avaya_config_error "empty value for $AVAYA_KEY at line $AVAYA_LINE_NUMBER"
      return 1
    fi

    case "$AVAYA_KEY" in
      TARGETS_FILE) TARGETS_FILE=$AVAYA_VALUE ;;
      STATE_DIR) STATE_DIR=$AVAYA_VALUE ;;
      LOG_FILE) LOG_FILE=$AVAYA_VALUE ;;
      LOCK_FILE) LOCK_FILE=$AVAYA_VALUE ;;
      SSH_KNOWN_HOSTS) SSH_KNOWN_HOSTS=$AVAYA_VALUE ;;
      REMOTE_BACKUP_DIR) REMOTE_BACKUP_DIR=$AVAYA_VALUE ;;
      SSH_CONNECT_TIMEOUT) SSH_CONNECT_TIMEOUT=$AVAYA_VALUE ;;
      FAILURE_POLICY) FAILURE_POLICY=$AVAYA_VALUE ;;
      MIN_REMAINING_DAYS) MIN_REMAINING_DAYS=$AVAYA_VALUE ;;
      *)
        avaya_config_error "unknown key $AVAYA_KEY at line $AVAYA_LINE_NUMBER"
        return 1
        ;;
    esac
  done <"$AVAYA_CONFIG_FILE"

  for AVAYA_PATH in "$TARGETS_FILE" "$STATE_DIR" "$LOG_FILE" "$LOCK_FILE" "$SSH_KNOWN_HOSTS" "$REMOTE_BACKUP_DIR"; do
    case "$AVAYA_PATH" in
      /*) ;;
      *)
        avaya_config_error "paths must be absolute: $AVAYA_PATH"
        return 1
        ;;
    esac
    case "$AVAYA_PATH" in
      *[!A-Za-z0-9_./-]*)
        avaya_config_error "path contains unsupported characters: $AVAYA_PATH"
        return 1
        ;;
    esac
  done

  case "$SSH_CONNECT_TIMEOUT" in
    '' | *[!0-9]*)
      avaya_config_error 'SSH_CONNECT_TIMEOUT must be an integer'
      return 1
      ;;
  esac
  if [ "$SSH_CONNECT_TIMEOUT" -lt 1 ] || [ "$SSH_CONNECT_TIMEOUT" -gt 300 ]; then
    avaya_config_error 'SSH_CONNECT_TIMEOUT must be between 1 and 300 seconds'
    return 1
  fi

  case "$MIN_REMAINING_DAYS" in
    '' | *[!0-9]*)
      avaya_config_error 'MIN_REMAINING_DAYS must be an integer'
      return 1
      ;;
  esac
  if [ "$MIN_REMAINING_DAYS" -lt 1 ] || [ "$MIN_REMAINING_DAYS" -gt 90 ]; then
    avaya_config_error 'MIN_REMAINING_DAYS must be between 1 and 90'
    return 1
  fi

  case "$FAILURE_POLICY" in
    continue | stop) ;;
    *)
      avaya_config_error 'FAILURE_POLICY must be continue or stop'
      return 1
      ;;
  esac

  export TARGETS_FILE STATE_DIR LOG_FILE LOCK_FILE SSH_KNOWN_HOSTS REMOTE_BACKUP_DIR
  export SSH_CONNECT_TIMEOUT FAILURE_POLICY MIN_REMAINING_DAYS
  return 0
}

avaya_validate_targets() {
  AVAYA_TARGETS_FILE=$1
  if [ ! -f "$AVAYA_TARGETS_FILE" ] || [ ! -r "$AVAYA_TARGETS_FILE" ]; then
    avaya_config_error "targets file is missing or unreadable: $AVAYA_TARGETS_FILE"
    return 1
  fi

  awk -F ';' '
    function fail(message) {
      print "Targets error at line " NR ": " message > "/dev/stderr"
      invalid = 1
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      if (NF != 9) {
        fail("expected nine fields")
        next
      }
      enabled = $1
      type = $2
      name = $3
      host = $4
      user = $5
      server_ip = $6
      profile = $7
      role = $8
      transport = $9

      if (enabled != "yes" && enabled != "no") fail("enabled must be yes or no")
      if (type != "ipo") fail("type must be ipo")
      if (name !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) fail("invalid target name")
      if (host !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) fail("invalid host")
      if (user !~ /^[A-Za-z_][A-Za-z0-9_-]*$/) fail("invalid SSH user")
      split(server_ip, octet, ".")
      if (server_ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
        fail("invalid server IP")
      } else {
        for (i = 1; i <= 4; i++) {
          if (octet[i] < 0 || octet[i] > 255) fail("invalid server IP")
        }
      }
      if (profile !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) fail("invalid certificate profile")
      if (role != "standalone" && role != "primary" && role != "secondary") fail("invalid role")
      if (transport != "local" && transport != "ssh") fail("invalid transport")
      if (transport == "local" && active_local++) fail("only one local target is permitted")
      if (seen_name[name]++) fail("duplicate target name " name)

      if (enabled == "yes" && type == "ipo") active_ipo++
    }
    END {
      if (active_ipo < 1 || active_ipo > 2) {
        print "Targets error: expected one or two active IP Office targets" > "/dev/stderr"
        invalid = 1
      }
      exit invalid ? 1 : 0
    }
  ' "$AVAYA_TARGETS_FILE"
}

avaya_targets_for_profile() {
  AVAYA_TARGETS_FILE=$1
  AVAYA_PROFILE=$2

  if ! avaya_validate_targets "$AVAYA_TARGETS_FILE"; then
    return 1
  fi
  case "$AVAYA_PROFILE" in
    '' | *[!A-Za-z0-9._-]*)
      avaya_config_error "invalid certificate profile: $AVAYA_PROFILE"
      return 1
      ;;
  esac

  awk -F ';' -v profile="$AVAYA_PROFILE" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == "yes" && $7 == profile { print }
  ' "$AVAYA_TARGETS_FILE"
}
