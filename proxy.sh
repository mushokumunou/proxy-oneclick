#!/bin/sh
# proxy.sh - one-click HTTP / HTTPS / SOCKS5 / SSH proxy installer
# Supports: Alpine (OpenRC) and Debian/Ubuntu (systemd)
# Idempotent: re-running keeps existing credentials and ports; use --force to regenerate.
# Usage: sh proxy.sh [--force] [--test]
set -eu

ETC_DIR="/etc/sing-box"
STATE_FILE="$ETC_DIR/proxy.env"
CONFIG_FILE="$ETC_DIR/config.json"
JSON_OUT="/root/proxy.json"
JSON_OUT_ALT="/roo/proxy.json"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.14.4}"
FORCE=0
RUN_TEST=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        --test)  RUN_TEST=1 ;;
        -h|--help) printf 'usage: sh proxy.sh [--force] [--test]\n'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$a" >&2; exit 1 ;;
    esac
done

log() { printf '[proxy.sh] %s\n' "$*"; }
die() { printf '[proxy.sh] ERROR: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    die "must run as root (try: sudo bash <(curl -Ls <url>))"
fi

# ---------- randomness ----------
rand_hex() {
    _n="$1"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$_n"
    else
        od -An -tx1 -N64 /dev/urandom | tr -d ' \n' | cut -c1-$((_n * 2))
    fi
}

rand_pass() {
    _len="$1"; _s=""
    while [ "${#_s}" -lt "$_len" ]; do
        _chunk=$(openssl rand -base64 60 2>/dev/null | tr -dc 'A-Za-z0-9' || true)
        _s="$_s$_chunk"
    done
    printf '%s' "$_s" | cut -c1-"$_len"
}

port_in_use() {
    _p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${_p}\$" && return 0
    fi
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${_p}\$" && return 0
    return 1
}

pick_port() {
    _tries=0
    while [ "$_tries" -lt 200 ]; do
        _r=$(od -An -N2 -tu2 /dev/urandom | tr -d ' \n')
        _p=$(( 20000 + (_r % 40000) ))
        if ! port_in_use "$_p"; then
            printf '%s' "$_p"
            return 0
        fi
        _tries=$((_tries + 1))
    done
    die "cannot find a free port"
}

# ---------- os detection ----------
if [ -f /etc/alpine-release ]; then
    OS_FAMILY="alpine"
elif [ -f /etc/os-release ] && grep -qiE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
    OS_FAMILY="debian"
else
    die "unsupported OS (only Alpine and Debian/Ubuntu are supported)"
fi
log "detected OS family: $OS_FAMILY"

case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7|armv6l) ARCH="armv7" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac
log "architecture: $ARCH"

# ---------- dependencies ----------
if [ "$OS_FAMILY" = "alpine" ]; then
    command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null
    command -v openssl >/dev/null 2>&1 || apk add --no-cache openssl >/dev/null
    apk add --no-cache ca-certificates >/dev/null 2>&1 || true
else
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v curl >/dev/null 2>&1; then
        apt-get update -qq >/dev/null
        apt-get install -y -qq curl >/dev/null
    fi
    command -v openssl >/dev/null 2>&1 || apt-get install -y -qq openssl >/dev/null
    command -v netstat >/dev/null 2>&1 || apt-get install -y -qq net-tools >/dev/null || true
fi
log "dependencies ready"

