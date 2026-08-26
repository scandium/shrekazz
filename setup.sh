#!/usr/bin/env bash
#
# setup.sh — one-shot Linux VM setup
#   Step 1  Install xRDP + XFCE desktop, give you the VM's IP so you can remote in
#   Step 2  Pause while YOU install VS Code + WakaTime ext & log in
#   Step 3  Deploy the spoof proxy so the dashboard shows "Lappy"
#           on macOS, egressing through your Webshare IP
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/setup.sh | bash
#
set -euo pipefail

# ----------------------------- config ---------------------------------------
SPOOF_DIR="/opt/wakatime-spoof"
PROXY_PORT="8383"
FAKE_OS="macOS-15.0.0-arm64"
FAKE_HOSTNAME="Lappy"
WEBSHARE_PROXY="45.38.107.97:6014"   # your Webshare exit node
TARGET_HOST="https://hackatime.hackclub.com"

# ----------------------------- helpers --------------------------------------
C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_C="\033[1;36m"; C_0="\033[0m"
info() { echo -e "${C_G}[+]${C_0} $*"; }
warn() { echo -e "${C_Y}[!]${C_0} $*"; }
die()  { echo -e "${C_R}[-]${C_0} $*" >&2; exit 1; }
step() { echo ""; echo -e "${C_C}========== $* ==========${C_0}"; }

# read from the terminal even when piped (curl ... | bash)
ask() { read -r -p "$1" "$2" < /dev/tty || true; }

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

export DEBIAN_FRONTEND=noninteractive

# ============================================================================
step "STEP 1 / 3  —  xRDP (remote desktop)"
# ============================================================================
info "Installing xRDP + XFCE desktop..."
$SUDO apt-get update -y -qq
$SUDO apt-get install -y -qq xrdp ca-certificates curl python3
$SUDO apt-get install -y -qq --no-install-recommends xfce4 xfce4-terminal dbus-x11
$SUDO systemctl enable --now xrdp
$SUDO adduser "$(id -un)" ssl-cert 2>/dev/null || true

# make xRDP sessions start XFCE instead of a bare fallback
echo "startxfce4" > "$HOME/.xsession"
$SUDO sed -i 's|^test -x /etc/X11/Xsession.*|#&|' /etc/xrdp/startwm.sh 2>/dev/null || true
$SUDO systemctl restart xrdp

IP="$(curl -fsS --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')"
echo ""
echo -e "${C_G}=====================================================${C_0}"
echo -e "${C_G}  xRDP is running. Connect now with any RDP client:${C_0}"
echo ""
echo -e "      ${C_C}Address : ${IP}:3389${C_0}"
echo -e "      User    : $(id -un)"
echo -e "      Password: (your linux user password)"
echo ""
echo -e "${C_G}=====================================================${C_0}"

# ============================================================================
step "STEP 2 / 3  —  your turn (VS Code + WakaTime login)"
# ============================================================================
ask "Install VS Code on this VM automatically? [Y/n]: " _vscode
_vscode="${_vscode:-Y}"
if [[ "$_vscode" =~ ^[Yy] ]]; then
    info "Installing VS Code..."
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/ms.gpg
    $SUDO install -o root -g root -m 644 /tmp/ms.gpg /usr/share/keyrings/packages.microsoft.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        | $SUDO tee /etc/apt/sources.list.d/vscode.list > /dev/null
    $SUDO apt-get update -y -qq
    $SUDO apt-get install -y -qq code
else
    warn "Skipping VS Code auto-install."
fi

echo ""
echo -e "${C_Y}NOW DO THIS INSIDE THE REMOTE DESKTOP (or SSH):${C_0}"
echo -e "   1. Open ${C_C}VS Code${C_0}"
echo -e "   2. Install the ${C_C}WakaTime${C_0} extension from the marketplace"
echo -e "   3. When prompted, paste your API key / log in to your account"
echo ""
ask "Press ENTER once you've installed WakaTime and logged in..." _

# ============================================================================
step "STEP 3 / 3  —  spoof proxy (Lappy @ macOS via Webshare)"
# ============================================================================
info "Using Webshare proxy: ${WEBSHARE_PROXY}"
PROXY_URL="http://$WEBSHARE_PROXY"

