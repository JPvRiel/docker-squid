FROM ubuntu:xenial
MAINTAINER jp.vanriel@gmail.com

ENV SQUID_CACHE_DIR=/var/spool/squid \
    SQUID_LOG_DIR=/var/log/squid \
    SQUID_LOG_TAIL=0 \
    SQUID_USER=proxy \
    VALIDATE_URLS='http://www.google.com http://whatismyip.akamai.com' \
    HTTP_TIMEOUT=15
ENV HTTP_PROXY_AUTH_TYPE='NONE'
  # if a username is provided, and the default of 'NONE' is left as is, 'BASIC' proxy authentication will be assumed

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y squid curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# use `docker build --build-arg CACHE_DATE=$(date +%Y-%m-%dT%H:%M:%S) .` to
# force the cache to break for config changes below.
ARG CACHE_DATE=2016-10-09

RUN mv /etc/squid/squid.conf /etc/squid/squid.conf.dist
RUN touch /etc/squid/direct_regex.txt
COPY peers.conf /etc/squid/peers.conf
COPY squid.conf /etc/squid/squid.conf
COPY entrypoint.sh /usr/local/sbin/entrypoint.sh
RUN chmod 755 /usr/local/sbin/entrypoint.sh

EXPOSE 3128/tcp
VOLUME ["${SQUID_CACHE_DIR}"]
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]