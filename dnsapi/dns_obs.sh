#!/usr/bin/env sh

# shellcheck disable=SC2034
dns_obs_info='Orange Business DNS (OBS/Eolas)
Site: orange-business.com
Options:
 OBS_File Path to a root-readable credentials file.
Credentials format:
 hostName;zoneName;apiToken
'

OBS_Api="${OBS_Api:-https://ihmdns.eolas.fr/api/v1}"
OBS_RenewBeforeDays="${OBS_RenewBeforeDays:-15}"
OBS_LockStaleSeconds="${OBS_LockStaleSeconds:-600}"

dns_obs_add() {
  fulldomain=$1
  txtvalue=$2

  if ! _obs_prepare "$fulldomain"; then
    return 1
  fi

  _info "Adding OBS DNS TXT record for $fulldomain"
  if ! _obs_rest POST "$_obs_zone/record" "{\"record\":{\"ttl\":3600,\"name\":\"$fulldomain\",\"type\":\"TXT\",\"value\":\"$txtvalue\"}}"; then
    _err "OBS DNS TXT record creation failed for $fulldomain"
    return 1
  fi

  if _contains "$response" "Record added successfully" ||
    _contains "$response" "The record already exists" ||
    _obs_response_success; then
    _info "OBS DNS TXT record is present for $fulldomain"
    return 0
  fi

  _err "OBS API did not confirm TXT record creation for $fulldomain"
  return 1
}

dns_obs_rm() {
  fulldomain=$1
  txtvalue=$2

  if ! _obs_prepare "$fulldomain"; then
    return 1
  fi

  _info "Removing OBS DNS TXT record for $fulldomain"
  if ! _obs_rest DELETE "$_obs_zone/record" "{\"record\":{\"name\":\"$fulldomain\",\"type\":\"TXT\",\"value\":\"$txtvalue\"}}"; then
    _err "OBS DNS TXT record removal failed for $fulldomain"
    return 1
  fi

  if _contains "$response" "Record deleted successfully" ||
    _contains "$response" "record does not exist" ||
    _obs_response_success; then
    _info "OBS DNS TXT record is absent for $fulldomain"
    return 0
  fi

  _err "OBS API did not confirm TXT record removal for $fulldomain"
  return 1
}

_obs_prepare() {
  _obs_fulldomain=$1
  _obs_hostname=${_obs_fulldomain#_acme-challenge.}

  if [ "$_obs_hostname" = "$_obs_fulldomain" ] || ! _obs_valid_dns_name "$_obs_hostname"; then
    _err "Invalid OBS challenge domain: $_obs_fulldomain"
    return 1
  fi

  OBS_File="${OBS_File:-$(_readaccountconf_mutable OBS_File)}"
  if [ -z "$OBS_File" ]; then
    _err "OBS_File is not configured"
    return 1
  fi
  _saveaccountconf_mutable OBS_File "$OBS_File"

  if [ ! -f "$OBS_File" ] || [ ! -r "$OBS_File" ]; then
    _err "OBS credentials file is missing or unreadable: $OBS_File"
    return 1
  fi
  if ! _obs_check_file_permissions "$OBS_File"; then
    return 1
  fi

  if ! _obs_lock; then
    return 1
  fi
  if ! _obs_load_credentials "$_obs_hostname"; then
    _obs_unlock
    return 1
  fi
  if ! _obs_check_token; then
    _obs_unlock
    return 1
  fi
  _obs_unlock
  return 0
}

_obs_load_credentials() {
  _obs_lookup_host=$1
  _obs_record=$(awk -F ';' -v host="$_obs_lookup_host" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == host { print; count++ }
    END { if (count != 1) exit 1 }
  ' "$OBS_File") || {
    _err "OBS credentials must contain exactly one entry for $_obs_lookup_host"
    return 1
  }

  _obs_field_count=$(printf '%s\n' "$_obs_record" | awk -F ';' '{ print NF }')
  if [ "$_obs_field_count" != "3" ]; then
    _err "Invalid OBS credentials entry for $_obs_lookup_host"
    return 1
  fi

  _obs_zone=$(printf '%s\n' "$_obs_record" | cut -d ';' -f 2)
  _obs_token=$(printf '%s\n' "$_obs_record" | cut -d ';' -f 3)
  if ! _obs_valid_dns_name "$_obs_zone" || [ -z "$_obs_token" ]; then
    _err "Invalid OBS zone or empty token for $_obs_lookup_host"
    return 1
  fi
  case "$_obs_token" in
    *';'* | *[!A-Za-z0-9._~-]*)
      _err "OBS token contains unsupported characters for $_obs_lookup_host"
      return 1
      ;;
  esac

  case "$_obs_lookup_host" in
    "$_obs_zone" | *."$_obs_zone") ;;
    *)
      _err "OBS host $_obs_lookup_host is not within zone $_obs_zone"
      return 1
      ;;
  esac
  return 0
}

