#!/usr/bin/env bash

# Update DNS records with public IP address
#
# Check current Public IP address from a Livebox (an ADSL/FTTH modem from
# "Orange France" Internet provider). If dynamic IP changed, update DNS records
# on OVH infrastructure.



# Set strict mode
set -Eeuo pipefail



### Global vars

DATE=$(date '+%Y%m%d_%H%M%S')
PROGNAME=$(basename "${0}")
PROGCONF=${PROGNAME%.*}.conf
DIRCONF=${DIRCONF:-/etc}
# Try to source config file from /etc or from current directory as failover path
if [ -f "${DIRCONF}/${PROGCONF}" ]; then
  . "${DIRCONF}/${PROGCONF}"
elif [[ -f "${PROGCONF}" ]]; then
  . "${PROGCONF}"
fi

# Livebox vars
LIVEBOX_USERNAME=${LIVEBOX_USERNAME:-"admin"}
LIVEBOX_PASSWORD=${LIVEBOX_PASSWORD:-"password"}
LIVEBOX_LAN_IP=${LIVEBOX_LAN_IP:-"192.168.1.1"}
LIVEBOX_ENDPOINT="http://${LIVEBOX_LAN_IP}/ws"
LIVEBOX_COOKIE=$(mktemp)  #Authentication cookie fullpath

# OVH vars
OVH_ENDPOINT=${OVH_ENDPOINT:-"https://eu.api.ovh.com/1.0"}
OVH_AK=${OVH_AK:-}  #Application Key
OVH_AS=${OVH_AS:-}  #Application Secret
OVH_CK=${OVH_CK:-}  #Consumer Key
# Set your domain name
OVH_ZONE_NAME=${OVH_ZONE_NAME:-"example.com"}
# File where we export the whole DNS zone
OVH_ZONE_BACKUP=${OVH_ZONE_BACKUP:-"/tmp/zone_backup-${DATE}.txt"}
# FQDN used to retrieve current IP address assigned in your OVH DNS zone
OVH_FQDN_CONTROL=${OVH_FQDN_CONTROL:-"subdomain.example.com"}



### functions

# Catch any unmanaged error, do some cleanup and print some revelant information
function trap_error () {
  local LINE CMD RC
  LINE=$1
  CMD=$2
  RC=$3
  cleanup
  echo "An unexpected error occurred." >&2
  echo "LINE=${LINE}, cmd=${CMD}, rc=${RC}" >&2
  exit 1
  }
trap 'trap_error "${LINENO}" "${BASH_COMMAND}" "${?}"' ERR

# Cleanup before EXIT
function cleanup () {
  # TODO: call a livebox logout function here
  #[ -f "${LIVEBOX_COOKIE}" ] && rm -rf "${LIVEBOX_COOKIE}"
  if [ -f "${LIVEBOX_COOKIE}" ]; then
    rm -rf "${LIVEBOX_COOKIE}"
  fi
}
trap 'cleanup' EXIT

# Send request to OVH API endpoint (path list: https://eu.api.ovh.com/console/)
function send_request () {
  local METHOD API_PATH BODY QUERY TSTAMP SIG_REQ RESPONSE
  METHOD="${1}"    #mandatory
  API_PATH="${2}"  #mandatory
  BODY=${3:-""}    #optionnal
  QUERY="${OVH_ENDPOINT}${API_PATH}"
  # Sign request as explained in the link below:
  # https://support.us.ovhcloud.com/hc/en-us/articles/360018130839-First-Steps-with-the-OVHcloud-API#api
  TSTAMP=$(curl --silent "${OVH_ENDPOINT}/auth/time")
  SIG_REQ="\$1\$$(echo -n ${OVH_AS}+${OVH_CK}+${METHOD}+${QUERY}+${BODY}+${TSTAMP} \
    | sha1sum \
    | awk '{print $1}')"
  # We use two tricks here:
  #   1. Alternative value substitution: '${BODY:+"--data"}' means that if body
  #      is set, '${BODY:+"--data"}' variable expand to '--data' value.
  #   2. Set true at the end of pipeline: because we use strict mode, we always
  #      need to handle return code not equal to 0 to avoid script stop.
  RESPONSE=$(curl "${QUERY}" \
    --silent \
    --header "Content-type: application/json; charset=utf-8" \
    --header "X-Ovh-Application: ${OVH_AK}" \
    --header "X-Ovh-Timestamp: ${TSTAMP}" \
    --header "X-Ovh-Signature: ${SIG_REQ}" \
    --header "X-Ovh-Consumer: ${OVH_CK}" \
    --request "${METHOD}" \
    ${BODY:+"--data"} "${BODY}" \
    || :)
  # Return response outside the function
  echo "${RESPONSE}"
}

