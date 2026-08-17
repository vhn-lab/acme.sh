#!/usr/bin/env sh

# Deploy an acme.sh certificate to one or more Avaya IP Office targets.
#
# Required configuration:
#   AVAYA_IPO_CONFIG: absolute path to the Avaya deployment configuration
#   AVAYA_IPO_PROFILE: certificate profile from the targets file
#   AVAYA_IPO_PASSWORD_FILE: root-readable PKCS12 password file
#   AVAYA_IPO_DEPLOYER: absolute path to custom/avaya/avaya-deploy.sh
#   AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS: must be "yes"
#
# Optional configuration:
#   AVAYA_IPO_EXPECTED_NAME: certificate name to validate (defaults to domain)
#   AVAYA_IPO_TRUST_FILE: explicit CA trust file
#   AVAYA_IPO_ALLOW_PARTIAL_CHAIN: "yes" to permit partial-chain validation

# domain keyfile certfile cafile fullchain
avaya_ipo_deploy() {
  _avaya_ipo_domain=$1
  _avaya_ipo_key=$2
  _avaya_ipo_cert=$3
  _avaya_ipo_ca=$4
  _avaya_ipo_fullchain=$5

  _debug _avaya_ipo_domain "$_avaya_ipo_domain"
  _debug _avaya_ipo_key "$_avaya_ipo_key"
  _debug _avaya_ipo_cert "$_avaya_ipo_cert"
  _debug _avaya_ipo_ca "$_avaya_ipo_ca"
  _debug _avaya_ipo_fullchain "$_avaya_ipo_fullchain"

  AVAYA_IPO_CONFIG=${AVAYA_IPO_CONFIG:-}
  AVAYA_IPO_PROFILE=${AVAYA_IPO_PROFILE:-}
  AVAYA_IPO_PASSWORD_FILE=${AVAYA_IPO_PASSWORD_FILE:-}
  AVAYA_IPO_DEPLOYER=${AVAYA_IPO_DEPLOYER:-}
  AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS=${AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS:-}
  AVAYA_IPO_EXPECTED_NAME=${AVAYA_IPO_EXPECTED_NAME:-}
  AVAYA_IPO_TRUST_FILE=${AVAYA_IPO_TRUST_FILE:-}
  AVAYA_IPO_ALLOW_PARTIAL_CHAIN=${AVAYA_IPO_ALLOW_PARTIAL_CHAIN:-}

  for _avaya_ipo_setting in \
    AVAYA_IPO_CONFIG AVAYA_IPO_PROFILE AVAYA_IPO_PASSWORD_FILE \
    AVAYA_IPO_DEPLOYER AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS \
    AVAYA_IPO_EXPECTED_NAME AVAYA_IPO_TRUST_FILE \
    AVAYA_IPO_ALLOW_PARTIAL_CHAIN; do
    _getdeployconf "$_avaya_ipo_setting"
  done

  if [ -z "$AVAYA_IPO_EXPECTED_NAME" ]; then
    AVAYA_IPO_EXPECTED_NAME=$_avaya_ipo_domain
  fi
  if [ -z "$AVAYA_IPO_ALLOW_PARTIAL_CHAIN" ]; then
    AVAYA_IPO_ALLOW_PARTIAL_CHAIN=no
  fi

  if [ -z "$AVAYA_IPO_CONFIG" ]; then
    _err "AVAYA_IPO_CONFIG is not defined."
    return 1
  fi
  if [ -z "$AVAYA_IPO_PROFILE" ]; then
    _err "AVAYA_IPO_PROFILE is not defined."
    return 1
  fi
  if [ -z "$AVAYA_IPO_PASSWORD_FILE" ]; then
    _err "AVAYA_IPO_PASSWORD_FILE is not defined."
    return 1
  fi
  if [ -z "$AVAYA_IPO_DEPLOYER" ]; then
    _err "AVAYA_IPO_DEPLOYER is not defined."
    return 1
  fi
  if [ "$AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS" != yes ]; then
    _err "AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS must be set to yes."
    return 1
  fi
  case "$AVAYA_IPO_ALLOW_PARTIAL_CHAIN" in
    yes | no) ;;
    *)
      _err "AVAYA_IPO_ALLOW_PARTIAL_CHAIN must be yes or no."
      return 1
      ;;
  esac

  for _avaya_ipo_path in "$AVAYA_IPO_CONFIG" "$AVAYA_IPO_PASSWORD_FILE" "$AVAYA_IPO_DEPLOYER"; do
    case "$_avaya_ipo_path" in
      /*) ;;
      *)
        _err "Avaya IP Office configuration paths must be absolute: $_avaya_ipo_path"
        return 1
        ;;
    esac
    if [ ! -f "$_avaya_ipo_path" ] || [ ! -r "$_avaya_ipo_path" ]; then
      _err "Avaya IP Office input is missing or unreadable: $_avaya_ipo_path"
      return 1
    fi
  done
  if [ -n "$AVAYA_IPO_TRUST_FILE" ]; then
    case "$AVAYA_IPO_TRUST_FILE" in
      /*) ;;
      *)
        _err "AVAYA_IPO_TRUST_FILE must be an absolute path."
        return 1
        ;;
    esac
    if [ ! -f "$AVAYA_IPO_TRUST_FILE" ] || [ ! -r "$AVAYA_IPO_TRUST_FILE" ]; then
      _err "AVAYA_IPO_TRUST_FILE is missing or unreadable."
      return 1
    fi
  fi

  for _avaya_ipo_cert_path in "$_avaya_ipo_key" "$_avaya_ipo_cert" "$_avaya_ipo_fullchain"; do
    if [ ! -f "$_avaya_ipo_cert_path" ] || [ ! -r "$_avaya_ipo_cert_path" ]; then
      _err "Certificate input is missing or unreadable: $_avaya_ipo_cert_path"
      return 1
    fi
  done

  _savedeployconf AVAYA_IPO_CONFIG "$AVAYA_IPO_CONFIG"
  _savedeployconf AVAYA_IPO_PROFILE "$AVAYA_IPO_PROFILE"
  _savedeployconf AVAYA_IPO_PASSWORD_FILE "$AVAYA_IPO_PASSWORD_FILE"
  _savedeployconf AVAYA_IPO_DEPLOYER "$AVAYA_IPO_DEPLOYER"
  _savedeployconf AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS "$AVAYA_IPO_ACKNOWLEDGE_SERVICE_RESTARTS"
  _savedeployconf AVAYA_IPO_EXPECTED_NAME "$AVAYA_IPO_EXPECTED_NAME"
  _savedeployconf AVAYA_IPO_ALLOW_PARTIAL_CHAIN "$AVAYA_IPO_ALLOW_PARTIAL_CHAIN"
  if [ -n "$AVAYA_IPO_TRUST_FILE" ]; then
    _savedeployconf AVAYA_IPO_TRUST_FILE "$AVAYA_IPO_TRUST_FILE"
  fi

  set -- "$AVAYA_IPO_DEPLOYER" --apply --acknowledge-service-restarts \
    --config "$AVAYA_IPO_CONFIG" --profile "$AVAYA_IPO_PROFILE" \
    --cert "$_avaya_ipo_cert" --key "$_avaya_ipo_key" \
    --fullchain "$_avaya_ipo_fullchain" \
    --expected-name "$AVAYA_IPO_EXPECTED_NAME" \
    --password-file "$AVAYA_IPO_PASSWORD_FILE"
  if [ -n "$AVAYA_IPO_TRUST_FILE" ]; then
    set -- "$@" --trust-file "$AVAYA_IPO_TRUST_FILE"
  fi
  if [ "$AVAYA_IPO_ALLOW_PARTIAL_CHAIN" = yes ]; then
    set -- "$@" --allow-partial-chain
  fi

  _info "Deploying certificate for $_avaya_ipo_domain to Avaya IP Office profile $AVAYA_IPO_PROFILE."
  sh "$@"
}