# ---------- state: reuse existing credentials/ports unless --force ----------
if [ "$FORCE" -eq 0 ] && [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    log "reusing existing credentials from $STATE_FILE"
fi

if [ "$FORCE" -eq 1 ] || [ -z "${PROXY_USER:-}" ]; then
    PROXY_USER="px$(rand_hex 4)"
    PROXY_PASS="$(rand_pass 20)"
fi
[ -n "${PORT_HTTP:-}" ]  || PORT_HTTP="$(pick_port)"
[ -n "${PORT_SOCKS:-}" ] || PORT_SOCKS="$(pick_port)"
[ -n "${PORT_HTTPS:-}" ] || PORT_HTTPS="$(pick_port)"
SSH_PORT="${SSH_PORT:-22}"

if [ "$FORCE" -eq 1 ] || [ -z "${SSH_USER:-}" ]; then
    SSH_USER="sx$(rand_hex 4)"
    SSH_PASS="$(rand_pass 24)"
fi

mkdir -p "$ETC_DIR"
cat > "$STATE_FILE" <<EOF
PROXY_USER=$PROXY_USER
PROXY_PASS=$PROXY_PASS
PORT_HTTP=$PORT_HTTP
PORT_SOCKS=$PORT_SOCKS
PORT_HTTPS=$PORT_HTTPS
SSH_USER=$SSH_USER
SSH_PASS=$SSH_PASS
SSH_PORT=$SSH_PORT
EOF
chmod 600 "$STATE_FILE"

# ---------- install sing-box ----------
SING_BOX_BIN=""
if [ "$OS_FAMILY" = "alpine" ]; then
    if [ ! -x /usr/bin/sing-box ]; then
        log "installing sing-box from Alpine repositories ..."
        apk add --no-cache sing-box >/dev/null 2>&1 || die "apk add sing-box failed"
    fi
    apk add --no-cache sing-box-openrc >/dev/null 2>&1 || true
    SING_BOX_BIN="/usr/bin/sing-box"
    rm -f /etc/sing-box/config.json.apk-new
else
    if [ ! -x /usr/local/bin/sing-box ]; then
        TARBALL="sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
        URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${TARBALL}"
        TMP="$(mktemp -d)"
        log "downloading sing-box v${SINGBOX_VERSION} ..."
        curl -fsSL --retry 3 -o "$TMP/$TARBALL" "$URL" || die "download failed: $URL"
        tar -xzf "$TMP/$TARBALL" -C "$TMP" || die "extract failed"
        SRC="$(find "$TMP" -type f -name sing-box | head -1)"
        [ -n "$SRC" ] || die "sing-box binary not found in tarball"
        install -m 0755 "$SRC" /usr/local/bin/sing-box
        rm -rf "$TMP"
    fi
    SING_BOX_BIN="/usr/local/bin/sing-box"
fi
log "sing-box: $("$SING_BOX_BIN" version 2>/dev/null | head -1)"

# ---------- TLS cert for the HTTPS (TLS-wrapped) proxy port ----------
CERT_DIR="$ETC_DIR/tls"
mkdir -p "$CERT_DIR"
PUBIP_PRE="$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || true)"
if [ ! -f "$CERT_DIR/cert.pem" ] || [ "$FORCE" -eq 1 ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -subj "/CN=proxy" \
        -addext "subjectAltName=DNS:localhost,IP:${PUBIP_PRE:-127.0.0.1}" >/dev/null 2>&1 \
    || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -subj "/CN=proxy" >/dev/null 2>&1 \
    || die "failed to generate TLS certificate"
    chmod 600 "$CERT_DIR/key.pem"
fi

# ---------- sing-box config ----------
USER_OBJ="{\"username\": \"${PROXY_USER}\", \"password\": \"${PROXY_PASS}\"}"
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "http",
      "tag": "http-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT_HTTP},
      "users": [${USER_OBJ}]
    },
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT_SOCKS},
      "users": [${USER_OBJ}]
    },
    {
      "type": "http",
      "tag": "https-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT_HTTPS},
      "users": [${USER_OBJ}],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_DIR}/cert.pem",
        "key_path": "${CERT_DIR}/key.pem"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
chmod 600 "$CONFIG_FILE"

"$SING_BOX_BIN" check -c "$CONFIG_FILE" || die "sing-box config check failed"
log "config written to $CONFIG_FILE"

# ---------- service ----------
if [ "$OS_FAMILY" = "alpine" ]; then
    if [ -f /etc/init.d/sing-box ]; then
        # use the init script shipped by sing-box-openrc
        mkdir -p /var/lib/sing-box
        cat > /etc/conf.d/sing-box <<EOF
# written by proxy.sh
SINGBOX_CONFIG=/etc/sing-box/config.json
SINGBOX_WORKDIR=/var/lib/sing-box
EOF
    else
        if command -v supervise-daemon >/dev/null 2>&1; then
            SUP_LINE='supervisor="supervise-daemon"'
        else
            SUP_LINE='command_background="yes"'
        fi
        cat > /etc/init.d/sing-box <<EOS
