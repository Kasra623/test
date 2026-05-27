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
WS_PATH="/$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 12)"

# ── Install Xray-core ────────────────────────────────────────
log "Installing Xray-core..."
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) \
    -- install 2>&1 | tail -5

XRAY_BIN=$(command -v xray || echo /usr/local/bin/xray)
[[ ! -x "$XRAY_BIN" ]] && err "Xray binary not found after install."

# ── Generate UUID ────────────────────────────────────────────
UUID=$("$XRAY_BIN" uuid)
log "UUID generated: $UUID"

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