_obs_check_token() {
  case "$OBS_RenewBeforeDays" in
    '' | *[!0-9]*)
      _err "OBS_RenewBeforeDays must be a non-negative integer"
      return 1
      ;;
  esac

  if ! _obs_rest GET token ""; then
    _err "Unable to inspect the OBS API token"
    return 1
  fi

  _obs_expiry=$(printf '%s\n' "$response" | sed -n 's/.*"expiresAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | _head_n 1)
  if [ -z "$_obs_expiry" ]; then
    _err "OBS API response does not contain a token expiration date"
    return 1
  fi
  _obs_expiry_epoch=$(date -d "$_obs_expiry" +%s 2>/dev/null) || {
    _err "Unable to parse the OBS API token expiration date"
    return 1
  }
  _obs_now=$(date +%s)
  _obs_renew_window=$((OBS_RenewBeforeDays * 86400))

  if [ $((_obs_expiry_epoch - _obs_now)) -ge "$_obs_renew_window" ]; then
    return 0
  fi

  if ! _obs_preflight_credentials_update; then
    _err "OBS credentials cannot be updated safely; token rotation was not attempted"
    return 1
  fi

  _info "Rotating OBS API token before expiration"
  _obs_old_token=$_obs_token
  if ! _obs_rest POST token/rotate ""; then
    _err "OBS API token rotation failed"
    return 1
  fi
  _obs_new_token=$(printf '%s\n' "$response" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | _head_n 1)
  if [ -z "$_obs_new_token" ] || [ "$_obs_new_token" = "$_obs_old_token" ]; then
    _err "OBS API token rotation returned an invalid token"
    return 1
  fi
  case "$_obs_new_token" in
    *';'* | *[!A-Za-z0-9._~-]*)
      _err "OBS API token rotation returned unsupported characters"
      return 1
      ;;
  esac

  if ! _obs_replace_token "$_obs_hostname" "$_obs_zone" "$_obs_old_token" "$_obs_new_token"; then
    _err "The rotated OBS token could not be stored safely"
    return 1
  fi
  _obs_token=$_obs_new_token
  return 0
}

_obs_preflight_credentials_update() {
  _obs_preflight_tmp="${OBS_File}.preflight.$$"
  if ! (umask 077 && : >"$_obs_preflight_tmp"); then
    rm -f "$_obs_preflight_tmp"
    return 1
  fi
  if ! chmod 600 "$_obs_preflight_tmp" || ! rm -f "$_obs_preflight_tmp"; then
    rm -f "$_obs_preflight_tmp"
    return 1
  fi
  return 0
}

