#!/usr/bin/env python3
"""Validate .env — report required and conditionally required variables."""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Models that typically require a Hugging Face token (gated / license agreement).
GATED_VLLM_MODEL_PREFIXES: tuple[str, ...] = (
    "meta-llama/",
    "meta-llama",
    "google/gemma-2",
    "mistralai/Mistral",
)

HF_PLACEHOLDERS = frozenset({"", "hf_your_token_here"})
NGROK_TOKEN_PLACEHOLDERS = frozenset({"", "your_ngrok_authtoken"})
NGROK_DOMAIN_PLACEHOLDERS = frozenset({"", "your-name.ngrok-free.app"})


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def litellm_placeholder(value: str) -> bool:
    return value in ("", "sk-replace-me-with-a-strong-random-value", "sk-llmstack-local") or value.startswith(
        "sk-replace-me"
    )


def grafana_placeholder(value: str) -> bool:
    return value in ("", "replace-me-with-a-strong-password", "admin") or value.startswith("replace-me")


def hf_missing(env: dict[str, str]) -> bool:
    return env.get("HF_TOKEN", "") in HF_PLACEHOLDERS


def ngrok_token_missing(env: dict[str, str]) -> bool:
    return env.get("NGROK_AUTHTOKEN", "") in NGROK_TOKEN_PLACEHOLDERS


def ngrok_domain_missing(env: dict[str, str]) -> bool:
    return env.get("NGROK_DOMAIN", "") in NGROK_DOMAIN_PLACEHOLDERS


def model_likely_gated(model: str) -> bool:
    normalized = model.strip().lower()
    return any(normalized.startswith(p.lower()) for p in GATED_VLLM_MODEL_PREFIXES)


def profiles_include_ngrok() -> bool:
    raw = os.environ.get("COMPOSE_PROFILES", "")
    return "ngrok" in [p.strip() for p in raw.replace(",", " ").split() if p.strip()]


def main() -> int:
    quiet = os.environ.get("QUIET") == "1"
    backend = os.environ.get("BACKEND", "nvidia")
    path = Path(".env")

    if not path.exists():
        print("ERROR: .env not found — run: make config", file=sys.stderr)
        return 1

    env = load_env(path)
    errors: list[str] = []
    warnings: list[str] = []
    notes: list[str] = []

    # ── Always required (docker compose enforces these too) ─────────────────
    if litellm_placeholder(env.get("LITELLM_MASTER_KEY", "")):
        errors.append(
            "LITELLM_MASTER_KEY — missing or placeholder. Run: make config"
        )
    if grafana_placeholder(env.get("GRAFANA_ADMIN_PASSWORD", "")):
        errors.append(
            "GRAFANA_ADMIN_PASSWORD — missing or placeholder. Run: make config"
        )

    # ── ngrok profile (COMPOSE_PROFILES=ngrok) ─────────────────────────────
    if profiles_include_ngrok():
        if ngrok_token_missing(env):
            errors.append(
                "NGROK_AUTHTOKEN — required for ngrok. "
                "Add to .env, then: COMPOSE_PROFILES=ngrok make up  (or: make up-ngrok)"
            )
        if ngrok_domain_missing(env):
            errors.append(
                "NGROK_DOMAIN — required for ngrok (e.g. your-name.ngrok-free.app). "
                "Add to .env with NGROK_AUTHTOKEN"
            )
    else:
        if ngrok_token_missing(env) and ngrok_domain_missing(env):
            notes.append(
                "NGROK_AUTHTOKEN, NGROK_DOMAIN — not set (OK). "
                "Only needed for: make up-ngrok"
            )
        elif ngrok_token_missing(env) or ngrok_domain_missing(env):
            warnings.append(
                "NGROK — partially set. Both NGROK_AUTHTOKEN and NGROK_DOMAIN "
                "are required together for: make up-ngrok"
            )

    # ── Hugging Face token (NVIDIA / model download) ───────────────────────
    if backend == "nvidia":
        vllm_model = env.get("VLLM_MODEL", "")
        if hf_missing(env):
            if model_likely_gated(vllm_model):
                errors.append(
                    f"HF_TOKEN — required for gated model VLLM_MODEL={vllm_model}. "
                    "Add to .env: HF_TOKEN=hf_..."
                )
            else:
                notes.append(
                    "HF_TOKEN — not set (OK for most public models). "
                    "Required if vLLM cannot download VLLM_MODEL (gated/private on Hugging Face)"
                )
        elif env.get("HF_TOKEN", "") in HF_PLACEHOLDERS:
            pass  # unreachable
        else:
            if not quiet:
                notes.append("HF_TOKEN — set")

    def emit(title: str, items: list[str], stream) -> None:
        if not items:
            return
        if not quiet or stream is sys.stderr:
            print(title)
            for item in items:
                print(f"  • {item}")
            print()

    if errors:
        emit("Missing required .env values:", errors, sys.stderr)
    if warnings:
        emit("Warnings:", warnings, sys.stderr)
    if notes and not quiet:
        emit("Optional / conditional:", notes, sys.stdout)

    if errors:
        print("Fix .env then re-run. See .env.example for variable names.", file=sys.stderr)
        return 1

    if not quiet and not warnings and not notes:
        print("✓ .env looks good for current settings.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
