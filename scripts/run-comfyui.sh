#!/bin/bash
# ==============================================================================
# ComfyUI Docker Run Script
# This does exactly what `docker compose up` does, but with explicit arguments.
# It's a learning tool — see comments on every flag.
#
# To block internet:  sudo ./scripts/comfyui-firewall.sh on
# To restore internet: sudo ./scripts/comfyui-firewall.sh off
# ==============================================================================

set -euo pipefail

# Get the directory where ComfyUI lives (parent of scripts/)
COMFYUI_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Must match container_name in docker-compose.yml
CONTAINER="comfyui-secure"

echo "=== ComfyUI Docker Launcher ==="
echo "ComfyUI directory: $COMFYUI_DIR"
echo ""

# ---------------------------------------------------------------------------
# Build the image (if needed)
# ---------------------------------------------------------------------------
# Same as: docker compose build
#
# -t comfyui          → name the image "comfyui"
# -f Dockerfile       → use this Dockerfile
# $COMFYUI_DIR        → build context (where to look for files)

echo "Building image..."
docker build \
    -t comfyui-secure \
    -f "$COMFYUI_DIR/Dockerfile" \
    "$COMFYUI_DIR"

echo ""
echo "Starting container..."

# ---------------------------------------------------------------------------
# Run the container
# ---------------------------------------------------------------------------
# This is what `docker compose up` translates to:

echo "Browser UI will be at: http://127.0.0.1:8188"
echo "To block internet:     sudo ./scripts/comfyui-firewall.sh on"
echo ""

docker run \
    --rm \
    --name "$CONTAINER" \
    \
    `# ── GPU Access ──` \
    --gpus all \
    \
    `# ── Port Mapping ──` \
    `# 127.0.0.1 = localhost only. Use the firewall script to block internet.` \
    -p 127.0.0.1:8188:8188 \
    \
    `# ── Bind Mounts ──` \
    `# Format: -v host_path:container_path:options` \
    `# :ro = read-only (container cannot modify these files)` \
    `# No :ro = read-write (container can create/modify files)` \
    \
    `# Mount ALL code as read-only (so you get updates without rebuilding)` \
    -v "$COMFYUI_DIR:/app:ro" \
    \
    `# Mount models as read-only (malicious code can't tamper with them)` \
    -v "$COMFYUI_DIR/models:/app/models:ro" \
    \
    `# Mount input as read-only` \
    -v "$COMFYUI_DIR/input:/app/input:ro" \
    \
    `# Mount output as read-write (so ComfyUI can save generated images)` \
    -v "$COMFYUI_DIR/output:/app/output" \
    \
    `# Mount temp as read-write (for intermediate files)` \
    -v "$COMFYUI_DIR/temp:/app/temp" \
    \
    `# Mount user data as read-write (ComfyUI stores settings here)` \
    -v "$COMFYUI_DIR/user:/app/user" \
    \
    `# ── Image to run ──` \
    comfyui-secure \
    \
    `# ── Command to execute inside container ──` \
    `# (overrides the CMD in Dockerfile)` \
    python3 main.py \
        --listen 0.0.0.0 \
        --disable-all-custom-nodes \
        --disable-api-nodes

# ==============================================================================
# What each flag means:
#
# --rm                     Remove container when it stops (clean up)
# --name comfyui-secure    Name the container (must match firewall script)
# --gpus all               Pass all GPUs to the container
# -p 127.0.0.1:8188:8188   Port mapping: localhost only can reach container
# -v host:container:ro     Bind mount (ro = read-only)
#
# ComfyUI flags:
# --listen 0.0.0.0         Listen on all interfaces INSIDE container
#                          (safe because Docker's -p restricts access)
# --disable-all-custom-nodes   Don't load any third-party code
# --disable-api-nodes      Block frontend from making internet requests
#
# To block internet while keeping the browser UI:
#   sudo ./scripts/comfyui-firewall.sh on
# ==============================================================================
