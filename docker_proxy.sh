#!/usr/bin/env bash

# need root access
if [ "$(id -u)" -ne 0 ]; then
  echo 'ERROR: docker requires root.' >&2
  exit 1
fi

check_env() {
  if [[ -n "$http_proxy" ]]; then
    if [[ "$http_proxy" == *'localhost'* ]] || [[ "$http_proxy" == *'127.0.0.1'* ]]; then
      echo "ERROR: 'http_proxy=$http_proxy' URL endpoint is a localhost location which the squid process in the conatiner cannot access." >&2
      return 1
    fi
    if [[ -z "$no_proxy" ]]; then
      no_proxy='localhost,127.0.0.1,.test'
    fi
  else
    echo 'NOTICE: '''http_proxy''' env var not set.'
  fi
  echo 'INFO: Proxy env vars checked.'
  return 0
}

case "$1" in
  start)
    echo 'INFO: Checking for squid_cache volume.'
    volumes=(squid_cache squid_log)
    for v in "${volumes[@]}"; do
      if ! docker volume inspect -f "{{ .Mountpoint }}" "$v"; then
        echo "INFO: Creating $v volume."
        docker volume create squid_cache
      fi
    done
    if docker ps -f status=running -f name=squid | grep squid; then
      echo 'ERROR: squid docker container already running?' >&2
      exit 1
    elif check_env; then
      if docker ps -f status=exited -f name=squid | grep squid; then
        echo 'INFO: starting previous squid docker container.'
	echo 'NOTICE: previous squid container will still have the same enviroment it was started with.'
	docker container start squid
      else
        echo 'INFO: Get virtual net devices to bind to.'
        interfaces=(docker0 virbr0)
        bind_ips=()
        for i in "${interfaces[@]}"; do
          if [ -e "/sys/class/net/$i" ]; then
            ip_addr=$(ip -4 addr show dev "$i" | grep -oP '(?<=inet )[^/]+(?=/)')
            bind_ips+=(" -p $ip_addr:3128:3128")
          fi
        done
        echo 'INFO: running new squid docker container.'
      	docker run -d -p 127.0.0.1:3128:3128 ${bind_ips[@]} -v squid_cache:/var/spool/squid -v squid_cache:/var/spool/squid -v squid_log:/var/log/squid -e http_proxy -e no_proxy --name squid jpvriel/squid:latest
      fi
    else
      exit 1
    fi
    ;;
  stop)
    if docker ps -f status=running -f name=squid | grep squid; then
      docker stop squid
    else
      echo "ERROR: no running 'squid' docker container found. Nothing to stop." >&2
      exit 1
    fi
    ;;
  status)
    if docker ps -f status=running -f name=squid | grep squid; then
      echo "INFO: a 'squid' docker container is running."
      docker top squid
    else
      echo "INFO: no 'squid' docker container found in the running state."
      if docker ps -a | grep squid; then
        echo "INFO: a non-running 'squid' container was found."
        docker ps -a | grep squid
      fi
    fi
    ;;
  *)
    echo "Usage: {start|stop|staus}"
    exit 1
    ;;
esac