# Check if IP passed in first parameter is valid
function is_ip_valid () {
  local IP="${1}"
  local IS_VALID="true"
  if [[ ${IP} =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    for i in $(echo "${IP}" | tr . ' '); do
      if [ "$i" -gt "255" ]; then
        IS_VALID="false"
        break
      fi
    done
  else
    IS_VALID="false"
  fi
  if [ ${IS_VALID} == false ]; then
    echo "Invalid IP address." >&2
    exit 1
  fi
}



### Main script

# Authentication process on Livebox 4
AUTH_RESPONSE=$(curl "${LIVEBOX_ENDPOINT}" \
  --silent \
  --cookie-jar "${LIVEBOX_COOKIE}" \
  --request POST \
  --header "Content-Type: application/x-sah-ws-4-call+json" \
  --header "Authorization: X-Sah-Login" \
  --write-out "%{http_code}" \
  --data @- <<-EOF
	{
	  "service": "sah.Device.Information",
	  "method": "createContext",
	  "parameters": {
	    "applicationName": "webui",
	    "username": "${LIVEBOX_USERNAME}",
	    "password": "${LIVEBOX_PASSWORD}"
	  }
	}
	EOF
)
# Check HTTP status code
if [[ "${AUTH_RESPONSE}" != *200 ]]; then
  echo "ERROR: Authentication failed" >&2
  exit 1
fi
# Get contextID with lookbehind regex
CONTEXT_ID=$(echo "${AUTH_RESPONSE}" | grep -Po '(?<=contextID":").+(?=","username)')

# Get current public IP address
DATA_RESPONSE=$(curl "${LIVEBOX_ENDPOINT}" \
  --silent \
  --cookie "${LIVEBOX_COOKIE}" \
  --request POST \
  --header "Content-Type: application/x-sah-ws-4-call+json" \
  --header "X-Context: ${CONTEXT_ID}" \
  --write-out "%{http_code}" \
  --data @- <<-EOF
	{
	  "service": "NMC",
	  "method": "getWANStatus",
	  "parameters": {}
	}
	EOF
)
# Check HTTP status code
if [[ "${DATA_RESPONSE}" != *200 ]]; then
  echo "ERROR: request failed" >&2
  exit 1
fi
LIVEBOX_WAN_IP=$(echo "${DATA_RESPONSE}" | grep -Po '(?<=IPAddress":").+(?=","RemoteGateway)')
is_ip_valid "${LIVEBOX_WAN_IP}"

# Check if your OVH record use the same IP address than your Livebox public IP
OVH_IP=$(nslookup "${OVH_FQDN_CONTROL}" | awk -F': ' 'NR==6 { print $2 }')
is_ip_valid "${OVH_IP}"
if [ "${LIVEBOX_WAN_IP}" == "${OVH_IP}" ]; then
  echo "No action required."
  exit 0
fi

# Backup whole OVH DNS zone for safety reasons
ZONE_EXPORT=$(send_request "GET" "/domain/zone/${OVH_ZONE_NAME}/export")
# Cleanup raw zone export result:
#   - remove first and last double quotes
#   - change '\n' by newline, '\t' by tab and '\"' by double quote
echo "${ZONE_EXPORT:1:-1}" \
  | sed 's/\\n/\n/g' \
  | sed 's/\\t/\t/g' \
  | sed 's/\\"/"/g' \
  > "${OVH_ZONE_BACKUP}"

# Get all records ID for your domain
RECORD_ALL=$(send_request "GET" "/domain/zone/${OVH_ZONE_NAME}/record")
RECORD_ALL=$(echo "${RECORD_ALL:1:-1}" | sed 's/,/\n/g')

# Update IP address for each DNS record
for R in ${RECORD_ALL}; do
  # Get all record's properties
  R_PROPERTIES=$(send_request "GET" "/domain/zone/${OVH_ZONE_NAME}/record/${R}")
  # Alter object's target property containing IP address that need to be changed
  R_PROPERTIES_TARGET=$(echo "${R_PROPERTIES:1:-1}" \
    | grep "${OVH_IP}" \
    | sed 's/,/\n/g' \
    | grep "target" \
    | sed "s/${OVH_IP}/${LIVEBOX_WAN_IP}/" \
    || :)
  if [ -n "${R_PROPERTIES_TARGET}" ]; then
    send_request "PUT" "/domain/zone/${OVH_ZONE_NAME}/record/${R}" "{${R_PROPERTIES_TARGET}}"
  fi
done

# Apply zone modification on DNS servers
send_request "POST" "/domain/zone/${OVH_ZONE_NAME}/refresh" > /dev/null
