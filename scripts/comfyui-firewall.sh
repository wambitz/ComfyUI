#!/usr/bin/env bash
# ==============================================================================
# ComfyUI Firewall
# Block internet access for the ComfyUI container while keeping the browser UI.
#
# Usage:
#   sudo ./scripts/comfyui-firewall.sh on      Block internet
#   sudo ./scripts/comfyui-firewall.sh off     Restore internet
#   sudo ./scripts/comfyui-firewall.sh status  Check current state
#
# How it works:
#   Inserts two iptables rules in the DOCKER-USER chain (evaluated before
#   Docker's own rules for all forwarded container traffic):
#
#   1. RETURN  — packets from the container in ESTABLISHED/RELATED state
#                (responses to your browser requests → UI keeps working)
#   2. DROP    — everything else from the container
#                (new outbound connections → internet blocked)
#
#   Rules are tagged with a comment ("comfyui-no-internet") so they can be
#   identified and removed cleanly.  Only the comfyui-secure container is
#   targeted by its IP address — other containers are not affected.
#
#   Rules do NOT survive a reboot (iptables is ephemeral by default).
#   Run "on" again after restarting your machine.
# ==============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
# Must match container_name in docker-compose.yml
CONTAINER="comfyui-secure"
TAG="comfyui-no-internet"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
info() { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

check_root() {
    [[ $EUID -eq 0 ]] || die "This script requires sudo.\n  →  sudo $0 ${1:-on}"
}

# Get the container's IP on its Docker network
get_container_ip() {
    local ip
    ip=$(docker inspect "$CONTAINER" \
        -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
        2>/dev/null | head -1)
    [[ -n "$ip" ]] || die "Container '${CONTAINER}' is not running.\n  Start it first:  docker compose up -d"
    echo "$ip"
}

# Check if our firewall rules exist in DOCKER-USER
rules_exist() {
    iptables -S DOCKER-USER 2>/dev/null | grep -q "$TAG"
}

# Remove all rules tagged with our comment (safe to call even if none exist)
remove_rules() {
    local ips
    ips=$(iptables -S DOCKER-USER 2>/dev/null | grep "$TAG" | grep -oP '(?<=-s )\S+' | sort -u) || true

    for ip in $ips; do
        iptables -D DOCKER-USER \
            -s "$ip" \
            -m conntrack --ctstate ESTABLISHED,RELATED \
            -m comment --comment "$TAG" \
            -j RETURN 2>/dev/null || true

        iptables -D DOCKER-USER \
            -s "$ip" \
            -m comment --comment "$TAG" \
            -j DROP 2>/dev/null || true

        info "Removed rules for $ip"
    done
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_on() {
    check_root "on"

    local ip
    ip=$(get_container_ip)

    # Clean up any stale rules first (handles container IP changes on restart)
    if rules_exist; then
        warn "Replacing existing rules (container may have a new IP)..."
        remove_rules
    fi

    echo -e "${BOLD}Blocking internet for '${CONTAINER}' (${ip})${NC}"
    echo ""

    # Rule 1 (position 1): Allow responses to incoming connections (browser UI)
    iptables -I DOCKER-USER 1 \
        -s "$ip" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -m comment --comment "$TAG" \
        -j RETURN

    # Rule 2 (position 2): Drop all new outbound from this container
    iptables -I DOCKER-USER 2 \
        -s "$ip" \
        -m comment --comment "$TAG" \
        -j DROP

    info "Firewall ON — internet blocked for ${CONTAINER}"
    echo "  Browser UI:  http://127.0.0.1:8188  (still works)"
    echo "  Undo:        sudo $0 off"
    echo ""

    # ── Verify ───────────────────────────────────────────────────────────
    echo -e "${BOLD}Verifying...${NC}"
    if docker exec "$CONTAINER" python3 -c "
import urllib.request, socket
socket.setdefaulttimeout(3)
try:
    urllib.request.urlopen('https://example.com')
    exit(1)
except Exception:
    exit(0)
" 2>/dev/null; then
        info "Verified: container cannot reach the internet."
    else
        warn "Could not verify (container may still be starting). Test manually:"
        echo "  docker exec $CONTAINER python3 -c \"import urllib.request; urllib.request.urlopen('https://example.com')\""
    fi
}

cmd_off() {
    check_root "off"

    if ! rules_exist; then
        info "No firewall rules found — nothing to remove."
        return 0
    fi

    remove_rules
    echo ""
    info "Firewall OFF — internet restored for ${CONTAINER}"
}

cmd_status() {
    echo -e "${BOLD}ComfyUI Firewall Status${NC}"
    echo ""

    # Container state
    if docker inspect "$CONTAINER" &>/dev/null; then
        local ip
        ip=$(docker inspect "$CONTAINER" \
            -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
            2>/dev/null | head -1)
        info "Container '${CONTAINER}' is running (IP: ${ip})"
    else
        warn "Container '${CONTAINER}' is not running."
    fi

    # Firewall state (needs root to read iptables)
    if ! iptables -S DOCKER-USER &>/dev/null; then
        warn "Cannot read iptables (try: sudo $0 status)"
        return 0
    fi

    if rules_exist; then
        echo -e "  Firewall: ${GREEN}ON${NC} — internet blocked"
        echo ""
        echo "  Active rules in DOCKER-USER chain:"
        iptables -S DOCKER-USER | grep "$TAG" | while IFS= read -r rule; do
            echo "    $rule"
        done
    else
        echo -e "  Firewall: ${YELLOW}OFF${NC} — internet accessible"
    fi
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    on)     cmd_on ;;
    off)    cmd_off ;;
    status) cmd_status ;;
    *)
        cat <<EOF
Usage: sudo $0 {on|off|status}

Block internet access for the ComfyUI Docker container while keeping
the browser UI working. Only affects the '${CONTAINER}' container.

Commands:
  on      Block internet (browser UI keeps working)
  off     Remove the block (restore internet)
  status  Show current state

Examples:
  docker compose up -d              # Start ComfyUI
  sudo $0 on                        # Block internet
  sudo $0 status                    # Check state
  sudo $0 off                       # Restore internet

Note: Rules do not survive a reboot. Run 'on' again after restarting.
EOF
        exit 1
        ;;
esac
