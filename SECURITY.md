# ComfyUI Security Guide

> **Applies to:** ComfyUI v0.13.0 · Last updated: February 2026

This document provides a security audit of ComfyUI's built-in protections and a
practical guide for running the application safely—especially on a workstation
that doubles as your primary machine.

---

## Table of Contents

1. [Security Architecture Overview](#1-security-architecture-overview)
2. [Built-In Security Mechanisms](#2-built-in-security-mechanisms)
   - 2.1 [Network Binding & Exposure](#21-network-binding--exposure)
   - 2.2 [CSRF / Origin Protection](#22-csrf--origin-protection)
   - 2.3 [Content Security Policy](#23-content-security-policy)
   - 2.4 [TLS / SSL Support](#24-tls--ssl-support)
   - 2.5 [Path Traversal Defenses](#25-path-traversal-defenses)
   - 2.6 [MIME-Type Enforcement](#26-mime-type-enforcement)
   - 2.7 [Model Loading Safety (Safetensors & Pickle)](#27-model-loading-safety)
   - 2.8 [Hook Breaker (Custom Node Integrity)](#28-hook-breaker)
   - 2.9 [Sensitive Data Handling](#29-sensitive-data-handling)
   - 2.10 [Telemetry Opt-Out](#210-telemetry-opt-out)
3. [Known Gaps & Limitations](#3-known-gaps--limitations)
4. [Running ComfyUI Safely](#4-running-comfyui-safely)
   - 4.1 [Recommended CLI Flags](#41-recommended-cli-flags)
   - 4.2 [Model File Hygiene](#42-model-file-hygiene)
   - 4.3 [Custom Node Policy](#43-custom-node-policy)
   - 4.4 [Docker Isolation (Recommended)](#44-docker-isolation-recommended)
   - 4.5 [Network Hardening](#45-network-hardening)
   - 4.6 [Runtime Environment](#46-runtime-environment)
5. [Quick-Reference Checklist](#5-quick-reference-checklist)

---

## 1. Security Architecture Overview

ComfyUI is a localhost-first application. By default it binds to `127.0.0.1`,
has no authentication system, and relies on a combination of origin checking,
content-security policies, and safe model-loading strategies to reduce the
attack surface. The three primary risk vectors are:

| # | Vector | Severity | Mitigation |
|---|--------|----------|------------|
| 1 | **Malicious model files** (pickle-based `.ckpt`/`.pt`) | Critical | Safetensors format; PyTorch ≥ 2.4 `weights_only` loading |
| 2 | **Untrusted custom nodes** (arbitrary Python) | Critical | `--disable-all-custom-nodes`; `--whitelist-custom-nodes` |
| 3 | **Network exposure** (no auth) | High | Localhost-only binding; CSRF middleware; Docker isolation |

---

## 2. Built-In Security Mechanisms

### 2.1 Network Binding & Exposure

| Setting | Default | Effect |
|---------|---------|--------|
| `--listen` (no argument) | `127.0.0.1` | **Loopback only** — not reachable from the network |
| `--listen` (passed without value) | `0.0.0.0,::` | Opens on **all interfaces** — every device on the network can reach it |
| `--port` | `8188` | Unprivileged port |
| `--max-upload-size` | `100` MB | Caps file-upload payloads |

> **Source:** `comfy/cli_args.py`, lines 39–46.

### 2.2 CSRF / Origin Protection

When the `--enable-cors-header` flag is **not** used (the default), ComfyUI
registers an *origin-only middleware* that compares the `Host` and `Origin`
headers on every request. If the host resolves to a loopback address and the
origin domain does not match, the server returns **HTTP 403**.

This prevents the most common browser-based CSRF attack where a malicious
website issues a `POST` to `http://127.0.0.1:8188` to silently queue a
workflow.

> **Source:** `server.py`, `create_origin_only_middleware()`, lines 147–175.

### 2.3 Content Security Policy

When `--disable-api-nodes` is passed, a middleware injects the following CSP
header on every response:

```
default-src 'self';
script-src  'self' 'unsafe-inline' 'unsafe-eval' blob:;
style-src   'self' 'unsafe-inline';
img-src     'self' data: blob:;
font-src    'self';
connect-src 'self' data:;
frame-src   'self';
object-src  'self';
```

This effectively **sandboxes the frontend**, preventing it from loading external
scripts, connecting to third-party servers, or exfiltrating data over the
network.

> **Source:** `server.py`, `create_block_external_middleware()`, lines 177–189.

### 2.4 TLS / SSL Support

ComfyUI supports HTTPS via two flags:

```
--tls-keyfile  /path/to/key.pem
--tls-certfile /path/to/cert.pem
```

The TLS context uses `ssl.Purpose.CLIENT_AUTH` with certificate verification
disabled (`check_hostname = False`, `verify_mode = CERT_NONE`). This provides
**encryption in transit** but not mutual authentication.

> **Note:** Self-signed certificates are suitable for local use only and should
> not be used in any shared or production deployment.

### 2.5 Path Traversal Defenses

File-serving endpoints (`/view`, `/upload/mask`) explicitly guard against
directory traversal:

- Reject filenames starting with `/` or containing `..`.
- Validate subfolder paths with `os.path.commonpath()` to ensure they do not
  escape the designated output directory (returns HTTP 403 on violation).

> **Source:** `server.py`, lines 442–455 and 486–499.

### 2.6 MIME-Type Enforcement

When serving user-uploaded files via the `/view` endpoint, potentially dangerous
MIME types are force-converted to `application/octet-stream` to trigger a
download instead of in-browser rendering:

- `text/html`
- `text/html-sandboxed`
- `application/xhtml+xml`
- `text/javascript`
- `text/css`

This mitigates stored XSS attacks through crafted file uploads.

> **Source:** `server.py`, lines 563–568.

### 2.7 Model Loading Safety

ComfyUI implements a **multi-layered defense** against malicious model files:

| Layer | Condition | Behavior |
|-------|-----------|----------|
| **Safetensors** | File ends in `.safetensors` or `.sft` | Loaded via the `safetensors` library — **no code execution possible** |
| **PyTorch ≥ 2.4** | `torch.serialization.add_safe_globals` exists | Uses `torch.load(..., weights_only=True)` with a minimal allowlist of safe globals (`ModelCheckpoint`, `numpy.scalar`, `numpy.dtype`, `Float64DType`, `_codecs.encode`). The global `ALWAYS_SAFE_LOAD` flag is set to `True`. |
| **PyTorch < 2.4** (fallback) | `add_safe_globals` unavailable | Falls back to `comfy.checkpoint_pickle.Unpickler`, which replaces all `pytorch_lightning` classes with an empty stub. Logs a warning: *"loading {} unsafely, upgrade your pytorch to 2.4 or newer"*. |

All 15+ internal model loaders (checkpoints, LoRA, ControlNet, upscale models,
style models, hypernetworks, etc.) pass `safe_load=True` to `load_torch_file`.

> **Source:** `comfy/utils.py`, lines 41–57 and 110–155;
> `comfy/checkpoint_pickle.py`.

### 2.8 Hook Breaker

`hook_breaker_ac10a0.py` is an integrity mechanism that prevents custom nodes
from permanently monkey-patching critical internal functions:

```python
HOOK_BREAK = [(comfy.model_management, "cast_to")]
```

- **`save_functions()`** is called *before* custom nodes are loaded, capturing
  the original implementation.
- **`restore_functions()`** is called *after* loading and again after each
  prompt execution, restoring the originals.

The obfuscated filename (`ac10a0` suffix) makes it harder for malicious nodes to
target or disable this module.

> **Source:** `hook_breaker_ac10a0.py`; `main.py`, lines 399–404.

### 2.9 Sensitive Data Handling

API tokens (`auth_token_comfy_org`, `api_key_comfy_org`) are classified as
sensitive and are:

- **Stripped** from queue items before being returned by any `/queue` endpoint.
- **Stripped** from prompt history after execution.
- Only injected into the execution context at runtime, never persisted in
  visible queue or history data.

> **Source:** `server.py`, `_remove_sensitive_from_queue()`, lines 54–55;
> queue/history endpoints at lines 789–863.

### 2.10 Telemetry Opt-Out

At startup, ComfyUI sets:

```python
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
os.environ['DO_NOT_TRACK'] = '1'
```

This disables Hugging Face Hub telemetry and any library that honors the
`DO_NOT_TRACK` convention.

> **Source:** `main.py`, lines 23–24.

---

## 3. Known Gaps & Limitations

| Gap | Risk | Notes |
|-----|------|-------|
| **No authentication** | Anyone who can reach the port can queue workflows, read outputs, and upload files. | The origin-only middleware is the sole CSRF mitigation—no password, API key, or session system exists. |
| **No rate limiting** | Denial-of-service via request flooding. | No built-in throttle on any endpoint. |
| **Pickle still possible** | On PyTorch < 2.4, the fallback `Unpickler` only blocks `pytorch_lightning`—other arbitrary-code vectors in pickle remain. | Upgrade to PyTorch ≥ 2.4 to eliminate this. |
| **CSP allows `unsafe-inline` / `unsafe-eval`** | Weakens XSS protection even when CSP is active. | Required for the frontend's current architecture. |
| **Hook breaker is narrow** | Only `model_management.cast_to` is protected; custom nodes can patch any other function. | Treat all custom nodes as untrusted code. |
| **No client certificate verification** | TLS provides encryption only, not mutual authentication. | Acceptable for localhost; insufficient for remote access. |

---

## 4. Running ComfyUI Safely

### 4.1 Recommended CLI Flags

**Minimal safe launch (core features only):**

```bash
python main.py \
  --disable-all-custom-nodes \
  --disable-api-nodes \
  --preview-method none
```

| Flag | Purpose |
|------|---------|
| `--disable-all-custom-nodes` | Blocks all custom node code — the primary arbitrary-code-execution surface |
| `--disable-api-nodes` | Disables API nodes **and** activates the strict Content-Security-Policy that prevents the frontend from accessing the internet |
| `--preview-method none` | Disables latent preview generation, reducing the processing surface |

**If you need specific custom nodes you trust:**

```bash
python main.py \
  --disable-all-custom-nodes \
  --whitelist-custom-nodes my-trusted-node another-trusted-node \
  --disable-api-nodes
```

**Flags to avoid on a workstation:**

| Flag | Why |
|------|-----|
| `--listen` | Opens the server to all network interfaces with no authentication |
| `--enable-cors-header` | Disables CSRF protection, allowing any website to POST workflows |
| `--enable-manager` | The manager can install arbitrary custom nodes at runtime |

### 4.2 Model File Hygiene

This is the **single most important practice**. Pickle-based model files
(`.ckpt`, `.pt`, `.pth`, `.bin`) can execute arbitrary Python code when loaded.

**Rules:**

1. **Use `.safetensors` exclusively.** This format is a pure tensor serialization
   with no code-execution capability.
2. **Never download `.ckpt`/`.pt` files from untrusted sources.** Even with
   PyTorch ≥ 2.4 safe loading, edge cases may exist.
3. **Download models only from reputable sources:** Hugging Face (verified
   repositories), Civitai (check uploader reputation), or the model author's
   official release.
4. **Verify file integrity.** ComfyUI defaults to `sha256` hashing
   (`--default-hashing-function sha256`). Compare hashes against the source
   when available.

### 4.3 Custom Node Policy

Custom nodes are Python packages that run with **full system privileges**. There
is no sandbox, no permission system, and no capability restriction.

| Risk Level | Policy |
|------------|--------|
| **Maximum safety** | `--disable-all-custom-nodes` — use only built-in nodes |
| **Moderate safety** | `--whitelist-custom-nodes` with individually audited nodes |
| **Minimum safety** | Default loading of all nodes in `custom_nodes/` (not recommended on a primary workstation) |

**Before installing any custom node:**

- Read its source code, especially `__init__.py` and any `prestartup_script.py`.
- Check the repository's star count, issue tracker, and recent commit activity.
- Look for obvious red flags: network calls, file-system writes outside the
  ComfyUI directory, `subprocess` calls, or obfuscated code.

### 4.4 Docker Isolation (Recommended)

Running ComfyUI inside a container provides the strongest isolation for a
workstation. Even if a malicious model or custom node achieves code execution,
the damage is confined to a disposable container.

**Example `docker run` command:**

```bash
docker run -d \
  --name comfyui-secure \
  --gpus all \
  -p 127.0.0.1:8188:8188 \
  -v /path/to/your/models:/app/models:ro \
  -v /path/to/your/input:/app/input:ro \
  -v /path/to/your/output:/app/output \
  your-comfyui-image \
  python main.py --disable-all-custom-nodes --disable-api-nodes
```

| Docker Flag | Purpose |
|-------------|---------|
| `-p 127.0.0.1:8188:8188` | Binds the port to **localhost only** — browser UI works |
| `-v ...models:ro` | Models mounted **read-only** — malicious code cannot modify them |
| `-v ...input:ro` | Input directory also read-only |
| `-v ...output` | Output directory is writable for generated images |
| `--gpus all` | GPU passthrough via the NVIDIA Container Toolkit |

> **Blocking internet while keeping the UI:** Docker's `--network none` disables
> *all* networking — including the bridge that connects your browser to the
> container. You cannot use `--network none` and `-p` together. Instead, use
> `scripts/comfyui-firewall.sh` to add an iptables rule that blocks only outbound
> internet while keeping the Docker bridge (and the UI) working. See
> `DOCKER_QUICKSTART.md` Step 4 for details.

**Example `Dockerfile`:**

```dockerfile
FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN useradd -m comfyuser && chown -R comfyuser:comfyuser /app
USER comfyuser

EXPOSE 8188
CMD ["python3", "main.py", "--listen", "0.0.0.0", "--disable-all-custom-nodes", "--disable-api-nodes"]
```

> **Note:** Inside the container, `--listen 0.0.0.0` is safe because the host's
> `-p 127.0.0.1:8188:8188` restricts external access. Use the firewall script
> (`scripts/comfyui-firewall.sh on`) to block outbound internet.

### 4.5 Network Hardening

If you cannot use Docker and must run bare-metal:

1. **Never pass `--listen` without a firewall rule.** If you must expose ComfyUI
   (e.g., to another machine on your LAN), place it behind a reverse proxy with
   authentication (e.g., Nginx + Basic Auth, Caddy + OAuth2, or Tailscale).

2. **Use TLS for any non-localhost access:**

   ```bash
   # Generate a self-signed certificate (local use only)
   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem \
     -sha256 -days 365 -nodes -subj '/CN=localhost'

   python main.py --tls-keyfile key.pem --tls-certfile cert.pem
   ```

3. **Do not enable CORS.** The default origin-only middleware provides CSRF
   protection. Passing `--enable-cors-header` disables it entirely.

4. **Firewall rule (UFW example):**

   ```bash
   # Deny all incoming to 8188 by default
   sudo ufw deny in on any to any port 8188

   # Allow only from a specific trusted IP if needed
   sudo ufw allow from 192.168.1.100 to any port 8188
   ```

### 4.6 Runtime Environment

| Requirement | Reason |
|-------------|--------|
| **PyTorch ≥ 2.4** | Enables `weights_only=True` loading with `add_safe_globals`. Older versions fall back to an incomplete pickle unpickler. |
| **Python ≥ 3.10** (3.12+ recommended) | Older Python versions have known security vulnerabilities. ComfyUI logs a warning below 3.10. |
| **Non-root user** | Never run ComfyUI as root. If compromised, a non-root process limits the blast radius. |
| **Virtual environment** | Isolate ComfyUI's dependencies from your system Python. |
| **Keep dependencies updated** | Run `pip install --upgrade -r requirements.txt` periodically to pick up security patches in PyTorch, aiohttp, Pillow, and safetensors. |

---

## 5. Quick-Reference Checklist

| # | Action | Priority |
|---|--------|----------|
| 1 | Use `.safetensors` models exclusively | 🔴 Critical |
| 2 | Pass `--disable-all-custom-nodes` (or whitelist only audited ones) | 🔴 Critical |
| 3 | Keep PyTorch ≥ 2.4 | 🔴 Critical |
| 4 | Run inside Docker with read-only model mounts + firewall script | 🟠 Strongly recommended |
| 5 | Never pass `--listen` without a reverse proxy + authentication | 🟠 Strongly recommended |
| 6 | Pass `--disable-api-nodes` to activate CSP and block internet access | 🟡 Recommended |
| 7 | Do not use `--enable-cors-header` | 🟡 Recommended |
| 8 | Do not use `--enable-manager` | 🟡 Recommended |
| 9 | Run as a non-root user inside a virtual environment | 🟡 Recommended |
| 10 | Keep all dependencies updated | 🟡 Recommended |
| 11 | Use TLS if any non-localhost access is required | 🔵 Situational |
| 12 | Apply firewall rules to port 8188 | 🔵 Situational |

---

*This document was generated from a source-level audit of ComfyUI v0.13.0. For
updates, review the referenced source files whenever you upgrade ComfyUI.*
