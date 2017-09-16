#!/usr/bin/env bash
set -e
[ "$DEBUG" == 'true' ] && set -x

# Term colour escape codes
T_DEFAULT='\e[0m'
T_RED_BOLD='\e[1;31m'
T_YELLOW_BOLD='\e[1;33m'
T_BLUE='\e[0;34m'

# funcitons

function report_info() {
  echo -e "${T_BLUE}INFO:${T_DEFAULT} $*"
}

function report_warning() {
  echo -e "${T_YELLOW_BOLD}WARN:${T_DEFAULT} $*" >&2
}

function report_error(){
  echo -e "${T_RED_BOLD}ERROR:${T_DEFAULT} $*" >&2
}

function sigterm_handler() {
  report_info 'Terminating child processes'
  [[ -z "$(jobs -p)" ]] || kill $(jobs -p)
  wait
  report_info 'Exited gracefully'
}
# Note, we don't wrap SIGHUP given squid should not be reloaded, but rather the container re-run.

test_http_head(){
  failed=0
  for u in "${@}"; do
    http_response_code="$(curl -ILso /dev/null -m "$HTTP_TIMEOUT" -w '%{response_code}\n' "$u")"
    if (( $? != 0 )) || (( http_response_code < 200 )) || (( http_response_code >= 500 )); then
      let $((failed++))
      report_error "${u} is not reachable."
    fi
    report_info "${u} = ${http_response_code}"
  done
  return $failed
}

url_decode() {
  local url_encoded="${1//+/ }"
  printf '%b' "${url_encoded//%/\\x}"
}

