# proxy.sh

One-click installer for **HTTP / HTTPS / SOCKS5 / SSH** proxies on a fresh Linux server.
It generates random credentials and random ports, configures the services, opens the
firewall, and writes all connection details to `/root/proxy.json`.

No interaction required. Run it once and you are done.

## Quick start

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh)
```

## What it installs

| Protocol | Implementation | Notes |
|----------|----------------|-------|
| HTTP     | sing-box `http` inbound        | Handles plain HTTP and HTTPS targets via `CONNECT` |
| HTTPS    | sing-box `http` inbound + TLS  | The proxy endpoint itself speaks TLS (self-signed cert) |
| SOCKS5   | sing-box `socks` inbound       | Supports remote DNS (`socks5h`) |
| SSH      | system `sshd` + a dedicated user | `-D` dynamic SOCKS and `-L` local forwarding enabled **for that user only** |

All proxy protocols share one randomly generated username/password. Ports are picked
from the free range 20000-59999 after checking they are not already listening.

## Supported systems

* Alpine Linux (OpenRC) - tested on 3.24
* Debian / Ubuntu (systemd)

Architectures: `x86_64`, `aarch64`, `armv7`.

> On Alpine the package manager version of sing-box is used (`apk add sing-box`).
> The upstream release binaries are dynamically linked against glibc and do **not**
> run on musl (Alpine), so the installer never uses them there. On Debian/Ubuntu the
> official static release binary is downloaded from GitHub.

## Requirements

* root access (the script only touches proxy-related config; it never removes existing
  root SSH access)
* outbound internet access (package install and, on Debian, the sing-box download)

## Install

One command, run as root on the server:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh)
```

Options go after the process substitution:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh) --test
bash <(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh) --force
```

No bash / no process substitution (minimal Alpine):

```bash
sh -c "$(curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh)"
```

Prefer to keep the file on the server? Copy it and run it directly:

```bash
scp proxy.sh root@YOUR_SERVER:/root/proxy.sh
ssh root@YOUR_SERVER 'sh /root/proxy.sh'
```

Note: the one-liner does not save itself to disk. If you want a local copy for re-runs,
install it once:

```bash
curl -Ls https://raw.githubusercontent.com/mushokumunou/proxy-oneclick/main/proxy.sh -o /root/proxy.sh
sh /root/proxy.sh
```

At the end the script prints a JSON block and stores the same content in:

```
/root/proxy.json      # connection details, mode 600
/roo/proxy.json       # same content (compatibility path), mode 600
/etc/sing-box/proxy.env   # state file used to keep credentials across re-runs
```

## Usage

```bash
sh /root/proxy.sh              # install / re-apply (reuses existing credentials and ports)
sh /root/proxy.sh --force      # regenerate credentials + ports and rebuild everything
sh /root/proxy.sh --test       # run a self test through 127.0.0.1 after installing
sh /root/proxy.sh --help
```

Re-running without `--force` is safe: existing clients keep working because the
credentials, ports and config are reused.

## Using the proxies

The JSON file contains ready-to-paste commands. Examples:

```bash
# HTTP proxy (to https or http targets)
curl -x http://USER:PASS@SERVER:PORT_HTTP https://api.ipify.org

# HTTPS proxy (TLS to the proxy endpoint; self-signed certificate)
curl --proxy-insecure -x https://USER:PASS@SERVER:PORT_HTTPS https://api.ipify.org

# SOCKS5 with remote DNS
curl --socks5-hostname USER:PASS@SERVER:PORT_SOCKS https://api.ipify.org

# SSH: dynamic SOCKS tunnel on local port 1080
ssh -N -D 127.0.0.1:1080 SSH_USER@SERVER -p 22
# then point any client at socks5h://127.0.0.1:1080

# SSH: local port forwarding (reach a host as seen from the server)
ssh -N -L 127.0.0.1:8080:target.host:80 SSH_USER@SERVER -p 22
```

## Verify

Fill in the values from `/root/proxy.json`:

```bash
H=SERVER
U=USERNAME
P=PASSWORD
curl -s -x "http://$U:$P@$H:PORT_HTTP"  https://api.ipify.org   # -> server IP
curl -s --proxy-insecure -x "https://$U:$P@$H:PORT_HTTPS" https://api.ipify.org
curl -s --socks5-hostname "$U:$P@$H:PORT_SOCKS" https://api.ipify.org
ssh SSH_USER@$H -p 22 'echo ok'
```

Each call must return the **server's** public IP (or succeed for SSH), not your own IP.
A wrong password must be rejected.

## Service management

```bash
# Alpine (OpenRC)
rc-service sing-box status|restart
rc-service sshd reload

# Debian/Ubuntu (systemd)
systemctl status|restart sing-box
systemctl reload ssh
```

Config: `/etc/sing-box/config.json`, TLS material: `/etc/sing-box/tls/`.

## Notes and caveats

* The HTTPS proxy uses a self-signed certificate, so clients need `--proxy-insecure`
  (curl), "ignore certificate" (browser: install/trust once), or `verify=False`.
  Encryption is real; only third-party validation is missing.
* `sshd` is edited through a clearly marked managed block that grants
  `AllowTcpForwarding yes` **only** to the generated proxy user. The pre-change file is
  kept at `/etc/ssh/sshd_config.pre-proxy.sh` and the config is validated with `sshd -t`
  before reloading; on failure the backup is restored automatically.
* Firewall rules are added with `ufw` (or `firewalld`, or iptables on Debian when no
  manager is active). If your cloud provider has its own firewall group, open the three
  ports there as well.
* No traffic logging is enabled by sing-box (`log.level = warn`).

## Uninstall

```bash
# stop and remove the proxy service
rc-service sing-box stop; rc-update del sing-box default; rm -f /etc/init.d/sing-box
rm -rf /etc/sing-box /usr/local/bin/sing-box

# remove the ssh proxy user and its sshd block
userdel -r SSH_USER
sed -i '/# >>> proxy.sh managed block >>>/,/# <<< proxy.sh managed block <<</d' /etc/ssh/sshd_config
sshd -t && rc-service sshd reload
```

## License

MIT
