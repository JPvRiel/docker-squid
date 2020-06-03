# Docker-Squid

## Overview

_NB!_ Not intended for production use! Dev/testing only... ;-)

Provides a squid caching proxy that can be chained to an upstream proxy.

Version numbers will be `<upstream squid version>-<release build number>`. E.g. with Ubuntu 20.04 LTS as a squid package: `4.10-1`.

The preconfigured cache size is 8GB. Modify the configuration file and rebuild if you wish to change it. It's not very large since it's intended to help speed up rebuilding docker images that rely on apt or yum to download packages over HTTP.

As a notable limitation, a transparent or HTTPS intercepting and caching configuration is not provided (future work).

## Run

_TL;DR!?_

A pre-created named volume is recommend,

```bash
sudo docker volume create squid_cache
```

Then run passing along your current proxy env vars e.g.:

```bash
sudo docker run -it --rm \
-p 127.0.0.1:3128:3128 -p 172.17.0.1:3128:3128 \
-v squid_cache:/var/spool/squid \
-e http_proxy="$http_proxy" -e no_proxy="$no_proxy" \
--name squid jpvriel/squid
```

Note, when running docker commands via sudo, either `sudo -E` is needed to share env vars, or explicitly pass along and copy the env vars needed as per the above example (I don't give my user ID dockerd socket access due to privilege escalation risks, and I rather set `alias docker='sudo docker'`).

When in the office, with an upstream proxy that needs authentication, run with the `http_proxy_get_cred=true` flag set:

```bash
sudo docker run -it --rm -p 127.0.0.1:3128:3128 -p 172.17.0.1:3128:3128 -v squid_cache:/var/spool/squid -e http_proxy='http://proxy.test:8080' -e no_proxy='localhost,127.0.0.1,.proxy.test' -e http_proxy_get_cred=true --name squid jpvriel/squid
```

Obviously replace 'proxy.test' with your actual proxy...

When at home, without an upstream proxy, run

```bash
docker run -it --rm -p 127.0.0.1:3128:3128 -p 172.17.0.1:3128:3128 -v squid_cache:/var/spool/squid --name squid jpvriel/squid
```

What it does:

- `-p 127.0.0.1:3128:3128 -p 172.17.0.1:3128:3128` Expose the proxy port on localhost and the docker host's bridged network IP (e.g. you wouldn't want 0.0.0.0 in case you get abused as an open proxy... )
- `-v ...` specify where to mount the data volume
- `-it` allows for seeing the container spit out the squid access log events on the console - handy to check if the cache is functioning and seeing what's being downloaded
- The containers `entrypoint.sh` will change ownership to proxy:proxy for the `cache` folder

TODO (implied limitations):