info "Deploying spoof proxy to $SPOOF_DIR..."
$SUDO mkdir -p "$SPOOF_DIR"

$SUDO tee "$SPOOF_DIR/proxy.py" > /dev/null << 'PYEOF'
#!/usr/bin/env python3
"""Local WakaTime spoof proxy.

Listens on 127.0.0.1:<port>, forwards everything to the real backend
through an upstream (Webshare) proxy while rewriting:
  - User-Agent:  linux-* -> macOS-*
  - JSON bodies: linux-* -> macOS-*, "hostname":"..." -> "Lappy"
"""
import gzip
import http.server
import os
import re
import ssl
import sys
import urllib.error
import urllib.request

TARGET_HOST = os.environ.get("TARGET_HOST", "https://hackatime.hackclub.com")
UPSTREAM = os.environ.get("UPSTREAM_PROXY")          # http://user:pass@host:port
PORT = int(os.environ.get("PORT", "8383"))
FAKE_OS = os.environ.get("FAKE_OS", "macOS-15.0.0-arm64")
FAKE_HOSTNAME = os.environ.get("FAKE_HOSTNAME", "Lappy")

ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE

handlers = [urllib.request.HTTPSHandler(context=ssl_ctx)]
if UPSTREAM:
    handlers.append(urllib.request.ProxyHandler({"http": UPSTREAM, "https": UPSTREAM}))
opener = urllib.request.build_opener(*handlers)

OS_RE = re.compile(rb"(?i)linux-[a-z0-9._\-]+")
HOST_RE = re.compile(rb'("hostname"\s*:\s*")[^"]*(")')
HOST_PLAIN_RE = re.compile(r'("hostname"\s*:\s*")[^"]*(")')


def spoof(body: bytes) -> bytes:
    if not body:
        return body
    gz = body[:2] == b"\x1f\x8b"
    if gz:  # gunzip -> rewrite -> regzip
        try:
            body = gzip.decompress(body)
        except OSError:
            return body
    body = OS_RE.sub(FAKE_OS.encode(), body)
    body = HOST_RE.sub(rb"\g<1>" + FAKE_HOSTNAME.encode() + rb"\g<2>", body)
    return gzip.compress(body) if gz else body


class SpoofProxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        body = spoof(body)

        headers = {}
        for k, v in self.headers.items():
            lk = k.lower()
            if lk in ("host", "content-length"):
                continue
            if lk == "user-agent":
                v = OS_RE.sub(FAKE_OS, v)
                v = re.sub(r"(?i)\blinux\b", "macOS", v)
            headers[k] = v
        if body:
            headers["Content-Length"] = str(len(body))

        req = urllib.request.Request(
            TARGET_HOST + self.path,
            data=body or None,
            headers=headers,
            method=self.command,
        )
        try:
            with opener.open(req, timeout=30) as resp:
                data = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() not in ("transfer-encoding", "content-length"):
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            for k, v in e.headers.items():
                if k.lower() not in ("transfer-encoding", "content-length"):
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            msg = str(e).encode()
            self.send_response(502)
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = handle_proxy

    def log_message(self, fmt, *args):
        sys.stderr.write("[spoof-proxy] %s\n" % (fmt % args))


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    print(f"spoof-proxy on 127.0.0.1:{PORT} -> {TARGET_HOST} via {UPSTREAM or 'direct'}")
    Server(("127.0.0.1", PORT), SpoofProxy).serve_forever()
PYEOF

$SUDO tee /etc/systemd/system/spoof.service > /dev/null << UNITEOF
[Unit]
Description=WakaTime spoof proxy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 ${SPOOF_DIR}/proxy.py
Environment=PORT=${PROXY_PORT}
Environment=UPSTREAM_PROXY=${PROXY_URL}
Environment=TARGET_HOST=${TARGET_HOST}
Environment=FAKE_OS=${FAKE_OS}
Environment=FAKE_HOSTNAME=${FAKE_HOSTNAME}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITEOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now spoof.service
info "Spoof proxy listening on 127.0.0.1:${PROXY_PORT}."

