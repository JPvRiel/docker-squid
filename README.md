# Overview

*NB!* Not intended for production use! Dev/testing only... ;-)

# Run

This assumes running docker safely in Linux environment with `sudo` (which protects against root privilege escalation through docker). Other platforms or running directly avoids needing `sudo`.

*TL;DR!?*

Best to make a directory on the host for the proxy cache
```
mkdir -p ~/.squid/cache
```

When in the office, with an upstream proxy that needs authentication, run:

```bash
sudo docker run -it -p 3128:3128 -v ~/.squid/cache:/var/spool/squid -e http_proxy='http://proxy.test:8080' -e no_proxy='localhost,127.0.0.1,.proxy.test' -e http_proxy_get_cred=0 -name squid jpvriel/squid
```

When at home, without an upstream proxy, run

```bash
sudo docker run -it -p 3128:3128 -v ~/.squid/cache:/var/spool/squid -name squid jpvriel/squid
```

TODO:
- show how to set client docker containers to use proxy
- improve to leverage transparent proxy option

## Simple

Without authentication and mapping a volume

```bash
$ sudo docker run --name squid jpvriel/squid
```

What is does (by default):

- runs squid
- creates a "data volume" so that the squid cache data can persist (only for the life-cycle of the container)
  - E.g. if the same container is started again later, the previous cache should still be effective
  - When running another container, that won't share the cache (unless you dug out and explicitly reused the volume mount point from a previous container run)

## Map the cache storage volume to a host directory

While more explicit, this will help the cache persist over time between multiple docker runs.

```bash
$ mkdir -p ~/.squid/cache
$ chmod -R 0750 ~/.squid/
$ sudo docker run -it -p 3128:3128 -v ~/.squid/cache:/var/spool/squid --name squid jpvriel/squid
```

What it does:
- `-p 172.17.0.1:3128:3128` Expose the proxy port on the docker host's bridged network IP (e.g. you wouldn't want 0.0.0.0 in case you get abused as an open proxy... )
- `-v ...` specify where to mount the data volume
- `-it` allows for seeing the container spit out the squid access log events on the console - handy to check if the cache is functioning and seeing what's being downloaded

Also:
- The containers `entrypoint.sh` will change ownership to proxy:proxy for the `cache` folder

*N.B!* It's better to explicitly map and mount docker volumes with `-v`, otherwise a large number of dangling automatically provisioned volumes can result, wasting space, and breaking caching between multiple docker container runs.

## Using an upstream proxy

### Proxy environment variable overview

First a quick detour about proxy environment variables (and the limits thereof!):
- Typically `http_proxy` is used, but other odd choices with different case, like `HTTP_PROXY`, and different protocols, like `https_proxy` and `ftp_proxy` exist.
  - Only `http_proxy` or `HTTP_PROXY` are parsed if given as environment variables to the docker container
  - In case more detail is wanted, `entrypoint.sh` in the docker container uses functions to parse `http_proxy` and `no_proxy` into squid config
  - The functions are smart enough to handle `http://user:pass@...` credentials inserted in the proxy URL (but this is generally bad form for security reasons)
    - password could be exposed in command history
    - password exposed in proxy logs
- Tools which read `no_proxy` are usually limited to globing FQDNS and often don't play nice with IP address exclusions.
  - `curl` is a very good example. `no_proxy='10.*' curl 10.0.0.1` will still try proxy your request.
  - nonetheless, try avoid polluting the cache with local/fast content by using `no_proxy` if possible
- As can be appreciated, this is nowhere near as flexible as the JavaScript function for a proxy `.pac` file

### Upstream proxy without authentication

Directly supply the proxy settings as environment variables in the docker command

```
$ sudo docker run -it -p 3128:3128 -v ~/.squid/cache:/var/spool/squid -e http_proxy='http://proxy.test:8080' -e no_proxy='localhost,127.0.0.1,.proxy.test' -name squid jpvriel/squid
```

Or export and inherit the proxy environment variables from the host's shell

```bash
$ export http_proxy='http://proxy.test:8080'
$ export no_proxy='localhost,127.0.0.1,.proxy.test'
$ sudo -E docker run -it -p 3128:3128 -v ~/.squid/cache:/var/spool/squid -e http_proxy -e no_proxy -name squid jpvriel/squid
```