- Show how to set other docker containers to use proxy (and support wider docker networking/compose options)
- Improve to leverage transparent proxy option (related to the above)?
- Detect parent/peer proxy authentication requirements and use Kerberos/NEGOTIATE authentication when required
- Test disabling cache_mem options with squid to make container more lightweight and rely on OS I/O cache instead
- Test suite to check various options and config choices behave
- Consider parsing and handling a proxy PAC file (it's javascript and can get complex...)

### Simple (and risky)

Without authentication and mapping a volume

```bash
docker run --name squid jpvriel/squid
```

What is does (by default):

- runs squid
- uses a volume so that the squid cache data can persist (only for the life-cycle of the specific container)
  - E.g. if the same container is started again later, the previous cache should still be effective via the volume
  - When running another container, that won't share the cache (unless you dug out and explicitly reused the volume mount point from a previous container run)

### Using an upstream proxy

#### Proxy environment variable overview

First a quick detour about proxy environment variables (and the limits thereof!):

- Typically `http_proxy` is used, but other odd choices with different case, like `HTTP_PROXY`, and different protocols, like `https_proxy` and `ftp_proxy` exist.
  - Only `http_proxy` or `HTTP_PROXY` are parsed if given as environment variables to the docker container
  - In case more detail is wanted, `entrypoint.sh` in the docker container uses functions to parse `http_proxy` and `no_proxy` into squid config
  - The functions are smart enough to handle `http://user:pass@...` credentials inserted in the proxy URL (but this is generally bad form for security reasons)
  - password could be exposed in command history
  - password exposed in proxy logs
- Tools which read `no_proxy` are usually limited to globing FQDNs and often don't play nice with IP address exclusions.
  - `curl` is a very good example. `no_proxy='10.*' curl 10.0.0.1` will still try proxy your request.
  - nonetheless, try avoid polluting the cache with local/fast content by using `no_proxy` if possible.

As can be appreciated, the above is nowhere near as flexible as the JavaScript function for a proxy `.pac` file.

#### Upstream proxy without authentication

This assumes the docker network running the container can access the proxy set by env vars (e.g. the default docker network can NAT out).

Directly supply the proxy settings as environment variables in the docker command

```bash
sudo docker run -it -p 3128:3128 -v squid_cache:/var/spool/squid -e http_proxy='http://proxy.test:8080' -e no_proxy='localhost,127.0.0.1,.proxy.test' -name squid jpvriel/squid
```

Or export and inherit the proxy environment variables from the host's shell

```bash
export http_proxy='http://proxy.test:8080'
export no_proxy='localhost,127.0.0.1,.proxy.test'
sudo -E docker run -it -p 3128:3128 -v squid_cache:/var/spool/squid -e http_proxy -e no_proxy -name squid jpvriel/squid
```

Furthermore, note:

- `-E` for `sudo` is needed to tell sudo to copy the proxy env vars so the next docker command part has access to them.
- `-e` for `docker` is needed to tell docker to copy the proxy env vars into the container.

#### Upstream proxy with authentication

##### Get prompted for the user and password

When the upstream proxy needs authentication, include an extra environment variable `http_proxy_get_cred=true` as a flag so that the entrypoint.sh script will prompt for the username and password. Assuming the usual proxy environment vars already exported by the host's shell, e.g.:

```bash
sudo -E docker run -it -p 3128:3128 -v squid_cache:/var/spool/squid -e http_proxy -e no_proxy -e http_proxy_get_cred=true -name squid jpvriel/squid
```

Notes, including security considerations:

- HTTP basic auth is not a secure choice, especially if the `cache_peer` proxy is not accessed over TLS.
- For basic HTTP proxy auth, ultimately, this ends up as `login=domain\user:pass` in squid config's `cache_peer` directive.

Future work could try make things more secure:

- Patching squid to be more secure about handling these credentials.
- Configuring the container to use RAM to back the `/etc/squid` directory instead of letting that end up somewhere in docker's storage system where it might persist.
- Configuring the container to mount `/etc/squid` directory as an encrypted volume with a once off (per docker run) random key.

From a threat model perspective, given the intended use as a local proxy for a developer, the above mitigations are not very effective anyhow:

- They are probably moot if the developer's laptop (docker engine host) is sufficiently compromised anyhow. It's likely if a developer's OS account is compromised, a common target would be a web browser or alternate piece of software is caching the credentials anyhow.
- They could help mitigate the case where, due to a lack of appropriate file-system permissions, storage encryption or storage block re-allocation and re-use (without secure erase) between containers, etc, the docker storage was made accessible to another unprivileged process or user account.

Currently, NTLM and Kerberos/Negotiate authentication are not supported yet.

- Squid upstream developers don't seem intent on supporting NTLM (given it's deprecated)
- Kerberos/Negotiate is possible, but requires the container sets up a keytab file to support the `login=NEGOTIATE` option which. The squid [cache_peer docs](http://www.squid-cache.org/Doc/config/cache_peer/) warn: "The connection may transmit requests from multiple clients. Negotiate often assumes end-to-end authentication and a single-client. Which is not strictly true here."
  - Just as above, if the content of the keytab file is exposed, the key can be stolen and used to access services as the user.
  - A work around for NTLM could be a semi-insane chain of `local squid -> cntlm proxy -> upstream ntlm proxy`, whereby CNTLM is run as a command in the container and prompts for the password. However, CNTLM looks like it's not actively maintained.

##### user:password@... URL encoded proxy credentials

As an alternative, the user and password can be passed via the legacy HTTP basic authentication URL method with `@`:

```bash
  export http_proxy='http://domain%5Cuser:pass@proxy.test:8080'
```

_N.B!_: there is an intentional extra space (or multiple spaces) before setting the environment variable!

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
sudo -E docker run -it -p 3128:3128 -v squid_cache:/var/spool/squid -e http_proxy -e no_proxy --name squid jpvriel/squid
```

### Advanced transparent proxy via docker host IP

TODO: INCOMPLETE - add/merge tricks from <https://github.com/silarsis/docker-proxy>

```bash
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to 3129 -w
```

TODO: INCOMPLETE - add/merge tricks from <https://github.com/silarsis/docker-proxy>

Other

```bash
docker run -d --restart=always \
  --publish 3128:3128 \
  --volume squid_cache:/var/spool/squid \
  --name squid jpvriel/squid
```

### Test proxy access

Assuming an appropriately configured client or networked container

```bash
$ curl -ILso /dev/null -w '%{response_code}\n' www.google.co.za
$ curl whatismyip.akamai.com; echo
196.8.123.36
```

Note:

- `407` = proxy authentication required implies your user name or password is wrong (likely), or squid is unable to handle the authentication the upstream proxy needs.

## Startup script

`docker_proxy.sh` provides a basic SysV-like startup script wrapper to run the container on a host as a convince (for lazy folk like me who don't like remembering all the docker command switches).

## Build

Docker build command

```bash
sudo docker build --build-arg CACHE_DATE=$(date +%Y-%m-%dT%H:%M:%S) -t jpvriel/squid:4.10-1 -t jpvriel/squid:latest .
```

Note:

- `-t` tags are set appropriately to reflect the version of squid (which depends on the package in the repo)
- `--build-arg CACHE_DATE=$(date +%Y-%m-%dT%H:%M:%S)`
  - Useful for breaking out of dockers caching when rebuilding the image and only changing the squid config files or entrypoint.sh script.
  - Leaves cache intact for steps above that take time (e.g. squid package and dependency downloads)

Docker build command through a proxy

```bash
sudo -E docker build --build-arg http_proxy --build-arg no_proxy --build-arg CACHE_DATE=$(date +%Y-%m-%dT%H:%M:%S) -t jpvriel/squid:4.10-1 -t jpvriel/squid:latest .
```

Note:

- Assumes something that provides a proxy without authentication, or a proxy you can provide authentication parameters to.
  - The cntlm proxy package can be useful to work around corporate proxies that require NTLM windows authentication.
- You need to have `http_proxy`, `no_proxy` (and if need be others) correctly setup for your environment.

## Debug

You can use `-e DEBUG=true` to get extra verbose output from both the entrypoint script and squid.

### Debug entrypoint.sh

If the containers entrypoint is failing to work, i.e. exiting, then rerun as another debugging container and override the entrypoint.

```bash
sudo docker run -it --entrypoint /bin/bash --name squid_debug squid
```

It's also possible to connect to a running container

```bash
sudo docker exec -it squid /bin/bash
```

If using overlayfs or aufs, it may be possible to directly modify files for the container from the host

Check where the merged dir is located on the host

```bash
sudo docker inspect -f "{{ .GraphDriver.Data.MergedDir }}" squid_debug
```

Edit the content from the host:

```bash
sudo -s
cd /var/lib/docker/overlay2/98c91d50a3654727ec25c5bbbcf98ab2eef261953ac78f9bbc7d9db11969b38c/merged
vim ./usr/local/sbin/entrypoint.sh
```

### Debug squid.conf

Likewise, one could inspect or edit the content of the squid config files from the host

```bash
sudo less ./etc/squid/squid.conf
```

And a way to debug squid config changes within the container

```bash
squid -k parse /etc/squid/squid.conf
```

### Check cache volume

Check where squid's cache volume has been mounted

```bash
sudo docker inspect -f "{{ .Mounts }}" squid_debug[{83b29460e185176994bc957077f9d10d143558ef1844c83fff55b9815540b93f /var/lib/docker/volumes/83b29460e185176994bc957077f9d10d143558ef1844c83fff55b9815540b93f/_data /var/spool/squid local  true }]
```

### Check DNS resolution

On some operating systems, such as Ubuntu 16.04 LTS, the container can fail to get workable local DNS servers and defaults to 8.8.8.8, which won't work well in an internal DNS or firewalled off environment.

If you're running Linux with Network Manager, the line below generates the --dns entries you need to give docker explicitly.

```bash
nm_dns=$(for d in $(nmcli device show | grep -E "^IP4.DNS" | grep -oP '(\d{1,3}\.){3}\d{1,3}'); do echo -n " --dns $d"; done)
```

## Cleanup

Remove the container and associated volume with `-v` if it wasn't explicitly mounted. An explicit volume mapping can omit `-v` given the intention to have future squid containers share the cache.

```bash
sudo docker rm -v squid
squid
```

_NB!_ remove the volume before removing the container, otherwise it requires searching for dangling volumes.

## References

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
