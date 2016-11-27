#!/usr/bin/env bash
# a bit of a unit test for the sourced function file

source ../proxy_env_to_squid_func.sh

test_proxy_cred() {
  if [[ -n "$http_proxy" ]] || [[ -n "$HTTP_PROXY" ]]; then
    if [[ -n "$http_proxy" ]]; then
      echo "Upstream parent proxy (peer) found. Using http_proxy"
    elif [[ -n "$HTTP_PROXY" ]]; then
      echo "Upstream parent proxy (peer) found. Using HTTP_PROXY"
      http_proxy="$HTTP_PROXY"
    fi
    squid_peer_proxy=$(parse_http_proxy "$http_proxy")
    # check and caution if user:pass@ legacy basic auth was embeded in HTTP URL
    user_pass_re='^http(s)?://[^:]{1,128}:[^@]{1,256}@[^/]+/?'
    if [[ "$http_proxy" =~ $user_pass_re ]]; then
      echo 'WARN: "user:pass@..." method of including proxy credentials is risky.'
    elif [[ -n "$http_proxy_get_cred" ]]; then
      echo -n 'proxy username: '
      IFS='' read -r user
      valid_user_re='^[0-9A-Za-z_.@$/\\][-0-9A-Za-z_.@$/\\]*$'
      if ! [[ "$user" =~ $valid_user_re ]]; then
        echo "ERROR: Invalid characters in username. Aborting." >&2
      fi
      echo -n 'proxy password: '
      IFS='' read -r -s pass
      squid_peer_proxy="$squid_peer_proxy login=$(escape_login "${user}" "${pass}")"
    fi
    if [[ -n "$squid_peer_proxy" ]]; then
      echo "${squid_peer_proxy}"
    else
      echo 'ERROR: Proxy env settings found, but unable to parse them. Aborting.' >&2
    fi
  else
    echo 'No upstream parent proxy (peer) found. Will connect to sites directly.'
  fi
}

# clear in case env has something exported...
reset() {
  unset http_proxy
  unset HTTP_PROXY
  unset http_proxy_get_cred
}

reset

echo '## posative test cases'

echo '# lowecase http_proxy'
http_proxy='http://proxy.test:8080'
test_proxy_cred
reset

echo '# uppercase HTTP_PROXY'
HTTP_PROXY='http://proxy.test:8080'
test_proxy_cred
reset

echo '# with user:pass@ and a slash for domain qualificaiton'
http_proxy='http://domain%5Cuser:pass@proxy.test:8080'
test_proxy_cred
reset

echo '# with special characters and space as url escaped password'
# ' `~!@#$%^&*()-_+=[{]};:'"|\,<.>/?'
http_proxy='http://domain%5Cuser:%20%60~!%40%23%24%25%5E%26*()-_%2B%3D%5B%7B%5D%7D%3B%3A'\''%22%7C%5C%2C%3C.%3E%2F%3F@proxy.test:8080'
test_proxy_cred
reset

echo '# testing http_proxy_get_cred env option with special characters'
http_proxy='http://proxy.test:8080'
http_proxy_get_cred=0
echo -e "domain\\user\n"' `~!@#$%^&*()-_+=[{]};:\'\''"|\\,<.>/?' | test_proxy_cred
reset

echo
echo '## negative test cases'

echo '# invalid http_proxy values, e.g. no http://, etc'
http_proxy='proxy.test:8080'
test_proxy_cred
reset
http_proxy='https://proxy.test/extra_crud'
test_proxy_cred
reset

echo '# invalid user, e.g. with colon'
http_proxy='http://proxy.test:8080'
http_proxy_get_cred=0
echo -e "domain:user!\n"'pass' | test_proxy_cred
reset