Furthermore, note:

- `-E` for `sudo` is needed to tell sudo to copy the proxy env vars so the next docker command part has access to them
- `-e` for `docker` is needed to tell docker to copy the proxy env vars into the container

### Upstream proxy with authentication

#### Get prompted for the user and password

When the upstream proxy needs authentication, include an extra environment variable `http_proxy_get_cred=0` as a flag so that the entrypoint.sh script will prompt for the username and password. Assuming the usual proxy environment vars already exported by the host's shell, e.g.:

```bash
$ sudo -E docker run -it -p 3128:3128 -v ~/.squid/cache:/var/spool/squid -e http_proxy -e no_proxy -e http_proxy_get_cred=0 -name squid jpvriel/squid
```

Note:
- In the bash shell (and other's), `0` implies true (which unlike some other languages, i.e. C, where 0 is false and anything else is true)
- Ultimately, this ends up as `login=domain\user:pass` in squid config's `cache_peer` directive. Future work could try make this more secure
  - Patching squid to be more secure about handling these credentials
  - Or work around it using an insane change of local squid -> cntlm proxy -> upstream ntlm proxy, whereby cntlm is run as a command and prompts for the password
  - Leverage OSX / Gnome / etc keyrings,

#### user:password@... URL encoded proxy credentials

As an alternative, the user and password can be passed via the legacy HTTP basic authentication URL method with `@`:

```bash
$   export http_proxy='http://domain%5Cuser:pass@proxy.test:8080'
```

However, note:

- *N.B!* there is an intentional extra space (or multiple spaces) before setting the environment variable!
  - If bash's `HISTIGNORE` is set to `ignoreboth` (or `ignorespace`), then using at lease one space before the `export` command will avoid having your password recorded in your bash_history file.
  - However, the password is still quite exposed as plain-text to any process/person:
    - who can read your shell env vars,
    - can access container's bash process env or squid configuration file, and
    - ultimately `domain%5Cuser:pass` becomes `login=domain\user:pass` in squid config's `cache_peer` directive.
- Special characters must be URL escaped. E.g. In `domain\user`, the `\` becomes `%5C`
  - Obviously applicable to the password as well! E.g. `$` becomes `%24`
  - e.g. [A Complete Guide to URL Escape Characters](http://www.werockyourweb.com/url-escape-characters/) has a table with common escape characters

Running squid docker proxy with `http_proxy` including the `user:pass@...` credentials

```bash
$ sudo -E docker run -it -p 3128:3128 -v ~/.squid/cache:/var/spool/squid -e http_proxy -e no_proxy --name squid jpvriel/squid
```

## Advanced transparent proxy via docker host IP

TODO: INCOMPLETE - add/merge tricks from https://github.com/silarsis/docker-proxy

```
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to 3129 -w
```

TODO: INCOMPLETE - add/merge tricks from https://github.com/silarsis/docker-proxy

Other
```
docker run -d --restart=always \
  --publish 3128:3128 \
  --volume ~/.squid/cache:/var/spool/squid \
  --name squid jpvriel/squid
```

## Test proxy access

Assuming an appropriately configured client or networked container

```bash
$ curl -ILso /dev/null -w '%{response_code}\n' www.google.co.za
$ curl whatismyip.akamai.com; echo
196.8.123.36
```

Note
- `407` = proxy authentication required implies your user name or password is wrong (likely), or squid is unable to handle the authentication the upstream proxy needs
- Don't generate too many `407`s, it can cause account lockout

# Startup script

`docker_proxy.sh` provides a basic SysV-like startup script wrapper to run the container on a host as a convince (for lazy folk like me who don't like remembering all the docker command switches).

# Build

# TODO: git pull

Docker build command
```
$ sudo docker build --build-arg CACHE_DATE=$(date +%Y-%m-%dT%H:%M:%S) -t jpvriel/squid:0.1.0 -t jpvriel/squid:latest .
```

Note:
- `-t` tags are set appropriately to reflect the version
- `--build-arg CACHE_DATE=$(date +%Y-%m-%dT%H:%M:%S)`
  - Useful for breaking out of dockers caching when rebuilding the image and only changing the squid config files or entrypoint.sh script.
  - Leaves cache intact for steps above that take time (e.g. squid package and dependency downloads)

Docker build command through a proxy
```
sudo -E docker build --build-arg http_proxy --build-arg no_proxy --build-arg CACHE_DATE=$(date +%Y-%m-%dT%H:%M:%S) -t jpvriel/squid:0.1.0 -t jpvriel/squid:latest .
```

Note:
- Assumes something that provides a proxy without authentication, or a proxy you can provide authentication parameters to.
  - The cntlm proxy package can be useful to work around corporate proxies that require NTLM windows authentication.
- You need to have `http_proxy`, `no_proxy` (and if need be others) correctly setup for your environment.

# Debug

## Debug entrypoint.sh

If the containers entrypoint is failing to work, i.e. exiting, then rerun as another debugging container and override the entrypoint.

```
$ sudo docker run -it --entrypoint /bin/bash --name squid_debug squid
root@3dd6f36d9357:/# /usr/local/sbin/entrypoint.sh
/usr/local/sbin/entrypoint.sh: line 5: 1: unbound variable
```

The above shows a bug in the `/usr/local/sbin/entrypoint.sh` bash script.

It's also possible to connect to a running container
```
$ sudo docker exec -it squid /bin/bash
```

If using overlayfs or aufs, it may be possible to directly modify files for the container from the host

Check where the merged dir is located on the host
```
sudo docker inspect -f "{{ .GraphDriver.Data.MergedDir }}" squid_debug
/var/lib/docker/overlay2/98c91d50a3654727ec25c5bbbcf98ab2eef261953ac78f9bbc7d9db11969b38c/merged
```

Edit the content from the host
```
$ sudo -s
# cd /var/lib/docker/overlay2/98c91d50a3654727ec25c5bbbcf98ab2eef261953ac78f9bbc7d9db11969b38c/merged
# vim ./usr/local/sbin/entrypoint.sh
```

## Debug squid.conf

Likewise, one could inspect or edit the content of the squid config files from the host

```
sudo less ./etc/squid/squid.conf
```

And a way to debug squid config changes within the container

```
# squid -k parse /etc/squid/squid.conf
```

## Check cache volume

Check where squid's cache volume has been mounted
```
$ sudo docker inspect -f "{{ .Mounts }}" squid_debug[{83b29460e185176994bc957077f9d10d143558ef1844c83fff55b9815540b93f /var/lib/docker/volumes/83b29460e185176994bc957077f9d10d143558ef1844c83fff55b9815540b93f/_data /var/spool/squid local  true }]
```

## Check DNS resolution

on some operating systems, such as Ubuntu 16.04 LTS, the container can fail to get workable local DNS servers and defaults to 8.8.8.8, which won't work well in an internal DNS or firewalled off environment

The line below generates the --dns entries you need to give docker explicitly.

```
nm_dns=$(for d in $(nmcli device show | grep -E "^IP4.DNS" | grep -oP '(\d{1,3}\.){3}\d{1,3}'); do echo -n " --dns $d"; done)
```

# Cleanup

Remove the container and associated volume with `-v` if it wasn't explicitly mounted. An explicit volume mapping can omit `-v` given the intention to have future squid containers share the cache.

```
sudo docker rm -v squid
squid
```

*NB!* remove the volume before removing the container, otherwise it requires searching for dangling volumes.

# References

There are many other squid proxy containers to choose from. I made my own simply because I disliked some of the steps used to build them, e.g. decreasing security or pinning against older versions. My aim was to simply base of the latest Ubuntu LTS release and version of squid available in the Ubuntu repo.

Hereby, a list of other proxy containers that provided inspiration (or example code to work from)
- [Transparent Squid in a container](https://github.com/jpetazzo/squid-in-a-can)
  - Includes transparent idea
  - Has some odd and insecure things happening during build, e.g. `curl` with `--insecure`
- [docker-squid](https://github.com/sameersbn/docker-squid)
  - Seems most popular
  - Oddly uses alternate PPA to install squid and older custom 14.04 image of Ubuntu
  - So not built from a fully trustworthy source
- [docker-proxy](https://github.com/silarsis/docker-proxy)
  - Seems the most sophisticated, but builds from source packages... Why!? That probably adds container bloat.
