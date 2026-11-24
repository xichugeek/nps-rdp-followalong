#!/usr/bin/env bash
# Run on a fresh Ubuntu 24.04 amd64 test VM with sudo. Configure cloud rules separately.
set -euo pipefail
umask 077

if [[ $(id -u) != 0 || $(uname -m) != x86_64 ]]; then
  printf 'Run with sudo on Ubuntu amd64.\n' >&2
  exit 1
fi
install_root=/opt/xichuremote-nps
state_root=/var/lib/xichuremote-nps
unit_root=/etc/systemd/system
for existing in "$install_root" "$state_root" "$unit_root/xichuremote-nps.service" "$unit_root/xichuremote-nps-tls.socket" "$unit_root/xichuremote-nps-tls.service"; do
  if [[ -e $existing || -L $existing ]]; then
    printf 'Existing NPS path needs review: %s\n' "$existing" >&2
    exit 1
  fi
done
busy_ports=$(ss -H -lnt '( sport = :8025 or sport = :18024 or sport = :18025 or sport = :18081 or sport = :43389 )')
if [[ -n $busy_ports ]]; then
  printf 'One or more tutorial ports are already in use.\n%s\n' "$busy_ports" >&2
  exit 1
fi
socket_proxy=/lib/systemd/systemd-socket-proxyd
test -x "$socket_proxy"
read -r -p 'Public IPv4 of this Tencent Cloud test instance: ' public_ip
if ! [[ $public_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  printf 'Enter an IPv4 address.\n' >&2
  exit 1
fi

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
archive="$scratch/linux_amd64_server.tar.gz"
curl --fail --show-error --silent --location --max-time 120 \
  'https://github.com/ZiDuNet/nps/releases/download/v1.1.52/linux_amd64_server.tar.gz' \
  --output "$archive"
printf '%s  %s\n' '93f3d1410fb38f8a32e228ddbb79775ca7b02cd37dcfad60b59cefb5f4693171' "$archive" | sha256sum -c -
tar -xzf "$archive" -C "$scratch" nps
curl --fail --show-error --silent --location --max-time 120 \
  'https://github.com/ZiDuNet/nps/releases/download/v1.1.52/npsctl_linux_amd64' \
  --output "$scratch/npsctl"
printf '%s  %s\n' '9f61340b311fedfea36afba00021b5024e3ca00299d80792b20bea39ace3d14f' "$scratch/npsctl" | sha256sum -c -

install -d -m 0755 "$install_root/bin"
install -m 0755 "$scratch/nps" "$install_root/bin/nps"
install -m 0755 "$scratch/npsctl" "$install_root/bin/npsctl"
printf '%s\n' "$public_ip" > "$scratch/public-ip"
install -m 0644 "$scratch/public-ip" "$install_root/public-ip"

cat > "$scratch/init.sh" <<'INIT'
#!/bin/sh
set -eu
umask 077
state=/var/lib/xichuremote-nps
public_ip=$(cat /opt/xichuremote-nps/public-ip)
mkdir -p "$state/conf"
if [ ! -s "$state/conf/bridge.pem" ] || [ ! -s "$state/conf/bridge.key" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 -sha256 \
      -subj "/CN=$public_ip" -addext "subjectAltName=IP:$public_ip" \
      -keyout "$state/conf/bridge.next.key" -out "$state/conf/bridge.next.pem" >/dev/null 2>&1
    mv "$state/conf/bridge.next.key" "$state/conf/bridge.key"
    mv "$state/conf/bridge.next.pem" "$state/conf/bridge.pem"
fi
if [ -e "$state/conf/nps.conf" ]; then
    exit 0
fi
cat > "$state/conf/nps.next.conf" <<EOF
runmode=pro
appname=nps
web_ip=127.0.0.1
web_port=18081
web_open_ssl=false
web_username=npsadmin
web_password=$(openssl rand -hex 24)
auth_key=$(openssl rand -hex 24)
auth_crypt_key=$(openssl rand -hex 8)
public_vkey=
bridge_type=tcp
bridge_ip=127.0.0.1
bridge_port=18024
bridge_tcp_show=false
bridge_tls_show_ip=$public_ip
bridge_tls_show_port=8025
tls_enable=true
tls_bridge_port=18025
bridge_cert_file=$state/conf/bridge.pem
bridge_key_file=$state/conf/bridge.key
http_proxy_port=
https_proxy_port=
allow_ports=43389
allow_remote_update=false
allow_user_register=false
timezone=Asia/Shanghai
log_level=6
EOF
mv "$state/conf/nps.next.conf" "$state/conf/nps.conf"
INIT
install -m 0755 "$scratch/init.sh" "$install_root/init.sh"

cat > "$unit_root/xichuremote-nps.service" <<'SERVICE'
[Unit]
Description=Tutorial NPS
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
User=xichuremote-nps
DynamicUser=yes
StateDirectory=xichuremote-nps
StateDirectoryMode=0700
WorkingDirectory=/var/lib/xichuremote-nps
UMask=0077
ExecStartPre=/opt/xichuremote-nps/init.sh
ExecStart=/opt/xichuremote-nps/bin/nps -conf_path=/var/lib/xichuremote-nps
Restart=on-failure
RestartSec=5
MemoryHigh=72M
MemoryMax=96M
CPUQuota=35%
TasksMax=64
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SocketBindDeny=any
SocketBindAllow=ipv4:tcp:18024
SocketBindAllow=ipv4:tcp:18025
SocketBindAllow=ipv4:tcp:18081
SocketBindAllow=ipv4:tcp:43389
SocketBindAllow=ipv6:tcp:43389

[Install]
WantedBy=multi-user.target
SERVICE

cat > "$unit_root/xichuremote-nps-tls.socket" <<'SOCKET'
[Unit]
Description=Tutorial NPS public TLS socket

[Socket]
ListenStream=0.0.0.0:8025

[Install]
WantedBy=sockets.target
SOCKET

cat > "$unit_root/xichuremote-nps-tls.service" <<'PROXY'
[Unit]
Description=Forward tutorial NPS TLS socket to loopback
Requires=xichuremote-nps.service
After=xichuremote-nps.service

[Service]
DynamicUser=yes
ExecStart=/lib/systemd/systemd-socket-proxyd 127.0.0.1:18025
MemoryMax=24M
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
PROXY
chmod 0644 "$unit_root"/xichuremote-nps{.service,-tls.socket,-tls.service}
systemd-analyze verify "$unit_root"/xichuremote-nps{.service,-tls.socket,-tls.service}
systemctl daemon-reload
systemctl enable --now xichuremote-nps.service xichuremote-nps-tls.socket
for attempt in 1 2 3 4 5; do
  if [[ $(curl --silent --show-error --max-time 2 --output /dev/null --write-out '%{http_code}' http://127.0.0.1:18081/login/index) == 200 ]]; then
    printf 'NPS panel responded on loopback.\n'
    exit 0
  fi
  sleep 2
done
printf 'Check the local panel and service log before proceeding.\n' >&2
exit 1
