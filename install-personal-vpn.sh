#!/usr/bin/env bash
# Ubuntu 22.04/24.04 or Debian 12/13 on a clean VPS with systemd.
# Usage: sudo bash install-personal-vpn.sh PUBLIC_IPV4 [REALITY_SNI]
set -Eeuo pipefail
umask 077

readonly version=v3.11.0
readonly installer_sha256=9684bae4f769b2127fcceceb4f200045657381311867529e6ba76c6b58e2825d
readonly panel_port=2053
readonly vpn_port=443
readonly result=/root/personal-vpn-access.txt
readonly log=/root/personal-vpn-install.log
readonly xui=/usr/local/x-ui/x-ui

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    printf '%s\n' "Usage: sudo bash install-personal-vpn.sh PUBLIC_IPV4 [REALITY_SNI]"
    exit 0
fi
[[ $# -ge 1 && $# -le 2 ]] || die "Usage: sudo bash install-personal-vpn.sh PUBLIC_IPV4 [REALITY_SNI]"
[[ $EUID -eq 0 ]] || die "Run this script as root."
[[ -r /etc/os-release && -d /run/systemd/system ]] || die "A Linux VPS with systemd is required."
source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
    *) die "Use Ubuntu 22.04/24.04 or Debian 12/13." ;;
esac
case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "This script supports x86_64 and aarch64." ;;
esac

exec 9>/run/lock/personal-vpn-install.lock
flock -n 9 || die "Another installation is running."
if [[ -e "$result" || -e /etc/x-ui || -e /usr/local/x-ui ]] ||
    systemctl cat x-ui.service >/dev/null 2>&1; then
    die "An existing installation or access file was found. Use a clean VPS."
fi

server_ip=$1
reality_sni=${2:-www.microsoft.com}
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null ||
    ! command -v ss >/dev/null || ! command -v openssl >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl python3 iproute2 openssl
fi
python3 - "$server_ip" "$reality_sni" <<'PY'
import ipaddress
import re
import sys

try:
    address = ipaddress.IPv4Address(sys.argv[1])
    if not address.is_global or address.is_multicast:
        raise ValueError
except ValueError:
    sys.exit("Pass the public IPv4 address of your VPS.")
hostname = sys.argv[2]
label = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
if len(hostname) > 253 or not re.fullmatch(rf"(?:{label}\.)+{label}", hostname):
    sys.exit("REALITY_SNI must be a DNS hostname without a port.")
PY

for port in "$vpn_port" "$panel_port"; do
    [[ -z "$(ss -H -ltn "sport = :$port")" ]] || die "TCP port $port is already in use."
done

if ! tls_check=$(timeout 12 openssl s_client -connect "$reality_sni:443" \
    -servername "$reality_sni" -verify_hostname "$reality_sni" -verify_return_error \
    -tls1_3 -alpn h2 </dev/null 2>&1) ||
    ! grep -Fxq 'ALPN protocol: h2' <<< "$tls_check"; then
    die "The REALITY target did not pass the TLS 1.3 and HTTP/2 check from this VPS."
fi

installer=$(mktemp)
trap 'rm -f -- "$installer"' EXIT
curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
    "https://raw.githubusercontent.com/MHSanaei/3x-ui/$version/install.sh" -o "$installer"
printf '%s  %s\n' "$installer_sha256" "$installer" | sha256sum --check --status ||
    die "The upstream installer checksum did not match."
# The pinned installer defaults to public HTTP in unattended mode.
# Select its loopback option before the panel starts.
python3 - "$installer" <<'PYCODE'
import sys
from pathlib import Path

path = Path(sys.argv[1])
script = path.read_text()
original = '                bind_local="n"'
if script.count(original) != 1:
    sys.exit("The pinned installer could not be configured for local-only panel access.")
path.write_text(script.replace(original, '                bind_local="y"', 1))
PYCODE

printf 'Installing 3x-ui %s.\n' "$version"
if ! XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none \
    XUI_PANEL_PORT="$panel_port" XUI_SERVER_IP="$server_ip" \
    bash "$installer" "$version" >"$log" 2>&1; then
    die "3x-ui installation failed. Root-only install log: $log"
fi

[[ -x "$xui" && -r /etc/x-ui/install-result.env ]] ||
    die "The installer did not produce the panel binary and access file. See $log"
"$xui" setting -listenIP 127.0.0.1 >>"$log" 2>&1
systemctl restart x-ui

panel_ready() {
    local listeners
    listeners=$(ss -H -ltn "sport = :$panel_port")
    [[ -n "$listeners" ]] && awk -v address="127.0.0.1:$panel_port" \
        '$4 != address { bad=1 } END { exit bad }' <<< "$listeners"
}
for attempt in {1..20}; do
    if panel_ready; then
        break
    fi
    sleep 1
done
if ! panel_ready; then
    systemctl stop x-ui
    die "Could not verify that the panel is bound to 127.0.0.1. See $log"
fi

source /etc/x-ui/install-result.env
[[ "${XUI_PANEL_PORT:-}" == "$panel_port" && -n "${XUI_USERNAME:-}" &&
   -n "${XUI_PASSWORD:-}" && -n "${XUI_WEB_BASE_PATH:-}" && -n "${XUI_API_TOKEN:-}" ]] ||
    die "The installer access file is incomplete."
shopt -s nullglob
xrays=(/usr/local/x-ui/bin/xray-linux-*)
[[ ${#xrays[@]} -eq 1 && -x "${xrays[0]}" ]] || die "Could not find the bundled Xray binary."

XUI_USERNAME="$XUI_USERNAME" XUI_PASSWORD="$XUI_PASSWORD" \
XUI_WEB_BASE_PATH="$XUI_WEB_BASE_PATH" XUI_API_TOKEN="$XUI_API_TOKEN" python3 - \
    "$server_ip" "$reality_sni" "$panel_port" "$vpn_port" "${xrays[0]}" "$result" <<'PY'
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

server_ip, sni, panel_port, vpn_port, xray, result = sys.argv[1:]
username = os.environ["XUI_USERNAME"]
password = os.environ["XUI_PASSWORD"]
api_token = os.environ["XUI_API_TOKEN"]
base_path = os.environ["XUI_WEB_BASE_PATH"].strip("/")
if not re.fullmatch(r"[A-Za-z0-9_-]+", base_path):
    sys.exit("Unexpected panel base path.")
panel = f"http://127.0.0.1:{panel_port}/{base_path}/"
browser = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def api(path, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    headers = {"Accept": "application/json", "Authorization": f"Bearer {api_token}"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(panel + path, data=body, headers=headers)
    try:
        with browser.open(req, timeout=15) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        sys.exit(f"3x-ui API request failed ({path}): HTTP {exc.code}")
    except (OSError, ValueError) as exc:
        sys.exit(f"3x-ui API request failed ({path}): {type(exc).__name__}")
    if not isinstance(data, dict) or data.get("success") is not True:
        sys.exit(f"3x-ui refused the request ({path}).")
    return data.get("obj")

key_output = subprocess.check_output([xray, "x25519"], text=True)
keys = {}
for line in key_output.splitlines():
    label, _, value = line.partition(":")
    keys[re.sub(r"[^a-z]", "", label.lower())] = value.strip()
private_key = keys.get("privatekey")
public_key = keys.get("passwordpublickey") or keys.get("password") or keys.get("publickey")
if not all(key and re.fullmatch(r"[A-Za-z0-9_-]{43}", key) for key in (private_key, public_key)):
    sys.exit("Xray did not return a usable REALITY key pair.")

client_id = str(uuid.uuid4())
short_id = secrets.token_hex(8)
service_name = "vpn"
stream = {
    "network": "grpc",
    "security": "reality",
    "grpcSettings": {"serviceName": service_name, "multiMode": False},
    "realitySettings": {
        "target": f"{sni}:443",
        "serverNames": [sni],
        "privateKey": private_key,
        "shortIds": [short_id],
        "settings": {"publicKey": public_key, "fingerprint": "chrome", "spiderX": "/"},
    },
}
client = {
    "id": client_id, "email": "personal-test", "enable": True, "flow": "",
    "limitIp": 0, "totalGB": 0, "expiryTime": 0, "subId": secrets.token_hex(8),
}
inbounds = api("panel/api/inbounds/list") or []
if inbounds:
    sys.exit("The panel already contains inbounds. No profile was created.")
api("panel/api/inbounds/add", {
    "remark": "Personal VPN", "enable": True, "listen": "0.0.0.0",
    "port": int(vpn_port), "protocol": "vless", "expiryTime": 0,
    "settings": json.dumps({"clients": [client], "decryption": "none", "encryption": "none"}),
    "streamSettings": json.dumps(stream),
    "sniffing": json.dumps({"enabled": False, "destOverride": []}),
})
for attempt in range(20):
    sockets = subprocess.check_output(["ss", "-H", "-ltnp", f"sport = :{vpn_port}"], text=True)
    if "xray" in sockets:
        break
    time.sleep(1)
else:
    sys.exit("The inbound was saved, but Xray is not listening. Check journalctl -u x-ui.")

query = urllib.parse.urlencode({
    "type": "grpc", "encryption": "none", "security": "reality",
    "pbk": public_key, "fp": "chrome", "sni": sni, "sid": short_id,
    "spx": "/", "serviceName": service_name, "mode": "gun",
})
uri = f"vless://{client_id}@{server_ip}:{vpn_port}?{query}#Personal-VPN-Test"
with tempfile.NamedTemporaryFile(mode="w", dir=Path(result).parent, delete=False) as output:
    try:
        output.write(
            f"Panel URL: {panel}\n"
            f"Panel username: {username}\n"
            f"Panel password: {password}\n"
            f"Run on your computer first: ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:{panel_port}:127.0.0.1:{panel_port} root@{server_ip}\n"
            f"Test profile: {uri}\n"
        )
        output.flush()
        os.replace(output.name, result)
    finally:
        if os.path.exists(output.name):
            os.unlink(output.name)
PY

if command -v ufw >/dev/null && LC_ALL=C ufw status | grep '^Status: active$' >/dev/null; then
    ufw allow "$vpn_port/tcp"
fi

rm -f -- "$log"
printf 'Ready. Access file (root only): %s\n' "$result"
printf 'Allow TCP %s in your hosting firewall. Keep the panel port private.\n' "$vpn_port"