escape_login() {
# login=user:password in the squid cache_peer directive
# - Docs suggest other %hex parts are decoded,
# - %20 for spaces
# - %% for %
# - But when special characters were tested, i.e. not spaces, this broke upstream authentication with a proxy requiring NTLM :-/
# - Hopefully falling back to single quoted value for login values will help limit the number of escape sequnces
  local u=${1}
  local p=${2}
  # also, take care to double escape, given bash treats / as an escape
  # escape \
  u=${u//\\/\\\\}
  p=${p//\\/\\\\}
  # escape '
  u=${u//\'/\\\'}
  p=${p//\'/\\\'}
  echo "'${u}:${p}'"
}

# provide peer proxy squid config
parse_http_proxy() {
  http_proxy_re='^http(s)?://(([^:]{1,128}):([^@]{1,256})@)?([^:/]{1,255})(:([0-9]{1,5}))?/?$'
  if [[ "$1" =~ $http_proxy_re ]]; then
    # care taken to skip parent nesting groups 2 and 6
    tls=${BASH_REMATCH[1]}
    if [[ -n ${BASH_REMATCH[3]} ]] && [[ -n ${BASH_REMATCH[4]} ]]; then
      # url decode username and password in case of url echnoded special characters
      user=$(url_decode "${BASH_REMATCH[3]}")
      pass=$(url_decode "${BASH_REMATCH[4]}")
    fi
    host=${BASH_REMATCH[5]}
    port=${BASH_REMATCH[7]}
    if [ -z "$port" ]; then
      port=80
    fi
    # set proxy host and port
    if [[ -n "$host" ]] && [[ -n "$port" ]]; then
      squid_peer_directive="cache_peer $host parent $port 0 no-query no-digest"
    else
      report_warning 'Unable to find at least a host in the proxy env var. Ignoring.'
      return
    fi
    # handle authentication and deal with special quoting and escaping required for squid config
    if [[ -n "$user" ]] && [[ -n "$pass" ]]; then
      if [[ "$http_proxy_auth_type" == 'NONE' ]] || [[ "$http_proxy_auth_type" == 'BASIC' ]]; then
        if [[ -z "$tls" ]]; then
          report_warning 'Using BASIC authentication for parent proxy without TLS is insecure!'
        fi
        login=$(escape_login "${user}" "${pass}")
        squid_peer_directive="$squid_peer_directive login=$login"
      elif [[ "$http_proxy_auth_type" == 'NEGOTIATE' ]]; then
        #TODO
        report_warning 'NEGOTIATE not implimented for parent proxy.'
      fi
    else
      squid_peer_directive="$squid_peer_directive login=PASSTHRU"
    fi
    # check for TLS/SSL
    if [[ -n "$tls" ]]; then
      squid_peer_directive="$squid_peer_directive tls"
    fi
    echo "$squid_peer_directive"
  else
    # return nothing as an indicator of failure
    return
  fi
}

# create a no proxy list for squid config
no_proxy_to_regex_list() {
  # replace . with re literal \. for dot
  list="$1"
  list="${list//./\\.}"
  # replace * glob with re .*? for lazy match
  list="${list//\*/.\*}"
  # replace commas with newline
  list="$(echo "$list" | tr ',' '\n')"
  echo "$list"
}

create_log_dir() {
  mkdir -p "$SQUID_LOG_DIR"
  chown -R "$SQUID_USER:$SQUID_USER" "$SQUID_LOG_DIR"
  chmod -R 755 "$SQUID_LOG_DIR"
}

create_cache_dir() {
  mkdir -p "$SQUID_CACHE_DIR"
  chown -R "$SQUID_USER:$SQUID_USER" "$SQUID_CACHE_DIR"
  chmod -R 750 "$SQUID_CACHE_DIR"
}

# set squid directories and permissions
create_log_dir
create_cache_dir

# Check if proxy enviroment variables have been set and enable using an upstream
# proxy
if [[ -z "$http_proxy_auth_type" ]]; then
  # set default
  http_proxy_auth_type="$HTTP_PROXY_AUTH_TYPE"
fi
if [[ -n "$http_proxy" ]] || [[ -n "$HTTP_PROXY" ]]; then
  if [[ -n "$http_proxy" ]]; then
    report_info 'Upstream parent proxy (peer) found. Using http_proxy'
  elif [[ -n "$HTTP_PROXY" ]]; then
    report_info 'Upstream parent proxy (peer) found. Using HTTP_PROXY'
    http_proxy="$HTTP_PROXY"
  fi
  squid_peer_proxy=$(parse_http_proxy "$http_proxy")
  # check and caution if user:pass@ legacy basic auth was embeded in HTTP URL
  user_pass_re='^http(s)?://[^:]{1,128}:[^@]{1,256}@[^/]+/?'
  if [[ "$http_proxy" =~ $user_pass_re ]]; then
    report_warning '"user:pass@..." method of including proxy credentials is risky!'
  elif [[ -n "$http_proxy_get_cred" ]] && [[ "$http_proxy_get_cred" == 'true' ]] ; then
    echo -n 'proxy username: '
    read -r user
    valid_user_re='^[0-9A-Za-z_.@$/\\][-0-9A-Za-z_.@$/\\]*$'
    if ! [[ "$user" =~ $valid_user_re ]]; then
      report_error 'Invalid characters in username. Aborting.'
      exit 1
    fi
    echo -n 'proxy password: '
    IFS='' read -r -s pass
    squid_peer_proxy="$squid_peer_proxy login=$(escape_login "${user}" "${pass}")"
    #TODO FIX to support more than just basic
  else
    report_info 'No proxy authN specified. Will test contacting site(s) without proxy authentication'
  fi
  if [[ -n "$squid_peer_proxy" ]]; then
    # Replace proxy seetings in peers.conf
    sed -i -e "s/^cache_peer.\+/${squid_peer_proxy}/" /etc/squid/peers.conf
    # Uncomment include
    sed -i -e 's/#include \/etc\/squid\/peers.conf/include \/etc\/squid\/peers.conf/' /etc/squid/squid.conf
  else
    report_error 'Proxy env settings found, but unable to parse them. Aborting.'
    exit 1
  fi
else
  report_info 'No upstream parent proxy (peer) found. Will test contacting site(s) directly.'
  # ensure peers.conf is not included
  if grep -q -E '^include /etc/squid/peers\.conf' /etc/squid/squid.conf; then
    sed -i -e 's/^include \/etc\/squid\/peers.conf/#include \/etc\/squid\/peers.conf/' /etc/squid/squid.conf
  fi
fi

# Test
if ! test_http_head "$VALIDATE_URLS"; then
  report_error 'No response from test site(s)'
  exit 1
fi

# Check for exclusions / direct and modify config
if [[ -n "$no_proxy" ]] || [[ -n "$NO_PROXY" ]]; then
  if [[ -n "$no_proxy" ]]; then
    report_info 'Proxy exclusions (direct) found. Using no_proxy'
  elif [[ -n "$NO_PROXY" ]]; then
    report_info 'Proxy exclusions (direct) found. Using NO_PROXY'
    no_proxy="$NO_PROXY"
  fi
  no_proxy_to_regex_list "$no_proxy" > /etc/squid/direct_regex.txt
  if grep -q -E '^#acl local_domain_dst dstdom_regex "/etc/squid/direct_regex\.txt"' /etc/squid/squid.conf; then
    sed -i -e 's/^#acl local_domain_dst dstdom_regex "\/etc\/squid\/direct_regex\.txt"/acl local_domain_dst dstdom_regex "\/etc\/squid\/direct_regex\.txt"/' /etc/squid/squid.conf
  fi
  if grep -q -E '^#cache deny local_domain_dst' /etc/squid/squid.conf; then
    sed -i -e 's/^#cache deny local_domain_dst/cache deny local_domain_dst/' /etc/squid/squid.conf
  fi
else
  if grep -q -E '^#acl local_domain_dst dstdom_regex "/etc/squid/direct_regex\.txt"' /etc/squid/squid.conf; then
    sed -i -e 's/^acl local_domain_dst dstdom_regex "\/etc\/squid\/direct_regex\.txt"/#acl local_domain_dst dstdom_regex "\/etc\/squid\/direct_regex\.txt"/' /etc/squid/squid.conf
  fi
  if grep -q -E '^cache deny local_domain_dst' /etc/squid/squid.conf; then
    sed -i -e 's/^cache deny local_domain_dst/#cache deny local_domain_dst/' /etc/squid/squid.conf
  fi
fi

# TODO: Logic to handle proxy PAC files for upstream proxy (epic task!)
# Two options:
# - parsing javascript pac funciton and creating squid rules
#   - hairy / yak shaving
#   - maybe https://pypi.python.org/pypi/pypac could help
#   - also https://github.com/rbcarson/pypac
# - patching squid with something like pacparser

# do a config sanity check
if ! $(which squid) -k parse -f /etc/squid/squid.conf &> /dev/null; then
  report_error 'Squid configuration corrupt. Aborting.'
  exit 1
fi


# output logs to stdout if enabled
if [[ ${SQUID_LOG_TAIL} -eq 0 ]]; then
  ( umask 0 && truncate -s0 "$SQUID_LOG_DIR"/{access,cache}.log )
  su - "$SQUID_USER" -s /bin/sh -c "tail --pid $$ -n 0 -F \"$SQUID_LOG_DIR/access.log\" &"
  log_tail_pid=$!
fi

# allow arguments to be passed to squid
if [[ -n ${1} ]]; then
  if [[ ${1:0:1} == '-' ]]; then
    EXTRA_ARGS=( "$@" )
    set --
  elif [[ ${1} == squid || ${1} == $(which squid) ]]; then
    EXTRA_ARGS=( "${@:2}" )
    set --
  fi
fi

# default behaviour is to launch squid
if [[ -z ${1} ]]; then
  if [[ ! -d ${SQUID_CACHE_DIR}/00 ]]; then
    report_info 'Initializing squid cache...'
    $(which squid) -N -f /etc/squid/squid.conf -z
  fi
  report_info 'Starting squid...'
  if [ "$DEBUG" == 'true' ]; then
    "$(which squid)" -X -f /etc/squid/squid.conf -NYC "${EXTRA_ARGS[@]}" &
  else
    "$(which squid)" -f /etc/squid/squid.conf -NYC "${EXTRA_ARGS[@]}" &
  fi
else
  "$@"
  exit $!
fi

trap 'sigterm_handler' SIGINT SIGQUIT SIGTERM
wait
