# ==============================================================================
# ComfyUI – Secure Docker Image
# Base: Official Python 3.11 slim image (Debian-based, minimal)
# ==============================================================================
FROM python:3.11-slim

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Application setup
# ---------------------------------------------------------------------------
WORKDIR /app

# Copy dependency files and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Code will be mounted at runtime — no COPY . . needed
# This keeps the image small and avoids rebuilds on code changes

# Create non-root user and set ownership of workdir
RUN useradd -m -s /bin/bash comfyuser \
    && chown -R comfyuser:comfyuser /app

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
USER comfyuser

EXPOSE 8188

# Safe defaults:
#   --listen 0.0.0.0       → accessible inside container (Docker port mapping controls host exposure)
#   --disable-all-custom-nodes → no third-party code
#   --disable-api-nodes    → activates CSP, blocks internet from the frontend
CMD ["python3", "main.py", \
     "--listen", "0.0.0.0", \
     "--disable-all-custom-nodes", \
     "--disable-api-nodes"]