# ---- repoint WakaTime at the proxy -----------------------------------------
CFG="$HOME/.wakatime.cfg"
touch "$CFG"
set_cfg() {
    grep -q "^$1 *=" "$CFG" 2>/dev/null \
        && sed -i "s|^$1 *=.*|$1 = $2|" "$CFG" \
        || echo "$1 = $2" >> "$CFG"
}
set_cfg api_url "http://127.0.0.1:${PROXY_PORT}/api/v1"
set_cfg hostname "$FAKE_HOSTNAME"
chmod 600 "$CFG"
info "~/.wakatime.cfg now routes heartbeats through the spoof proxy."

# ---- also fix the VS Code extension's bundled settings if present ----------
VSC_SETTINGS="$HOME/.config/Code/User/settings.json"
if [[ -f "$VSC_SETTINGS" ]] && command -v python3 > /dev/null; then
    python3 - "$VSC_SETTINGS" "$PROXY_PORT" << 'PYJ'
import json, sys
path, port = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
data["wakatime.apiUrl"] = f"http://127.0.0.1:{port}/api/v1"
with open(path, "w") as f:
    json.dump(data, f, indent=4)
PYJ
    info "VS Code settings.json pinned to the local proxy too."
fi

# ---- test heartbeat through the whole chain --------------------------------
info "Sending one test heartbeat through the proxy..."
API_KEY="$(grep '^api_key *=' "$CFG" | head -n1 | cut -d'=' -f2- | xargs)"
if [[ -z "$API_KEY" || "$API_KEY" == "REPLACE_ME" ]]; then
    warn "No API key set — skipping test heartbeat. After setting your key in ~/.wakatime.cfg, test with:"
    warn "  AUTH=\$(printf '%s' \$(grep '^api_key' ~/.wakatime.cfg | cut -d= -f2- | xargs) | base64); \\\n    curl -sS -X POST http://127.0.0.1:${PROXY_PORT}/api/v1/users/current/heartbeats.bulk \\\n    -H \"Authorization: Basic \$AUTH\" -H 'Content-Type: application/json' \\\n    -d '[{\"entity\":\"test.py\",\"type\":\"file\",\"time\":'\"\$(date +%s)\"'}]'"
else
    AUTH_B64="$(printf '%s' "$API_KEY" | base64 | tr -d '\n')"
    HTTP_CODE=""
    RESP="$(curl -sS --max-time 30 -w '\nHTTP_STATUS:%{http_code}' -X POST \
        "http://127.0.0.1:${PROXY_PORT}/api/v1/users/current/heartbeats.bulk" \
        -H "Authorization: Basic ${AUTH_B64}" \
        -H "Content-Type: application/json" \
        -d "[{\"entity\":\"test.py\",\"type\":\"file\",\"time\":$(date +%s),\"project\":\"setup-test\",\"is_write\":false,\"editor\":\"vscode\",\"language\":\"Python\",\"user_agent\":\"wakatime/14.0.0 (${FAKE_OS})\",\"hostname\":\"${FAKE_HOSTNAME}\"}]" 2>&1 || true)"
    HTTP_CODE="$(echo "$RESP" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)"
    BODY="$(echo "$RESP" | sed 's/HTTP_STATUS:[0-9]*//')"
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
        info "Test heartbeat accepted ✓ (HTTP $HTTP_CODE) — check the dashboard for Lappy/macOS"
    else
        warn "Test heartbeat FAILED (HTTP ${HTTP_CODE:-none}) — response:"
        echo    "    ${BODY:-<empty>}${RESP:+}"
        warn "Live logs: journalctl -u spoof -f"
    fi
fi

# ============================================================================
step "DONE"
echo -e "    • xRDP        : active on ${C_C}${IP}:3389${C_0}"
echo -e "    • spoof proxy : 127.0.0.1:${PROXY_PORT} -> ${TARGET_HOST}"
echo -e "                    egressing via ${C_C}${PROXY_URL}${C_0}"
echo -e "                    shows as '${C_G}${FAKE_HOSTNAME}${C_0}' on ${C_G}${FAKE_OS}${C_0}"
echo ""
echo -e "    Restart VS Code inside the RDP session so it picks up the new config."
echo -e "    Logs: ${C_Y}journalctl -u spoof -f${C_0}"
