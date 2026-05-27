#!/bin/bash
# ============================================================
#  Xray (V2Ray) on GitHub Codespaces — Iran bypass script
#  Protocol: VLESS over WebSocket + TLS (auto via Codespaces)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[*]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── Sanity checks ────────────────────────────────────────────
if [[ -z "$CODESPACE_NAME" ]]; then
    err "CODESPACE_NAME is not set. Run this inside a GitHub Codespace."
fi

INTERNAL_PORT=8080
UUID_FILE="$HOME/.xray-cs-uuid"
WS_PATH_FILE="$HOME/.xray-cs-wspath"

# ── Install Xray-core ────────────────────────────────────────
log "Installing Xray-core..."
XRAY_BIN="$HOME/.local/bin/xray"
mkdir -p "$HOME/.local/bin"

# Try system install with sudo first, fall back to local binary install
# Detect arch for fallback
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  XRAY_ARCH="64" ;;
    aarch64) XRAY_ARCH="arm64-v8a" ;;
    *)        err "Unsupported architecture: $ARCH" ;;
esac

# Try sudo system install first
log "Trying sudo install..."
curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh -o /tmp/xray-install.sh
chmod +x /tmp/xray-install.sh
if sudo bash /tmp/xray-install.sh 2>&1 | tail -5; then
    XRAY_BIN=$(command -v xray 2>/dev/null || echo "")
    # Also check common paths
    for p in /usr/local/bin/xray /usr/bin/xray; do
        [[ -x "$p" ]] && XRAY_BIN="$p" && break
    done
fi

# Fall back to direct binary download if sudo install didn't produce a working binary
if [[ -z "$XRAY_BIN" || ! -x "$XRAY_BIN" ]]; then
    warn "System install failed or binary missing — falling back to direct download..."
    XRAY_VER=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${XRAY_ARCH}.zip"
    log "Downloading Xray ${XRAY_VER} for linux-${XRAY_ARCH}..."
    curl -Ls "$XRAY_URL" -o /tmp/xray.zip
    unzip -o /tmp/xray.zip xray -d "$HOME/.local/bin/" 2>/dev/null
    XRAY_BIN="$HOME/.local/bin/xray"
    chmod +x "$XRAY_BIN"
    log "Xray binary installed locally at $XRAY_BIN"
fi

[[ ! -x "$XRAY_BIN" ]] && err "Xray binary not found after all install attempts."
log "Using Xray at: $XRAY_BIN"

# ── Generate or reuse UUID + WS_PATH ───────────────────────
if [[ -f "$UUID_FILE" && -f "$WS_PATH_FILE" ]]; then
    UUID=$(cat "$UUID_FILE")
    WS_PATH=$(cat "$WS_PATH_FILE")
    log "Reusing saved UUID: $UUID"
    log "Reusing saved WS path: $WS_PATH"
else
    UUID=$("$XRAY_BIN" uuid)
    WS_PATH="/$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 12)"
    echo "$UUID" > "$UUID_FILE"
    echo "$WS_PATH" > "$WS_PATH_FILE"
    log "New UUID saved: $UUID"
    log "New WS path saved: $WS_PATH"
fi

# ── Write Xray config ────────────────────────────────────────
CONFIG_PATH="$HOME/.xray-cs-config.json"
cat > "$CONFIG_PATH" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $INTERNAL_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "level": 0 }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF
log "Xray config written to $CONFIG_PATH"

# ── Start Xray ───────────────────────────────────────────────
log "Starting Xray..."
nohup "$XRAY_BIN" run -c "$CONFIG_PATH" > "$HOME/.xray-cs.log" 2>&1 &
XRAY_PID=$!
sleep 2

if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    err "Xray failed to start. Check $HOME/.xray-cs.log"
fi
log "Xray running (PID $XRAY_PID)"

