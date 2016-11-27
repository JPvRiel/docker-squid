#!/usr/bin/env bash

# need root access
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: docker requires root." >&2
  exit 1
fi

check_args() { 
  if [[ -n "$http_proxy" ]] && [[ -z "$no_proxy" ]]; then
    no_proxy='localhost,127.0.0.1,.test'
  fi
}

case "$1" in
  start)
    if docker ps -f status=running,name=squid | grep squid; then
      echo "ERROR: 'squid'' docker container already running?" >&2
      exit 1
    else
      check_args
      docker run --rm -it -p 172.17.0.1:3128:3128 -v ~/.squid/cache:/var/spool/squid -e http_proxy -e no_proxy --name squid jpvriel/squid
    fi
    ;;
  stop)
    if docker ps -f status=running,name=squid | grep squid; then
       docker stop squid
    else
      echo "ERROR: no running 'squid' docker container found. Nothing to stop." >&2
      exit 1
    fi
    ;;
  status)
    if docker ps -f status=running,name=squid | grep squid; then
      echo "INFO: a 'squid' docker container is running."
      docker top squid
    else
      echo "INFO: no 'squid' docker container found in the running state."
      if docker ps -a | grep squid; then
        echo "INFO: a non-running 'squid' container was found"
        docker ps -a | grep squid
      fi
    fi
    ;;
  *)
    echo "Usage: {start|stop|staus}"
    exit 1
    ;;
esac





