#!/usr/bin/env python3
"""Parked 2026-08-23 from Cruz-Engineering/social-media-automation's playground/generate.py.

That repo went cloud-only and deleted this script's three dependencies
(comfyui_client.py, image_client.py, the old config.py shape) from `main`.
Nothing is lost though -- the full working set (this script + all three
deps + the custom nodes it used) is preserved at tag `comfyui-final` /
branch `archive/comfyui` in that repo. Pull those from there rather than
reimplementing the HTTP client from scratch.

Not wired into this ComfyUI checkout yet -- refactor into scripts/, a
custom node, or fold into whatever workflow replaces it. This file is a
reminder so the code and the prompt/negative-prompt text aren't lost, not
a working entry point as-is.

Original docstring below.
"""

"""Minimal single-image generator via ComfyUI.

Usage:
    python playground/generate.py                  # uses prompt.txt, falls back to DEFAULT_PROMPT
    python playground/generate.py "your prompt"    # uses inline prompt
"""

import dataclasses
import sys
from pathlib import Path

# Allow imports from project root
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import comfyui_client  # noqa: E402
from comfyui_client import generate_image  # noqa: E402
from config import load_settings, setup_logging  # noqa: E402
from image_client import start_image_backend, stop_image_backend  # noqa: E402

# Remove NSFW restrictions from negative prompt for playground use
comfyui_client.COMFY_NEGATIVE_PROMPT = (
    "blurry, low quality, ugly, deformed, text, watermark, logo, oversaturated, cartoon, "
    "bad anatomy, bad hands, extra fingers, missing fingers, mutated hands, poorly drawn face, "
    "mutation, worst quality, jpeg artifacts, bad face, distorted face, disfigured, "
    "malformed limbs, fused fingers, too many fingers, cloned face, poorly drawn eyes, "
    "crossed eyes, lazy eye, double chin, asymmetrical face, out of focus, grainy"
)

DEFAULT_PROMPT = (
    "fashion advertisement photo, beautiful woman wearing a stylish bikini, "
    "standing on a tropical beach at golden hour, soft warm sunlight, "
    "ocean waves in the background, professional studio lighting, "
    "high-end fashion magazine editorial, confident natural pose, "
    "flawless skin, sharp focus, shallow depth of field, "
    "shot on Canon EOS R5 85mm f/1.4, 8k uhd, photorealistic"
)


PROMPT_FILE = Path(__file__).parent / "prompt.txt"
OUTPUT_FILE = Path(__file__).parent / "output.png"


def main() -> None:
    setup_logging(verbose=True)
    # Force comfyui as image provider regardless of .env
    settings = dataclasses.replace(load_settings(), image_provider="comfyui")

    # Prompt: CLI arg > prompt.txt > DEFAULT_PROMPT
    if len(sys.argv) > 1:
        prompt = " ".join(sys.argv[1:])
    elif PROMPT_FILE.exists():
        prompt = PROMPT_FILE.read_text().strip()
    else:
        prompt = DEFAULT_PROMPT

    print(f"\nPrompt: {prompt}\n")

    auto_started = start_image_backend(settings)
    try:
        img = generate_image(prompt, 0, settings)
        if img is None:
            print("Generation failed - check logs above.")
            sys.exit(1)

        img.save(OUTPUT_FILE)
        print(f"Saved to {OUTPUT_FILE}")
    finally:
        if auto_started:
            stop_image_backend(settings)


if __name__ == "__main__":
    main()