# ── Expose port publicly via Codespaces CLI ──────────────────
log "Making port $INTERNAL_PORT public..."
# Try gh CLI first (available in all Codespaces)
if command -v gh &>/dev/null; then
    gh codespace ports visibility "$INTERNAL_PORT:public" \
        -c "$CODESPACE_NAME" 2>/dev/null && \
        log "Port forwarded publicly via gh CLI." || \
        warn "gh CLI port visibility failed — forward port manually in VS Code Ports tab."
else
    warn "gh CLI not found. Open the Ports panel and set port $INTERNAL_PORT to Public."
fi

# ── Build public host & VLESS link ──────────────────────────
# Codespaces public URL format (TLS 443 auto):
PUBLIC_HOST="${CODESPACE_NAME}-${INTERNAL_PORT}.app.github.dev"
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$WS_PATH'))")
VLESS_LINK="vless://${UUID}@${PUBLIC_HOST}:443?encryption=none&security=tls&sni=${PUBLIC_HOST}&type=ws&host=${PUBLIC_HOST}&path=${ENCODED_PATH}#CS-Iran"

# ── Print config ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║          XRAY CONFIG — READY TO USE              ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}── Manual Config ──────────────────────────────────${NC}"
echo -e "  Protocol : ${YELLOW}VLESS${NC}"
echo -e "  Address  : ${YELLOW}${PUBLIC_HOST}${NC}"
echo -e "  Port     : ${YELLOW}443${NC}"
echo -e "  UUID     : ${YELLOW}${UUID}${NC}"
echo -e "  Network  : ${YELLOW}WebSocket (ws)${NC}"
echo -e "  Path     : ${YELLOW}${WS_PATH}${NC}"
echo -e "  TLS      : ${YELLOW}true${NC}"
echo -e "  SNI      : ${YELLOW}${PUBLIC_HOST}${NC}"
echo ""
echo -e "${CYAN}── VLESS Import Link (copy into v2rayNG / Hiddify) ──${NC}"
echo ""
echo -e "${BOLD}${YELLOW}${VLESS_LINK}${NC}"
echo ""

# ── Save config to file for easy access ─────────────────────
CONFIG_OUT="$HOME/.xray-cs-client.txt"
{
    echo "=== XRAY CLIENT CONFIG ==="
    echo "Address  : $PUBLIC_HOST"
    echo "Port     : 443"
    echo "UUID     : $UUID"
    echo "Network  : ws"
    echo "Path     : $WS_PATH"
    echo "TLS      : true"
    echo "SNI      : $PUBLIC_HOST"
    echo ""
    echo "VLESS Link:"
    echo "$VLESS_LINK"
} > "$CONFIG_OUT"
log "Config also saved to $CONFIG_OUT"

# ── Anti-AFK Loop ────────────────────────────────────────────
echo ""
info "Anti-AFK loop started. Codespace will stay alive."
info "Press Ctrl+C to stop."
echo ""

TICK=0
while true; do
    sleep 120

    # Check Xray is still alive, restart if dead
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        warn "Xray died. Restarting..."
        nohup "$XRAY_BIN" run -c "$CONFIG_PATH" > "$HOME/.xray-cs.log" 2>&1 &
        XRAY_PID=$!
        sleep 1
        kill -0 "$XRAY_PID" 2>/dev/null && log "Xray restarted (PID $XRAY_PID)" || \
            warn "Restart failed — check $HOME/.xray-cs.log"
    fi

    TICK=$((TICK + 1))
    UPTIME_MIN=$((TICK * 2))

    # Lightweight activity signal (file I/O, not CPU spam)
    touch "$HOME/.xray-cs-afk" && \
        echo "$(date)" >> "$HOME/.xray-cs-afk"

    # Trim AFK log so it doesn't balloon
    tail -20 "$HOME/.xray-cs-afk" > "$HOME/.xray-cs-afk.tmp" && \
        mv "$HOME/.xray-cs-afk.tmp" "$HOME/.xray-cs-afk"

    printf "\r${CYAN}[AFK]${NC} Uptime: ${UPTIME_MIN}m | Xray PID: $XRAY_PID | $(date '+%H:%M:%S')"
done