#!/sbin/openrc-run
description="sing-box proxy service"
command="${SING_BOX_BIN}"
command_args="run -c ${CONFIG_FILE}"
command_user="root"
pidfile="/run/sing-box.pid"
${SUP_LINE}
respawn_delay=5
respawn_max=0
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
EOS
        chmod 0755 /etc/init.d/sing-box
    fi
    rc-update add sing-box default >/dev/null 2>&1 || true
    rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1 || true
else
    cat > /etc/systemd/system/sing-box.service <<EOS
[Unit]
Description=sing-box proxy service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SING_BOX_BIN} run -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOS
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box
fi
sleep 2
if [ "$OS_FAMILY" = "alpine" ]; then
    log "sing-box service: $(rc-service sing-box status 2>&1 | head -1)"
else
    log "sing-box service: $(systemctl is-active sing-box 2>&1 | head -1)"
fi

# ---------- firewall ----------
open_port() {
    _p="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${_p}/tcp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${_p}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}
open_port "$PORT_HTTP"
open_port "$PORT_SOCKS"
open_port "$PORT_HTTPS"
log "firewall ports opened"

# ---------- ssh proxy user ----------
if ! id "$SSH_USER" >/dev/null 2>&1; then
    if [ "$OS_FAMILY" = "alpine" ]; then
        adduser -D -s /bin/ash -h "/home/$SSH_USER" "$SSH_USER" >/dev/null 2>&1 || \
            adduser -D -s /bin/sh -h "/home/$SSH_USER" "$SSH_USER" >/dev/null 2>&1 || \
            die "failed to create ssh proxy user"
    else
        adduser --disabled-password --gecos "" --shell /bin/bash "$SSH_USER" >/dev/null 2>&1 || \
            die "failed to create ssh proxy user"
    fi
fi

set_ssh_password() {
    u="$1"; p="$2"
    if printf '%s:%s\n' "$u" "$p" | chpasswd 2>/dev/null; then
        return 0
    fi
    if command -v openssl >/dev/null 2>&1 && command -v usermod >/dev/null 2>&1; then
        h="$(openssl passwd -6 "$p")"
        usermod -p "$h" "$u" 2>/dev/null && return 0
    fi
    return 1
}
set_ssh_password "$SSH_USER" "$SSH_PASS" || die "failed to set ssh password"
chage -E -1 -M 99999 "$SSH_USER" >/dev/null 2>&1 || true

# allow TCP forwarding for the proxy user only (global config keeps AllowTcpForwarding no)
SSHD_CONF="/etc/ssh/sshd_config"
SSHD_CONF_D="/etc/ssh/sshd_config.d"
BACKUP="/etc/ssh/sshd_config.pre-proxy.sh"
[ -f "$BACKUP" ] || cp "$SSHD_CONF" "$BACKUP"

if grep -rqiE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHD_CONF" "$SSHD_CONF_D" 2>/dev/null; then
    log "note: PasswordAuthentication is globally disabled; the Match block re-enables it for $SSH_USER"
fi

if grep -q 'proxy.sh managed block' "$SSHD_CONF" 2>/dev/null; then
    awk '
        /# >>> proxy.sh managed block >>>/ { skip=1 }
        skip != 1 { print }
        /# <<< proxy.sh managed block <<</ { skip=0 }
    ' "$SSHD_CONF" > "$SSHD_CONF.tmp" && mv "$SSHD_CONF.tmp" "$SSHD_CONF"
fi
{
    printf '\n# >>> proxy.sh managed block >>>\n'
    printf 'Match User %s\n' "$SSH_USER"
    printf '    AllowTcpForwarding yes\n'
    printf '    PermitOpen any\n'
    printf '    PasswordAuthentication yes\n'
    printf '    AllowAgentForwarding no\n'
    printf '    X11Forwarding no\n'
    printf '    GatewayPorts no\n'
    printf '# <<< proxy.sh managed block <<<\n'
} >> "$SSHD_CONF"

SSHD_BIN=""
for c in /usr/sbin/sshd /usr/bin/sshd; do
    [ -x "$c" ] && SSHD_BIN="$c" && break
done
[ -n "$SSHD_BIN" ] || SSHD_BIN="sshd"

if "$SSHD_BIN" -t 2>/dev/null; then
    if [ "$OS_FAMILY" = "alpine" ]; then
        rc-service sshd reload >/dev/null 2>&1 || \
            { [ -f /run/sshd.pid ] && kill -HUP "$(cat /run/sshd.pid)" 2>/dev/null; } || \
            rc-service sshd restart >/dev/null 2>&1 || true
    else
        systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || \
            systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
    fi
    sleep 1
else
    cp "$BACKUP" "$SSHD_CONF"
    die "sshd config validation failed - restored backup, ssh proxy not configured"
fi
log "ssh proxy user ready: $SSH_USER"

# ---------- output json ----------
PUBIP="$PUBIP_PRE"
[ -n "$PUBIP" ] || PUBIP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
[ -n "$PUBIP" ] || PUBIP="$(hostname -i 2>/dev/null | awk '{print $1}')"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_json() {
    cat > "$1" <<EOF
{
  "generated_at": "${NOW}",
  "host": "${PUBIP}",
  "username": "${PROXY_USER}",
  "password": "${PROXY_PASS}",
  "http": {
    "port": ${PORT_HTTP},
    "url": "http://${PROXY_USER}:${PROXY_PASS}@${PUBIP}:${PORT_HTTP}",
    "curl": "curl -x http://${PROXY_USER}:${PROXY_PASS}@${PUBIP}:${PORT_HTTP} https://api.ipify.org"
  },
  "https": {
    "port": ${PORT_HTTPS},
    "note": "HTTP proxy wrapped in TLS (self-signed certificate)",
    "url": "https://${PROXY_USER}:${PROXY_PASS}@${PUBIP}:${PORT_HTTPS}",
    "curl": "curl --proxy-insecure -x https://${PROXY_USER}:${PROXY_PASS}@${PUBIP}:${PORT_HTTPS} https://api.ipify.org"
  },
  "socks5": {
    "port": ${PORT_SOCKS},
    "url": "socks5h://${PROXY_USER}:${PROXY_PASS}@${PUBIP}:${PORT_SOCKS}",
    "curl": "curl --socks5-hostname ${PROXY_USER}:${PROXY_PASS}@${PUBIP}:${PORT_SOCKS} https://api.ipify.org"
  },
  "ssh": {
    "port": ${SSH_PORT},
    "username": "${SSH_USER}",
    "password": "${SSH_PASS}",
    "dynamic_socks": "ssh -N -D 127.0.0.1:1080 ${SSH_USER}@${PUBIP} -p ${SSH_PORT}",
    "local_forward": "ssh -N -L 127.0.0.1:8080:target.host:port ${SSH_USER}@${PUBIP} -p ${SSH_PORT}"
  }
}
EOF
    chmod 600 "$1"
}
write_json "$JSON_OUT"
mkdir -p "$(dirname "$JSON_OUT_ALT")" 2>/dev/null || true
write_json "$JSON_OUT_ALT" 2>/dev/null || true

log "connection info saved to $JSON_OUT"

# ---------- optional self test (runs on the server, through 127.0.0.1) ----------
if [ "$RUN_TEST" -eq 1 ]; then
    log "running self test ..."
    printf 'direct ip            : %s\n' "$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null || echo FAIL)"
    printf 'http   (>https)      : %s\n' "$(curl -fsS -m 15 -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PORT_HTTP}" https://api.ipify.org 2>/dev/null || echo FAIL)"
    printf 'http   (>http)       : %s\n' "$(curl -fsS -m 15 -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PORT_HTTP}" http://ifconfig.me/ip 2>/dev/null || echo FAIL)"
    printf 'https  (tls)         : %s\n' "$(curl -fsS -m 15 --proxy-insecure -x "https://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PORT_HTTPS}" https://api.ipify.org 2>/dev/null || echo FAIL)"
    printf 'socks5               : %s\n' "$(curl -fsS -m 15 --socks5-hostname "${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PORT_SOCKS}" https://api.ipify.org 2>/dev/null || echo FAIL)"
fi

printf '\n'
cat "$JSON_OUT"
printf '\n'
log "done. http:${PORT_HTTP} https:${PORT_HTTPS} socks5:${PORT_SOCKS} ssh:${SSH_PORT} (user ${SSH_USER})"
