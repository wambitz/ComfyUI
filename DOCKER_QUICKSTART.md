# ComfyUI Docker Quickstart — A Beginner's Tutorial

> **Prerequisites you already have:**
> NVIDIA GPU (RTX 4090) · Docker · Docker Compose · NVIDIA Container Toolkit

This guide walks you through running ComfyUI inside Docker, step by step. Every
command is explained so you understand *what* it does and *why*.

---

## What Are We Doing and Why?

ComfyUI is a web application that runs on your machine. You open it in your
browser, build a visual workflow (like connecting boxes together), and it
generates images using AI models.

The problem: AI models and third-party plugins can run **arbitrary code** on your
computer. If you download a poisoned model file, it could steal your files, install
malware, or worse.

**Docker** solves this by running ComfyUI inside a container — think of it as a
lightweight virtual machine. The container:

- Has its own filesystem (can't see your personal files)
- Can be **cut off from the internet** (via a firewall rule — see Step 4)
- Can only access folders you explicitly share with it (called "volumes")
- If something goes wrong, you just delete the container — your host is untouched

---

## Step 1: Understand the Files We Created

Three files were added to your ComfyUI folder. Here's what each one does:

### `Dockerfile` — The Recipe

This is like a recipe that tells Docker how to build an **image** (a snapshot of
a mini operating system with ComfyUI installed). Key parts:

```
FROM python:3.11-slim
```
↑ Start with the official Python 3.11 slim image (~124 MB). PyTorch's pip
package ships with CUDA built in, so we don't need a heavy NVIDIA base image.

```
RUN useradd -m -s /bin/bash comfyuser
```
↑ Create a non-root user. ComfyUI will run as this user, not as `root`. If
something malicious runs, it has fewer permissions.

```
RUN pip install --no-cache-dir -r requirements.txt
```
↑ Install PyTorch (the AI framework) and all ComfyUI dependencies. PyTorch's
pip package includes CUDA support automatically.

```
USER comfyuser
```
↑ Switch to the non-root user from this point on.

```
CMD ["python3", "main.py", "--listen", "0.0.0.0",
     "--disable-all-custom-nodes", "--disable-api-nodes"]
```
↑ The default command when the container starts. The flags:
- `--listen 0.0.0.0` → Listen on all interfaces **inside the container** (this
  is safe because Docker controls what's exposed to the host).
- `--disable-all-custom-nodes` → Don't load any third-party plugins.
- `--disable-api-nodes` → Block the frontend from making internet requests.

### `.dockerignore` — What NOT to Copy

When Docker builds the image, it copies your project files into it. This file
tells it to skip things like `models/`, `output/`, `.git/`, etc. We don't want
multi-gigabyte model files baked into the image — we'll mount them separately.

### `docker-compose.yml` — The Run Configuration

Instead of typing a long `docker run ...` command every time, this file describes
*how* to run the container. Think of it as a saved configuration.

---

## Step 2: Download a Safe Model

Before we build anything, we need an AI model. **This is the most important
security decision you'll make.**

### What's a "model" and why does the format matter?

A model is a large file containing the "brain" (neural network weights) that
generates images. There are two common formats:

| Format | Extension | Safe? | Why |
|--------|-----------|-------|-----|
| **Safetensors** | `.safetensors` | ✅ Yes | Pure data — just numbers. Cannot execute code. |
| **Pickle/Checkpoint** | `.ckpt`, `.pt`, `.pth` | ❌ No | Can contain hidden Python code that runs when loaded. |

> **Rule: Only download `.safetensors` files. Ever.**

### Which model should we use?

For this tutorial, we'll use **Stable Diffusion 1.5** (SD 1.5). It's:
- Small (~2 GB vs 6+ GB for SDXL)
- Fast on your RTX 4090
- Perfect for a hello-world test

**Download it from Hugging Face** (a trusted model hosting site):

```bash
# Navigate to your models folder
cd /media/jcastillo/ssd990/Workspace/AI/ComfyUI/models/checkpoints

# Download the official SD 1.5 model in safetensors format
# (this is from Runway, the original creators — a trusted source)
wget -O sd_v1-5.safetensors \
  "https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors"
```

> **What just happened?**
> `wget` downloaded a ~4 GB file from Hugging Face. The `-O` flag renames it
> so it's easy to identify. The `.safetensors` extension means it's the safe
> format — just tensor data, no executable code.

You can verify the file looks right:

```bash
ls -lh /media/jcastillo/ssd990/Workspace/AI/ComfyUI/models/checkpoints/
# Should show: sd_v1-5.safetensors  ~4.0G
```

---

## Step 3: Build the Docker Image

Now let's build the image from the `Dockerfile`.

```bash
cd /media/jcastillo/ssd990/Workspace/AI/ComfyUI
docker compose build
```

> **What just happened?**
> Docker read the `Dockerfile`, executed each instruction (set up Python,
> install PyTorch and dependencies...), and saved the result as an **image** — a
> frozen snapshot. Code is mounted at runtime, not copied into the image. This
> takes 5–15 minutes the first time because it's downloading and installing
> everything. Subsequent builds are fast because Docker **caches** unchanged
> layers.

You can verify the image was created:

```bash
docker images | grep comfyui
```

---

## Step 4: Block Internet Access

The `docker-compose.yml` maps port `8188` so the browser UI works. But in this
mode the container **can also reach the internet** — a malicious model or custom
node could phone home.

We fix this with a firewall script: `scripts/comfyui-firewall.sh`. It adds an
iptables rule that blocks **only** the ComfyUI container from making outbound
connections, while still letting your browser reach the UI. Other Docker
containers on your machine are not affected.

### How it works (plain English)

When your browser opens `http://127.0.0.1:8188`, the traffic travels over
Docker's internal bridge — it never leaves your machine. When the container tries
to reach the internet, the traffic must go through your real network interface.

The firewall script tells Linux: "allow responses from the ComfyUI container to
connections **we** started (the browser), but drop any **new** outbound
connections the container tries to make (the internet)."

- ✅ `http://127.0.0.1:8188` keeps working (your browser → ComfyUI)
- ✅ Other Docker containers are untouched
- ❌ ComfyUI container cannot reach the internet

### Usage

```bash
# 1. Start ComfyUI first
docker compose up -d

# 2. Block internet (requires sudo because iptables needs root)
sudo ./scripts/comfyui-firewall.sh on

# 3. Verify
sudo ./scripts/comfyui-firewall.sh status
```

> **What does `127.0.0.1:8188:8188` mean?**
> `host_ip:host_port:container_port`
> - `127.0.0.1` → Only bind to localhost (your machine). No one on your
>   Wi-Fi/LAN can reach it.
> - First `8188` → The port on your machine.
> - Second `8188` → The port inside the container.
>
> So `http://127.0.0.1:8188` on your browser → goes to port 8188 inside the
> container → reaches ComfyUI.

> **Note:** The firewall rules don't survive a reboot (iptables is ephemeral).
> Run `sudo ./scripts/comfyui-firewall.sh on` again after restarting your
> machine.

---

## Step 5: Start the Container

```bash
cd /media/jcastillo/ssd990/Workspace/AI/ComfyUI
docker compose up
```

> **What just happened?**
> Docker Compose:
> 1. Created a container from the image you built.
> 2. Mounted your `models/` folder (read-only), `input/` folder (read-only), and
>    `output/` folder (writable) into the container.
> 3. Gave the container access to your GPU.
> 4. Started ComfyUI with the safe flags.
>
> You should see log output ending with something like:
> ```
> Starting server
> To see the GUI go to: http://0.0.0.0:8188
> ```

Now open your browser and go to:

```
http://127.0.0.1:8188
```

You should see the ComfyUI interface — a visual node editor.

> **Tip:** Use `docker compose up -d` (with `-d`) to run in the background.
> Then check logs with `docker compose logs -f`. Stop with `docker compose down`.

---

## Step 6: Generate Your First Image (Hello World!)

When ComfyUI opens, it loads a **default workflow** — a pre-built pipeline with
boxes (nodes) already connected. Here's what each node in the default workflow does:

```
┌─────────────────┐     ┌──────────────┐     ┌────────────┐
│ Load Checkpoint  │────▶│  KSampler    │────▶│ VAE Decode  │──▶ Save Image
│ (loads the model)│     │ (generates)  │     │ (to pixels) │
└─────────────────┘     └──────────────┘     └────────────┘
        ▲                      ▲
        │                      │
┌───────┴─────────┐    ┌──────┴───────┐
│ CLIP Text Encode │    │ Empty Latent  │
│ (your prompt)    │    │ (canvas size) │
└─────────────────┘    └──────────────┘
```

**Follow these steps:**

1. **Select the model:** Click on the "Load Checkpoint" node. In the dropdown,
   select `sd_v1-5.safetensors` (the file you downloaded).

2. **Type a prompt:** Click on the "CLIP Text Encode" node connected to the
   **positive** input. Replace the text with something like:

   ```
   a beautiful sunset over mountains, digital art, highly detailed
   ```

3. **Set a negative prompt:** Click the other "CLIP Text Encode" node (connected
   to the **negative** input). Type what you *don't* want:

   ```
   blurry, low quality, deformed
   ```

4. **Click "Queue Prompt"** (the button at the bottom of the panel, or on the
   sidebar).

5. **Wait a few seconds.** With your RTX 4090, SD 1.5 should generate in under
   5 seconds. The image appears in the "Save Image" node and is also saved to
   your `output/` folder on the host.

> **What just happened behind the scenes?**
>
> 1. ComfyUI loaded `sd_v1-5.safetensors` from `/app/models` inside the
>    container (which is actually your host's `models/` folder, mounted read-only).
> 2. Your prompt was encoded into numbers using the CLIP text encoder (part of
>    the model).
> 3. The KSampler started with random noise and iteratively "denoised" it,
>    guided by your prompt, over 20 steps.
> 4. The VAE decoder converted the internal representation into actual pixel
>    colors.
> 5. The result was saved to `/app/output` inside the container (which is your
>    host's `output/` folder).

Check the generated image on your host:

```bash
ls -lt /media/jcastillo/ssd990/Workspace/AI/ComfyUI/output/ | head -5
```

🎉 **Congratulations — you just generated your first image safely inside Docker!**

---

## Step 7: Stop and Clean Up

Press `Ctrl+C` in the terminal where `docker compose up` is running, or:

```bash
docker compose down
```

> This stops and removes the container. Your images in `output/` and your models
> are safe — they live on your host, not inside the container.

---

## Step 8: Day-to-Day Workflow

Now that you've confirmed everything works, here's your daily routine:

```bash
# Start ComfyUI
docker compose up -d

# Block internet (do this every time — rules don't survive reboots)
sudo ./scripts/comfyui-firewall.sh on

# Open browser → http://127.0.0.1:8188
# Generate images!

# When you're done:
docker compose down
# (firewall rules are automatically removed when the container stops)
```

If you ever need the container to reach the internet temporarily (e.g., debugging):

```bash
sudo ./scripts/comfyui-firewall.sh off     # restore internet
# ... do what you need ...
sudo ./scripts/comfyui-firewall.sh on      # block it again
```

---

## Cheat Sheet

| Task | Command |
|------|---------|
| Build the image | `docker compose build` |
| Start ComfyUI | `docker compose up` |
| Start in background | `docker compose up -d` |
| View logs | `docker compose logs -f` |
| Stop | `docker compose down` |
| Enter the container | `docker exec -it comfyui-secure bash` |
| Check GPU inside container | `docker exec comfyui-secure nvidia-smi` |
| Rebuild after code changes | `docker compose up --build` |
| Block internet | `sudo ./scripts/comfyui-firewall.sh on` |
| Restore internet | `sudo ./scripts/comfyui-firewall.sh off` |
| Check firewall status | `sudo ./scripts/comfyui-firewall.sh status` |

---

## What's Next?

- **More models:** Download other `.safetensors` models into `models/checkpoints/`.
  They'll appear in the "Load Checkpoint" dropdown automatically (restart the
  container to pick them up).
- **LoRAs:** Small style add-ons go in `models/loras/`. Same rule — `.safetensors`
  only.
- **Custom nodes (advanced):** If you *need* a custom node, audit its code first,
  then add `--whitelist-custom-nodes node-folder-name` to the command in
  `docker-compose.yml`. See `SECURITY.md` for the full policy.
- **Save workflows:** Use File → Export in the ComfyUI UI. Workflows are JSON
  files — they're safe to share and don't contain model weights.

---

## Glossary

| Term | Meaning |
|------|---------|
| **Image (Docker)** | A frozen snapshot of an OS + application. Like a template. |
| **Container** | A running instance of an image. Like a lightweight VM. |
| **Volume / Mount** | A folder on your host shared with the container. |
| **Safetensors** | A safe file format for AI model weights. No code, just numbers. |
| **Pickle / .ckpt** | An older, unsafe format that can contain hidden executable code. |
| **CLIP** | The text encoder that turns your prompt into numbers the AI understands. |
| **VAE** | Variational Auto-Encoder — converts between pixel space and the AI's internal "latent" space. |
| **KSampler** | The node that runs the diffusion process (iterative denoising). |
| **Latent space** | A compressed mathematical representation of images that the AI works in. |
| **CSP** | Content Security Policy — browser-level rules that restrict what a web page can do. |
| **CSRF** | Cross-Site Request Forgery — an attack where a malicious site tricks your browser into making requests to localhost. |