_obs_replace_token() {
  _obs_replace_host=$1
  _obs_replace_zone=$2
  _obs_replace_old=$3
  _obs_replace_new=$4
  _obs_tmp="${OBS_File}.tmp.$$"

  if ! awk -F ';' -v OFS=';' -v host="$_obs_replace_host" -v zone="$_obs_replace_zone" \
    -v old="$_obs_replace_old" -v new="$_obs_replace_new" '
      $1 == host && $2 == zone && $3 == old { $3 = new; changed++ }
      { print }
      END { if (changed != 1) exit 1 }
    ' "$OBS_File" >"$_obs_tmp"; then
    rm -f "$_obs_tmp"
    return 1
  fi
  if ! chmod 600 "$_obs_tmp" || ! mv -f "$_obs_tmp" "$OBS_File"; then
    rm -f "$_obs_tmp"
    return 1
  fi
  return 0
}

_obs_rest() {
  _obs_method=$1
  _obs_endpoint=$2
  _obs_data=$3

  export _H1="Content-Type: application/json; charset=UTF-8"
  export _H2="Authorization: Bearer $_obs_token"
  export _H3="Accept: application/json"

  if [ "$_obs_method" = "GET" ]; then
    if ! response="$(_get "$OBS_Api/$_obs_endpoint")"; then
      return 1
    fi
  else
    if ! response="$(_post "$_obs_data" "$OBS_Api/$_obs_endpoint" "" "$_obs_method")"; then
      return 1
    fi
  fi
  return 0
}

_obs_response_success() {
  printf '%s\n' "$response" | tr -d '[:space:]' | grep '"success":true' >/dev/null 2>&1
}

_obs_valid_dns_name() {
  _obs_name=$1
  case "$_obs_name" in
    '' | .* | *. | *..* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

_obs_check_file_permissions() {
  _obs_perm_file=$1
  _obs_mode=$(stat -c '%a' "$_obs_perm_file" 2>/dev/null) || {
    _err "Unable to inspect OBS credentials file permissions"
    return 1
  }
  case "$_obs_mode" in
    600 | 400) return 0 ;;
    *)
      _err "OBS credentials file must have mode 600 or 400: $_obs_perm_file"
      return 1
      ;;
  esac
}

_obs_lock() {
  _obs_lock_dir="${OBS_File}.lock"
  _obs_lock_attempt=0
  while ! mkdir "$_obs_lock_dir" 2>/dev/null; do
    _obs_recover_stale_lock || true
    _obs_lock_attempt=$((_obs_lock_attempt + 1))
    if [ "$_obs_lock_attempt" -ge 30 ]; then
      _err "Timed out waiting for the OBS credentials lock"
      return 1
    fi
    _sleep 1
  done
  if ! (umask 077 && printf '%s\n' "$$" >"$_obs_lock_dir/pid"); then
    rmdir "$_obs_lock_dir" 2>/dev/null || true
    _err "Unable to record ownership of the OBS credentials lock"
    return 1
  fi
  return 0
}

_obs_recover_stale_lock() {
  case "$OBS_LockStaleSeconds" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ -d "$_obs_lock_dir" ] || return 1

  _obs_lock_mtime=$(stat -c '%Y' "$_obs_lock_dir" 2>/dev/null) || return 1
  _obs_lock_now=$(date +%s)
  [ $((_obs_lock_now - _obs_lock_mtime)) -ge "$OBS_LockStaleSeconds" ] || return 1

  _obs_lock_pid=
  if [ -r "$_obs_lock_dir/pid" ]; then
    IFS= read -r _obs_lock_pid <"$_obs_lock_dir/pid" || true
  fi
  case "$_obs_lock_pid" in
    '' | *[!0-9]*) ;;
    *)
      if kill -0 "$_obs_lock_pid" 2>/dev/null; then
        return 1
      fi
      ;;
  esac

  rm -f "$_obs_lock_dir/pid"
  rmdir "$_obs_lock_dir" 2>/dev/null
}

_obs_unlock() {
  _obs_lock_pid=
  if [ -r "$_obs_lock_dir/pid" ]; then
    IFS= read -r _obs_lock_pid <"$_obs_lock_dir/pid" || true
  fi
  if [ "$_obs_lock_pid" = "$$" ]; then
    rm -f "$_obs_lock_dir/pid"
    rmdir "$_obs_lock_dir" 2>/dev/null || true
  fi
}
